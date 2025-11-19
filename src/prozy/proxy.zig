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
//! - **Keep-Alive & Pipelining**: HTTP Keep-Alive and pipelining are fully supported.
//!   The proxy maintains persistent connections with clients and handles multiple requests per connection.
//!   Idle connections are timed out after 30 seconds.
//!
//! ### Protocol Support
//! - **HTTP-only**: Currently designed for HTTP traffic. No TLS/SSL termination,
//!   WebSocket support, or HTTP/2.
//! - **TCP-only**: No UDP support. Adding UDP would require significant changes.
//!
//! ### Connection Handling
//! - **30-second timeout**: Idle connections are closed after 30 seconds.
//!   For bidirectional tunnels (CONNECT), both directions are monitored.
//! - **Full close only**: No TCP half-close support. Both directions are closed together.
//!
//! ### Cache Behavior
//! - **GET requests only**: Only GET requests are cached. POST/PUT/DELETE bypass cache.
//! - **Full Cache-Control**: Supports `no-store`, `max-age`, `s-maxage`, `stale-while-revalidate`, `Vary`, and more.
//! - **Conditional requests**: Supports 304 Not Modified responses and ETag/Last-Modified validation.
//! - **Stale-while-revalidate**: Can serve stale content while background revalidation refreshes cache.
//! - **No cache population from backend**: Responses are streamed to clients and optionally stored
//!   if cacheable.
//! - **Fixed-size buffers**: Request headers are buffered in an 8KB buffer.
//!
//! ### Load Balancing
//! - **Reactive health checks**: Backend health is determined by connection success/
//!   failure only. No proactive health checks.
//! - **Per-request routing**: Routing decisions are made for each request in the connection.
//!
//! ### Security
//! - **X-Forwarded-For**: Client IP is extracted from TCP socket for ACLs.
//!   `X-Forwarded-For` header is appended for backend visibility.
//! - **Trusted backend assumption**: No validation of backend responses or protection
//!   against malicious backends.
//!
//! ### Performance
//! - **Fixed buffer sizes**: 4KB client buffers, 4KB backend buffers, 8KB request buffer
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
const getTimestamp = @import("http.zig").getTimestamp;
const Backend = @import("backend.zig").Backend;
const LoadBalancer = @import("backend.zig").LoadBalancer;
const ProxyAuth = @import("auth.zig").ProxyAuth;
const resolveListenAddress = @import("transport.zig").resolveListenAddress;
const connectToBackend = @import("transport.zig").connectToBackend;
const extractClientIp = @import("transport.zig").extractClientIp;
const HealthMonitor = @import("health.zig").HealthMonitor;

// Phase 3: Routing infrastructure
const Router = @import("router.zig").Router;
const HttpMode = @import("routing.zig").HttpMode;
const RoutingDecision = @import("routing.zig").RoutingDecision;
const Config = @import("config.zig").Config;

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
    /// Enable RFC 7235 proxy authentication
    enable_proxy_authentication: bool = false,
    /// Authentication realm for Proxy-Authenticate header
    auth_realm: []const u8 = "Prozy Proxy",
    /// Enable Basic authentication scheme
    auth_basic_enabled: bool = true,
    /// Enable Digest authentication scheme (Phase 2)
    auth_digest_enabled: bool = false,
    /// Maximum failed authentication attempts before blocking
    auth_max_failed_attempts: u32 = 5,
    /// Authentication timeout in milliseconds
    auth_timeout_ms: u32 = 30000,
};

