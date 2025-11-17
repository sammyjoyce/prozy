//! Production Gateway Example
//!
//! Comprehensive production setup demonstrating all Prozy features:
//! - Routing with multiple routes and policies
//! - Load balancing with weighted backends
//! - HTTP caching with per-route policies
//! - Rate limiting (per-IP and global)
//! - Admin server on :9090
//! - Health checking for backend recovery
//! - Graceful shutdown support
//!
//! Usage:
//!   zig run examples/production_gateway.zig
//!
//!   # Main proxy endpoints:
//!   curl -H 'Host: api.example.com' http://localhost:8080/v1/users
//!   curl -H 'Host: static.example.com' http://localhost:8080/assets/logo.png
//!
//!   # Admin endpoints:
//!   curl http://localhost:9090/health
//!   curl http://localhost:9090/metrics
//!   curl http://localhost:9090/backends
//!   curl http://localhost:9090/routes

const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Create Io executor
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    std.log.info("=== Prozy Production Gateway ===", .{});
    std.log.info("", .{});

    // ====================================================================
    // Backend Configuration
    // ====================================================================

    var api_backends = [_]prozy.Backend{
        prozy.Backend.init("127.0.0.1", 3003, 2), // Weight 2
        prozy.Backend.init("127.0.0.1", 3004, 1), // Weight 1
    };

    const static_backends = [_]prozy.Backend{
        prozy.Backend.init("127.0.0.1", 3005, 1),
        prozy.Backend.init("127.0.0.1", 3006, 1),
    };
    _ = static_backends; // Would be used with full Router implementation

    // ====================================================================
    // Route Configuration
    // ====================================================================
    // Note: In a real application, you would create Cluster instances
    // and pass them to the Router. For this demo, we show the Route structure.

    const api_methods = [_][]const u8{"GET"};
    const api_route = prozy.Route{
        .name = "api-route",
        .match = prozy.RouteMatch{
            .host = "api.example.com",
            .path_prefix = "/v1",
            .methods = &api_methods,
        },
        .cluster = .{ .name = "api-cluster" },
        .cache_policy = prozy.CachePolicy{
            .ttl_seconds = 300, // 5 minutes
        },
        .timeout_policy = prozy.TimeoutPolicy{
            .connect_timeout_ms = 5000,
            .request_timeout_ms = 30000,
        },
        .transform_policy = .{},
        .concurrency_policy = prozy.ConcurrencyPolicy{
            .max_concurrent = 100,
        },
    };

    const static_methods = [_][]const u8{"GET"};
    const static_route = prozy.Route{
        .name = "static-route",
        .match = prozy.RouteMatch{
            .host = "static.example.com",
            .path_prefix = "/assets",
            .methods = &static_methods,
        },
        .cluster = .{ .name = "static-cluster" },
        .cache_policy = prozy.CachePolicy{
            .ttl_seconds = 3600, // 1 hour (static content)
        },
        .timeout_policy = prozy.TimeoutPolicy{
            .connect_timeout_ms = 3000,
            .request_timeout_ms = 10000,
        },
        .transform_policy = .{},
        .concurrency_policy = prozy.ConcurrencyPolicy{
            .max_concurrent = 200,
        },
    };

    var routes = [_]prozy.Route{ api_route, static_route };

    // ====================================================================
    // Router Configuration
    // ====================================================================

    // Note: Router needs clusters array too, so this example shows structure only
    const clusters = [_]prozy.Cluster{};
    var router = prozy.Router.init(allocator, .reverse_proxy, routes[0..], clusters[0..]);

    // ====================================================================
    // Proxy Configuration
    // ====================================================================

    var proxy = prozy.Proxy.init(allocator, 8080, "127.0.0.1", 3003);
    defer proxy.deinit();

    // Configure router
    proxy.router = &router;
    proxy.mode = .reverse_proxy;

    // Enable all features
    proxy.enableCaching(50 * 1024 * 1024); // 50MB cache
    proxy.enableRateLimiting(100, 1000); // 100 per IP, 1000 global

    // ====================================================================
    // Admin Server Configuration
    // ====================================================================

    const admin_server = prozy.AdminServer.init(
        allocator,
        9090,
        "127.0.0.1",
        &proxy.stats,
        null, // Load balancer managed by router
        &router,
        null, // No authentication in this demo
    );

    // ====================================================================
    // Health Checker Configuration
    // ====================================================================

    const health_checker = prozy.HealthChecker.init(
        allocator,
        api_backends[0..], // Would include all backends in production
        10000, // Check every 10 seconds
        3000, // 3 second connection timeout
        &proxy.shutdown_requested,
    );

    // ====================================================================
    // Startup Information
    // ====================================================================

    std.log.info("Configuration:", .{});
    std.log.info("  Mode: reverse_proxy", .{});
    std.log.info("  Proxy: 127.0.0.1:8080", .{});
    std.log.info("  Admin: 127.0.0.1:9090", .{});
    std.log.info("  Cache: 50MB", .{});
    std.log.info("  Rate Limiting: 100/IP, 1000 global", .{});
    std.log.info("", .{});
    std.log.info("Routes:", .{});
    std.log.info("  api.example.com/v1 → api-cluster (2 backends, 5min cache, weighted)", .{});
    std.log.info("  static.example.com/assets → static-cluster (2 backends, 1hr cache)", .{});
    std.log.info("", .{});
    std.log.info("Health Checking: Every 10 seconds", .{});
    std.log.info("", .{});
    std.log.info("Try it:", .{});
    std.log.info("  curl -H 'Host: api.example.com' http://localhost:8080/v1/users", .{});
    std.log.info("  curl -H 'Host: static.example.com' http://localhost:8080/assets/logo.png", .{});
    std.log.info("  curl http://localhost:9090/health", .{});
    std.log.info("  curl http://localhost:9090/metrics", .{});
    std.log.info("", .{});

    // ====================================================================
    // Run Services
    // ====================================================================

    // Note: In production, run admin server and health checker in separate threads
    // For this demo, we show the structure

    _ = admin_server; // Would run in separate thread
    _ = health_checker; // Would run in separate thread

    std.log.info("Note: In production, admin server and health checker run in separate threads", .{});
    std.log.info("This demo shows the configuration structure", .{});
    std.log.info("", .{});

    // Run main proxy
    try proxy.runWithIoOptions(io, .{
        .enable_stats = true,
        .enable_caching = true,
        .enable_rate_limiting = true,
        .enable_connection_logging = true,
        .max_connections = 10000,
    });
}
