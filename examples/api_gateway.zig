const std = @import("std");
const prozy = @import("prozy");

const Backend = prozy.Backend;
const LoadBalancer = prozy.LoadBalancer;
const Route = prozy.Route;
const RouteMatch = prozy.RouteMatch;
const Cluster = prozy.Cluster;
const Router = prozy.Router;
const HttpMode = prozy.HttpMode;
const Proxy = prozy.Proxy;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Create Io executor once in main (Andrew Kelley's pattern)
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    std.debug.print("\n", .{});
    std.debug.print("=".** 70, .{});
    std.debug.print("\n", .{});
    std.debug.print("  Prozy Phase 3: API Gateway with Routing Demo\n", .{});
    std.debug.print("=".** 70, .{});
    std.debug.print("\n\n", .{});

    std.debug.print("This example demonstrates:\n", .{});
    std.debug.print("  - Reverse proxy mode with route matching\n", .{});
    std.debug.print("  - Multiple routes with different policies\n", .{});
    std.debug.print("  - Backend clusters with load balancing\n", .{});
    std.debug.print("  - Per-route caching and timeout policies\n", .{});
    std.debug.print("  - Graceful backend selection\n\n", .{});

    // Define backend servers
    var api_backends = [_]Backend{
        Backend.init("127.0.0.1", 3003, 2), // Weight 2
        Backend.init("127.0.0.1", 3004, 1), // Weight 1
    };

    var static_backends = [_]Backend{
        Backend.init("127.0.0.1", 8001, 1),
    };

    // Create clusters
    var api_cluster = Cluster.init(
        "api-cluster",
        &api_backends,
        .weighted_round_robin,
        100, // max 100 concurrent connections
    );

    var static_cluster = Cluster.init(
        "static-cluster",
        &static_backends,
        .round_robin,
        50, // max 50 concurrent connections
    );

    var clusters = [_]Cluster{ api_cluster, static_cluster };

    // Define routes
    const routes = [_]Route{
        // API route: high cache TTL, moderate timeout
        .{
            .name = "api-v1",
            .match = .{
                .host = "api.example.com",
                .path_prefix = "/v1",
                .methods = &[_][]const u8{ "GET", "POST" },
            },
            .cluster = .{ .name = "api-cluster" },
            .cache_policy = .{
                .allow = true,
                .ttl_seconds = 600, // 10 minutes
                .max_size = 1024 * 1024, // 1MB
            },
            .timeout_policy = .{
                .connect_timeout_ms = 3000,
                .request_timeout_ms = 10000,
                .response_timeout_ms = 30000,
            },
            .concurrency_policy = .{
                .max_concurrent = 100,
                .max_queue_depth = 50,
                .reject_when_full = false,
            },
        },

        // Static content route: long cache, fast timeout
        .{
            .name = "static-files",
            .match = .{
                .host = "static.example.com",
                .path_prefix = "/",
                .methods = &[_][]const u8{"GET"},
            },
            .cluster = .{ .name = "static-cluster" },
            .cache_policy = .{
                .allow = true,
                .ttl_seconds = 3600, // 1 hour
                .max_size = 5 * 1024 * 1024, // 5MB
            },
            .timeout_policy = .{
                .connect_timeout_ms = 1000,
                .request_timeout_ms = 5000,
                .response_timeout_ms = 10000,
            },
            .concurrency_policy = .{
                .max_concurrent = 50,
                .max_queue_depth = 20,
                .reject_when_full = true,
            },
        },

        // Catch-all route for other traffic
        .{
            .name = "default",
            .match = .{
                .host = null, // Match any host
                .path_prefix = null, // Match any path
                .methods = &[_][]const u8{}, // Match any method
            },
            .cluster = .{ .name = "api-cluster" },
            .cache_policy = .{
                .allow = false, // No caching for unknown routes
            },
            .timeout_policy = .{
                .connect_timeout_ms = 5000,
            },
            .concurrency_policy = .{
                .max_concurrent = 50,
            },
        },
    };

    // Create router
    var router = Router.init(allocator, .reverse_proxy, &routes, &clusters);

    std.debug.print("Router Configuration:\n", .{});
    std.debug.print("  Mode: {}\n", .{router.mode});
    std.debug.print("  Routes: {}\n", .{router.routes.len});
    std.debug.print("  Clusters: {}\n", .{router.clusters.len});
    std.debug.print("\n", .{});

    // Create and configure proxy
    var proxy = Proxy.init(allocator, 8080, "127.0.0.1", 3003);
    defer proxy.deinit();

    // Enable features
    proxy.enableCaching(10 * 1024 * 1024); // 10MB cache
    proxy.router = &router;
    proxy.mode = .reverse_proxy;

    std.debug.print("Proxy Configuration:\n", .{});
    std.debug.print("  Listen: 127.0.0.1:8080\n", .{});
    std.debug.print("  Cache: 10MB enabled\n", .{});
    std.debug.print("  Routing: ENABLED\n", .{});
    std.debug.print("\n", .{});

    std.debug.print("Testing Instructions:\n", .{});
    std.debug.print("  1. Start backend servers on ports 3003, 3004, 8001\n", .{});
    std.debug.print("  2. Send requests with different Host headers:\n\n", .{});
    std.debug.print("     # API route (weighted round-robin to 3003/3004)\n", .{});
    std.debug.print("     curl -H 'Host: api.example.com' http://localhost:8080/v1/users\n\n", .{});
    std.debug.print("     # Static route (to port 8001)\n", .{});
    std.debug.print("     curl -H 'Host: static.example.com' http://localhost:8080/images/logo.png\n\n", .{});
    std.debug.print("     # Default route (to api-cluster)\n", .{});
    std.debug.print("     curl -H 'Host: unknown.example.com' http://localhost:8080/anything\n\n", .{});
    std.debug.print("  3. Observe routing decisions and backend selection in logs\n", .{});
    std.debug.print("  4. Press Ctrl+C for graceful shutdown\n\n", .{});

    std.debug.print("=".** 70, .{});
    std.debug.print("\n\n", .{});

    std.debug.print("Starting proxy...\n\n", .{});

    // Run proxy with routing enabled
    try proxy.runWithIoOptions(io, .{
        .max_connections = 100,
        .enable_caching = true,
        .enable_stats = true,
        .enable_connection_logging = true,
        .enable_http_inspection = true,
    });
}
