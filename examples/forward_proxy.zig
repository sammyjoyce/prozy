//! Forward Proxy Example
//!
//! Demonstrates forward proxy mode where the proxy parses absolute URIs
//! and routes to the origin server.
//!
//! Usage:
//!   zig run examples/forward_proxy.zig
//!
//!   # In another terminal, use as HTTP proxy:
//!   curl --proxy http://localhost:8080 http://example.com/
//!   curl --proxy http://localhost:8080 http://httpbin.org/get
//!   curl --proxy http://localhost:8080 https://httpbin.org/get  # HTTPS via CONNECT
//!
//! The proxy will:
//! 1. Parse absolute URIs (http://example.com/path)
//! 2. Extract host and port from URI
//! 3. Connect to origin server
//! 4. Forward the request with origin-form path (/path)

const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Create Io executor
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Create proxy in forward proxy mode
    var proxy = prozy.Proxy.init(allocator, 8080, "127.0.0.1", 3003);
    defer proxy.deinit();

    // Set mode to forward_proxy (parses absolute URIs)
    proxy.mode = .forward_proxy;

    // Enable features
    proxy.enableCaching(10 * 1024 * 1024); // 10MB cache
    proxy.enableRateLimiting(100, 1000); // 100 per IP, 1000 global

    std.log.info("Forward proxy listening on 127.0.0.1:8080", .{});
    std.log.info("", .{});
    std.log.info("Mode: forward_proxy (parses absolute URIs)", .{});
    std.log.info("", .{});
    std.log.info("Usage:", .{});
    std.log.info("  curl --proxy http://localhost:8080 http://example.com/", .{});
    std.log.info("  curl --proxy http://localhost:8080 http://httpbin.org/get", .{});
    std.log.info("  curl --proxy http://localhost:8080 https://httpbin.org/get  # HTTPS via CONNECT", .{});
    std.log.info("", .{});
    std.log.info("The proxy will:", .{});
    std.log.info("  1. Parse absolute URIs (http://example.com/path)", .{});
    std.log.info("  2. Extract host and port from URI", .{});
    std.log.info("  3. Connect to origin server", .{});
    std.log.info("  4. Forward request with origin-form path (/path)", .{});
    std.log.info("", .{});

    // Run proxy
    try proxy.runWithIoOptions(io, .{
        .enable_stats = true,
        .enable_caching = true,
        .enable_rate_limiting = true,
        .enable_connection_logging = true,
    });
}
