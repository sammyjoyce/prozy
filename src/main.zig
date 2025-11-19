const std = @import("std");
const prozy = @import("prozy");

const default_config_path = "config/openai_translator.json";

const ConfigPath = struct {
    value: []const u8,
    owned: bool,
};

pub fn main() !void {
    var gpa = std.heap.page_allocator;

    const config_path = resolveConfigPath(gpa) catch |err| {
        std.log.err("Failed to resolve config path: {any}", .{err});
        return;
    };
    defer if (config_path.owned) gpa.free(config_path.value);

    std.log.info("🚀 Starting Prozy LLM Gateway", .{});
    std.log.info("📄 Loading configuration from {s}", .{config_path.value});

    var config_manager = try prozy.ConfigManager.init(gpa, config_path.value);
    defer config_manager.deinit();

    var config_lease = config_manager.getConfig();
    defer config_lease.release();
    const cfg = config_lease.get();

    var gateway = try prozy.Gateway.init(gpa, cfg);
    defer gateway.deinit();

    std.log.info("🔧 Running LLM Gateway (press Ctrl+C to stop)...", .{});

    var threaded_io = std.Io.Threaded.init(gpa);
    defer threaded_io.deinit();

    try gateway.run(threaded_io.io());
}

fn resolveConfigPath(allocator: std.mem.Allocator) !ConfigPath {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // skip executable name
    if (args.next()) |arg| {
        return .{ .value = try allocator.dupe(u8, arg), .owned = true };
    }

    if (std.process.getEnvVarOwned(allocator, "PROZY_CONFIG_PATH")) |env_path| {
        return .{ .value = env_path, .owned = true };
    } else |_| {}

    return .{ .value = default_config_path, .owned = false };
}
