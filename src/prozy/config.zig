const std = @import("std");
const json = std.json;

pub const BackendProvider = struct {
    name: []const u8,
    api_url: []const u8,
    api_key: []const u8,
};

pub const Route = struct {
    inbound_model: []const u8,
    backend_provider: []const u8,
};

pub const ProxyConfig = struct {
    listen_host: []const u8 = "127.0.0.1",
    listen_port: u16 = 8080,
};

pub const Config = struct {
    proxy: ProxyConfig = .{},
    providers: []const BackendProvider = &.{},
    routing_table: []const Route = &.{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.proxy.listen_host);
        for (self.providers) |p| {
            allocator.free(p.name);
            allocator.free(p.api_url);
            allocator.free(p.api_key);
        }
        allocator.free(@ptrCast([*]BackendProvider, self.providers.ptr)[0..self.providers.len]);
        for (self.routing_table) |r| {
            allocator.free(r.inbound_model);
            allocator.free(r.backend_provider);
        }
        allocator.free(@ptrCast([*]Route, self.routing_table.ptr)[0..self.routing_table.len]);
    }
};

pub const ConfigManager = struct {
    allocator: std.mem.Allocator,
    config: *Config,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !ConfigManager {
        const file_contents = std.fs.cwd().readFileAlloc(allocator, path, 1 * 1024 * 1024) catch |err| {
            std.log.err("Failed to read config file '{s}': {any}", .{path, err});
            return err;
        };
        defer allocator.free(file_contents);

        const config = try json.parseFromSlice(Config, allocator, file_contents, .{});

        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *ConfigManager) void {
        self.config.deinit(self.allocator);
        self.allocator.destroy(self.config);
    }

    pub const ConfigLease = struct {
        config: *const Config,
        pub fn get(self: *const ConfigLease) *const Config {
            return self.config;
        }
        pub fn release(self: *const ConfigLease) void {
            _ = self;
        }
    };

    pub fn getConfig(self: *ConfigManager) ConfigLease {
        return .{ .config = self.config };
    }
};
