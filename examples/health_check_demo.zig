//! Health Check Demo
//!
//! Demonstrates proactive backend health checking with:
//! - Background health checker task
//! - Automatic backend recovery
//! - Exponential backoff respect
//! - Graceful shutdown
//!
//! Usage:
//!   zig run examples/health_check_demo.zig
//!
//! The health checker will periodically probe backends and automatically
//! mark them as healthy when connections succeed.

const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Create Io executor
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Configure multiple backends
    var backends = [_]prozy.Backend{
        prozy.Backend.init("127.0.0.1", 3003, 1),
        prozy.Backend.init("127.0.0.1", 3004, 1),
        prozy.Backend.init("127.0.0.1", 3005, 1),
    };

    // Mark some backends as unhealthy to demonstrate recovery
    backends[1].markHealthy(false);
    backends[2].markHealthy(false);

    std.log.info("Initial backend states:", .{});
    std.log.info("  Backend 127.0.0.1:3003 - healthy: {}", .{backends[0].isHealthy()});
    std.log.info("  Backend 127.0.0.1:3004 - healthy: {}", .{backends[1].isHealthy()});
    std.log.info("  Backend 127.0.0.1:3005 - healthy: {}", .{backends[2].isHealthy()});
    std.log.info("", .{});

    // Create proxy with load balancer
    var proxy = prozy.Proxy.init(allocator, 8080, "127.0.0.1", 3003);
    defer proxy.deinit();

    proxy.enableLoadBalancing(backends[0..], .round_robin);

    // Create health checker
    var health_checker = prozy.HealthChecker.init(
        allocator,
        backends[0..],
        5000, // Check every 5 seconds
        2000, // 2 second connection timeout
        &proxy.shutdown_requested,
    );

    std.log.info("Starting health checker (5 second interval)...", .{});
    std.log.info("Health checker will probe unhealthy backends and mark them healthy on success", .{});
    std.log.info("Press Ctrl+C to shutdown", .{});
    std.log.info("", .{});

    // Run health checker in background
    var health_group: std.Io.Group = .init;
    defer health_group.wait(io);

    health_group.async(io, runHealthChecker, .{ &health_checker, io });

    // Run proxy (this will block)
    try proxy.runWithIoOptions(io, .{
        .enable_stats = true,
        .enable_load_balancing = true,
        .max_connections = 100,
    });
}

fn runHealthChecker(health_checker: *prozy.HealthChecker, io: std.Io) void {
    health_checker.run(io) catch |err| {
        std.log.err("health checker failed: {s}", .{@errorName(err)});
    };
}
