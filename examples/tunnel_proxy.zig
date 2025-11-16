const std = @import("std");
const prozy = @import("prozy");

const Proxy = prozy.Proxy;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Create Io executor
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    std.debug.print("\n", .{});
    std.debug.print("=".** 70, .{});
    std.debug.print("\n", .{});
    std.debug.print("  Prozy Phase 3: CONNECT Tunnel Proxy Demo\n", .{});
    std.debug.print("=".** 70, .{});
    std.debug.print("\n\n", .{});

    std.debug.print("This example demonstrates:\n", .{});
    std.debug.print("  - CONNECT method handling for HTTPS proxying\n", .{});
    std.debug.print("  - Raw TCP tunnel establishment\n", .{});
    std.debug.print("  - Transparent TLS forwarding\n", .{});
    std.debug.print("  - Bidirectional data copying\n\n", .{});

    // Create proxy (for CONNECT mode, we just need basic TCP forwarding)
    var proxy = Proxy.init(allocator, 8080, "127.0.0.1", 443);
    defer proxy.deinit();

    std.debug.print("Proxy Configuration:\n", .{});
    std.debug.print("  Listen: 127.0.0.1:8080\n", .{});
    std.debug.print("  Mode: CONNECT Tunnel\n", .{});
    std.debug.print("  Transparent HTTPS proxying enabled\n", .{});
    std.debug.print("\n", .{});

    std.debug.print("Testing Instructions:\n", .{});
    std.debug.print("  1. Use curl with --proxy flag for HTTPS:\n\n", .{});
    std.debug.print("     # HTTPS through CONNECT tunnel\n", .{});
    std.debug.print("     curl --proxy http://localhost:8080 https://httpbin.org/get\n\n", .{});
    std.debug.print("     # HTTPS with verbose output\n", .{});
    std.debug.print("     curl -v --proxy http://localhost:8080 https://example.com/\n\n", .{});
    std.debug.print("  2. Observe tunnel establishment in logs:\n", .{});
    std.debug.print("     - Proxy receives CONNECT request\n", .{});
    std.debug.print("     - Proxy responds with 200 Connection Established\n", .{});
    std.debug.print("     - Raw TCP tunnel forwards encrypted TLS traffic\n\n", .{});
    std.debug.print("  3. Press Ctrl+C for graceful shutdown\n\n", .{});

    std.debug.print("=".** 70, .{});
    std.debug.print("\n\n", .{});

    std.debug.print("Starting CONNECT tunnel proxy...\n\n", .{});

    // Run proxy (CONNECT handling is automatic in handleClientWithFeatures)
    try proxy.runWithIoOptions(io, .{
        .max_connections = 50,
        .enable_stats = true,
        .enable_connection_logging = true,
        .enable_http_inspection = true,
        .enable_caching = false, // No caching for CONNECT tunnels
    });
}
