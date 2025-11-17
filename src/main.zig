//! Real async TCP proxy using Zig's new I/O system

const std = @import("std");
const prozy = @import("prozy");
const Io = std.Io;
const net = Io.net;

const default_config_path = "config/openai_translator.json";

const ConfigPath = struct {
    value: []const u8,
    owned: bool,
};

const BackendTarget = struct {
    host: []const u8,
    port: u16,
};

const DerivedSettings = struct {
    listen_host: []const u8,
    listen_port: u16,
    backend: BackendTarget,
};

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    const config_path = try resolveConfigPath(gpa);
    defer if (config_path.owned) gpa.free(config_path.value);

    std.debug.print("🚀 Starting Prozy TCP Proxy with Zig's new async I/O\n", .{});
    std.debug.print("📄 Loading configuration from {s}\n", .{config_path.value});

    var threaded_io = Io.Threaded.init(gpa);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var config_manager = try prozy.ConfigManager.init(gpa, config_path.value);
    defer config_manager.deinit();

    var config_lease = config_manager.getConfig();
    defer config_lease.release();
    const cfg = config_lease.get();

    const derived = try deriveProxySettings(cfg);

    const listen_host = try gpa.dupe(u8, derived.listen_host);
    defer gpa.free(listen_host);
    const backend_host = try gpa.dupe(u8, derived.backend.host);
    defer gpa.free(backend_host);

    var proxy = prozy.Proxy.init(gpa, derived.listen_port, backend_host, derived.backend.port);
    defer proxy.deinit();

    try configureProxyFeatures(&proxy, cfg);

    std.debug.print("🎯 Proxy Configuration:\n", .{});
    std.debug.print("   • Listen on {s}:{}\n", .{ listen_host, derived.listen_port });
    std.debug.print("   • Forward to {s}:{}\n", .{ backend_host, derived.backend.port });
    std.debug.print("   • Using async I/O with threaded executor\n\n", .{});

    std.debug.print("🧠 Capabilities enabled:\n", .{});
    std.debug.print("   ✓ std.Io.Threaded runtime\n", .{});
    std.debug.print("   ✓ io.concurrent() & io.select()\n", .{});
    std.debug.print("   ✓ Config-driven bootstrap\n\n", .{});
    std.debug.print("🔧 Running real TCP proxy (press Ctrl+C to stop)...\n", .{});

    const run_options = buildRunOptions(cfg, listen_host);

    try proxy.runWithIoOptions(io, run_options);
}

fn resolveConfigPath(allocator: std.mem.Allocator) !ConfigPath {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    if (args.next()) |arg| {
        const copy = try allocator.dupe(u8, arg);
        return .{ .value = copy, .owned = true };
    }

    const env_value: ?[]u8 = std.process.getEnvVarOwned(allocator, "PROZY_CONFIG_PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_value) |value| {
        return .{ .value = value, .owned = true };
    }

    return .{ .value = default_config_path, .owned = false };
}

fn deriveProxySettings(cfg: *const prozy.Config) !DerivedSettings {
    const backend = try pickBackendTarget(cfg);
    return .{
        .listen_host = cfg.proxy.listen_host,
        .listen_port = cfg.proxy.listen_port,
        .backend = backend,
    };
}

fn pickBackendTarget(cfg: *const prozy.Config) !BackendTarget {
    if (cfg.routes.len != 0) {
        for (cfg.routes) |route| {
            if (findCluster(cfg, route.cluster)) |cluster| {
                if (cluster.backends.len == 0) continue;
                const backend = cluster.backends[0];
                return .{ .host = backend.host, .port = backend.port };
            }
        }
    }

    if (cfg.clusters.len != 0) {
        const cluster = cfg.clusters[0];
        if (cluster.backends.len == 0) return error.NoBackendConfigured;
        const backend = cluster.backends[0];
        return .{ .host = backend.host, .port = backend.port };
    }

    return error.NoBackendConfigured;
}

fn findCluster(cfg: *const prozy.Config, name: []const u8) ?*const prozy.ClusterConfig {
    for (cfg.clusters) |cluster| {
        if (std.mem.eql(u8, cluster.name, name)) {
            return &cluster;
        }
    }
    return null;
}

fn configureProxyFeatures(proxy: *prozy.Proxy, cfg: *const prozy.Config) !void {
    if (cfg.cache.enabled) {
        proxy.enableCaching(cfg.cache.max_size);
    }

    if (cfg.rate_limit.enabled) {
        proxy.enableRateLimiting(cfg.rate_limit.max_per_ip, cfg.rate_limit.max_global);
    }

    if (cfg.access_control.enabled) {
        try proxy.enableAccessControl(cfg.access_control.default_policy);
        if (proxy.access_control) |*acl| {
            try populateAclList(acl, cfg.access_control.allow_list, true);
            try populateAclList(acl, cfg.access_control.deny_list, false);
        }
    }
}

fn populateAclList(acl: *prozy.AccessControl, entries: []const []const u8, is_allow_list: bool) !void {
    for (entries) |entry| {
        const key = try parseIpKey(entry);
        if (is_allow_list) {
            try acl.addToAllowList(key);
        } else {
            try acl.addToDenyList(key);
        }
    }
}

fn parseIpKey(text: []const u8) !prozy.IpKey {
    if (net.Ip4Address.parse(text, 0)) |ip4| {
        return prozy.IpKey.fromAddress(.{ .ip4 = ip4 });
    } else |_| {}

    if (net.Ip6Address.parse(text, 0)) |ip6| {
        return prozy.IpKey.fromAddress(.{ .ip6 = ip6 });
    } else |_| {}

    return error.InvalidIpAddress;
}

fn buildRunOptions(cfg: *const prozy.Config, listen_host: []const u8) prozy.RunOptions {
    return .{
        .listen_host = listen_host,
        .max_connections = cfg.proxy.max_connections,
        .reuse_address = cfg.proxy.reuse_address,
        .enable_stats = cfg.logging.enable_stats,
        .enable_access_control = cfg.access_control.enabled,
        .enable_rate_limiting = cfg.rate_limit.enabled,
        .enable_http_inspection = true,
        .enable_connection_logging = cfg.logging.enable_connection_logging,
        .enable_caching = cfg.cache.enabled,
        .enable_load_balancing = false,
    };
}
