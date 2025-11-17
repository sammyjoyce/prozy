//! Prozy: A simple TCP proxy
//!
//! This is a production-grade async TCP proxy using Zig's new std.Io runtime.
//! It demonstrates the expected pattern from the 0.16 era async APIs: create an
//! Io executor at the edge (usually `main`), then pass it through the
//! application just like an allocator so the implementation can target
//! Threaded, io_uring, kqueue, or any future backend without code changes.
//!
//! The proxy showcases the core patterns needed:
//! - TCP socket listening and accepting with std.Io.net
//! - Bidirectional data copying coordinated via io.concurrent/io.select
//! - Structured concurrency via Io.Group and explicit cancellation
//!
//! ## Known Limitations and Assumptions
//!
//! ### Request Handling
//! - **One HTTP request per TCP connection**: The proxy assumes each TCP connection
//!   carries a single HTTP request. HTTP keep-alive and pipelining are NOT supported.
//!   Subsequent requests in the same connection will bypass cache checking and request
//!   inspection.
//!
//! ### Protocol Support
//! - **HTTP-only**: Currently designed for HTTP traffic. No TLS/SSL termination,
//!   WebSocket support, or HTTP/2.
//! - **TCP-only**: No UDP support. Adding UDP would require significant changes.
//!
//! ### Connection Handling
//! - **30-second timeout**: After one direction of a connection completes, the proxy
//!   waits up to 30 seconds for the other direction before timing out and canceling.
//!   Implemented using io.concurrent(sleep, ...) combined with io.select() for concurrent
//!   timeout enforcement. Prevents hung connections during HTTP keep-alive scenarios.
//! - **Full close only**: No TCP half-close support. Both directions are closed together.
//!
//! ### Cache Behavior
//! - **GET requests only**: Only GET requests are cached. POST/PUT/DELETE bypass cache.
//! - **Basic cacheability**: Cache does NOT respect Cache-Control, Vary, or other
//!   HTTP caching headers. All GET responses are cached with a fixed TTL.
//! - **No cache population from backend**: Currently, responses from backends are
//!   streamed directly to clients but NOT buffered and stored in the cache for future
//!   requests. This is planned for a future release.
//! - **Fixed-size buffers**: Request headers are buffered in an 8KB buffer. Headers
//!   larger than 8KB will cause cache checking to fail (request still forwarded).
//!
//! ### Load Balancing
//! - **Reactive health checks**: Backend health is determined by connection success/
//!   failure only. No proactive health checks, HTTP 5xx tracking, or timeout detection.
//! - **Connection-level routing**: Load balancing decision is made per connection,
//!   not per request (consistent with one-request-per-connection assumption).
//!
//! ### Security
//! - **No X-Forwarded-For handling**: Client IP is extracted from TCP socket only.
//!   If behind another proxy, all clients appear to come from the proxy's IP.
//! - **Trusted backend assumption**: No validation of backend responses or protection
//!   against malicious backends.
//!
//! ### Performance
//! - **Fixed buffer sizes**: 4KB client buffers, 4KB backend buffers, 8KB request buffer
//! - **Per-chunk byte counting**: Statistics are updated per 8KB chunk (atomic operations)
//! - **Approximate LRU**: Cache get() does NOT update LRU order for performance
//!   (uses lockShared instead of write lock)

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
const Clock = Io.Clock;

// Timeout configuration for bidirectional copy operations
const BIDIRECTIONAL_TIMEOUT_SECONDS: i64 = 30;

// Re-export types from other modules
const IpKey = @import("transport.zig").IpKey;
const ProxyStats = @import("stats.zig").ProxyStats;
const AccessControl = @import("access.zig").AccessControl;
const RateLimiter = @import("access.zig").RateLimiter;
const HTTPInspector = @import("http.zig").HTTPInspector;
const HTTPCache = @import("http.zig").HTTPCache;
const Backend = @import("backend.zig").Backend;
const LoadBalancer = @import("backend.zig").LoadBalancer;
const resolveListenAddress = @import("transport.zig").resolveListenAddress;
const connectToBackend = @import("transport.zig").connectToBackend;
const extractClientIp = @import("transport.zig").extractClientIp;

// Phase 3: Routing infrastructure
const Router = @import("router.zig").Router;
const HttpMode = @import("routing.zig").HttpMode;
const RoutingDecision = @import("routing.zig").RoutingDecision;

pub const RunOptions = struct {
    /// Host/interface to bind the proxy listener to. Default is loopback.
    listen_host: []const u8 = "127.0.0.1",
    /// Set a hard cap on accepted connections (useful for examples/tests).
    max_connections: ?usize = null,
    /// Allow reusing the listen socket if the process restarts quickly.
    reuse_address: bool = true,
    /// Backend dial timeout configuration (default: blocking/no timeout).
    connect_timeout: Timeout = .none,
    /// Enable statistics tracking
    enable_stats: bool = true,
    /// Enable access control (requires acl to be configured)
    enable_access_control: bool = false,
    /// Enable rate limiting (requires rate_limiter to be configured)
    enable_rate_limiting: bool = false,
    /// Enable HTTP header inspection and manipulation
    enable_http_inspection: bool = true,
    /// Enable detailed connection logging
    enable_connection_logging: bool = true,
    /// Enable HTTP response caching for performance optimization
    enable_caching: bool = true,
    /// Enable load balancing across multiple backends
    enable_load_balancing: bool = false,
};

