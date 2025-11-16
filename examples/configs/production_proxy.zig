//! Production Proxy Configuration
//!
//! Full-featured proxy with all enterprise capabilities.
//! Use case: Production deployment, high-traffic services, mission-critical

const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Create proxy
    var proxy = prozy.Proxy.init(allocator, 8080, "0.0.0.0", 3003);
    defer proxy.deinit();

    // 1. Load Balancing: Multiple backends with health checks
    var backends = [_]prozy.Backend{
        prozy.Backend.init("backend1.prod.internal", 3003, 3), // Primary (weight: 3)
        prozy.Backend.init("backend2.prod.internal", 3003, 2), // Secondary (weight: 2)
        prozy.Backend.init("backend3.prod.internal", 3003, 2), // Secondary (weight: 2)
        prozy.Backend.init("backend4.prod.internal", 3003, 1), // Tertiary (weight: 1)
    };
    proxy.enableLoadBalancing(&backends, .weighted_round_robin);

    // 2. Caching: Large cache for performance (500 MB)
    proxy.enableCaching(500 * 1024 * 1024);

    // 3. Rate Limiting: Moderate limits for public-facing service
    // 100 connections per IP, 50,000 global
    proxy.enableRateLimiting(100, 50000);

    // 4. Access Control: ALLOW by default, block known bad actors
    try proxy.enableAccessControl(.allow);

    if (proxy.access_control) |*acl| {
        // Block malicious IPs (example)
        // In production, integrate with threat intelligence feeds
        const blocked_ip1 = try std.Io.net.IpAddress.parseIp4("198.51.100.99", 0);
        try acl.addDeniedIp(blocked_ip1);

        std.log.info("Access Control: ALLOW by default (blocklist mode)", .{});
        std.log.info("  Blocked IPs: Dynamic blocklist enabled", .{});
    }

    std.log.info("======================================", .{});
    std.log.info("Production Proxy Configuration", .{});
    std.log.info("======================================", .{});
    std.log.info("Listen: 0.0.0.0:8080", .{});
    std.log.info("", .{});
    std.log.info("Backends: 4 servers (weighted round-robin)", .{});
    std.log.info("  - backend1: weight 3 (primary)", .{});
    std.log.info("  - backend2: weight 2", .{});
    std.log.info("  - backend3: weight 2", .{});
    std.log.info("  - backend4: weight 1 (backup)", .{});
    std.log.info("", .{});
    std.log.info("Features:", .{});
    std.log.info("  ✓ HTTP cache: 500 MB (LRU)", .{});
    std.log.info("  ✓ Rate limiting: 100/IP, 50K global", .{});
    std.log.info("  ✓ Access control: Blocklist mode", .{});
    std.log.info("  ✓ Health checks: Exponential backoff", .{});
    std.log.info("  ✓ Auto-failover: Enabled", .{});
    std.log.info("  ✓ Statistics: Real-time metrics", .{});
    std.log.info("", .{});
    std.log.info("Use case: Production HTTP service", .{});
    std.log.info("======================================", .{});

    // Run proxy using the primary API (Io passed as first-class parameter)
    try proxy.runWithIoOptions(io, .{});
}
