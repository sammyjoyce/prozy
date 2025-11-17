//! Admin Server: HTTP server for observability and management
//!
//! Provides endpoints for:
//! - /metrics - Prometheus-style metrics
//! - /health - Health check endpoint
//! - /backends - JSON backend status
//! - /routes - Current routing table (if router configured)
//! - /auth/stats - Authentication statistics (if auth enabled)

const std = @import("std");
const builtin = @import("builtin");
const log = std.log;
const mem = std.mem;
const Io = std.Io;
const net = Io.net;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Timeout = Io.Timeout;

const ProxyStats = @import("stats.zig").ProxyStats;
const LoadBalancer = @import("backend.zig").LoadBalancer;
const Router = @import("router.zig").Router;
const ProxyAuth = @import("auth.zig").ProxyAuth;

pub const AdminServer = struct {
    allocator: mem.Allocator,
    listen_port: u16,
    listen_host: []const u8,
    stats: *const ProxyStats,
    load_balancer: ?*const LoadBalancer,
    router: ?*const Router,
    proxy_auth: ?*const ProxyAuth,

    pub fn init(
        allocator: mem.Allocator,
        listen_port: u16,
        listen_host: []const u8,
        stats: *const ProxyStats,
        load_balancer: ?*const LoadBalancer,
        router: ?*const Router,
        proxy_auth: ?*const ProxyAuth,
    ) AdminServer {
        return .{
            .allocator = allocator,
            .listen_port = listen_port,
            .listen_host = listen_host,
            .stats = stats,
            .load_balancer = load_balancer,
            .router = router,
            .proxy_auth = proxy_auth,
        };
    }

    pub fn run(self: *AdminServer, io: Io) !void {
        const address = try net.Address.parse(self.listen_host, self.listen_port);
        const listener = try net.Listener.bind(io, address, .{});
        defer listener.close(io);

        if (!builtin.is_test) {
            log.info("admin server listening on {s}:{}", .{ self.listen_host, self.listen_port });
        }

        var connection_group = Io.Group.init(io);
        defer connection_group.wait();

        while (true) {
            const client_stream = listener.accept(io) catch |err| {
                log.err("admin server accept failed: {s}", .{@errorName(err)});
                continue;
            };

            connection_group.async(io, handleRequest, .{
                client_stream,
                io,
                self,
            }) catch |err| switch (err) {
                error.ConcurrencyUnavailable => {
                    // Fallback: handle synchronously if no concurrency available
                    handleRequest(client_stream, io, self);
                },
            };
        }
    }

    fn handleRequest(
        client_stream: net.Stream,
        io: Io,
        admin_server: *const AdminServer,
    ) void {
        defer client_stream.close(io);

        // Read request
        var read_buf: [4096]u8 = undefined;
        var reader = client_stream.reader(io, &read_buf);

        var request_buffer: [4096]u8 = undefined;
        var slices = [_][]u8{request_buffer[0..]};
        const bytes_read = reader.interface.readVec(&slices) catch |err| {
            log.err("admin server read failed: {s}", .{@errorName(err)});
            return;
        };

        if (bytes_read == 0) {
            return;
        }

        const request_data = request_buffer[0..bytes_read];

        // Parse HTTP request line
        const request_line_end = mem.indexOf(u8, request_data, "\r\n") orelse return;
        const request_line = request_data[0..request_line_end];

        // Extract path from "GET /path HTTP/1.1"
        var parts_iter = mem.splitScalar(u8, request_line, ' ');
        const method = parts_iter.next() orelse return;
        const path = parts_iter.next() orelse return;

        // Route to appropriate handler
        var write_buf: [16384]u8 = undefined;
        var writer = client_stream.writer(io, &write_buf);

        if (mem.eql(u8, method, "GET")) {
            if (mem.eql(u8, path, "/health")) {
                handleHealth(&writer.interface);
            } else if (mem.eql(u8, path, "/metrics")) {
                handleMetrics(&writer.interface, admin_server.stats);
            } else if (mem.eql(u8, path, "/backends")) {
                handleBackends(&writer.interface, admin_server.load_balancer);
            } else if (mem.eql(u8, path, "/routes")) {
                handleRoutes(&writer.interface, admin_server.router);
            } else if (mem.eql(u8, path, "/auth/stats")) {
                handleAuthStats(&writer.interface, admin_server.proxy_auth);
            } else {
                handle404(&writer.interface, path);
            }
        } else {
            handle405(&writer.interface, method);
        }

        _ = Writer.flush(&writer.interface) catch {};
    }

    fn handleHealth(writer: *const Io.Reader.Interface) void {
        const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"status\":\"ok\"}";
        _ = Writer.writeAll(writer, response) catch {};
    }

    fn handleMetrics(writer: *const Io.Reader.Interface, stats: *const ProxyStats) void {
        const snapshot = stats.getStats();

        var buffer: [4096]u8 = undefined;
        const body = std.fmt.bufPrint(&buffer,
            \\# HELP prozy_connections_active Current number of active connections
            \\# TYPE prozy_connections_active gauge
            \\prozy_connections_active {}
            \\
            \\# HELP prozy_connections_total Total number of connections processed
            \\# TYPE prozy_connections_total counter
            \\prozy_connections_total {}
            \\
            \\# HELP prozy_bytes_client_to_backend_total Total bytes forwarded from client to backend
            \\# TYPE prozy_bytes_client_to_backend_total counter
            \\prozy_bytes_client_to_backend_total {}
            \\
            \\# HELP prozy_bytes_backend_to_client_total Total bytes forwarded from backend to client
            \\# TYPE prozy_bytes_backend_to_client_total counter
            \\prozy_bytes_backend_to_client_total {}
            \\
            \\# HELP prozy_errors_total Total number of errors encountered
            \\# TYPE prozy_errors_total counter
            \\prozy_errors_total {}
            \\
            \\# HELP prozy_backend_failures_total Total number of backend connection failures
            \\# TYPE prozy_backend_failures_total counter
            \\prozy_backend_failures_total {}
            \\
        , .{
            snapshot.active_connections,
            snapshot.total_connections,
            snapshot.total_bytes_client_to_backend,
            snapshot.total_bytes_backend_to_client,
            snapshot.total_errors,
            snapshot.backend_connect_failures,
        }) catch "# Error formatting metrics\n";

        var header_buffer: [256]u8 = undefined;
        const headers = std.fmt.bufPrint(&header_buffer, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {}\r\n\r\n", .{body.len}) catch return;

        _ = Writer.writeAll(writer, headers) catch {};
        _ = Writer.writeAll(writer, body) catch {};
    }

    fn handleBackends(writer: *const Io.Reader.Interface, load_balancer: ?*const LoadBalancer) void {
        if (load_balancer) |lb| {
            var buffer: [8192]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buffer);
            const w = stream.writer();

            // Build JSON manually for simplicity
            w.writeAll("{\"backends\":[") catch return;

            for (lb.backends, 0..) |*backend, i| {
                if (i > 0) {
                    w.writeAll(",") catch return;
                }

                const healthy = backend.isHealthy();
                const connections = backend.getActiveConnections();
                const retry_count = backend.getRetryCount();
                const recovery_interval = backend.getRecoveryInterval();

                std.fmt.format(w,
                    \\{{"host":"{s}","port":{},"weight":{},"healthy":{},"connections":{},"retry_count":{},"recovery_interval_seconds":{}}}
                , .{
                    backend.host,
                    backend.port,
                    backend.weight,
                    healthy,
                    connections,
                    retry_count,
                    recovery_interval,
                }) catch return;
            }

            w.writeAll("]}") catch return;

            const body = stream.getWritten();

            var header_buffer: [256]u8 = undefined;
            const headers = std.fmt.bufPrint(&header_buffer, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n", .{body.len}) catch return;

            _ = Writer.writeAll(writer, headers) catch {};
            _ = Writer.writeAll(writer, body) catch {};
        } else {
            const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 17\r\n\r\n{\"backends\":null}";
            _ = Writer.writeAll(writer, response) catch {};
        }
    }

    fn handleRoutes(writer: *const Io.Reader.Interface, router: ?*const Router) void {
        if (router) |rtr| {
            var buffer: [8192]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buffer);
            const w = stream.writer();

            w.writeAll("{\"mode\":\"") catch return;
            w.writeAll(@tagName(rtr.mode)) catch return;
            w.writeAll("\",\"routes\":[") catch return;

            for (rtr.routes, 0..) |route, i| {
                if (i > 0) {
                    w.writeAll(",") catch return;
                }

                std.fmt.format(w,
                    \\{{"host":"{s}","path_prefix":"{s}","cluster":"{s}"}}
                , .{
                    route.match.host orelse "*",
                    route.match.path_prefix orelse "/",
                    route.cluster.name,
                }) catch return;
            }

            w.writeAll("]}") catch return;

            const body = stream.getWritten();

            var header_buffer: [256]u8 = undefined;
            const headers = std.fmt.bufPrint(&header_buffer, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n", .{body.len}) catch return;

            _ = Writer.writeAll(writer, headers) catch {};
            _ = Writer.writeAll(writer, body) catch {};
        } else {
            const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"routes\":null}";
            _ = Writer.writeAll(writer, response) catch {};
        }
    }

    fn handleAuthStats(writer: *const Io.Reader.Interface, proxy_auth: ?*const ProxyAuth) void {
        if (proxy_auth) |auth| {
            const snapshot = auth.getStats();

            var buffer: [2048]u8 = undefined;
            const body = std.fmt.bufPrint(&buffer, "{{\"total_auth_requests\":{},\"successful_auths\":{},\"failed_auths\":{},\"blocked_ips\":{},\"active_sessions\":{},\"success_rate\":{d:.2}}}", .{
                snapshot.total_auth_requests,
                snapshot.successful_auths,
                snapshot.failed_auths,
                snapshot.blocked_ips,
                snapshot.active_sessions,
                snapshot.success_rate,
            }) catch "# Error formatting auth stats\n";

            var header_buffer: [256]u8 = undefined;
            const headers = std.fmt.bufPrint(&header_buffer, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n", .{body.len}) catch return;

            _ = Writer.writeAll(writer, headers) catch {};
            _ = Writer.writeAll(writer, body) catch {};
        } else {
            const response = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 48\r\n\r\n{\"error\":\"Authentication not enabled on proxy\"}";
            _ = Writer.writeAll(writer, response) catch {};
        }
    }

    fn handle404(writer: *const Io.Reader.Interface, path: []const u8) void {
        _ = path;
        const response = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n\r\nNot Found";
        _ = Writer.writeAll(writer, response) catch {};
    }

    fn handle405(writer: *const Io.Reader.Interface, method: []const u8) void {
        _ = method;
        const response = "HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/plain\r\nContent-Length: 18\r\n\r\nMethod Not Allowed";
        _ = Writer.writeAll(writer, response) catch {};
    }
};

// Tests
test "AdminServer initialization" {
    const allocator = std.testing.allocator;
    var stats = ProxyStats.init();

    const admin = AdminServer.init(allocator, 9090, "127.0.0.1", &stats, null, null, null);

    try std.testing.expectEqual(@as(u16, 9090), admin.listen_port);
    try std.testing.expectEqualStrings("127.0.0.1", admin.listen_host);
}
