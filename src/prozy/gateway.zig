const std = @import("std");
const tls = @import("tls.zig");
const translation = @import("translation.zig");
const config = @import("config.zig");

const Io = std.Io;
const net = Io.net;
const http = std.http;

pub const Gateway = struct {
    allocator: std.mem.Allocator,
    config: *const config.Config,
    tls_provider: tls.TlsProvider,
    translation_engine: translation.TranslationEngine,

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config) !Gateway {
        return Gateway{
            .allocator = allocator,
            .config = cfg,
            .tls_provider = try tls.TlsProvider.init(allocator),
            .translation_engine = try translation.TranslationEngine.init(allocator, cfg),
        };
    }

    pub fn deinit(self: *Gateway) void {
        self.tls_provider.deinit();
        self.translation_engine.deinit();
    }

    pub fn run(self: *Gateway, io: Io) !void {
        const listen_addr = try net.IpAddress.parse(self.config.proxy.listen_host, self.config.proxy.listen_port);
        var server = try listen_addr.listen(io, .{ .reuse_address = true });
        defer server.deinit(io);

        var tls_server = try self.tls_provider.wrapServer(io, &server);
        defer tls_server.deinit(io);

        std.log.info("✅ Gateway listening on {s}:{d} with TLS", .{ self.config.proxy.listen_host, self.config.proxy.listen_port });

        var connection_group: std.Io.Group = .init;
        defer connection_group.wait(io);

        while (true) {
            const client_stream = try tls_server.accept(io);
            _ = connection_group.async(io, handleRequest, .{ self, client_stream, io, self.allocator });
        }
    }

    fn handleRequest(self: *Gateway, client_stream: net.Stream, io: Io, allocator: std.mem.Allocator) void {
        defer client_stream.close(io);

        var server_header = http.ServerHeader.init(.{});
        http.Server.serveConnection(client_stream, io, &server_header, handleHttp, .{ .allocator = allocator, .gateway = self }) catch |err| {
             std.log.warn("Failed to serve connection: {any}", .{err});
        };
    }

    fn handleHttp(conn: *http.Server.Connection, data: anytype) !void {
        const allocator = data.allocator;
        const self: *Gateway = data.gateway;

        while (try conn.beginRequest()) {
            const body = try conn.reader().readAllAlloc(allocator, 1 * 1024 * 1024); // 1MB limit
            defer allocator.free(body);

            // Observability: log request details
            const request_hash = std.hash.XxHash64.hash(0, body);
            std.log.info("Received request (hash: {x}, size: {d} bytes)", .{request_hash, body.len});

            try conn.response.headers.append("Content-Type", "text/event-stream");
            try conn.response.headers.append("Connection", "close");
            try conn.response.setStatus(.ok);
            try conn.response.send();

            const start_time = std.time.Instant.now() catch 0;

            try self.translation_engine.translate_stream(body, conn.writer());

            const duration_ns = if (start_time == 0) 0 else (std.time.Instant.now() catch 0) - start_time;
            std.log.info("Finished request (hash: {x}, duration: {d}ms)", .{request_hash, duration_ns / 1_000_000});

            conn.response.finish() catch {};
        }
    }
};
