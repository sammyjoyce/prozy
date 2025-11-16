//! HTTP Proxy Implementation
//!
//! This module contains the main HTTP proxy server with support for:
//! - TCP connection forwarding with bidirectional data flow
//! - HTTP response caching with LRU eviction
//! - Load balancing across multiple backends
//! - Access control and rate limiting
//! - Statistics tracking and monitoring

const std = @import("std");
const builtin = @import("builtin");

const log = std.log;
const mem = std.mem;
const Io = std.Io;
const net = Io.net;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Timeout = Io.Timeout;
const Duration = Io.Duration;

// Import core modules
const ProxyStats = @import("../core/stats.zig").ProxyStats;
const AccessControl = @import("../core/access_control.zig").AccessControl;
const RateLimiter = @import("../core/rate_limiter.zig").RateLimiter;
const LoadBalancer = @import("../core/load_balancer.zig").LoadBalancer;
const Backend = @import("../core/backend.zig").Backend;
const IpKey = @import("../core/ip_key.zig").IpKey;

// Import HTTP modules
const HTTPCache = @import("../http/cache.zig").HTTPCache;
const HTTPInspector = @import("../http/inspector.zig").HTTPInspector;

// Import TCP modules
const tcp_copy = @import("../tcp/copy.zig");
const BIDIRECTIONAL_TIMEOUT_SECONDS = tcp_copy.BIDIRECTIONAL_TIMEOUT_SECONDS;
const PipeJob = tcp_copy.PipeJob;
const CopyError = tcp_copy.CopyError;
const PipeJobWithStats = tcp_copy.PipeJobWithStats;

// Import proxy configuration
const proxy_core = @import("proxy_core.zig");
const RunOptions = proxy_core.RunOptions;

