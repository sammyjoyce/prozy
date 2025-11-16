//! HTTP Proxy Example (L7 Mode)
//!
//! Demonstrates the new HTTP-aware proxy mode with:
//! - L7 request/response handling
//! - HTTP keep-alive support
//! - Cache integration at the request level
//! - Load balancing with HTTP awareness
//!
//! Usage:
//!   zig build && zig build-exe examples/configs/http_proxy.zig
//!   ./http_proxy
//!
//! Then test with:
//!   curl -v http://localhost:8080/api/test
//!   curl -v -H "Connection: keep-alive" http://localhost:8080/api/test

const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    std.debug.print("🌐 Starting Prozy in HTTP Proxy Mode (L7)\n", .{});
    std.debug.print("=========================================\n\n", .{});

    // Create Io executor once (Andrew Kelley's pattern)
    var threaded_io = std.Io.Threaded.init(gpa);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Initialize proxy
    var proxy = prozy.Proxy.init(gpa, 8080, "127.0.0.1", 3003);
    defer proxy.deinit();

    // Enable HTTP caching (10MB cache)
    proxy.enableCaching(10 * 1024 * 1024);

    std.debug.print("🎯 Configuration:\n", .{});
    std.debug.print("   • Mode: HTTP Proxy (L7)\n", .{});
    std.debug.print("   • Listen: 127.0.0.1:8080\n", .{});
    std.debug.print("   • Backend: 127.0.0.1:3003\n", .{});
    std.debug.print("   • Cache: 10MB (GET requests only)\n", .{});
    std.debug.print("   • Keep-Alive: Enabled\n\n", .{});

    std.debug.print("✨ L7 Features:\n", .{});
    std.debug.print("   ✓ HTTP request/response parsing\n", .{});
    std.debug.print("   ✓ Keep-alive support (multiple requests per connection)\n", .{});
    std.debug.print("   ✓ Host-aware caching (multi-tenant isolation)\n", .{});
    std.debug.print("   ✓ Method-based routing (GET, POST, etc.)\n", .{});
    std.debug.print("   ✓ Connection header handling\n", .{});
    std.debug.print("   ✓ Proper HTTP lifecycle management\n\n", .{});

    std.debug.print("🔧 Testing:\n", .{});
    std.debug.print("   curl -v http://localhost:8080/api/test\n", .{});
    std.debug.print("   curl -v -H \"Connection: keep-alive\" http://localhost:8080/\n\n", .{});

    std.debug.print("🚀 Starting proxy (press Ctrl+C to stop)...\n\n", .{});

    // Run in HTTP proxy mode with keep-alive
    try proxy.runWithIoOptions(io, .{
        .http_mode = .http_proxy,
        .enable_caching = true,
        .enable_stats = true,
        .enable_connection_logging = true,
        .enable_http_inspection = true,
    });
}
