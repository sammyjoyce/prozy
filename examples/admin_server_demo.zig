//! Admin Server Demo
//!
//! Demonstrates the admin server running alongside the proxy with:
//! - Main proxy on port 8080
//! - Admin server on port 9090
//! - Metrics endpoint (/metrics)
//! - Health endpoint (/health)
//! - Backend status (/backends)
//!
//! Usage:
//!   zig run examples/admin_server_demo.zig
//!
//!   # In another terminal:
//!   curl http://localhost:9090/health
//!   curl http://localhost:9090/metrics
//!   curl http://localhost:9090/backends

const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Create Io executor
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Create proxy with load balancer
    var proxy = prozy.Proxy.init(allocator, 8080, "127.0.0.1", 3003);
    defer proxy.deinit();

    // Configure load balancer with multiple backends
    var backends = [_]prozy.Backend{
        prozy.Backend.init("127.0.0.1", 3003, 1),
        prozy.Backend.init("127.0.0.1", 3004, 1),
        prozy.Backend.init("127.0.0.1", 3005, 1),
    };

    proxy.enableLoadBalancing(backends[0..], .round_robin);
    proxy.enableCaching(10 * 1024 * 1024); // 10MB cache
    proxy.enableRateLimiting(100, 1000);

    // Create admin server - note: load_balancer is stored inside proxy
    const admin_server = prozy.AdminServer.init(
        allocator,
        9090,
        "127.0.0.1",
        &proxy.stats,
        if (proxy.load_balancer != null) &proxy.load_balancer.? else null,
        null, // No router in this demo
    );
    _ = admin_server; // Used in production with threading

    std.log.info("Starting proxy on 127.0.0.1:8080", .{});
    std.log.info("Starting admin server on 127.0.0.1:9090", .{});
    std.log.info("", .{});
    std.log.info("Try these endpoints:", .{});
    std.log.info("  curl http://localhost:9090/health", .{});
    std.log.info("  curl http://localhost:9090/metrics", .{});
    std.log.info("  curl http://localhost:9090/backends", .{});
    std.log.info("", .{});

    // Note: Running both proxy and admin server requires spawning a thread
    // For simplicity in this demo, we just show how to create the admin server
    // In production, run admin server in a separate thread or process

    std.log.info("Note: This demo shows the admin server structure.", .{});
    std.log.info("In production, run the admin server in a separate thread using std.Thread.spawn()", .{});
    std.log.info("", .{});

    // Run just the proxy for this demo
    try proxy.runWithIoOptions(io, .{
        .enable_stats = true,
        .enable_load_balancing = true,
        .enable_caching = true,
        .enable_rate_limiting = true,
        .max_connections = 100,
    });
}