/// Main HTTP Proxy server implementation
pub const HttpProxy = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    proxy_port: u16,
    backend_host: []const u8,
    backend_port: u16,

    // Core proxy features
    stats: ProxyStats,
    access_control: ?AccessControl = null,
    rate_limiter: ?RateLimiter = null,
    http_inspector: HTTPInspector,
    http_cache: ?HTTPCache = null,
    load_balancer: ?LoadBalancer = null,

    pub fn init(allocator: std.mem.Allocator, proxy_port: u16, backend_host: []const u8, backend_port: u16) Self {
        return Self{
            .allocator = allocator,
            .proxy_port = proxy_port,
            .backend_host = backend_host,
            .backend_port = backend_port,
            .stats = ProxyStats.init(),
            .http_inspector = HTTPInspector.init(true, true, "Prozy/1.0"),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.access_control) |*acl| {
            acl.deinit();
        }
        if (self.rate_limiter) |*limiter| {
            limiter.deinit();
        }
        if (self.http_cache) |*cache| {
            cache.deinit();
        }
    }

    /// Enable access control with default policy
    pub fn enableAccessControl(self: *Self, default_policy: AccessControl.Policy) !void {
        self.access_control = try AccessControl.init(self.allocator, default_policy);
    }

    /// Enable rate limiting
    pub fn enableRateLimiting(self: *Self, max_per_ip: u32, max_global: u32) void {
        self.rate_limiter = RateLimiter.init(self.allocator, max_per_ip, max_global);
    }

    /// Enable HTTP caching for performance optimization
    pub fn enableCaching(self: *Self, max_cache_size: usize) void {
        self.http_cache = HTTPCache.init(self.allocator, max_cache_size);
    }

    /// Enable load balancing with multiple backends
    pub fn enableLoadBalancing(self: *Self, backends: []Backend, strategy: LoadBalancer.Strategy) void {
        self.load_balancer = LoadBalancer.init(backends, strategy);
    }

    /// Get current statistics snapshot
    pub fn getStats(self: *const Self) ProxyStats.StatsSnapshot {
        return self.stats.getStats();
    }

    /// Get cache statistics if caching is enabled
    pub fn getCacheStats(self: *const Self) ?HTTPCache.CacheStats {
        if (self.http_cache) |*cache| {
            return cache.getStats();
        }
        return null;
    }

    /// Print statistics to stdout
    pub fn printStats(self: *const Self) void {
        const stats = self.getStats();
        log.info("=== Proxy Statistics ===", .{});
        log.info("Active connections: {}", .{stats.active_connections});
        log.info("Total connections: {}", .{stats.total_connections});
        log.info("Client→Backend bytes: {}", .{stats.total_bytes_client_to_backend});
        log.info("Backend→Client bytes: {}", .{stats.total_bytes_backend_to_client});
        log.info("Total errors: {}", .{stats.total_errors});
        log.info("Backend failures: {}", .{stats.backend_connect_failures});

        if (self.getCacheStats()) |cache_stats| {
            log.info("", .{});
            log.info("=== Cache Statistics ===", .{});
            log.info("Cache hits: {}", .{cache_stats.hits});
            log.info("Cache misses: {}", .{cache_stats.misses});
            log.info("Hit rate: {d:.2}%", .{cache_stats.hitRate()});
            log.info("Cache size: {} / {} bytes", .{ cache_stats.current_size, cache_stats.max_size });
            log.info("Cache entries: {}", .{cache_stats.entry_count});
        }
    }

    pub fn run(self: *Self) !void {
        var threaded_io = std.Io.Threaded.init(self.allocator);
        defer threaded_io.deinit();
        return self.runWithIoOptions(threaded_io.io(), .{});
    }

    pub fn runWithOptions(self: *Self, options: RunOptions) !void {
        var threaded_io = std.Io.Threaded.init(self.allocator);
        defer threaded_io.deinit();
        return self.runWithIoOptions(threaded_io.io(), options);
    }

    pub fn runWithIo(self: *Self, io: Io) !void {
        return self.runWithIoOptions(io, .{});
    }

    pub fn runWithIoOptions(self: *Self, io: Io, options: RunOptions) !void {
        const configured_limit = options.max_connections orelse if (builtin.is_test)
            0
        else
            std.math.maxInt(usize);

        if (configured_limit == 0) {
            self.printArchitectureSummary();
            return;
        }

        const listen_addr = try resolveListenAddress(options.listen_host, self.proxy_port);
        var server = try listen_addr.listen(io, .{ .reuse_address = options.reuse_address });
        defer server.deinit(io);

        log.info("proxy listening on {any}", .{server.socket.address});
        log.info("backend target: {s}:{}", .{ self.backend_host, self.backend_port });
        log.info("waiting to accept connections (limit: {})", .{configured_limit});

        if (options.enable_stats) {
            log.info("statistics tracking: ENABLED", .{});
        }
        if (options.enable_access_control) {
            log.info("access control: ENABLED", .{});
        }
        if (options.enable_rate_limiting) {
            log.info("rate limiting: ENABLED", .{});
        }
        if (options.enable_http_inspection) {
            log.info("HTTP inspection: ENABLED", .{});
        }
        if (options.enable_caching) {
            log.info("HTTP caching: ENABLED", .{});
        }
        if (options.enable_load_balancing) {
            if (self.load_balancer) |*lb| {
                log.info("load balancing: ENABLED ({} backends, strategy: {})", .{ lb.backends.len, lb.strategy });
            }
        }

        var connection_group: std.Io.Group = .init;
        defer connection_group.wait(io);

        var accepted: usize = 0;
        while (accepted < configured_limit) {
            log.info("calling server.accept() [accepted={}/{}]", .{ accepted, configured_limit });
            const client_stream = server.accept(io) catch |err| {
                log.err("accept failed: {s}", .{@errorName(err)});
                continue;
            };

            // Extract client IP for access control and rate limiting
            const client_ip = extractClientIp(client_stream.socket.address);

            // Check access control
            if (options.enable_access_control) {
                if (self.access_control) |acl| {
                    if (!acl.isAllowed(client_ip)) {
                        log.warn("connection from {any} denied by access control", .{client_ip});
                        client_stream.close(io);
                        continue;
                    }
                }
            }

            // Check rate limiting
            if (options.enable_rate_limiting) {
                if (self.rate_limiter) |*limiter| {
                    if (!limiter.tryAcquire(client_ip)) {
                        log.warn("connection from {any} denied by rate limiter", .{client_ip});
                        client_stream.close(io);
                        continue;
                    }
                }
            }

            // Only increment accepted counter after all validation passes
            accepted += 1;
            log.info("accepted connection #{} from {any}", .{ accepted, client_ip });

            if (options.enable_stats) {
                self.stats.recordConnection();
            }

            _ = connection_group.async(io, handleClientWithFeatures, .{
                client_stream,
                io,
                self.backend_host,
                self.backend_port,
                options.connect_timeout,
                @as(*ProxyStats, @constCast(&self.stats)),
                &self.http_inspector,
                options,
                client_ip,
                if (self.rate_limiter) |*limiter| limiter else null,
                if (self.load_balancer) |*lb| lb else null,
                if (self.http_cache) |*cache| cache else null,
                self.allocator,
            });
        }

        // Print final statistics
        if (options.enable_stats and !builtin.is_test) {
            self.printStats();
        }
    }

    /// Extract client IP address as IpKey for rate limiting and access control
    /// FIXED: Now returns IpKey to prevent IPv6 hash collisions
    /// Previous implementation hashed IPv6 to u32, causing potential collisions
    fn extractClientIp(address: net.IpAddress) IpKey {
        return IpKey.fromAddress(address);
    }

    fn printArchitectureSummary(self: Self) void {
        if (builtin.is_test) return;

        std.debug.print("Prozy TCP Proxy Architecture:\n", .{});
        std.debug.print("==============================\n", .{});
        std.debug.print("Proxy port: {}\n", .{self.proxy_port});
        std.debug.print("Backend target: {s}:{}\n", .{ self.backend_host, self.backend_port });

        std.debug.print("\nCore Implementation Patterns:\n", .{});
        std.debug.print("1. Server listener: accept incoming connections\n", .{});
        std.debug.print("2. Dedicated concurrent task per client via io.concurrent()\n", .{});
        std.debug.print("3. Backend connection: resolve + connect\n", .{});
        std.debug.print("4. Bidirectional copy with io.select()\n", .{});

        std.debug.print("\nAsync Primitives Demonstrated:\n", .{});
        std.debug.print("- std.Io.Threaded for a managed worker pool\n", .{});
        std.debug.print("- Io.Group for lifecycle management\n", .{});
        std.debug.print("- io.concurrent + io.select for duplex pipes\n", .{});
        std.debug.print("- Reader/Writer interfaces with buffering\n", .{});
    }

    fn resolveListenAddress(host: []const u8, port: u16) !net.IpAddress {
        if (net.Ip4Address.parse(host, port)) |ip4| {
            return .{ .ip4 = ip4 };
        } else |_| {}

        if (net.Ip6Address.parse(host, port)) |ip6| {
            return .{ .ip6 = ip6 };
        } else |_| {}

        if (host.len == 0 or mem.eql(u8, host, "*") or mem.eql(u8, host, "0.0.0.0")) {
            return .{ .ip4 = net.Ip4Address.unspecified(port) };
        }

        return .{ .ip4 = net.Ip4Address.loopback(port) };
    }

    fn handleClient(
        client_stream: net.Stream,
        io: Io,
        backend_host: []const u8,
        backend_port: u16,
        connect_timeout: Timeout,
    ) void {
        defer client_stream.close(io);

        if (!builtin.is_test) {
            log.info("handling new client connection", .{});
        }

        if (!builtin.is_test) log.info("connecting to backend {s}:{}", .{ backend_host, backend_port });
        const backend_stream = connectToBackend(io, backend_host, backend_port, connect_timeout) catch |err| {
            log.err("backend connect failed: {s}", .{@errorName(err)});
            return;
        };
        defer backend_stream.close(io);

        if (!builtin.is_test) {
            log.info("connected to backend {s}:{}", .{ backend_host, backend_port });
        }

        if (!builtin.is_test) log.info("setting up readers and writers", .{});
        var client_read_buf: [4096]u8 = undefined;
        var backend_read_buf: [4096]u8 = undefined;
        var client_write_buf: [4096]u8 = undefined;
        var backend_write_buf: [4096]u8 = undefined;

        var client_reader = client_stream.reader(io, &client_read_buf);
        var backend_reader = backend_stream.reader(io, &backend_read_buf);
        var client_writer = client_stream.writer(io, &client_write_buf);
        var backend_writer = backend_stream.writer(io, &backend_write_buf);

        if (!builtin.is_test) log.info("starting bidirectional copy", .{});
        tcp_copy.copyBidirectional(
            io,
            &client_reader.interface,
            &backend_writer.interface,
            &backend_reader.interface,
            &client_writer.interface,
        );
        if (!builtin.is_test) log.info("bidirectional copy completed", .{});
    }
};

