const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Get config path from args
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const config_path = args.next() orelse "config/simple.json";

    std.log.info("Loading configuration from: {s}", .{config_path});

    // Initialize ConfigManager
    const manager = try prozy.ConfigManager.init(allocator, config_path);
    defer manager.deinit();

    // Create Io executor
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Start watcher
    try manager.startWatcher(io);
    defer manager.stopWatcher(io);

    // Get initial config
    var lease = manager.getConfig();
    const config = lease.get();

    std.log.info("Initializing proxy on {s}:{d}", .{
        config.proxy.listen_host,
        config.proxy.listen_port,
    });

    // Initialize proxy
    var proxy = try prozy.Proxy.initFromConfig(allocator, config);
    defer proxy.deinit();
    lease.release();

    // Run proxy
    try proxy.runWithIo(io);
}
