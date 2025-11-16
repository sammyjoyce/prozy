//! Secure Proxy Configuration
//!
//! Proxy with access control and rate limiting.
//! Use case: Internal services, API gateway, security enforcement

const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var proxy = prozy.Proxy.init(allocator, 8080, "127.0.0.1", 3003);
    defer proxy.deinit();

    // Enable access control with DENY-by-default policy
    try proxy.enableAccessControl(.deny);

    if (proxy.access_control) |*acl| {
        // Whitelist specific IP addresses
        // Note: Current implementation is per-IP, not CIDR
        // For CIDR support, extend AccessControl in your fork

        const allowed_ip1 = try std.Io.net.IpAddress.parseIp4("10.0.1.100", 0);
        const allowed_ip2 = try std.Io.net.IpAddress.parseIp4("10.0.2.50", 0);
        const allowed_ip3 = try std.Io.net.IpAddress.parseIp4("192.168.1.10", 0);

        try acl.addAllowedIp(allowed_ip1);
        try acl.addAllowedIp(allowed_ip2);
        try acl.addAllowedIp(allowed_ip3);

        std.log.info("Access Control: DENY by default", .{});
        std.log.info("  Allowed IPs: 3 addresses whitelisted", .{});
    }

    // Enable aggressive rate limiting
    // 50 connections per IP, 5000 global maximum
    proxy.enableRateLimiting(50, 5000);

    std.log.info("Secure Proxy Configuration", .{});
    std.log.info("  Listen: 127.0.0.1:8080", .{});
    std.log.info("  Backend: 127.0.0.1:3003", .{});
    std.log.info("  Security: Access control + rate limiting", .{});
    std.log.info("  Rate limits: 50/IP, 5000 global", .{});
    std.log.info("  Use case: Internal API, restricted access", .{});

    try proxy.runWithIo(io);
}
