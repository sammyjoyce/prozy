//! Caching Proxy Configuration
//!
//! HTTP proxy with aggressive caching for performance.
//! Use case: CDN, content delivery, static asset serving

const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Create proxy with caching enabled
    var proxy = prozy.Proxy.init(allocator, 8080, "127.0.0.1", 3003);
    defer proxy.deinit();

    // Enable large cache (1 GB) for high hit rates
    // Suitable for static content, images, videos, etc.
    const cache_size_mb = 1024; // 1 GB
    proxy.enableCaching(cache_size_mb * 1024 * 1024);

    std.log.info("Caching Proxy Configuration", .{});
    std.log.info("  Listen: 127.0.0.1:8080", .{});
    std.log.info("  Backend: 127.0.0.1:3003", .{});
    std.log.info("  Cache: {} MB (LRU with TTL)", .{cache_size_mb});
    std.log.info("  Use case: CDN, static content delivery", .{});

    // Run proxy using the primary API (Io passed as first-class parameter)
    try proxy.runWithIoOptions(io, .{});
}
