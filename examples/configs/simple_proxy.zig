//! Simple Proxy Configuration
//!
//! Basic TCP proxy with no additional features.
//! Use case: Simple request forwarding, development, testing

const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Initialize async runtime
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Create basic proxy
    // Listen on 127.0.0.1:8080, forward to 127.0.0.1:3003
    var proxy = prozy.Proxy.init(allocator, 8080, "127.0.0.1", 3003);
    defer proxy.deinit();

    std.log.info("Simple Proxy Configuration", .{});
    std.log.info("  Listen: 127.0.0.1:8080", .{});
    std.log.info("  Backend: 127.0.0.1:3003", .{});
    std.log.info("  Features: None (basic forwarding only)", .{});

    // Run proxy
    try proxy.runWithIo(io);
}