pub const Proxy = struct {
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

    // Phase 3: Routing and lifecycle
    router: ?*Router = null,
    mode: HttpMode = .reverse_proxy,
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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

    /// Request graceful shutdown (Phase 3)
    /// This will cause the accept loop to terminate after the current iteration
    pub fn shutdown(self: *Self) void {
        self.shutdown_requested.store(true, .monotonic);
        log.info("graceful shutdown requested", .{});
    }

    /// Check if shutdown has been requested
    pub fn isShutdownRequested(self: *const Self) bool {
        return self.shutdown_requested.load(.monotonic);
    }

    /// Convenience wrapper: Creates a std.Io.Threaded runtime and runs the proxy.
    /// For production use, prefer runWithIoOptions() to pass your own Io executor.
    pub fn run(self: *Self) !void {
        var threaded_io = std.Io.Threaded.init(self.allocator);
        defer threaded_io.deinit();
        return self.runWithIoOptions(threaded_io.io(), .{});
    }

    /// Convenience wrapper: Creates a std.Io.Threaded runtime with custom options.
    /// For production use, prefer runWithIoOptions() to pass your own Io executor.
    pub fn runWithOptions(self: *Self, options: RunOptions) !void {
        var threaded_io = std.Io.Threaded.init(self.allocator);
        defer threaded_io.deinit();
        return self.runWithIoOptions(threaded_io.io(), options);
    }

    /// Convenience wrapper: Runs the proxy with a provided Io executor and default options.
    /// For custom options, use runWithIoOptions() directly.
    pub fn runWithIo(self: *Self, io: Io) !void {
        return self.runWithIoOptions(io, .{});
    }

    /// PRIMARY API: Run the proxy with a provided Io executor and custom options.
    ///
    /// This is the recommended API following Andrew Kelley's Io pattern:
    /// - Create std.Io.Threaded (or io_uring/kqueue) in main()
    /// - Pass the Io executor through your application like an allocator
    /// - This enables testing different Io backends without changing proxy code
    ///
    /// Example:
    /// ```zig
    /// var threaded_io = std.Io.Threaded.init(allocator);
    /// defer threaded_io.deinit();
    /// const io = threaded_io.io();
    ///
    /// var proxy = Proxy.init(allocator, 8080, "127.0.0.1", 3003);
    /// defer proxy.deinit();
    ///
    /// try proxy.runWithIoOptions(io, .{
    ///     .enable_caching = true,
    ///     .enable_load_balancing = true,
    /// });
    /// ```
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
        if (self.router) |router| {
            log.info("routing mode: {} ({} routes, {} clusters)", .{ router.mode, router.routes.len, router.clusters.len });
        }

        var connection_group: std.Io.Group = .init;
        defer connection_group.wait(io);

        var accepted: usize = 0;
        while (!self.isShutdownRequested() and accepted < configured_limit) {
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
                self.allocator,
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
                self.router, // Phase 3: Pass router for advanced routing
            });
        }

        // Print final statistics
        if (options.enable_stats and !builtin.is_test) {
            self.printStats();
        }
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

    /// Handle CONNECT tunnel (Phase 3)
    /// This implements HTTPS proxying by establishing a raw TCP tunnel
    ///
    /// Flow:
    /// 1. Respond with "HTTP/1.1 200 Connection Established\r\n\r\n"
    /// 2. Connect to the backend
    /// 3. Hand off to bidirectional copy for raw TCP forwarding
    ///
    /// This is used for HTTPS proxying where the client sends:
    /// CONNECT example.com:443 HTTP/1.1
    fn handleConnectTunnel(
        client_stream: net.Stream,
        io: Io,
        backend_host: []const u8,
        backend_port: u16,
        connect_timeout: Timeout,
        stats: *ProxyStats,
        http_inspector: *const HTTPInspector,
        options: RunOptions,
    ) void {
        // Note: client_stream will be closed by caller's defer, not here

        if (!builtin.is_test) {
            log.info("CONNECT tunnel to {s}:{}", .{ backend_host, backend_port });
        }

        // Send 200 Connection Established response
        const response = "HTTP/1.1 200 Connection Established\r\n\r\n";
        var client_write_buf: [4096]u8 = undefined;
        var client_writer = client_stream.writer(io, &client_write_buf);

        Writer.writeAll(&client_writer.interface, response) catch |err| {
            log.err("failed to send CONNECT response: {s}", .{@errorName(err)});
            if (options.enable_stats) {
                stats.recordError();
            }
            return;
        };
        Writer.flush(&client_writer.interface) catch |err| {
            log.err("failed to flush CONNECT response: {s}", .{@errorName(err)});
            if (options.enable_stats) {
                stats.recordError();
            }
            return;
        };

        if (!builtin.is_test) {
            log.info("sent 200 Connection Established, establishing tunnel", .{});
        }

        // Connect to backend
        const backend_stream = connectToBackend(io, backend_host, backend_port, connect_timeout) catch |err| {
            log.err("CONNECT tunnel backend connect failed: {s}", .{@errorName(err)});
            if (options.enable_stats) {
                stats.recordBackendFailure();
                stats.recordError();
            }
            return;
        };
        defer backend_stream.close(io);

        if (!builtin.is_test) {
            log.info("CONNECT tunnel established, starting bidirectional copy", .{});
        }

        // Set up buffered readers and writers for bidirectional copy
        var client_read_buf: [4096]u8 = undefined;
        var backend_read_buf: [4096]u8 = undefined;
        var backend_write_buf: [4096]u8 = undefined;

        var client_reader = client_stream.reader(io, &client_read_buf);
        var backend_reader = backend_stream.reader(io, &backend_read_buf);
        var backend_writer = backend_stream.writer(io, &backend_write_buf);

        // Reuse client_writer from above (already initialized)

        // Start bidirectional copy (raw TCP tunnel)
        copyBidirectionalWithStats(
            io,
            &client_reader.interface,
            &backend_writer.interface,
            &backend_reader.interface,
            &client_writer.interface,
            stats,
            http_inspector,
            options,
        );

        if (!builtin.is_test) {
            log.info("CONNECT tunnel closed", .{});
        }
    }

    fn handleClientWithFeatures(
        client_stream: net.Stream,
        io: Io,
        allocator: std.mem.Allocator,
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
        router: ?*Router, // Phase 3: Optional router for advanced routing
    ) void {
        const start_time = if (options.enable_connection_logging) std.time.Instant.now() catch null else null;
        var selected_backend: ?*Backend = null;
        var routing_decision: ?RoutingDecision = null; // Phase 3: Track routing decision for cleanup

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
            // Phase 3: Release cluster semaphore if using router
            if (routing_decision) |decision| {
                decision.cluster.release();
            }
        }

        if (options.enable_connection_logging and !builtin.is_test) {
            log.info("new connection from client", .{});
        }

        // Phase 3: Router-based request handling
        // Read and parse initial request for routing decision
        var parsed_request: ?HTTPInspector.HTTPRequest = null;
        var request_headers: []const u8 = &[_]u8{};

        if (router != null or options.enable_caching or options.enable_http_inspection) {
            // Buffer initial request for inspection/routing
            var client_read_buf: [4096]u8 = undefined;
            var client_reader = client_stream.reader(io, &client_read_buf);

            // Read first chunk of request
            var slices = [_][]u8{request_buffer[0..]};
            const bytes_read = client_reader.interface.readVec(&slices) catch 0;
            buffered_request_size = bytes_read;

            if (bytes_read > 0) {
                // Parse HTTP request line
                parsed_request = HTTPInspector.parseRequestLine(request_buffer[0..bytes_read]);
                request_headers = request_buffer[0..bytes_read];
            }
        }

        // Phase 3: If router is configured, use it for routing decision
        if (router) |rtr| {
            if (parsed_request) |req| {
                // Check for CONNECT method - delegate to tunnel handler
                if (std.mem.eql(u8, req.method, "CONNECT")) {
                    // Parse target from path (format: "host:port")
                    var host_port_iter = std.mem.splitScalar(u8, req.path, ':');
                    const connect_host = host_port_iter.next() orelse {
                        log.err("invalid CONNECT request path: {s}", .{req.path});
                        const error_response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 22\r\n\r\nInvalid CONNECT request";
                        var error_write_buf: [4096]u8 = undefined;
                        var error_writer = client_stream.writer(io, &error_write_buf);
                        _ = Writer.writeAll(&error_writer.interface, error_response) catch {};
                        _ = Writer.flush(&error_writer.interface) catch {};
                        return;
                    };
                    const connect_port_str = host_port_iter.next() orelse "443";
                    const connect_port = std.fmt.parseInt(u16, connect_port_str, 10) catch {
                        log.err("invalid port in CONNECT request: {s}", .{connect_port_str});
                        const error_response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 22\r\n\r\nInvalid CONNECT request";
                        var error_write_buf: [4096]u8 = undefined;
                        var error_writer = client_stream.writer(io, &error_write_buf);
                        _ = Writer.writeAll(&error_writer.interface, error_response) catch {};
                        _ = Writer.flush(&error_writer.interface) catch {};
                        return;
                    };

                    if (!builtin.is_test) {
                        log.info("CONNECT request detected for {s}:{}, delegating to tunnel handler", .{ connect_host, connect_port });
                    }
                    handleConnectTunnel(
                        client_stream,
                        io,
                        connect_host,
                        connect_port,
                        connect_timeout,
                        stats,
                        http_inspector,
                        options,
                    );
                    return;
                }

                // Route the request using the router
                const decision = rtr.routeRequest(&req, request_headers, client_ip) catch |err| {
                    log.err("routing failed: {s}", .{@errorName(err)});
                    if (options.enable_stats) {
                        stats.recordError();
                    }

                    // Send error response
                    const error_response = switch (err) {
                        error.NoRoute => "HTTP/1.1 404 Not Found\r\nContent-Length: 14\r\n\r\nNo route found",
                        error.NoHealthyBackend => "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 19\r\n\r\nNo healthy backends",
                        error.ClusterAtCapacity => "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 19\r\n\r\nCluster at capacity",
                        else => "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 13\r\n\r\nRouting error",
                    };

                    var error_write_buf: [4096]u8 = undefined;
                    var error_writer = client_stream.writer(io, &error_write_buf);
                    Writer.writeAll(&error_writer.interface, error_response) catch {};
                    Writer.flush(&error_writer.interface) catch {};
                    return;
                };

                // Store routing decision for cleanup
                routing_decision = decision;

                // Use backend from routing decision
                selected_backend = decision.backend;
                decision.backend.incrementConnections();

                if (!builtin.is_test) {
                    log.info("router selected backend: {s}:{} (cluster: {s})", .{
                        decision.backend.host,
                        decision.backend.port,
                        decision.cluster.name,
                    });
                }

                // Continue with backend connection using router's decision
                // (skip load balancer logic below)
            } else {
                log.warn("router configured but failed to parse request", .{});
                if (options.enable_stats) {
                    stats.recordError();
                }
                return;
            }
        }

        // Try to use HTTP cache if enabled (and not using router, or router allows caching)
        const cache_enabled = if (routing_decision) |decision|
            options.enable_caching and decision.cache_allowed and http_cache != null
        else
            options.enable_caching and http_cache != null;

        if (cache_enabled and http_cache != null and buffered_request_size > 0) {
            // Use already buffered request data to check cache
            // (buffered from router/inspection earlier)
            if (parsed_request) |request| {
                // Extract Host header for cache key (multi-tenant isolation)
                // SECURITY: Requests without Host header are NOT cached to prevent
                // cache pollution across different virtual hosts/APIs
                const maybe_host = HTTPInspector.findHeader(request_headers, "Host");

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

        // Select backend (use router if configured, otherwise fall back to load balancer)
        var actual_backend_host = backend_host;
        var actual_backend_port = backend_port;
        var actual_connect_timeout = connect_timeout;

        // Phase 3: If router selected a backend, use it
        if (routing_decision) |decision| {
            actual_backend_host = decision.backend.host;
            actual_backend_port = decision.backend.port;

            // Apply router's timeout policy
            const timeout_ms = decision.timeouts.connect_timeout_ms;
            actual_connect_timeout = if (timeout_ms > 0)
                Timeout{ .duration = .{
                    .raw = Duration.fromMilliseconds(@intCast(timeout_ms)),
                    .clock = .awake,
                } }
            else
                .none;

            if (!builtin.is_test) {
                log.info("using router-selected backend with timeout {}ms", .{timeout_ms});
            }
        } else if (options.enable_load_balancing) {
            // Fall back to load balancer if no router
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
        const backend_stream = connectToBackend(io, actual_backend_host, actual_backend_port, actual_connect_timeout) catch |err| {
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
            forwardBufferedData(
                &backend_writer.interface,
                request_buffer[0..buffered_request_size],
                http_inspector,
                client_ip,
                allocator,
                options.enable_http_inspection,
            ) catch |err| {
                log.err("failed to forward buffered data: {s}", .{@errorName(err)});
                if (options.enable_stats) {
                    stats.recordError();
                }
                return;
            };
            if (options.enable_stats) {
                // Note: We record the ORIGINAL buffer size, not modified size
                // The modification (adding headers) is an implementation detail
                stats.recordBytesClientToBackend(@intCast(buffered_request_size));
            }
        }

        // Start bidirectional copy with statistics tracking
        copyBidirectionalWithStats(
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

    fn forwardBufferedData(
        writer: *Writer,
        buffered_data: []const u8,
        http_inspector: *const HTTPInspector,
        client_ip: IpKey,
        allocator: std.mem.Allocator,
        enable_header_manipulation: bool,
    ) !void {
        // Precondition: buffered_data must be non-empty and within bounds
        if (buffered_data.len == 0) return;
        if (buffered_data.len > 8192) return error.BufferTooLarge;

        // If header manipulation is disabled or inspector disabled, forward as-is
        if (!enable_header_manipulation or (!http_inspector.add_forwarded_headers and !http_inspector.add_via_header)) {
            Writer.writeAll(writer, buffered_data) catch |err| {
                log.warn("failed to forward buffered request data: {s}", .{@errorName(err)});
                return err;
            };
            Writer.flush(writer) catch |err| {
                log.warn("failed to flush buffered request data: {s}", .{@errorName(err)});
                return err;
            };
            return;
        }

        // Manipulate headers: add X-Forwarded-*, Via, remove hop-by-hop headers
        const client_ip_str = client_ip.toStringAlloc(allocator) catch |err| {
            log.warn("failed to convert client IP to string: {s}, forwarding without header manipulation", .{@errorName(err)});
            Writer.writeAll(writer, buffered_data) catch {};
            Writer.flush(writer) catch {};
            return err;
        };
        defer allocator.free(client_ip_str);

        // Extract Host header for X-Forwarded-Host
        const host_header = HTTPInspector.findHeader(buffered_data, "Host");

        // Determine protocol (http or https)
        // For now, assume http (we don't terminate TLS)
        // TODO: Detect if behind TLS terminator by checking X-Forwarded-Proto from upstream
        const client_proto = "http";

        const modified_request = http_inspector.manipulateRequestHeaders(
            allocator,
            buffered_data,
            client_ip_str,
            client_proto,
            host_header,
        ) catch |err| {
            log.warn("failed to manipulate request headers: {s}, forwarding original request", .{@errorName(err)});
            Writer.writeAll(writer, buffered_data) catch {};
            Writer.flush(writer) catch {};
            return err;
        };
        defer allocator.free(modified_request);

        if (!builtin.is_test) {
            log.info("forwarding request with manipulated headers ({} -> {} bytes)", .{ buffered_data.len, modified_request.len });
        }

        // Write modified request to backend
        Writer.writeAll(writer, modified_request) catch |err| {
            log.warn("failed to forward modified request data: {s}", .{@errorName(err)});
            return err;
        };

        // Flush to ensure data is sent immediately
        Writer.flush(writer) catch |err| {
            log.warn("failed to flush modified request data: {s}", .{@errorName(err)});
            return err;
        };
    }

    const PipeJob = struct {
        reader: *Reader,
        writer: *Writer,
    };

    const CopyError = Reader.Error || Writer.Error;

    fn copyBidirectional(
        io: Io,
        client_reader: *Reader,
        backend_writer: *Writer,
        backend_reader: *Reader,
        client_writer: *Writer,
    ) void {
        const job_c2b = PipeJob{ .reader = client_reader, .writer = backend_writer };
        const job_b2c = PipeJob{ .reader = backend_reader, .writer = client_writer };

        // Simple approach: use concurrency but wait for both to complete naturally
        var future_c2b = io.concurrent(copyPipe, .{job_c2b}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                sequentialCopy(job_c2b);
                sequentialCopy(job_b2c);
                return;
            },
        };

        var future_b2c = io.concurrent(copyPipe, .{job_b2c}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                future_c2b.cancel(io) catch {};
                sequentialCopy(job_c2b);
                sequentialCopy(job_b2c);
                return;
            },
        };

        // Use io.select to wait for first completion, then wait for second without canceling
        const first_completed = io.select(.{
            .client_to_backend = &future_c2b,
            .backend_to_client = &future_b2c,
        }) catch |err| {
            log.err("io.select failed: {s}", .{@errorName(err)});
            future_c2b.cancel(io) catch {};
            future_b2c.cancel(io) catch {};
            return;
        };

        // Wait for second completion with timeout and error handling
        switch (first_completed) {
            .client_to_backend => |completion_result| {
                // Check if first direction succeeded or failed
                if (completion_result) |_| {
                    // Success: wait for backend->client with timeout
                    handleCopyResult("client->backend", completion_result);

                    // Launch timeout future
                    var timeout_future = io.concurrent(sleepForTimeout, .{ io, BIDIRECTIONAL_TIMEOUT_SECONDS }) catch |err| switch (err) {
                        error.ConcurrencyUnavailable => {
                            // Fallback: wait without timeout
                            const second_completed = io.select(.{
                                .backend_to_client = &future_b2c,
                            }) catch |err2| {
                                log.err("second io.select failed: {s}, canceling backend->client", .{@errorName(err2)});
                                future_b2c.cancel(io) catch {};
                                return;
                            };
                            switch (second_completed) {
                                .backend_to_client => |result| handleCopyResult("backend->client", result),
                            }
                            return;
                        },
                    };

                    const second_completed = io.select(.{
                        .backend_to_client = &future_b2c,
                        .timeout = &timeout_future,
                    }) catch |err| {
                        log.err("second io.select failed: {s}, canceling both futures", .{@errorName(err)});
                        future_b2c.cancel(io) catch {};
                        timeout_future.cancel(io);
                        return;
                    };

                    switch (second_completed) {
                        .backend_to_client => |result| {
                            timeout_future.cancel(io);
                            handleCopyResult("backend->client", result);
                        },
                        .timeout => {
                            log.warn("backend->client timeout after {d}s, canceling", .{BIDIRECTIONAL_TIMEOUT_SECONDS});
                            future_b2c.cancel(io) catch {};
                        },
                    }
                } else |err| {
                    // Error in client->backend: cancel backend->client immediately
                    log.err("client->backend failed: {s}, canceling backend->client", .{@errorName(err)});
                    handleCopyResult("client->backend", completion_result);
                    future_b2c.cancel(io) catch {};
                }
            },
            .backend_to_client => |completion_result| {
                // Check if first direction succeeded or failed
                if (completion_result) |_| {
                    // Success: wait for client->backend with timeout
                    handleCopyResult("backend->client", completion_result);

                    // Launch timeout future
                    var timeout_future = io.concurrent(sleepForTimeout, .{ io, BIDIRECTIONAL_TIMEOUT_SECONDS }) catch |err| switch (err) {
                        error.ConcurrencyUnavailable => {
                            // Fallback: wait without timeout
                            const second_completed = io.select(.{
                                .client_to_backend = &future_c2b,
                            }) catch |err2| {
                                log.err("second io.select failed: {s}, canceling client->backend", .{@errorName(err2)});
                                future_c2b.cancel(io) catch {};
                                return;
                            };
                            switch (second_completed) {
                                .client_to_backend => |result| handleCopyResult("client->backend", result),
                            }
                            return;
                        },
                    };

                    const second_completed = io.select(.{
                        .client_to_backend = &future_c2b,
                        .timeout = &timeout_future,
                    }) catch |err| {
                        log.err("second io.select failed: {s}, canceling both futures", .{@errorName(err)});
                        future_c2b.cancel(io) catch {};
                        timeout_future.cancel(io);
                        return;
                    };

                    switch (second_completed) {
                        .client_to_backend => |result| {
                            timeout_future.cancel(io);
                            handleCopyResult("client->backend", result);
                        },
                        .timeout => {
                            log.warn("client->backend timeout after {d}s, canceling", .{BIDIRECTIONAL_TIMEOUT_SECONDS});
                            future_c2b.cancel(io) catch {};
                        },
                    }
                } else |err| {
                    // Error in backend->client: cancel client->backend immediately
                    log.err("backend->client failed: {s}, canceling client->backend", .{@errorName(err)});
                    handleCopyResult("backend->client", completion_result);
                    future_c2b.cancel(io) catch {};
                }
            },
        }
    }

    const PipeJobWithStats = struct {
        reader: *Reader,
        writer: *Writer,
        stats: *ProxyStats,
        direction: Direction,
        http_inspector: *const HTTPInspector,
        enable_http_inspection: bool,

        const Direction = enum {
            client_to_backend,
            backend_to_client,
        };
    };

    const PipeJobWithCaching = struct {
        reader: *Reader,
        writer: *Writer,
        stats: *ProxyStats,
        direction: Direction,
        http_inspector: *const HTTPInspector,
        enable_http_inspection: bool,
        http_cache: *HTTPCache,
        request_method: []const u8,
        request_host: []const u8,
        request_path: []const u8,
        allocator: std.mem.Allocator,

        const Direction = enum {
            client_to_backend,
            backend_to_client,
        };

        // Configuration constants for cache population
        const default_ttl_seconds: u32 = 300;
        const max_cacheable_size: usize = 1024 * 1024; // 1MB
    };

    fn copyBidirectionalWithStats(
        io: Io,
        client_reader: *Reader,
        backend_writer: *Writer,
        backend_reader: *Reader,
        client_writer: *Writer,
        stats: *ProxyStats,
        http_inspector: *const HTTPInspector,
        options: RunOptions,
    ) void {
        const job_c2b = PipeJobWithStats{
            .reader = client_reader,
            .writer = backend_writer,
            .stats = stats,
            .direction = .client_to_backend,
            .http_inspector = http_inspector,
            .enable_http_inspection = options.enable_http_inspection,
        };
        const job_b2c = PipeJobWithStats{
            .reader = backend_reader,
            .writer = client_writer,
            .stats = stats,
            .direction = .backend_to_client,
            .http_inspector = http_inspector,
            .enable_http_inspection = options.enable_http_inspection,
        };

        // Use concurrent copying with statistics
        var future_c2b = io.concurrent(copyPipeWithStats, .{job_c2b}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                sequentialCopyWithStats(job_c2b);
                sequentialCopyWithStats(job_b2c);
                return;
            },
        };

        var future_b2c = io.concurrent(copyPipeWithStats, .{job_b2c}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                future_c2b.cancel(io) catch {};
                sequentialCopyWithStats(job_c2b);
                sequentialCopyWithStats(job_b2c);
                return;
            },
        };

        // Wait for first completion
        const first_completed = io.select(.{
            .client_to_backend = &future_c2b,
            .backend_to_client = &future_b2c,
        }) catch |err| {
            log.err("io.select failed: {s}", .{@errorName(err)});
            if (options.enable_stats) {
                stats.recordError();
            }
            future_c2b.cancel(io) catch {};
            future_b2c.cancel(io) catch {};
            return;
        };

        // Wait for second completion with timeout and error handling
        //
        // CRITICAL FIXES:
        // 1. 30-second timeout: Uses io.concurrent(sleep, ...) + io.select() to enforce timeout
        // 2. Cancel opposite direction immediately when one side fails (resource cleanup)
        // 3. Proper error propagation with stats recording
        //
        // Previous issues:
        // - No timeout: connections could hang forever waiting for EOF
        // - No cancellation: failed direction kept other side running indefinitely
        // - Resource leak: tasks continued consuming CPU/memory after connection died
        //
        // Timeout implementation: Uses io.concurrent(sleepForTimeout, ...) combined with
        // io.select() to enforce 30-second timeout when waiting for second direction.
        switch (first_completed) {
            .client_to_backend => |result| {
                // Check if first direction succeeded or failed
                if (result) |_| {
                    // Success: wait for backend->client with timeout
                    handleCopyResult("client->backend", result);

                    // Launch timeout future
                    var timeout_future = io.concurrent(sleepForTimeout, .{ io, BIDIRECTIONAL_TIMEOUT_SECONDS }) catch |err| switch (err) {
                        error.ConcurrencyUnavailable => {
                            // Fallback: wait without timeout
                            const second = io.select(.{
                                .backend_to_client = &future_b2c,
                            }) catch |err2| {
                                log.err("second io.select failed: {s}, canceling backend->client", .{@errorName(err2)});
                                future_b2c.cancel(io) catch {};
                                if (options.enable_stats) {
                                    stats.recordError();
                                }
                                return;
                            };
                            switch (second) {
                                .backend_to_client => |r| handleCopyResult("backend->client", r),
                            }
                            return;
                        },
                    };

                    const second = io.select(.{
                        .backend_to_client = &future_b2c,
                        .timeout = &timeout_future,
                    }) catch |err| {
                        log.err("second io.select failed: {s}, canceling both futures", .{@errorName(err)});
                        future_b2c.cancel(io) catch {};
                        timeout_future.cancel(io);
                        if (options.enable_stats) {
                            stats.recordError();
                        }
                        return;
                    };

                    switch (second) {
                        .backend_to_client => |r| {
                            timeout_future.cancel(io);
                            handleCopyResult("backend->client", r);
                        },
                        .timeout => {
                            log.warn("backend->client timeout after {d}s, canceling", .{BIDIRECTIONAL_TIMEOUT_SECONDS});
                            future_b2c.cancel(io) catch {};
                            if (options.enable_stats) {
                                stats.recordError();
                            }
                        },
                    }
                } else |err| {
                    // Error in client->backend: cancel backend->client immediately
                    log.err("client->backend failed: {s}, canceling backend->client", .{@errorName(err)});
                    handleCopyResult("client->backend", result);
                    future_b2c.cancel(io) catch {};
                    if (options.enable_stats) {
                        stats.recordError();
                    }
                }
            },
            .backend_to_client => |result| {
                // Check if first direction succeeded or failed
                if (result) |_| {
                    // Success: wait for client->backend with timeout
                    handleCopyResult("backend->client", result);

                    // Launch timeout future
                    var timeout_future = io.concurrent(sleepForTimeout, .{ io, BIDIRECTIONAL_TIMEOUT_SECONDS }) catch |err| switch (err) {
                        error.ConcurrencyUnavailable => {
                            // Fallback: wait without timeout
                            const second = io.select(.{
                                .client_to_backend = &future_c2b,
                            }) catch |err2| {
                                log.err("second io.select failed: {s}, canceling client->backend", .{@errorName(err2)});
                                future_c2b.cancel(io) catch {};
                                if (options.enable_stats) {
                                    stats.recordError();
                                }
                                return;
                            };
                            switch (second) {
                                .client_to_backend => |r| handleCopyResult("client->backend", r),
                            }
                            return;
                        },
                    };

                    const second = io.select(.{
                        .client_to_backend = &future_c2b,
                        .timeout = &timeout_future,
                    }) catch |err| {
                        log.err("second io.select failed: {s}, canceling both futures", .{@errorName(err)});
                        future_c2b.cancel(io) catch {};
                        timeout_future.cancel(io);
                        if (options.enable_stats) {
                            stats.recordError();
                        }
                        return;
                    };

                    switch (second) {
                        .client_to_backend => |r| {
                            timeout_future.cancel(io);
                            handleCopyResult("client->backend", r);
                        },
                        .timeout => {
                            log.warn("client->backend timeout after {d}s, canceling", .{BIDIRECTIONAL_TIMEOUT_SECONDS});
                            future_c2b.cancel(io) catch {};
                            if (options.enable_stats) {
                                stats.recordError();
                            }
                        },
                    }
                } else |err| {
                    // Error in backend->client: cancel client->backend immediately
                    log.err("backend->client failed: {s}, canceling client->backend", .{@errorName(err)});
                    handleCopyResult("backend->client", result);
                    future_c2b.cancel(io) catch {};
                    if (options.enable_stats) {
                        stats.recordError();
                    }
                }
            },
        }
    }

    fn sequentialCopy(job: PipeJob) void {
        copyPipe(job) catch |err| log.warn("sequential copy error: {s}", .{@errorName(err)});
    }

    fn sequentialCopyWithStats(job: PipeJobWithStats) void {
        copyPipeWithStats(job) catch |err| log.warn("sequential copy with stats error: {s}", .{@errorName(err)});
    }

    fn handleCopyResult(direction: []const u8, result: CopyError!void) void {
        result catch |err| log.warn("{s} stream closed with {s}", .{ direction, @errorName(err) });
    }

    fn sleepForTimeout(io: Io, seconds: i64) void {
        const duration = Duration.fromSeconds(seconds);
        io.sleep(duration, .awake) catch |err| {
            log.warn("timeout sleep failed: {s}", .{@errorName(err)});
        };
    }

    fn copyPipe(job: PipeJob) CopyError!void {
        var buffer: [8192]u8 = undefined;
        var total_bytes: usize = 0;

        if (!builtin.is_test) log.info("copyPipe: starting copy operation", .{});

        while (true) {
            var slices = [_][]u8{buffer[0..]};
            const n = job.reader.readVec(&slices) catch |err| switch (err) {
                error.EndOfStream => {
                    if (!builtin.is_test) log.info("copyPipe: EOF after {} bytes", .{total_bytes});
                    break;
                },
                error.ReadFailed => {
                    if (!builtin.is_test) log.warn("copyPipe: read failed after {} bytes", .{total_bytes});
                    return err;
                },
            };

            if (n == 0) continue;

            total_bytes += n;
            if (!builtin.is_test) log.info("copyPipe: read {} bytes (total: {})", .{ n, total_bytes });

            try Writer.writeAll(job.writer, buffer[0..n]);
            try Writer.flush(job.writer);
            if (!builtin.is_test) log.info("copyPipe: wrote {} bytes to destination", .{n});
        }

        if (!builtin.is_test) log.info("copyPipe: flushing {} total bytes", .{total_bytes});
        try Writer.flush(job.writer);
        if (!builtin.is_test) log.info("copyPipe: completed successfully", .{});
    }

    fn copyPipeWithStats(job: PipeJobWithStats) CopyError!void {
        var buffer: [8192]u8 = undefined;
        var total_bytes: usize = 0;
        var first_packet = true;

        if (!builtin.is_test) log.info("copyPipeWithStats: starting copy operation", .{});

        while (true) {
            var slices = [_][]u8{buffer[0..]};
            const n = job.reader.readVec(&slices) catch |err| switch (err) {
                error.EndOfStream => {
                    if (!builtin.is_test) log.info("copyPipeWithStats: EOF after {} bytes", .{total_bytes});
                    break;
                },
                error.ReadFailed => {
                    if (!builtin.is_test) log.warn("copyPipeWithStats: read failed after {} bytes", .{total_bytes});
                    job.stats.recordError();
                    return err;
                },
            };

            if (n == 0) continue;

            // HTTP inspection on first packet from client
            if (first_packet and job.direction == .client_to_backend and job.enable_http_inspection) {
                if (HTTPInspector.parseRequestLine(buffer[0..n])) |request| {
                    if (!builtin.is_test) {
                        log.info("HTTP {s} {s}", .{ request.method, request.path });
                    }
                }
                first_packet = false;
            }

            total_bytes += n;

            // Record bytes in statistics
            switch (job.direction) {
                .client_to_backend => job.stats.recordBytesClientToBackend(@intCast(n)),
                .backend_to_client => job.stats.recordBytesBackendToClient(@intCast(n)),
            }

            if (!builtin.is_test) log.info("copyPipeWithStats: read {} bytes (total: {})", .{ n, total_bytes });

            try Writer.writeAll(job.writer, buffer[0..n]);
            try Writer.flush(job.writer);
            if (!builtin.is_test) log.info("copyPipeWithStats: wrote {} bytes to destination", .{n});
        }

        if (!builtin.is_test) log.info("copyPipeWithStats: flushing {} total bytes", .{total_bytes});
        try Writer.flush(job.writer);
        if (!builtin.is_test) log.info("copyPipeWithStats: completed successfully", .{});
    }

    fn copyPipeWithCaching(job: PipeJobWithCaching) CopyError!void {
        var buffer: [8192]u8 = undefined;
        var total_bytes: usize = 0;
        var first_packet = true;

        // Response buffer for caching (only for backend->client direction)
        var response_buffer: ?std.ArrayList(u8) = null;
        defer if (response_buffer) |*buf| buf.deinit(job.allocator);

        // HTTP response state tracking
        var is_cacheable = false;
        var is_http_200 = false;
        var headers_complete = false;

        // Only allocate buffer for backend->client with GET requests
        if (job.direction == .backend_to_client and std.mem.eql(u8, job.request_method, "GET")) {
            response_buffer = .{};
            is_cacheable = true;
        }

        if (!builtin.is_test) log.info("copyPipeWithCaching: starting copy operation (cacheable={})", .{is_cacheable});

        while (true) {
            var slices = [_][]u8{buffer[0..]};
            const n = job.reader.readVec(&slices) catch |err| switch (err) {
                error.EndOfStream => {
                    if (!builtin.is_test) log.info("copyPipeWithCaching: EOF after {} bytes", .{total_bytes});
                    break;
                },
                error.ReadFailed => {
                    if (!builtin.is_test) log.warn("copyPipeWithCaching: read failed after {} bytes", .{total_bytes});
                    job.stats.recordError();
                    is_cacheable = false; // Don't cache on error
                    return err;
                },
            };

            if (n == 0) continue;

            // HTTP inspection on first packet from client
            if (first_packet and job.direction == .client_to_backend and job.enable_http_inspection) {
                if (HTTPInspector.parseRequestLine(buffer[0..n])) |request| {
                    if (!builtin.is_test) {
                        log.info("HTTP {s} {s}", .{ request.method, request.path });
                    }
                }
                first_packet = false;
            }

            // HTTP response inspection on first packet from backend
            if (first_packet and job.direction == .backend_to_client and is_cacheable) {
                // Check for "HTTP/1.1 200 OK" or "HTTP/1.0 200 OK"
                if (n >= 12) {
                    if (std.mem.startsWith(u8, buffer[0..n], "HTTP/1.1 200") or
                        std.mem.startsWith(u8, buffer[0..n], "HTTP/1.0 200"))
                    {
                        is_http_200 = true;
                        if (!builtin.is_test) {
                            log.info("detected HTTP 200 response, will cache", .{});
                        }
                    } else {
                        is_cacheable = false; // Not a 200 response
                        if (!builtin.is_test) {
                            log.info("non-200 response, will not cache", .{});
                        }
                    }
                }
                first_packet = false;
            }

            total_bytes += n;

            // Buffer response data if cacheable and under size limit
            if (is_cacheable and is_http_200 and response_buffer != null) {
                if (total_bytes <= PipeJobWithCaching.max_cacheable_size) {
                    response_buffer.?.appendSlice(job.allocator, buffer[0..n]) catch |err| {
                        if (!builtin.is_test) {
                            log.warn("failed to buffer response for caching: {s}", .{@errorName(err)});
                        }
                        is_cacheable = false;
                    };

                    // Check if headers are complete (look for \r\n\r\n)
                    if (!headers_complete and response_buffer.?.items.len >= 4) {
                        const items = response_buffer.?.items;
                        for (0..items.len - 3) |i| {
                            if (items[i] == '\r' and items[i + 1] == '\n' and
                                items[i + 2] == '\r' and items[i + 3] == '\n')
                            {
                                headers_complete = true;

                                // SECURITY: Check for Cache-Control: no-store (RFC 9111)
                                // Do not cache responses marked as no-store (may contain sensitive data)
                                if (HTTPInspector.hasCacheControlNoStore(items)) {
                                    is_cacheable = false;
                                    if (!builtin.is_test) {
                                        log.info("response has Cache-Control: no-store, will not cache", .{});
                                    }
                                }

                                break;
                            }
                        }
                    }
                } else {
                    is_cacheable = false; // Response too large
                    if (!builtin.is_test) {
                        log.info("response exceeds max cacheable size, will not cache", .{});
                    }
                }
            }

            // Record bytes in statistics
            switch (job.direction) {
                .client_to_backend => job.stats.recordBytesClientToBackend(@intCast(n)),
                .backend_to_client => job.stats.recordBytesBackendToClient(@intCast(n)),
            }

            if (!builtin.is_test) log.info("copyPipeWithCaching: read {} bytes (total: {})", .{ n, total_bytes });

            try Writer.writeAll(job.writer, buffer[0..n]);
            try Writer.flush(job.writer);
            if (!builtin.is_test) log.info("copyPipeWithCaching: wrote {} bytes to destination", .{n});
        }

        if (!builtin.is_test) log.info("copyPipeWithCaching: flushing {} total bytes", .{total_bytes});
        try Writer.flush(job.writer);

        // Store in cache if all conditions met
        if (is_cacheable and is_http_200 and headers_complete and response_buffer != null) {
            const response_data = response_buffer.?.items;
            if (response_data.len > 0 and response_data.len <= PipeJobWithCaching.max_cacheable_size) {
                job.http_cache.put(
                    job.request_method,
                    job.request_host,
                    job.request_path,
                    response_data,
                    PipeJobWithCaching.default_ttl_seconds,
                ) catch |err| {
                    if (!builtin.is_test) {
                        log.warn("failed to cache response: {s}", .{@errorName(err)});
                    }
                };

                if (!builtin.is_test) {
                    log.info("cached response for {s} {s} ({} bytes, TTL={}s)", .{
                        job.request_method,
                        job.request_path,
                        response_data.len,
                        PipeJobWithCaching.default_ttl_seconds,
                    });
                }
            }
        }

        if (!builtin.is_test) log.info("copyPipeWithCaching: completed successfully", .{});
    }

    fn sequentialCopyWithCaching(job: PipeJobWithCaching) void {
        copyPipeWithCaching(job) catch |err| log.warn("sequential copy with caching error: {s}", .{@errorName(err)});
    }

    /// Handle a single client connection (simplified concept)
    pub fn handleConnection(self: Self, client_connection: anytype) !void {
        // In the full implementation, this would:
        // 1. Connect to backend server
        // 2. Set up bidirectional async copy tasks
        // 3. Use io.select() to manage both directions
        // 4. Clean up properly when connection ends

        _ = self;
        _ = client_connection;
    }

    /// Copy data between two streams (placeholder)
    pub fn copyStream(source: anytype, destination: anytype) !void {
        // Historical shim retained for API compatibility. The actual async
        // proxy implementation relies on copyBidirectional{,WithStats}, which
        // uses io.concurrent/io.select as described in the new std.Io guide.
        _ = source;
        _ = destination;
    }
};

// Convenience function for quick testing
pub fn runProxy(allocator: std.mem.Allocator, proxy_port: u16, backend_host: []const u8, backend_port: u16) !void {
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    try runProxyWithIo(allocator, threaded_io.io(), proxy_port, backend_host, backend_port);
}

pub fn runProxyWithIo(
    allocator: std.mem.Allocator,
    io: Io,
    proxy_port: u16,
    backend_host: []const u8,
    backend_port: u16,
) !void {
    var proxy = Proxy.init(allocator, proxy_port, backend_host, backend_port);
    defer proxy.deinit();
    try proxy.runWithIoOptions(io, .{});
}
