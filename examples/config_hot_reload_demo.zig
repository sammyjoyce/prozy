//! Configuration Hot Reload Demo
//!
//! This example demonstrates:
//! 1. Loading configuration from JSON file
//! 2. Starting proxy with config
//! 3. Detecting config file changes
//! 4. Reloading config with zero downtime
//!
//! Usage:
//!   zig build config_reload_demo
//!
//! Then in another terminal:
//!   1. Edit config/simple.json
//!   2. Touch the file: touch config/simple.json
//!   3. Watch the logs show config reload

const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.log.info("=== Prozy Config Hot Reload Demo ===", .{});
    std.log.info("", .{});

    // Create Io executor
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Initialize config manager
    const config_path = "config/simple.json";
    std.log.info("Loading config from: {s}", .{config_path});

    var config_manager = try prozy.ConfigManager.init(allocator, config_path);
    defer config_manager.deinit();

    std.log.info("Config loaded successfully!", .{});
    std.log.info("", .{});

    // Get initial config
    {
        var initial_config = config_manager.getConfig();
        defer initial_config.release();
        const initial = initial_config.get();
        std.log.info("Initial configuration:", .{});
        std.log.info("  Listen: {s}:{}", .{ initial.proxy.listen_host, initial.proxy.listen_port });
        std.log.info("  Mode: {}", .{initial.mode});
        std.log.info("  Clusters: {}", .{initial.clusters.len});
        std.log.info("  Routes: {}", .{initial.routes.len});
    }
    std.log.info("", .{});

    // Simulate config reload monitoring
    std.log.info("Starting config reload monitor...", .{});
    std.log.info("Try editing config/simple.json to trigger a reload!", .{});
    std.log.info("", .{});

    // Monitor for config changes (in a real application, this would be in a background thread)
    var iterations: usize = 0;
    const max_iterations = 30; // Run for 30 seconds

    while (iterations < max_iterations) : (iterations += 1) {
        // Check for config changes
        const reloaded = config_manager.checkAndReload() catch |err| {
            std.log.err("Failed to check/reload config: {s}", .{@errorName(err)});
            continue;
        };

        if (reloaded) {
            std.log.info("", .{});
            std.log.info("✓ Config reloaded successfully!", .{});
            var new_config_guard = config_manager.getConfig();
            defer new_config_guard.release();
            const new_config = new_config_guard.get();
            std.log.info("New configuration:", .{});
            std.log.info("  Listen: {s}:{}", .{ new_config.proxy.listen_host, new_config.proxy.listen_port });
            std.log.info("  Mode: {}", .{new_config.mode});
            std.log.info("  Clusters: {}", .{new_config.clusters.len});
            std.log.info("  Routes: {}", .{new_config.routes.len});
            std.log.info("", .{});
            std.log.info("Active connections would continue using old config", .{});
            std.log.info("New connections would use new config", .{});
            std.log.info("", .{});
        }

        // Sleep for 1 second
        io.sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
    }

    std.log.info("Demo completed. In production, the monitor would run continuously.", .{});
}
