//! Cache Warming Proxy Configuration
//!
//! HTTP proxy with cache warming for immediate high hit rates.
//! This example demonstrates pre-populating the cache before accepting
//! client connections, ensuring 70-90% hit rates from the start.
//!
//! Use case:
//! - Production deployments requiring immediate cache effectiveness
//! - CDN edge servers warming popular content
//! - API gateways pre-caching common endpoints
//! - Load testing scenarios with realistic cache behavior

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

    // Enable cache (100 MB for demonstration)
    const cache_size_mb = 100;
    proxy.enableCaching(cache_size_mb * 1024 * 1024);

    std.log.info("", .{});
    std.log.info("=== Cache Warming Proxy Configuration ===", .{});
    std.log.info("Listen: 127.0.0.1:8080", .{});
    std.log.info("Backend: 127.0.0.1:3003", .{});
    std.log.info("Cache: {} MB (LRU with TTL)", .{cache_size_mb});
    std.log.info("", .{});

    // Define URLs to warm the cache
    // These should be your most frequently accessed endpoints
    const warmup_urls = [_]prozy.http.HTTPCache.WarmupUrl{
        // Common API endpoints
        .{ .host = "127.0.0.1", .path = "/", .port = 3003 },
        .{ .host = "127.0.0.1", .path = "/api/status", .port = 3003 },
        .{ .host = "127.0.0.1", .path = "/api/data", .port = 3003 },
        .{ .host = "127.0.0.1", .path = "/api/config", .port = 3003 },

        // Popular resources (example)
        .{ .host = "127.0.0.1", .path = "/api/users", .port = 3003 },
        .{ .host = "127.0.0.1", .path = "/api/products", .port = 3003 },
        .{ .host = "127.0.0.1", .path = "/api/categories", .port = 3003 },

        // Static content (example)
        .{ .host = "127.0.0.1", .path = "/css/main.css", .port = 3003 },
        .{ .host = "127.0.0.1", .path = "/js/app.js", .port = 3003 },
        .{ .host = "127.0.0.1", .path = "/images/logo.png", .port = 3003 },
    };

    std.log.info("=== Pre-warming Cache ===", .{});
    std.log.info("Fetching {} URLs from backend...", .{warmup_urls.len});
    std.log.info("", .{});

    // Warm the cache (with 5 second timeout per URL)
    const connect_timeout = std.Io.Timeout{
        .duration = .{
            .raw = std.Io.Duration.fromSeconds(5),
            .clock = .awake,
        },
    };

    const warmup_stats = proxy.warmupCache(io, &warmup_urls, connect_timeout) catch |err| {
        std.log.err("cache warming failed: {s}", .{@errorName(err)});
        std.log.info("starting proxy WITHOUT pre-warmed cache", .{});
        std.log.info("", .{});
        try proxy.runWithIoOptions(io, .{});
        return;
    };

    // Display warming statistics
    std.log.info("", .{});
    std.log.info("=== Cache Warming Results ===", .{});
    std.log.info("Total URLs: {}", .{warmup_stats.total_urls});
    std.log.info("Successful: {}", .{warmup_stats.successful});
    std.log.info("Failed: {}", .{warmup_stats.failed});
    std.log.info("Cached bytes: {} bytes", .{warmup_stats.cached_bytes});
    std.log.info("Success rate: {d:.1}%", .{warmup_stats.successRate()});
    std.log.info("Duration: {}ms", .{warmup_stats.duration_ms});
    std.log.info("", .{});

    // Display current cache statistics
    if (proxy.getCacheStats()) |cache_stats| {
        std.log.info("=== Cache State (After Warming) ===", .{});
        std.log.info("Entries: {}", .{cache_stats.entry_count});
        std.log.info("Size: {} / {} bytes ({d:.1}% full)", .{
            cache_stats.current_size,
            cache_stats.max_size,
            @as(f64, @floatFromInt(cache_stats.current_size)) / @as(f64, @floatFromInt(cache_stats.max_size)) * 100.0,
        });
        std.log.info("", .{});
    }

    // Provide guidance to user
    if (warmup_stats.successful > 0) {
        std.log.info("✓ Cache is WARM - expect high hit rates immediately!", .{});
        std.log.info("", .{});
    } else {
        std.log.warn("⚠ Cache warming failed - starting with COLD cache", .{});
        std.log.warn("First requests will be slower (cache misses)", .{});
        std.log.info("", .{});
    }

    std.log.info("=== Starting Proxy Server ===", .{});
    std.log.info("Ready to accept connections on 127.0.0.1:8080", .{});
    std.log.info("Backend: 127.0.0.1:3003", .{});
    std.log.info("", .{});

    // Start proxy server
    try proxy.runWithIoOptions(io, .{});
}