pub const Proxy = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    proxy_port: u16,

    // Core proxy features
    stats: ProxyStats,
    access_control: ?AccessControl = null,
    rate_limiter: ?RateLimiter = null,
    http_inspector: HTTPInspector,
    http_cache: ?HTTPCache = null,
    load_balancer: ?LoadBalancer = null,
    proxy_auth: ?ProxyAuth = null,
    health_monitor: ?*HealthMonitor = null,
    health_monitor_arena: ?std.heap.ArenaAllocator = null,

    // Phase 3: Routing and lifecycle
    router: *Router,
    router_arena: std.heap.ArenaAllocator,
    mode: HttpMode = .reverse_proxy,
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, proxy_port: u16, backend_host: []const u8, backend_port: u16) !Self {
        // Create arena for router
        var router_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer router_arena.deinit();
        const arena = router_arena.allocator();

        const routing = @import("routing.zig");

        // Create default backend
        const host_copy = try arena.dupe(u8, backend_host);
        const backend = Backend.init(host_copy, backend_port, 1);

        // Create backends slice
        const backends = try arena.alloc(Backend, 1);
        backends[0] = backend;

        // Create cluster
        const cluster_name = try arena.dupe(u8, "default");
        const clusters = try arena.alloc(routing.Cluster, 1);
        clusters[0] = routing.Cluster.init(
            cluster_name,
            backends,
            .round_robin,
            10000,
        );

        // Create default route
        const route_name = try arena.dupe(u8, "default");
        const routes = try arena.alloc(routing.Route, 1);
        routes[0] = .{
            .name = route_name,
            .match = .{},
            .cluster = .{ .name = cluster_name },
        };

        // Create router
        const router = try arena.create(Router);
        router.* = Router.init(arena, .reverse_proxy, routes, clusters);
        router.default_route = &routes[0];

        return Self{
            .allocator = allocator,
            .proxy_port = proxy_port,
            .stats = ProxyStats.init(),
            .http_inspector = HTTPInspector.init(true, true, "Prozy/1.0"),
            .router = router,
            .router_arena = router_arena,
        };
    }

    /// Initialize proxy from configuration
    pub fn initFromConfig(allocator: std.mem.Allocator, config: *const Config) !Self {
        var proxy = Self{
            .allocator = allocator,
            .proxy_port = config.proxy.listen_port,
            .stats = ProxyStats.init(),
            .http_inspector = HTTPInspector.init(true, true, "Prozy/1.0"),
            .router = undefined, // Will be set by setupRouter
            .router_arena = undefined, // Will be set by setupRouter
            .mode = config.mode,
        };

        // Enable features
        if (config.cache.enabled) {
            proxy.enableCaching(config.cache.max_size);
        }

        if (config.rate_limit.enabled) {
            proxy.enableRateLimiting(config.rate_limit.max_per_ip, config.rate_limit.max_global);
        }

        if (config.access_control.enabled) {
            try proxy.enableAccessControl(config.access_control.default_policy);
            if (proxy.access_control) |*acl| {
                for (config.access_control.allow_list) |ip_str| {
                    if (net.Ip4Address.parse(ip_str, 0) catch null) |ip4| {
                        const addr = net.IpAddress{ .ip4 = ip4 };
                        const ip_key = extractClientIp(addr);
                        try acl.addToAllowList(ip_key);
                    } else {
                        if (net.Ip6Address.parse(ip_str, 0) catch null) |ip6| {
                            const addr = net.IpAddress{ .ip6 = ip6 };
                            const ip_key = extractClientIp(addr);
                            try acl.addToAllowList(ip_key);
                        }
                    }
                }
                for (config.access_control.deny_list) |ip_str| {
                    if (net.Ip4Address.parse(ip_str, 0) catch null) |ip4| {
                        const addr = net.IpAddress{ .ip4 = ip4 };
                        const ip_key = extractClientIp(addr);
                        try acl.addToDenyList(ip_key);
                    } else {
                        if (net.Ip6Address.parse(ip_str, 0) catch null) |ip6| {
                            const addr = net.IpAddress{ .ip6 = ip6 };
                            const ip_key = extractClientIp(addr);
                            try acl.addToDenyList(ip_key);
                        }
                    }
                }
            }
        }

        // Setup Router
        if (config.routes.len > 0) {
            try proxy.setupRouter(config);
        } else {
            // Create empty router if no routes (should fail validation but safe fallback)
            // Or create default?
            // Let's assume valid config.
            // But we need to initialize router/arena.
            // Create arena for router data
            proxy.router_arena = std.heap.ArenaAllocator.init(allocator);
            const arena = proxy.router_arena.allocator();
            const router = try arena.create(Router);
            router.* = Router.init(arena, config.mode, &.{}, &.{});
            proxy.router = router;
        }

        return proxy;
    }

    fn setupRouter(self: *Self, config: *const Config) !void {
        // Create arena for router data
        self.router_arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena = self.router_arena.allocator();

        const routing = @import("routing.zig");

        // Allocate clusters
        const clusters = try arena.alloc(routing.Cluster, config.clusters.len);

        for (config.clusters, 0..) |conf_cluster, i| {
            const backends = try arena.alloc(Backend, conf_cluster.backends.len);

            for (conf_cluster.backends, 0..) |conf_backend, j| {
                const host = try arena.dupe(u8, conf_backend.host);
                backends[j] = Backend.init(host, conf_backend.port, conf_backend.weight);
            }

            const name = try arena.dupe(u8, conf_cluster.name);

            clusters[i] = routing.Cluster.init(
                name,
                backends,
                conf_cluster.strategy,
                conf_cluster.max_concurrent,
            );
        }

        // Allocate routes
        const routes = try arena.alloc(routing.Route, config.routes.len);

        for (config.routes, 0..) |conf_route, i| {
            const name = try arena.dupe(u8, conf_route.name);
            const cluster_name = try arena.dupe(u8, conf_route.cluster);

            const host = if (conf_route.match.host) |h| try arena.dupe(u8, h) else null;
            const path_prefix = if (conf_route.match.path_prefix) |p| try arena.dupe(u8, p) else null;

            const methods = try arena.alloc([]const u8, conf_route.match.methods.len);
            for (conf_route.match.methods, 0..) |m, j| {
                methods[j] = try arena.dupe(u8, m);
            }

            routes[i] = .{
                .name = name,
                .match = .{
                    .host = host,
                    .path_prefix = path_prefix,
                    .methods = methods,
                },
                .cluster = .{ .name = cluster_name },
                .cache_policy = conf_route.cache_policy,
                .timeout_policy = conf_route.timeout_policy,
                .transform_policy = .{},
                .concurrency_policy = conf_route.concurrency_policy,
            };
        }

        // Create Router in arena
        const router_ptr = try arena.create(Router);
        router_ptr.* = Router.init(arena, config.mode, routes, clusters);
        self.router = router_ptr;
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
        if (self.proxy_auth) |*auth| {
            auth.deinit();
        }
        if (self.health_monitor_arena) |*arena| {
            arena.deinit();
        }
        self.router_arena.deinit();
    }

    /// Enable proactive health monitoring
    pub fn enableHealthMonitoring(self: *Self, check_interval_ms: u64, connect_timeout_ms: u64) !void {
        // Create dedicated arena for health monitor
        self.health_monitor_arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena = self.health_monitor_arena.?.allocator();

        // Collect all backends from all clusters
        var total_backends: usize = 0;
        for (self.router.clusters) |cluster| {
            total_backends += cluster.backends.len;
        }

        // Allocate slice of pointers to backends
        const backends = try arena.alloc(*Backend, total_backends);
        var i: usize = 0;
        for (self.router.clusters) |cluster| {
            for (cluster.backends) |*backend| {
                backends[i] = backend;
                i += 1;
            }
        }

        // Create HealthMonitor
        const monitor = try arena.create(HealthMonitor);
        monitor.* = HealthMonitor.init(
            arena,
            backends,
            check_interval_ms,
            connect_timeout_ms,
            &self.shutdown_requested,
        );
        self.health_monitor = monitor;
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

    /// Enable RFC 7235 proxy authentication
    pub fn enableProxyAuthentication(self: *Self, realm: []const u8, options: ProxyAuth.AuthOptions) !void {
        self.proxy_auth = try ProxyAuth.init(self.allocator, realm, options);
    }

    /// Add a user to the authentication store
    pub fn addAuthUser(self: *Self, username: []const u8, password: []const u8) !void {
        if (self.proxy_auth) |*auth| {
            try auth.addUser(username, password);
        } else {
            return error.AuthenticationNotEnabled;
        }
    }

    /// Remove a user from the authentication store
    pub fn removeAuthUser(self: *Self, username: []const u8) !void {
        if (self.proxy_auth) |*auth| {
            try auth.removeUser(username);
        } else {
            return error.AuthenticationNotEnabled;
        }
    }

    /// Get authentication statistics if enabled
    pub fn getAuthStats(self: *const Self) ?ProxyAuth.AuthStatsSnapshot {
        if (self.proxy_auth) |*auth| {
            return auth.getStats();
        }
        return null;
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
        // Backend target is determined by router
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
                log.info("load balancing: ENABLED ({d} backends, strategy: {any})", .{ lb.backends.len, lb.strategy });
            }
        }
        log.info("routing mode: {any} ({d} routes, {d} clusters)", .{ self.router.mode, self.router.routes.len, self.router.clusters.len });

        if (options.enable_proxy_authentication) {
            var schemes_buffer: [64]u8 = undefined;
            var schemes_len: usize = 0;

            if (options.auth_basic_enabled) {
                const basic_str = "Basic";
                if (schemes_len + basic_str.len <= schemes_buffer.len) {
                    @memcpy(schemes_buffer[schemes_len..][0..basic_str.len], basic_str);
                    schemes_len += basic_str.len;
                }
            }
            if (options.auth_digest_enabled) {
                const digest_str = "Digest";
                if (schemes_len > 0 and schemes_len + 2 + digest_str.len <= schemes_buffer.len) {
                    schemes_buffer[schemes_len] = ',';
                    schemes_buffer[schemes_len + 1] = ' ';
                    schemes_len += 2;
                    @memcpy(schemes_buffer[schemes_len..][0..digest_str.len], digest_str);
                    schemes_len += digest_str.len;
                }
            }

            const schemes_str = schemes_buffer[0..schemes_len];
            log.info("proxy authentication: ENABLED (realm: {s}, schemes: {s})", .{ options.auth_realm, schemes_str });
        }

        var connection_group: std.Io.Group = .init;
        defer connection_group.wait(io);

        // Start health monitor if enabled
        if (self.health_monitor) |monitor| {
            monitor.start(io, &connection_group) catch |err| {
                log.err("failed to start health monitor: {s}", .{@errorName(err)});
                // Non-fatal? Probably fatal if monitoring was requested.
                // But let's log and continue for resilience.
            };
        }

        var accepted: usize = 0;
        while (!self.isShutdownRequested() and accepted < configured_limit) {
            log.info("calling server.accept() [accepted={}/{}]", .{ accepted, configured_limit });
            const client_stream = server.accept(io) catch |err| {
                log.err("accept failed: {s}", .{@errorName(err)});
                continue;
            };

            accepted += 1;
            log.info("accepted connection #{} from {any}", .{ accepted, client_stream.socket.address });

            if (options.enable_stats) {
                self.stats.recordConnection();
            }

            _ = connection_group.async(io, handleClientWithFeatures, .{
                client_stream,
                io,
                &connection_group,
                self.allocator,
                @as(*ProxyStats, @constCast(&self.stats)),
                &self.http_inspector,
                options,
                if (self.rate_limiter) |*limiter| limiter else null,
                if (self.http_cache) |*cache| cache else null,
                if (self.proxy_auth) |*auth| auth else null, // RFC 7235 Proxy Authentication
                self.router, // Phase 3: Pass router for advanced routing
                self.access_control,
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
        // Backend target is now determined dynamically by router
        std.debug.print("Routing: {} routes, {} clusters\n", .{ self.router.routes.len, self.router.clusters.len });

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
        allocator: std.mem.Allocator,
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
        // CONNECT tunnels don't use caching (no HTTP parsing)
        copyBidirectionalWithStats(
            io,
            &client_reader.interface,
            &backend_writer.interface,
            &backend_reader.interface,
            &client_writer.interface,
            stats,
            http_inspector,
            options,
            allocator,
            null, // no cache for CONNECT tunnels
            null, // no cache context
        );

        if (!builtin.is_test) {
            log.info("CONNECT tunnel closed", .{});
        }
    }

    fn handleClientWithFeatures(
        client_stream: net.Stream,
        io: Io,
        connection_group: *std.Io.Group,
        allocator: std.mem.Allocator,
        stats: *ProxyStats,
        http_inspector: *const HTTPInspector,
        options: RunOptions,
        rate_limiter: ?*RateLimiter,
        http_cache: ?*HTTPCache,
        proxy_auth: ?*ProxyAuth, // RFC 7235 Proxy Authentication
        router: *Router, // Phase 3: Router for advanced routing
        access_control: ?AccessControl,
    ) void {
        const connect_timeout = options.connect_timeout;
        // Extract client IP for access control and rate limiting
        const client_ip = extractClientIp(client_stream.socket.address);

        // Check access control (Connection Level)
        if (options.enable_access_control) {
            if (access_control) |acl| {
                if (!acl.isAllowed(client_ip)) {
                    log.warn("connection from {any} denied by access control", .{client_ip});
                    client_stream.close(io);
                    return;
                }
            }
        }

        // Check rate limiting (Connection Level)
        if (options.enable_rate_limiting) {
            if (rate_limiter) |limiter| {
                if (!limiter.tryAcquire(client_ip)) {
                    log.warn("connection from {any} denied by rate limiter", .{client_ip});
                    client_stream.close(io);
                    return;
                }
            }
        }

        // Statistics: Connection Start
        if (options.enable_stats) {
            stats.recordConnection();
        }

        const connection_start_time = if (options.enable_connection_logging) std.time.Instant.now() catch null else null;
        if (options.enable_connection_logging and !builtin.is_test) {
            log.info("new connection from client {any}", .{client_ip});
        }

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
            if (options.enable_connection_logging and !builtin.is_test and connection_start_time != null) {
                if (std.time.Instant.now() catch null) |end_time| {
                    const duration_ns = end_time.since(connection_start_time.?);
                    const duration_ms = duration_ns / std.time.ns_per_ms;
                    log.info("connection closed, duration: {}ms", .{duration_ms});
                }
            }
        }

        // Setup buffered reader/writer for Client (Persistent across loop)
        var client_read_buf: [4096]u8 = undefined;
        var client_write_buf: [4096]u8 = undefined;
        var client_reader = client_stream.reader(io, &client_read_buf);
        var client_writer = client_stream.writer(io, &client_write_buf);

        // Keep-Alive State
        var keep_alive = true;
        var request_count: usize = 0;

        // Request Buffer (Reusable)
        var request_buffer: [8192]u8 = undefined;

        // Loop for Persistent Connection
        while (keep_alive) {
            // 1. Read Request Headers with Idle Timeout
            const idle_timeout_s: i64 = if (request_count > 0) 30 else 30; // 30s idle timeout (first or subsequent)

            // Create a future for reading headers
            var read_future = io.concurrent(readHeaders, .{ &client_reader.interface, &request_buffer }) catch |err| switch (err) {
                error.ConcurrencyUnavailable => {
                    // Fallback to blocking read (no timeout enforcement possible without concurrent)
                    // This is suboptimal but functional
                    // For Phase 2, we assume concurrency is available
                    log.warn("concurrency unavailable for readHeaders", .{});
                    break;
                },
            };

            // Create a future for timeout
            var timeout_future = io.concurrent(sleepForTimeout, .{ io, idle_timeout_s }) catch {
                _ = read_future.cancel(io) catch {};
                break;
            };

            // Wait for either Read or Timeout
            const result = io.select(.{
                .read = &read_future,
                .timeout = &timeout_future,
            }) catch |err| {
                log.warn("io.select failed in keep-alive loop: {s}", .{@errorName(err)});
                _ = read_future.cancel(io) catch {};
                timeout_future.cancel(io);
                break;
            };

            // Process Result
            var headers_len: usize = 0;
            switch (result) {
                .read => |read_result| {
                    timeout_future.cancel(io); // Cancel timeout
                    headers_len = read_result catch |err| {
                        if (err == error.EndOfStream) {
                            if (request_count > 0 and !builtin.is_test) {
                                log.info("client closed connection (EOF)", .{});
                            }
                        } else {
                            log.warn("failed to read headers: {s}", .{@errorName(err)});
                        }
                        break; // Exit loop on error/EOF
                    };
                },
                .timeout => {
                    _ = read_future.cancel(io) catch {}; // Cancel read
                    if (request_count > 0 and !builtin.is_test) {
                        log.info("keep-alive idle timeout ({d}s)", .{idle_timeout_s});
                    }
                    break; // Exit loop on timeout
                },
            }

            request_count += 1;
            const request_headers = request_buffer[0..headers_len];

            // 2. Parse Request Line
            const parsed_request = HTTPInspector.parseRequestLine(request_headers) orelse {
                log.warn("invalid request line", .{});
                break;
            };

            // Check Connection: close header to update keep_alive state
            // Simple check: if "Connection: close" is present
            // TODO: Improved parsing for comma-separated values
            if (HTTPInspector.findHeader(request_headers, "Connection")) |conn| {
                if (std.ascii.indexOfIgnoreCase(conn, "close") != null) {
                    keep_alive = false;
                }
            }

            // 3. Check for CONNECT Tunnel
            if (std.mem.eql(u8, parsed_request.method, "CONNECT")) {
                // Handle CONNECT (opaque tunnel) - this takes over the connection completely
                // Parse host/port logic duplicated from original...
                var host_port_iter = std.mem.splitScalar(u8, parsed_request.path, ':');
                const connect_host = host_port_iter.next() orelse {
                    break;
                };
                const connect_port_str = host_port_iter.next() orelse "443";
                const connect_port = std.fmt.parseInt(u16, connect_port_str, 10) catch {
                    break;
                };

                handleConnectTunnel(client_stream, io, allocator, connect_host, connect_port, connect_timeout, stats, http_inspector, options);
                return; // CONNECT tunnel consumes connection
            }

            // 4. RFC 7235 Proxy Authentication
            if (options.enable_proxy_authentication and proxy_auth != null) {
                const auth_header = HTTPInspector.findProxyAuthorizationHeader(request_headers);
                const auth_result = proxy_auth.?.authenticate(auth_header, client_ip);

                if (auth_result != .success) {
                    // Send 407 and Close (auth failure usually breaks keep-alive flow in simple proxies)
                    // Or we can try to keep alive, but 407 body streaming is needed.
                    // For simplicity, send 407 and close.
                    const auth_response = proxy_auth.?.generateAuthChallenge() catch {
                        break;
                    };
                    defer allocator.free(auth_response);
                    _ = Writer.writeAll(&client_writer.interface, auth_response) catch {};
                    _ = Writer.flush(&client_writer.interface) catch {};
                    break;
                }
            }

            // 5. Routing
            const decision = router.routeRequest(&parsed_request, request_headers, client_ip) catch |err| {
                log.warn("routing failed: {s}", .{@errorName(err)});
                // Send 502/500
                const err_resp = "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n";
                _ = Writer.writeAll(&client_writer.interface, err_resp) catch {};
                _ = Writer.flush(&client_writer.interface) catch {};
                break;
            };

            // 6. Caching Check
            var cache_hit = false;
            var cached_entry: ?HTTPCache.GetResult = null;

            if (options.enable_caching and decision.cache_allowed and http_cache != null) {
                if (std.mem.eql(u8, parsed_request.method, "GET")) {
                    if (HTTPInspector.findHeader(request_headers, "Host")) |host| {
                        // Try GET (allow stale to handle revalidation)
                        if (http_cache.?.get(parsed_request.method, host, parsed_request.path, null, true)) |entry| {
                            if (!entry.is_stale) {
                                // Fresh hit: Serve immediately
                                defer http_cache.?.allocator.free(entry.response);
                                _ = Writer.writeAll(&client_writer.interface, entry.response) catch {
                                    // Clean up entry before breaking
                                    break;
                                };
                                _ = Writer.flush(&client_writer.interface) catch {
                                    break;
                                };
                                if (options.enable_stats) {
                                    stats.recordBytesBackendToClient(@intCast(entry.response.len));
                                }
                                cache_hit = true;
                                decision.cluster.release();
                            } else {
                                // Stale hit: Keep entry for conditional request
                                cached_entry = entry;

                                // Check if stale entry supports stale-while-revalidate
                                if (entry.metadata.cache_control.stale_while_revalidate) |swr_duration| {
                                    // Calculate freshness to see if we are within SWR window
                                    const freshness_info = HTTPInspector.FreshnessInfo{
                                        .date = entry.metadata.date_header,
                                        .age = entry.metadata.age_header,
                                        .expires = entry.metadata.expires_header,
                                        .cache_control = entry.metadata.cache_control,
                                        .response_time = entry.metadata.response_time,
                                        .request_time = entry.metadata.request_time,
                                    };

                                    const now = getTimestamp();
                                    const current_age = freshness_info.calculateCurrentAge(now);
                                    const freshness_lifetime = freshness_info.calculateFreshnessLifetime();
                                    const swr_limit = freshness_lifetime + swr_duration;

                                    if (current_age <= swr_limit) {
                                        if (!builtin.is_test) {
                                            log.debug("stale-while-revalidate applicable (age={d}, limit={d})", .{ current_age, swr_limit });
                                        }

                                        // Create context for revalidation
                                        // Note: context.init performs deep copies of metadata strings
                                        if (HTTPCache.RevalidationContext.init(allocator, http_cache.?, parsed_request.method, host, parsed_request.path, entry.metadata, decision.backend.host, decision.backend.port, connect_timeout)) |context| {
                                            // Spawn background revalidation task
                                            // Use connection_group.async to spawn detached task
                                            _ = connection_group.async(io, HTTPCache.revalidateStaleEntry, .{ io, context });

                                            // Serve stale content immediately
                                            defer http_cache.?.allocator.free(entry.response);
                                            if (entry.metadata.etag) |e| http_cache.?.allocator.free(e);
                                            if (entry.metadata.last_modified) |l| http_cache.?.allocator.free(l);

                                            _ = Writer.writeAll(&client_writer.interface, entry.response) catch {
                                                break;
                                            };
                                            _ = Writer.flush(&client_writer.interface) catch {
                                                break;
                                            };
                                            if (options.enable_stats) {
                                                stats.recordBytesBackendToClient(@intCast(entry.response.len));
                                            }

                                            cache_hit = true;
                                            decision.cluster.release();
                                            // Clean up cached_entry reference since we served it
                                            cached_entry = null;
                                        } else |err| {
                                            log.warn("failed to create revalidation context: {s}", .{@errorName(err)});
                                        }
                                    }
                                }

                                // If not SWR or failed to init context, fall through to synchronous revalidation
                            }
                        }
                    }
                }
            }

            if (cache_hit) {
                continue; // Next request
            }

            // 7. Cache Miss or Stale Revalidation: Proxy to Backend

            // Determine request body type to stream it
            const request_body_type = HTTPInspector.getBodyType(request_headers);

            // Connect Backend
            const backend_stream = connectToBackend(io, decision.backend.host, decision.backend.port, connect_timeout) catch {
                decision.cluster.release();
                // If we have a stale entry, serve it as fallback (stale-if-error behavior)
                if (cached_entry) |entry| {
                    defer http_cache.?.allocator.free(entry.response);
                    if (entry.metadata.etag) |e| http_cache.?.allocator.free(e);
                    if (entry.metadata.last_modified) |l| http_cache.?.allocator.free(l);

                    log.warn("backend connection failed, serving stale content", .{});
                    _ = Writer.writeAll(&client_writer.interface, entry.response) catch {};
                    _ = Writer.flush(&client_writer.interface) catch {};
                    continue;
                }

                // Send 503
                const err_resp = "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n";
                _ = Writer.writeAll(&client_writer.interface, err_resp) catch {};
                _ = Writer.flush(&client_writer.interface) catch {};
                break;
            };
            defer backend_stream.close(io); // Close backend at end of scope (request)

            // Mark Healthy/Stats
            decision.backend.incrementConnections();
            decision.backend.markHealthy(true);

            var backend_read_buf: [4096]u8 = undefined;
            var backend_write_buf: [4096]u8 = undefined;
            var backend_reader = backend_stream.reader(io, &backend_read_buf);
            var backend_writer = backend_stream.writer(io, &backend_write_buf);

            // Forward Request Headers (Manipulated + Conditional)
            {
                const ip_str = client_ip.toStringAlloc(allocator) catch "0.0.0.0";
                defer allocator.free(ip_str);

                // X-Forwarded-Proto Check
                const client_proto = if (HTTPInspector.findHeader(request_headers, "X-Forwarded-Proto")) |p| p else "http";
                const host_header = HTTPInspector.findHeader(request_headers, "Host");

                var headers_to_send = if (http_inspector.manipulateRequestHeaders(allocator, request_headers, ip_str, client_proto, host_header)) |mod|
                    mod
                else |_|
                    allocator.dupe(u8, request_headers) catch request_headers; // Fallback

                // Add Conditional Headers if revalidating
                if (cached_entry) |entry| {
                    if (HTTPInspector.addConditionalHeaders(allocator, headers_to_send, entry.metadata)) |cond_headers| {
                        // Free previous headers if they were allocated (not equal to buffer)
                        if (headers_to_send.ptr != request_headers.ptr) {
                            allocator.free(headers_to_send);
                        }
                        headers_to_send = cond_headers;
                    } else |_| {}
                }

                defer if (headers_to_send.ptr != request_headers.ptr) allocator.free(headers_to_send);

                Writer.writeAll(&backend_writer.interface, headers_to_send) catch {
                    break;
                };
            }
            Writer.flush(&backend_writer.interface) catch {
                break;
            };

            // Stream Request Body
            streamMessage(&client_reader.interface, &backend_writer.interface, request_body_type, stats, .client_to_backend) catch |err| {
                log.warn("failed to stream request body: {s}", .{@errorName(err)});
                break;
            };

            // Read Response Headers
            var response_header_buf: [8192]u8 = undefined;
            const resp_headers_len = readHeaders(&backend_reader.interface, &response_header_buf) catch |err| {
                log.warn("failed to read response headers: {s}", .{@errorName(err)});
                break;
            };
            const response_headers = response_header_buf[0..resp_headers_len];

            // Handle 304 Not Modified
            if (cached_entry) |entry| {
                // Check if response is 304
                if (std.mem.indexOf(u8, response_headers, " 304 ") != null) {
                    // Revalidation Successful!
                    if (!builtin.is_test) log.info("revalidation successful (304), serving cached content", .{});

                    // Update cache metadata
                    if (http_cache) |cache| {
                        if (HTTPInspector.findHeader(request_headers, "Host")) |host| {
                            // Parse headers needed for metadata update
                            const cache_control = HTTPInspector.parseCacheControl(response_headers);

                            var etag: ?[]const u8 = null;
                            if (HTTPInspector.findHeader(response_headers, "ETag")) |e| etag = e;
                            var last_modified: ?[]const u8 = null;
                            if (HTTPInspector.findHeader(response_headers, "Last-Modified")) |l| last_modified = l;

                            const date_header = if (HTTPInspector.findHeader(response_headers, "Date")) |d| HTTPInspector.parseHttpDate(d) else null;
                            const expires_header = if (HTTPInspector.findHeader(response_headers, "Expires")) |e| HTTPInspector.parseHttpDate(e) else null;
                            const age_header = if (HTTPInspector.findHeader(response_headers, "Age")) |a| std.fmt.parseInt(u32, a, 10) catch null else null;

                            const new_metadata = HTTPCache.CacheMetadata{
                                .cache_control = cache_control,
                                .response_time = getTimestamp(),
                                .request_time = getTimestamp(),
                                .etag = etag,
                                .last_modified = last_modified,
                                .date_header = date_header,
                                .expires_header = expires_header,
                                .age_header = age_header,
                                .vary_context = entry.metadata.vary_context, // Preserve vary context
                            };

                            cache.updateMetadata(parsed_request.method, host, parsed_request.path, entry.metadata.vary_context, new_metadata) catch |err| {
                                log.warn("failed to update cache metadata: {s}", .{@errorName(err)});
                            };
                        }
                    }

                    defer http_cache.?.allocator.free(entry.response);
                    if (entry.metadata.etag) |e| http_cache.?.allocator.free(e);
                    if (entry.metadata.last_modified) |l| http_cache.?.allocator.free(l);

                    // Return cached response (using handle304 helper if we wanted, but direct write is fine)
                    _ = Writer.writeAll(&client_writer.interface, entry.response) catch {
                        break;
                    };
                    _ = Writer.flush(&client_writer.interface) catch {
                        break;
                    };

                    decision.backend.decrementConnections();
                    decision.cluster.release();
                    continue;
                } else {
                    // 200 OK or other code -> New content or error
                    // Free the stale entry since we won't use it
                    http_cache.?.allocator.free(entry.response);
                    if (entry.metadata.etag) |e| http_cache.?.allocator.free(e);
                    if (entry.metadata.last_modified) |l| http_cache.?.allocator.free(l);
                    cached_entry = null;
                }
            }

            // Determine Response Body Type

            const response_body_type = HTTPInspector.getBodyType(response_headers);

            // Check Backend Connection: close
            if (HTTPInspector.findHeader(response_headers, "Connection")) |conn| {
                if (std.ascii.indexOfIgnoreCase(conn, "close") != null) {
                    // Backend closed
                }
            }

            // Manipulate Response Headers (Add Via, etc)
            if (http_inspector.manipulateResponseHeaders(allocator, response_headers)) |mod_resp| {
                defer allocator.free(mod_resp);
                Writer.writeAll(&client_writer.interface, mod_resp) catch {
                    break;
                };
            } else |_| {
                Writer.writeAll(&client_writer.interface, response_headers) catch {
                    break;
                };
            }
            Writer.flush(&client_writer.interface) catch {
                break;
            };

            // Stream Response Body (and Cache)
            var streamed = false;

            if (options.enable_caching and decision.cache_allowed and http_cache != null) {
                const cache_control = HTTPInspector.parseCacheControl(response_headers);

                const status_line = if (std.mem.indexOf(u8, response_headers, "\r\n")) |idx| response_headers[0..idx] else response_headers;
                const is_200 = std.mem.indexOf(u8, status_line, " 200 ") != null;
                const is_get = std.mem.eql(u8, parsed_request.method, "GET");

                if (is_get and is_200 and cache_control.isCacheable()) {
                    var response_buffer = std.ArrayListUnmanaged(u8){};
                    defer response_buffer.deinit(allocator);

                    var tee_writer = TeeWriter(*Writer){
                        .child_writer = &client_writer.interface,
                        .buffer = &response_buffer,
                        .max_size = 100 * 1024, // 100KB limit
                        .allocator = allocator,
                    };

                    streamMessage(&backend_reader.interface, &tee_writer, response_body_type, stats, .backend_to_client) catch |err| {
                        log.warn("failed to stream response body (caching): {s}", .{@errorName(err)});
                        break;
                    };
                    streamed = true;

                    // If complete and within size, store in cache
                    if (!tee_writer.was_truncated and response_buffer.items.len > 0) {
                        const ttl = cache_control.getTTL(300);

                        // Extract validators
                        var etag: ?[]const u8 = null;
                        if (HTTPInspector.findHeader(response_headers, "ETag")) |e| {
                            etag = e;
                        }
                        var last_modified: ?[]const u8 = null;
                        if (HTTPInspector.findHeader(response_headers, "Last-Modified")) |l| {
                            last_modified = l;
                        }

                        const metadata = HTTPCache.CacheMetadata{
                            .cache_control = cache_control,
                            .response_time = getTimestamp(),
                            .request_time = getTimestamp(), // approx
                            .etag = etag,
                            .last_modified = last_modified,
                        };

                        if (HTTPInspector.findHeader(request_headers, "Host")) |host| {
                            http_cache.?.put(parsed_request.method, host, parsed_request.path, response_buffer.items, ttl, metadata, null) catch {};
                        }
                    }
                }
            }

            if (!streamed) {
                streamMessage(&backend_reader.interface, &client_writer.interface, response_body_type, stats, .backend_to_client) catch |err| {
                    log.warn("failed to stream response body: {s}", .{@errorName(err)});
                    break;
                };
            }

            decision.backend.decrementConnections();
            decision.cluster.release();

            // End of Loop Iteration
        }
    }

    /// Forward buffered request data to backend, with optional header manipulation
    /// Returns the number of bytes actually sent to the backend
    fn forwardBufferedData(
        writer: *Writer,
        buffered_data: []const u8,
        http_inspector: *const HTTPInspector,
        client_ip: IpKey,
        allocator: std.mem.Allocator,
        enable_header_manipulation: bool,
    ) !usize {
        // Precondition: buffered_data must be non-empty and within bounds
        if (buffered_data.len == 0) return 0;
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
            return buffered_data.len;
        }

        // Manipulate headers: add X-Forwarded-*, Via, remove hop-by-hop headers
        const client_ip_str = client_ip.toStringAlloc(allocator) catch |err| {
            log.warn("failed to convert client IP to string: {s}, forwarding without header manipulation", .{@errorName(err)});
            // Fallback: forward original request without header manipulation
            // This is not a failure - we successfully forward the data, just without manipulation
            Writer.writeAll(writer, buffered_data) catch |write_err| {
                log.warn("failed to forward buffered request data: {s}", .{@errorName(write_err)});
                return write_err;
            };
            Writer.flush(writer) catch |flush_err| {
                log.warn("failed to flush buffered request data: {s}", .{@errorName(flush_err)});
                return flush_err;
            };
            return buffered_data.len; // Success - data forwarded successfully
        };
        defer allocator.free(client_ip_str);

        // Extract Host header for X-Forwarded-Host
        const host_header = HTTPInspector.findHeader(buffered_data, "Host");

        // Determine protocol (http or https)
        // Check if we are behind a TLS terminator (e.g. AWS ALB, Nginx)
        const client_proto = if (HTTPInspector.findHeader(buffered_data, "X-Forwarded-Proto")) |proto|
            proto
        else
            "http";

        const modified_request = http_inspector.manipulateRequestHeaders(
            allocator,
            buffered_data,
            client_ip_str,
            client_proto,
            host_header,
        ) catch |err| {
            log.warn("failed to manipulate request headers: {s}, forwarding original request", .{@errorName(err)});
            // Fallback: forward original request without header manipulation
            // This is not a failure - we successfully forward the data, just without manipulation
            Writer.writeAll(writer, buffered_data) catch |write_err| {
                log.warn("failed to forward buffered request data: {s}", .{@errorName(write_err)});
                return write_err;
            };
            Writer.flush(writer) catch |flush_err| {
                log.warn("failed to flush buffered request data: {s}", .{@errorName(flush_err)});
                return flush_err;
            };
            return buffered_data.len; // Success - data forwarded successfully
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

        // Return actual bytes sent (may be larger than original if headers were added)
        return modified_request.len;
    }

    fn TeeWriter(comptime ChildWriterType: type) type {
        return struct {
            const TeeSelf = @This();
            child_writer: ChildWriterType,
            buffer: *std.ArrayListUnmanaged(u8),
            max_size: usize,
            allocator: std.mem.Allocator,
            was_truncated: bool = false,

            pub fn writeAll(self: *TeeSelf, bytes: []const u8) !void {
                try self.child_writer.writeAll(bytes);
                if (self.was_truncated) return;

                if (self.buffer.items.len + bytes.len <= self.max_size) {
                    try self.buffer.appendSlice(self.allocator, bytes);
                } else {
                    self.was_truncated = true;
                }
            }

            pub fn flush(self: *TeeSelf) !void {
                if (@hasDecl(@TypeOf(self.child_writer.*), "flush")) {
                    try self.child_writer.flush();
                }
            }
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
        const max_cacheable_size: usize = 100 * 1024; // 100KB (reduced from 1MB for memory efficiency)
    };

    /// Cache context for request/response caching
    /// Note: Contains owned copies of request data to ensure lifetime safety
    const CacheContext = struct {
        method: []const u8,
        host: []const u8,
        path: []const u8,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, method: []const u8, host: []const u8, path: []const u8) !CacheContext {
            return CacheContext{
                .method = try allocator.dupe(u8, method),
                .host = try allocator.dupe(u8, host),
                .path = try allocator.dupe(u8, path),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: CacheContext) void {
            self.allocator.free(self.method);
            self.allocator.free(self.host);
            self.allocator.free(self.path);
        }
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
        allocator: std.mem.Allocator,
        http_cache: ?*HTTPCache,
        cache_context: ?CacheContext,
    ) void {
        const job_c2b = PipeJobWithStats{
            .reader = client_reader,
            .writer = backend_writer,
            .stats = stats,
            .direction = .client_to_backend,
            .http_inspector = http_inspector,
            .enable_http_inspection = options.enable_http_inspection,
        };

        // Choose appropriate copy function based on caching configuration
        // Use caching path for backend->client when all conditions are met:
        // 1. Caching is enabled in options
        // 2. http_cache is not null
        // 3. cache_context is not null (method, host, path available)
        const use_caching = options.enable_caching and http_cache != null and cache_context != null;

        // Use concurrent copying with statistics (and caching for backend->client if enabled)
        var future_c2b = io.concurrent(copyPipeWithStats, .{job_c2b}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                sequentialCopyWithStats(job_c2b);
                if (use_caching) {
                    const job_b2c_caching_seq = PipeJobWithCaching{
                        .reader = backend_reader,
                        .writer = client_writer,
                        .stats = stats,
                        .direction = .backend_to_client,
                        .http_inspector = http_inspector,
                        .enable_http_inspection = options.enable_http_inspection,
                        .http_cache = http_cache.?,
                        .request_method = cache_context.?.method,
                        .request_host = cache_context.?.host,
                        .request_path = cache_context.?.path,
                        .allocator = allocator,
                    };
                    sequentialCopyWithCaching(job_b2c_caching_seq);
                } else {
                    const job_b2c = PipeJobWithStats{
                        .reader = backend_reader,
                        .writer = client_writer,
                        .stats = stats,
                        .direction = .backend_to_client,
                        .http_inspector = http_inspector,
                        .enable_http_inspection = options.enable_http_inspection,
                    };
                    sequentialCopyWithStats(job_b2c);
                }
                return;
            },
        };
        defer future_c2b.cancel(io) catch {};

        var future_b2c: @TypeOf(future_c2b) = undefined;
        if (use_caching) {
            const job_b2c_caching = PipeJobWithCaching{
                .reader = backend_reader,
                .writer = client_writer,
                .stats = stats,
                .direction = .backend_to_client,
                .http_inspector = http_inspector,
                .enable_http_inspection = options.enable_http_inspection,
                .http_cache = http_cache.?,
                .request_method = cache_context.?.method,
                .request_host = cache_context.?.host,
                .request_path = cache_context.?.path,
                .allocator = allocator,
            };
            future_b2c = io.concurrent(copyPipeWithCaching, .{job_b2c_caching}) catch |err| switch (err) {
                error.ConcurrencyUnavailable => {
                    // future_c2b deferred cancel will handle cleanup
                    sequentialCopyWithStats(job_c2b);
                    sequentialCopyWithCaching(job_b2c_caching);
                    return;
                },
            };
        } else {
            const job_b2c = PipeJobWithStats{
                .reader = backend_reader,
                .writer = client_writer,
                .stats = stats,
                .direction = .backend_to_client,
                .http_inspector = http_inspector,
                .enable_http_inspection = options.enable_http_inspection,
            };
            future_b2c = io.concurrent(copyPipeWithStats, .{job_b2c}) catch |err| switch (err) {
                error.ConcurrencyUnavailable => {
                    // future_c2b deferred cancel will handle cleanup
                    sequentialCopyWithStats(job_c2b);
                    sequentialCopyWithStats(job_b2c);
                    return;
                },
            };
        }
        defer future_b2c.cancel(io) catch {};

        // Wait for first completion
        const first_completed = io.select(.{
            .client_to_backend = &future_c2b,
            .backend_to_client = &future_b2c,
        }) catch |err| {
            log.err("io.select failed: {s}", .{@errorName(err)});
            if (options.enable_stats) {
                stats.recordError();
            }
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
                    defer timeout_future.cancel(io);

                    const second = io.select(.{
                        .backend_to_client = &future_b2c,
                        .timeout = &timeout_future,
                    }) catch |err| {
                        log.err("second io.select failed: {s}", .{@errorName(err)});
                        if (options.enable_stats) {
                            stats.recordError();
                        }
                        return;
                    };

                    switch (second) {
                        .backend_to_client => |r| {
                            handleCopyResult("backend->client", r);
                        },
                        .timeout => {
                            log.warn("backend->client timeout after {d}s", .{BIDIRECTIONAL_TIMEOUT_SECONDS});
                            if (options.enable_stats) {
                                stats.recordError();
                            }
                        },
                    }
                } else |err| {
                    // Error in client->backend: cancel backend->client immediately
                    // (Deferred cancel will handle this)
                    log.err("client->backend failed: {s}", .{@errorName(err)});
                    handleCopyResult("client->backend", result);
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
                    defer timeout_future.cancel(io);

                    const second = io.select(.{
                        .client_to_backend = &future_c2b,
                        .timeout = &timeout_future,
                    }) catch |err| {
                        log.err("second io.select failed: {s}", .{@errorName(err)});
                        if (options.enable_stats) {
                            stats.recordError();
                        }
                        return;
                    };

                    switch (second) {
                        .client_to_backend => |r| {
                            handleCopyResult("client->backend", r);
                        },
                        .timeout => {
                            log.warn("client->backend timeout after {d}s", .{BIDIRECTIONAL_TIMEOUT_SECONDS});
                            if (options.enable_stats) {
                                stats.recordError();
                            }
                        },
                    }
                } else |err| {
                    // Error in backend->client: cancel client->backend immediately
                    // (Deferred cancel will handle this)
                    log.err("backend->client failed: {s}", .{@errorName(err)});
                    handleCopyResult("backend->client", result);
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
        var cache_control_directives: ?HTTPInspector.CacheControlDirectives = null;

        // Transfer validation state
        var expected_content_length: ?usize = null;
        var transfer_complete = false;

        // RFC 9111 Phase 5: Freshness metadata (extracted from response headers)
        var date_header: ?i64 = null;
        var age_header: ?u32 = null;
        var expires_header: ?i64 = null;
        const request_time = getTimestamp(); // Track when request was sent

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
                    // Store Cache-Control directives for TTL calculation
                    if (!headers_complete and response_buffer.?.items.len >= 4) {
                        const items = response_buffer.?.items;
                        for (0..items.len - 3) |i| {
                            if (items[i] == '\r' and items[i + 1] == '\n' and
                                items[i + 2] == '\r' and items[i + 3] == '\n')
                            {
                                headers_complete = true;

                                // RFC 9111: Parse full Cache-Control directives
                                cache_control_directives = HTTPInspector.parseCacheControl(items);

                                // TRANSFER VALIDATION: Parse Content-Length for transfer completion check
                                if (HTTPInspector.findHeader(items, "Content-Length")) |content_length_str| {
                                    expected_content_length = std.fmt.parseInt(usize, content_length_str, 10) catch null;
                                    if (!builtin.is_test and expected_content_length != null) {
                                        log.info("response has Content-Length: {d} bytes", .{expected_content_length.?});
                                    }
                                }

                                // RFC 9111 Phase 5: Extract freshness metadata headers
                                // This is implemented here in copyPipeWithCaching to capture the actual
                                // request/response timestamps and parse HTTP date headers for accurate
                                // freshness calculation as per RFC 9111 Section 4.2
                                if (HTTPInspector.findHeader(items, "Date")) |date_str| {
                                    date_header = HTTPInspector.parseHttpDate(date_str);
                                    if (!builtin.is_test and date_header != null) {
                                        log.info("parsed Date header: {d} ({s})", .{ date_header.?, date_str });
                                    } else if (!builtin.is_test and date_header == null) {
                                        log.warn("failed to parse Date header: {s}", .{date_str});
                                    }
                                }

                                if (HTTPInspector.findHeader(items, "Age")) |age_str| {
                                    age_header = std.fmt.parseInt(u32, age_str, 10) catch null;
                                    if (!builtin.is_test and age_header != null) {
                                        log.info("parsed Age header: {} seconds", .{age_header.?});
                                    }
                                }

                                if (HTTPInspector.findHeader(items, "Expires")) |expires_str| {
                                    expires_header = HTTPInspector.parseHttpDate(expires_str);
                                    if (!builtin.is_test and expires_header != null) {
                                        log.info("parsed Expires header: {d} ({s})", .{ expires_header.?, expires_str });
                                    } else if (!builtin.is_test and expires_header == null) {
                                        log.warn("failed to parse Expires header: {s}", .{expires_str});
                                    }
                                }

                                // SECURITY: Check cacheability (no-store, private, etc.)
                                if (!cache_control_directives.?.isCacheable()) {
                                    is_cacheable = false;
                                    if (!builtin.is_test) {
                                        if (cache_control_directives.?.no_store) {
                                            log.info("response has Cache-Control: no-store, will not cache", .{});
                                        } else if (cache_control_directives.?.private) {
                                            log.info("response has Cache-Control: private, will not cache (shared cache)", .{});
                                        }
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

        // TRANSFER VALIDATION: Verify response was completely received
        if (expected_content_length) |content_length| {
            const headers_size = if (cache_control_directives != null) blk: {
                // Find where headers end in our buffered response
                const items = response_buffer.?.items;
                if (HTTPInspector.findHeadersEnd(items)) |headers_end| {
                    break :blk headers_end;
                }
                break :blk 0;
            } else 0;

            const body_received = total_bytes - headers_size;
            transfer_complete = (body_received >= content_length);

            if (!builtin.is_test) {
                if (transfer_complete) {
                    log.info("transfer validation: complete (body: {d}/{d} bytes)", .{ body_received, content_length });
                } else {
                    log.warn("transfer validation: incomplete (body: {d}/{d} bytes), will not cache", .{ body_received, content_length });
                    is_cacheable = false;
                }
            }
        } else {
            // No Content-Length header - assume transfer is complete for HTTP/1.0
            // or connection-terminated responses
            transfer_complete = true;
            if (!builtin.is_test) {
                log.info("transfer validation: no Content-Length, assuming complete", .{});
            }
        }

        // Store in cache if all conditions met AND transfer is complete
        if (is_cacheable and is_http_200 and headers_complete and transfer_complete and response_buffer != null) {
            const response_data = response_buffer.?.items;
            if (response_data.len > 0 and response_data.len <= PipeJobWithCaching.max_cacheable_size) {
                // Calculate TTL using Cache-Control directives (respects max-age, s-maxage)
                const ttl = if (cache_control_directives) |directives|
                    directives.getTTL(PipeJobWithCaching.default_ttl_seconds)
                else
                    PipeJobWithCaching.default_ttl_seconds;

                // RFC 9111 Phase 5: Build cache metadata with freshness info
                const response_time = getTimestamp();
                const metadata = HTTPCache.CacheMetadata{
                    .date_header = date_header,
                    .age_header = age_header,
                    .expires_header = expires_header,
                    .request_time = request_time,
                    .response_time = response_time,
                    .cache_control = cache_control_directives orelse .{},
                    // Phase 4 fields (ETags) will be populated later
                    .etag = null,
                    .last_modified = null,
                    .is_weak_etag = false,
                };

                job.http_cache.put(
                    job.request_method,
                    job.request_host,
                    job.request_path,
                    response_data,
                    ttl,
                    metadata,
                    null,
                ) catch |err| {
                    if (!builtin.is_test) {
                        log.warn("failed to cache response: {s}", .{@errorName(err)});
                    }
                };

                if (!builtin.is_test) {
                    log.info("cached response for {s} {s} ({} bytes, TTL={}s, Date={?}, Age={?}, Expires={?})", .{
                        job.request_method,
                        job.request_path,
                        response_data.len,
                        ttl,
                        date_header,
                        age_header,
                        expires_header,
                    });
                }
            }
        }

        if (!builtin.is_test) log.info("copyPipeWithCaching: completed successfully", .{});
    }

    fn sequentialCopyWithCaching(job: PipeJobWithCaching) void {
        copyPipeWithCaching(job) catch |err| log.warn("sequential copy with caching error: {s}", .{@errorName(err)});
    }

    /// Phase 2: Read HTTP headers byte-by-byte to ensure we don't over-read into the body.
    /// Relies on the fact that the underlying Reader is buffered for performance.
    fn readHeaders(reader: *Reader, buffer: []u8) !usize {
        var total_read: usize = 0;
        var state: u8 = 0; // 0: start, 1: \r, 2: \r\n, 3: \r\n\r

        while (total_read < buffer.len) {
            var byte: [1]u8 = undefined;
            var slices = [_][]u8{&byte};
            const n = reader.readVec(&slices) catch |err| switch (err) {
                error.EndOfStream => return if (total_read == 0) error.EndOfStream else error.IncompleteHeaders,
                else => return err,
            };

            if (n == 0) {
                if (total_read == 0) return error.EndOfStream;
                return error.IncompleteHeaders;
            }

            buffer[total_read] = byte[0];
            total_read += 1;

            switch (state) {
                0 => if (byte[0] == '\r') {
                    state = 1;
                } else {
                    state = 0;
                },
                1 => if (byte[0] == '\n') {
                    state = 2;
                } else if (byte[0] == '\r') {
                    state = 1;
                } else {
                    state = 0;
                },
                2 => if (byte[0] == '\r') {
                    state = 3;
                } else {
                    state = 0;
                },
                3 => if (byte[0] == '\n') {
                    return total_read;
                } else {
                    state = 0;
                },
                else => unreachable,
            }
        }
        return error.HeadersTooLarge;
    }

    /// Phase 2: Copy exactly N bytes
    fn copyNBytes(reader: *Reader, writer: anytype, n: u64, stats: *ProxyStats, direction: PipeJobWithStats.Direction) !void {
        var remaining = n;
        var buffer: [8192]u8 = undefined;

        while (remaining > 0) {
            const to_read = @min(remaining, buffer.len);
            var slices = [_][]u8{buffer[0..to_read]};
            const read = try reader.readVec(&slices);
            if (read == 0) return error.UnexpectedEOF;

            // Update stats
            switch (direction) {
                .client_to_backend => stats.recordBytesClientToBackend(@intCast(read)),
                .backend_to_client => stats.recordBytesBackendToClient(@intCast(read)),
            }

            try writer.writeAll(buffer[0..read]);
            remaining -= read;
        }
        // Flush if available (duck typing try)
        if (@hasDecl(@TypeOf(writer.*), "flush")) {
            try writer.flush();
        }
    }

    /// Phase 2: Copy chunked encoding stream
    /// Reads chunks until 0-sized chunk is found.
    fn copyChunked(reader: *Reader, writer: anytype, stats: *ProxyStats, direction: PipeJobWithStats.Direction) !void {
        var header_buffer: [128]u8 = undefined; // Chunk headers are small

        while (true) {
            // 1. Read chunk size line
            var size_line_len: usize = 0;
            var state: u8 = 0; // 0: start, 1: \r
            var chunk_size: u64 = 0;

            // Read until \r\n
            while (size_line_len < header_buffer.len) {
                var byte: [1]u8 = undefined;
                var slices = [_][]u8{&byte};
                const n = try reader.readVec(&slices);
                if (n == 0) return error.UnexpectedEOF;

                header_buffer[size_line_len] = byte[0];
                size_line_len += 1;

                if (state == 0 and byte[0] == '\r') {
                    state = 1;
                } else if (state == 1 and byte[0] == '\n') {
                    break;
                } else {
                    state = 0;
                }
            }

            // Parse hex size
            // Format: size [; extension] \r\n
            const line = header_buffer[0..size_line_len];
            const trim_line = std.mem.trimRight(u8, line, "\r\n");
            var parts = std.mem.splitScalar(u8, trim_line, ';');
            const size_hex = parts.first();
            const trimmed_hex = std.mem.trim(u8, size_hex, " ");

            chunk_size = std.fmt.parseInt(u64, trimmed_hex, 16) catch return error.InvalidChunkSize;

            // Write chunk header
            try writer.writeAll(line);

            // If size 0, this is the last chunk
            if (chunk_size == 0) {
                // Read/Write trailers until empty line
                // State machine to detect empty line (\r\n at start of line)
                var trailer_state: u8 = 0; // 0: start of line, 1: saw \r at start, 2: mid-line, 3: saw \r mid-line

                trailers: while (true) {
                    var byte: [1]u8 = undefined;
                    var slices = [_][]u8{&byte};
                    const n = try reader.readVec(&slices);
                    if (n == 0) return error.UnexpectedEOF;

                    try writer.writeAll(&byte);
                    const c = byte[0];

                    switch (trailer_state) {
                        0 => { // Start of line
                            if (c == '\r') {
                                trailer_state = 1;
                            } else {
                                trailer_state = 2;
                            }
                        },
                        1 => { // Saw \r at start
                            if (c == '\n') {
                                break :trailers;
                            } else {
                                trailer_state = 2;
                            }
                        },
                        2 => { // Mid-line
                            if (c == '\r') {
                                trailer_state = 3;
                            }
                        },
                        3 => { // Saw \r mid-line
                            if (c == '\n') {
                                trailer_state = 0;
                            } else {
                                trailer_state = 2;
                            }
                        },
                        else => unreachable,
                    }
                }

                if (@hasDecl(@TypeOf(writer.*), "flush")) {
                    try writer.flush();
                }
                return;
            }

            // Copy chunk data
            try copyNBytes(reader, writer, chunk_size, stats, direction);

            // Read/Write trailing CRLF
            var crlf: [2]u8 = undefined;
            var crlf_slices = [_][]u8{&crlf};
            if (try reader.readVec(&crlf_slices) != 2) return error.UnexpectedEOF;
            try writer.writeAll(&crlf);
        }
    }

    /// Phase 2: Stream a complete HTTP message based on body type
    fn streamMessage(reader: *Reader, writer: anytype, body_type: HTTPInspector.MessageBodyType, stats: *ProxyStats, direction: PipeJobWithStats.Direction) !void {
        switch (body_type) {
            .none => {},
            .content_length => |len| try copyNBytes(reader, writer, len, stats, direction),
            .chunked => try copyChunked(reader, writer, stats, direction),
            .until_close => {
                // Fallback for HTTP/1.0 or unknown length: read until EOF
                var buffer: [8192]u8 = undefined;
                while (true) {
                    var slices = [_][]u8{buffer[0..]};
                    const n = reader.readVec(&slices) catch |err| switch (err) {
                        error.EndOfStream => break,
                        else => return err,
                    };
                    if (n == 0) break;

                    switch (direction) {
                        .client_to_backend => stats.recordBytesClientToBackend(@intCast(n)),
                        .backend_to_client => stats.recordBytesBackendToClient(@intCast(n)),
                    }
                    try writer.writeAll(buffer[0..n]);
                }
                if (@hasDecl(@TypeOf(writer.*), "flush")) {
                    try writer.flush();
                }
            },
        }
    }

    /// Handle a single client connection (simplified concept)
    pub fn handleConnection(self: Self, client_connection: anytype) !void {
        _ = self;
        _ = client_connection;
    }

    /// Copy data between two streams (placeholder)
    pub fn copyStream(source: anytype, destination: anytype) !void {
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
    var proxy = try Proxy.init(allocator, proxy_port, backend_host, backend_port);
    defer proxy.deinit();
    try proxy.runWithIoOptions(io, .{});
}