fn handleClientWithFeatures(
    client_stream: net.Stream,
    io: Io,
    backend_host: []const u8,
    backend_port: u16,
    connect_timeout: Timeout,
    stats: *ProxyStats,
    http_inspector: *const HTTPInspector,
    options: RunOptions,
    client_ip: IpKey,
    rate_limiter: ?*RateLimiter,
    load_balancer: ?*LoadBalancer,
    http_cache: ?*HTTPCache,
    _: std.mem.Allocator,
) void {
    const start_time = if (options.enable_connection_logging) std.time.Instant.now() catch null else null;
    var selected_backend: ?*Backend = null;

    // Track buffered request data that must be forwarded after cache miss
    var request_buffer: [8192]u8 = undefined;
    var buffered_request_size: usize = 0;

    defer {
        client_stream.close(io);
        if (options.enable_stats) {
            stats.recordConnectionEnd();
        }
        if (options.enable_rate_limiting) {
            if (rate_limiter) |limiter| {
                limiter.release(client_ip);
            }
        }
        if (selected_backend) |backend| {
            backend.decrementConnections();
        }
    }

    if (options.enable_connection_logging and !builtin.is_test) {
        log.info("new connection from client", .{});
    }

    // Try to use HTTP cache if enabled
    if (options.enable_caching and http_cache != null) {
        // Buffer initial request to check cache
        var client_read_buf: [4096]u8 = undefined;
        var client_reader = client_stream.reader(io, &client_read_buf);

        // Read first chunk of request
        var slices = [_][]u8{request_buffer[0..]};
        const bytes_read = client_reader.interface.readVec(&slices) catch 0;
        buffered_request_size = bytes_read;

        if (bytes_read > 0) {
            // Try to parse HTTP request
            if (HTTPInspector.parseRequestLine(request_buffer[0..bytes_read])) |request| {
                // Extract Host header for cache key (multi-tenant isolation)
                // SECURITY: Requests without Host header are NOT cached to prevent
                // cache pollution across different virtual hosts/APIs
                const maybe_host = HTTPInspector.findHeader(request_buffer[0..bytes_read], "Host");

                // Only cache GET requests WITH valid Host header
                if (std.mem.eql(u8, request.method, "GET")) {
                    if (maybe_host) |host| {
                        // Host header present - check cache
                        if (http_cache.?.get(request.method, host, request.path)) |cached_response| {
                            // IMPORTANT: get() returns an owned copy that we must free
                            defer http_cache.?.allocator.free(cached_response);

                            // Cache hit! Send cached response directly
                            if (!builtin.is_test) {
                                log.info("cache HIT for GET {s} Host: {s}", .{ request.path, host });
                            }

                            var client_write_buf: [4096]u8 = undefined;
                            var client_writer = client_stream.writer(io, &client_write_buf);

                            Writer.writeAll(&client_writer.interface, cached_response) catch |err| {
                                log.warn("failed to write cached response: {s}", .{@errorName(err)});
                                return;
                            };
                            Writer.flush(&client_writer.interface) catch {};

                            if (options.enable_stats) {
                                stats.recordBytesBackendToClient(@intCast(cached_response.len));
                            }
                            return;
                        }

                        // Cache miss - log and proceed to forward request
                        if (!builtin.is_test) {
                            log.info("cache MISS for GET {s} Host: {s}", .{ request.path, host });
                        }
                    } else {
                        // Missing Host header - skip caching for security
                        if (!builtin.is_test) {
                            log.warn("cache SKIPPED for GET {s} - missing Host header (HTTP/1.1 violation)", .{request.path});
                        }
                        // Request will still be forwarded to backend, just not cached
                    }
                }
            }
        }
    }

    // Select backend (use load balancer if enabled)
    var actual_backend_host = backend_host;
    var actual_backend_port = backend_port;

    if (options.enable_load_balancing) {
        if (load_balancer) |lb| {
            if (lb.selectBackend(client_ip)) |backend| {
                selected_backend = backend;
                actual_backend_host = backend.host;
                actual_backend_port = backend.port;
                backend.incrementConnections();
                if (!builtin.is_test) {
                    log.info("selected backend: {s}:{}", .{ actual_backend_host, actual_backend_port });
                }
            } else {
                log.err("no healthy backend available", .{});
                if (options.enable_stats) {
                    stats.recordBackendFailure();
                    stats.recordError();
                }
                return;
            }
        }
    }

    // Connect to backend
    const backend_stream = connectToBackend(io, actual_backend_host, actual_backend_port, connect_timeout) catch |err| {
        log.err("backend connect failed: {s}", .{@errorName(err)});
        if (options.enable_stats) {
            stats.recordBackendFailure();
            stats.recordError();
        }
        if (selected_backend) |backend| {
            backend.markHealthy(false);
            if (!builtin.is_test) {
                log.warn("marked backend {s}:{} as unhealthy", .{ backend.host, backend.port });
            }
        }
        return;
    };
    defer backend_stream.close(io);

    // Connection succeeded - mark backend as healthy (recovery mechanism)
    if (selected_backend) |backend| {
        if (!backend.isHealthy()) {
            backend.markHealthy(true);
            if (!builtin.is_test) {
                log.info("backend {s}:{} recovered to healthy state", .{ backend.host, backend.port });
            }
        }
    }

    if (options.enable_connection_logging and !builtin.is_test) {
        log.info("[{any}] connected to backend {s}:{}", .{ start_time, actual_backend_host, actual_backend_port });
    }

    // Set up buffered readers and writers
    var client_read_buf: [4096]u8 = undefined;
    var backend_read_buf: [4096]u8 = undefined;
    var client_write_buf: [4096]u8 = undefined;
    var backend_write_buf: [4096]u8 = undefined;

    var client_reader = client_stream.reader(io, &client_read_buf);
    var backend_reader = backend_stream.reader(io, &backend_read_buf);
    var client_writer = client_stream.writer(io, &client_write_buf);
    var backend_writer = backend_stream.writer(io, &backend_write_buf);

    // Forward any buffered request data from cache check before bidirectional copy
    if (buffered_request_size > 0) {
        forwardBufferedData(&backend_writer.interface, request_buffer[0..buffered_request_size]) catch |err| {
            log.err("failed to forward buffered data: {s}", .{@errorName(err)});
            if (options.enable_stats) {
                stats.recordError();
            }
            return;
        };
        if (options.enable_stats) {
            stats.recordBytesClientToBackend(@intCast(buffered_request_size));
        }
    }

    // Start bidirectional copy with statistics tracking
    tcp_copy.copyBidirectionalWithStats(
        io,
        &client_reader.interface,
        &backend_writer.interface,
        &backend_reader.interface,
        &client_writer.interface,
        stats,
        http_inspector,
        options,
    );

    if (options.enable_connection_logging and !builtin.is_test and start_time != null) {
        if (std.time.Instant.now()) |end_time| {
            const duration_ns = end_time.since(start_time.?);
            const duration_ms = duration_ns / std.time.ns_per_ms;
            log.info("connection completed, duration: {}ms", .{duration_ms});
        } else |_| {
            log.info("connection completed", .{});
        }
    }
}

