//! Load Balanced Proxy Configuration
//!
//! Proxy with multiple backends and load balancing.
//! Use case: High availability, horizontal scaling, backend redundancy

const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Create proxy (backend_host/port unused with load balancing)
    var proxy = prozy.Proxy.init(allocator, 8080, "127.0.0.1", 3003);
    defer proxy.deinit();

    // Define backend pool
    var backends = [_]prozy.Backend{
        prozy.Backend.init("backend1.internal", 3003, 2), // Weight: 2 (higher capacity)
        prozy.Backend.init("backend2.internal", 3003, 1), // Weight: 1
        prozy.Backend.init("backend3.internal", 3003, 1), // Weight: 1
    };

    // Enable load balancing with weighted round-robin strategy
    // Other strategies: .round_robin, .least_connections, .random, .ip_hash
    proxy.enableLoadBalancing(&backends, .weighted_round_robin);

    // Optional: Enable caching for performance
    proxy.enableCaching(100 * 1024 * 1024); // 100 MB

    std.log.info("Load Balanced Proxy Configuration", .{});
    std.log.info("  Listen: 127.0.0.1:8080", .{});
    std.log.info("  Backends: 3 servers (weighted round-robin)", .{});
    std.log.info("    - backend1.internal:3003 (weight: 2)", .{});
    std.log.info("    - backend2.internal:3003 (weight: 1)", .{});
    std.log.info("    - backend3.internal:3003 (weight: 1)", .{});
    std.log.info("  Features: Health checks, auto-failover, cache", .{});

    try proxy.runWithIo(io);
}
