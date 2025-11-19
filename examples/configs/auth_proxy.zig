//! Authentication Proxy Configuration
//!
//! Proxy with RFC 7235 proxy authentication enabled.
//! Use case: Corporate proxy, API gateway with authentication, secure services
//!
//! This example demonstrates:
//! - Basic authentication setup
//! - User credential management
//! - Integration with existing security features
//! - Authentication statistics and monitoring

const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var proxy = try prozy.Proxy.init(allocator, 8080, "127.0.0.1", 3003);
    defer proxy.deinit();

    // Enable RFC 7235 proxy authentication
    try proxy.enableProxyAuthentication("Corporate Proxy", .{
        .basic_enabled = true,
        .digest_enabled = false, // Phase 2 feature
        .max_failed_attempts = 5,
        .auth_timeout_ms = 30000,
    });

    // Add users to the authentication store
    // In production, these would come from a database, LDAP, or configuration file
    try proxy.addAuthUser("admin", "admin123");
    try proxy.addAuthUser("alice", "alicepass");
    try proxy.addAuthUser("bob", "bobpass");
    try proxy.addAuthUser("charlie", "charliepass");

    // Enable additional security features
    try proxy.enableAccessControl(.allow);
    proxy.enableRateLimiting(10, 100); // 10 per IP, 100 global

    // Optional: Enable caching and load balancing
    proxy.enableCaching(10 * 1024 * 1024); // 10MB cache

    std.log.info("Authentication Proxy Configuration", .{});
    std.log.info("  Listen: 127.0.0.1:8080", .{});
    std.log.info("  Backend: 127.0.0.1:3003", .{});
    std.log.info("  Authentication: RFC 7235 Basic auth", .{});
    std.log.info("  Realm: Corporate Proxy", .{});
    std.log.info("  Users: 4 configured (admin, alice, bob, charlie)", .{});
    std.log.info("  Security: Access control + rate limiting + auth", .{});
    std.log.info("  Rate limits: 10/IP, 100 global", .{});
    std.log.info("  Cache: 10MB HTTP response cache", .{});
    std.log.info("", .{});
    std.log.info("Usage Examples:", .{});
    std.log.info("  curl --proxy http://127.0.0.1:8080 -U admin:admin123 http://example.com", .{});
    std.log.info("  curl --proxy http://127.0.0.1:8080 -U alice:alicepass http://api.service.com", .{});
    std.log.info("", .{});
    std.log.info("Authentication Features:", .{});
    std.log.info("  - RFC 7235 compliant Proxy-Authenticate headers", .{});
    std.log.info("  - Basic authentication with secure password hashing", .{});
    std.log.info("  - Rate limiting for failed authentication attempts", .{});
    std.log.info("  - Per-IP and per-username attempt tracking", .{});
    std.log.info("  - Exponential backoff for repeated failures", .{});
    std.log.info("  - Comprehensive authentication statistics", .{});
    std.log.info("  - Constant-time credential comparison", .{});
    std.log.info("", .{});
    std.log.info("Security Measures:", .{});
    std.log.info("  - Timing attack prevention", .{});
    std.log.info("  - Brute force protection", .{});
    std.log.info("  - Secure credential storage", .{});
    std.log.info("  - Detailed audit logging", .{});

    // Run proxy using the primary API (Io passed as first-class parameter)
    try proxy.runWithIoOptions(io, .{
        .enable_proxy_authentication = true,
        .enable_access_control = true,
        .enable_rate_limiting = true,
        .enable_caching = true,
        .enable_stats = true,
        .enable_connection_logging = true,
    });
}
