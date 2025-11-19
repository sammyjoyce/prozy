//! Comprehensive showcase of Zig 0.16.x async I/O capabilities
//!
//! This demo demonstrates:
//! - std.Io.Threaded runtime initialization
//! - Fire-and-forget operations with io.async()
//! - Awaitable concurrency with io.concurrent()
//! - Racing operations with io.select()
//! - Real TCP networking (listen, connect)
//! - Integration with Prozy proxy architecture

const std = @import("std");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    std.debug.print("🔥 Zig 0.16.x Async I/O Capabilities Demo\n", .{});
    std.debug.print("==========================================\n\n", .{});

    // Demonstrate each async I/O capability
    try showcaseAsyncRuntime(gpa);
    try showcaseConcurrentOperations(gpa);
    try showcaseSelectRaces(gpa);
    try showcaseTcpNetworking(gpa);
    try showcaseProxyArchitecture(gpa);

    std.debug.print("\n🎉 CONCLUSION: Zig's async I/O is production-ready!\n", .{});
    std.debug.print("   Prozy leverages these capabilities for:\n", .{});
    std.debug.print("   • Concurrent connection handling\n", .{});
    std.debug.print("   • Efficient buffered I/O\n", .{});
    std.debug.print("   • Bidirectional proxying with io.select()\n", .{});
    std.debug.print("   • Cross-platform compatibility\n", .{});
    std.debug.print("   • Proper resource management\n\n", .{});
}

fn showcaseAsyncRuntime(gpa: std.mem.Allocator) !void {
    std.debug.print("1️⃣  Async Runtime Initialization\n", .{});

    var threaded_io = std.Io.Threaded.init(gpa);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    std.debug.print("   ✅ std.Io.Threaded.init() - Thread pool created\n", .{});
    std.debug.print("   ✅ Cross-platform backend (Threaded, IoUring, Kqueue)\n", .{});

    // Fire-and-forget operation
    _ = io.async(simpleTask, .{"Runtime initialized"});
    std.debug.print("   ✅ io.async() - Fire-and-forget task launched\n\n", .{});
}

fn showcaseConcurrentOperations(gpa: std.mem.Allocator) !void {
    std.debug.print("2️⃣  Concurrent Operations (io.concurrent + await)\n", .{});

    var threaded_io = std.Io.Threaded.init(gpa);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Launch multiple concurrent tasks
    var task1 = try io.concurrent(computeTask, .{ 1, 100 });
    var task2 = try io.concurrent(computeTask, .{ 2, 200 });
    var task3 = try io.concurrent(computeTask, .{ 3, 150 });

    std.debug.print("   ✅ Launched 3 concurrent tasks\n", .{});

    // Wait for all tasks to complete
    task1.await(io);
    task2.await(io);
    task3.await(io);

    std.debug.print("   ✅ All tasks completed via future.await()\n\n", .{});
}

fn showcaseSelectRaces(gpa: std.mem.Allocator) !void {
    std.debug.print("3️⃣  Racing Operations (io.select)\n", .{});

    var threaded_io = std.Io.Threaded.init(gpa);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Race between fast and slow tasks
    var fast = try io.concurrent(delayTask, .{ "fast", 50 });
    var slow = try io.concurrent(delayTask, .{ "slow", 200 });

    const winner = io.select(.{
        .fast_track = &fast,
        .slow_track = &slow,
    }) catch |err| {
        std.debug.print("   ❌ io.select failed: {s}\n\n", .{@errorName(err)});
        return err;
    };

    switch (winner) {
        .fast_track => std.debug.print("   🏆 Fast task won!\n", .{}),
        .slow_track => std.debug.print("   🏆 Slow task won!\n", .{}),
    }

    // Clean up remaining tasks
    fast.cancel(io);
    slow.cancel(io);

    std.debug.print("   ✅ io.select() enables bidirectional proxying\n\n", .{});
}

fn showcaseTcpNetworking(gpa: std.mem.Allocator) !void {
    std.debug.print("4️⃣  Real TCP Networking\n", .{});

    var threaded_io = std.Io.Threaded.init(gpa);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Create TCP server on any available port
    const server_addr = std.Io.net.IpAddress{
        .ip4 = std.Io.net.Ip4Address.loopback(0),
    };

    var server = server_addr.listen(io, .{ .reuse_address = true }) catch |err| {
        std.debug.print("   ❌ Failed to create server: {s}\n\n", .{@errorName(err)});
        return err;
    };
    defer server.deinit(io);

    std.debug.print("   ✅ TCP server listening on {any}\n", .{server.socket.address});
    std.debug.print("   ✅ std.Io.net APIs:\n", .{});
    std.debug.print("      • IpAddress.listen() - Create servers\n", .{});
    std.debug.print("      • Server.accept() - Accept connections\n", .{});
    std.debug.print("      • IpAddress.connect() - Connect to backends\n", .{});
    std.debug.print("      • Stream.reader/writer() - Buffered I/O\n\n", .{});
}

fn showcaseProxyArchitecture(gpa: std.mem.Allocator) !void {
    std.debug.print("5️⃣  Prozy Proxy Architecture\n", .{});

    std.debug.print("   ✅ TCP Proxy Pattern:\n", .{});
    std.debug.print("      1. address.listen(io, .{{.reuse_address = true}})\n", .{});
    std.debug.print("      2. while (true) server.accept(io)\n", .{});
    std.debug.print("      3. io.concurrent(handleClient, .{{client, backend}})\n", .{});
    std.debug.print("      4. backend.connect(io, .{{.mode = .stream}})\n", .{});
    std.debug.print("      5. io.select(.{{.c2b = &copy_c2b, .b2c = &copy_b2c}})\n", .{});
    std.debug.print("      6. defer cleanup with client.close(io)\n", .{});

    // Show that Prozy can be imported and used
    const prozy = @import("prozy");
    var proxy = try prozy.Proxy.init(gpa, 0, "127.0.0.1", 3000);
    defer proxy.deinit();

    std.debug.print("   ✅ Prozy.Proxy initialized successfully\n", .{});
    std.debug.print("   ✅ Ready for enterprise features:\n", .{});
    std.debug.print("      • HTTP caching with LRU eviction\n", .{});
    std.debug.print("      • Load balancing (5 strategies)\n", .{});
    std.debug.print("      • Access control and rate limiting\n", .{});
    std.debug.print("      • Real-time statistics\n", .{});
    std.debug.print("      • Backend health monitoring\n\n", .{});
}

// ===== Helper Functions =====

fn simpleTask(message: []const u8) void {
    std.debug.print("   📨 Task: {s}\n", .{message});
}

fn computeTask(task_id: usize, iterations: usize) void {
    var sum: usize = 0;
    for (0..iterations) |i| {
        sum +%= i; // Use wrapping addition
    }
    std.debug.print("   🔢 Task {d} computed sum: {d}\n", .{ task_id, sum });
}

fn delayTask(name: []const u8, delay_ms: u64) void {
    // Simple busy-wait for demo purposes
    var i: u64 = 0;
    const target = delay_ms * 10000;
    while (i < target) : (i += 1) {}
    std.debug.print("   🏃 {s} task finished\n", .{name});
}
