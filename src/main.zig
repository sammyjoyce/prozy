//! Real async TCP proxy using Zig's new I/O system

const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    // Initialize the real async TCP proxy
    std.debug.print("🚀 Starting Prozy TCP Proxy with Zig's new async I/O\n", .{});
    std.debug.print("📡 Real async implementation using std.Io.Threaded\n", .{});
    std.debug.print("🔥 Demonstrating io.concurrent() and io.select() capabilities\n\n", .{});

    // Create the async runtime once and pass it down, per the new std.Io guidance
    var threaded_io = std.Io.Threaded.init(gpa);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Create and run the actual proxy (listen: 8080 → forward: 3003)
    var proxy = prozy.Proxy.init(gpa, 8080, "127.0.0.1", 3003);
    defer proxy.deinit();

    std.debug.print("🎯 Proxy Configuration:\n", .{});
    std.debug.print("   • Listen on 127.0.0.1:8080\n", .{});
    std.debug.print("   • Forward to 127.0.0.1:3003\n", .{});
    std.debug.print("   • Using async I/O with thread pool\n\n", .{});

    std.debug.print("✨ Async I/O Features Demonstrated:\n", .{});
    std.debug.print("   ✓ std.Io.Threaded.init() - Cross-platform async runtime\n", .{});
    std.debug.print("   ✓ io.concurrent() - True concurrent operations\n", .{});
    std.debug.print("   ✓ io.select() - Multi-future coordination\n", .{});
    std.debug.print("   ✓ Buffered Stream readers/writers\n", .{});
    std.debug.print("   ✓ Proper resource cleanup with defer\n", .{});
    std.debug.print("   ✓ Graceful cancellation of async tasks\n\n", .{});

    std.debug.print("🔧 Running real TCP proxy (press Ctrl+C to stop)...\n", .{});

    try proxy.runWithIo(io);
}