fn forwardBufferedData(writer: *Writer, buffered_data: []const u8) !void {
    // Precondition: buffered_data must be non-empty and within bounds
    if (buffered_data.len == 0) return;
    if (buffered_data.len > 8192) return error.BufferTooLarge;

    // Write all buffered data to backend
    Writer.writeAll(writer, buffered_data) catch |err| {
        log.warn("failed to forward buffered request data: {s}", .{@errorName(err)});
        return err;
    };

    // Flush to ensure data is sent immediately
    Writer.flush(writer) catch |err| {
        log.warn("failed to flush buffered request data: {s}", .{@errorName(err)});
        return err;
    };
}

fn connectToBackend(io: Io, host: []const u8, port: u16, timeout: Timeout) !net.Stream {
    if (net.Ip4Address.parse(host, port)) |ip4| {
        return (net.IpAddress{ .ip4 = ip4 }).connect(io, .{ .mode = .stream, .timeout = timeout });
    } else |_| {}

    if (net.Ip6Address.parse(host, port)) |ip6| {
        return (net.IpAddress{ .ip6 = ip6 }).connect(io, .{ .mode = .stream, .timeout = timeout });
    } else |_| {}

    const host_name = try net.HostName.init(host);
    return host_name.connect(io, port, .{ .mode = .stream, .timeout = timeout });
}
