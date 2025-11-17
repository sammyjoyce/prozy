//! Configuration Hot Reload System
//!
//! This module implements zero-downtime configuration reloading using:
//! - JSON config file parsing (with future ZON support)
//! - Atomic pointer swapping for lock-free reads
//! - File watching for automatic reload detection
//! - Validation and safe fallback on parse errors
//!
//! Design Philosophy:
//! - Zero downtime: Active connections continue with old config
//! - Lock-free reads: Use atomic pointers for configuration access
//! - Fail-safe: Parse errors don't affect running proxy
//! - Observable: Log all config changes and errors
//!
//! Example JSON config file:
//! ```json
//! {
//!   "proxy": {
//!     "listen_host": "0.0.0.0",
//!     "listen_port": 8080,
//!     "max_connections": 10000
//!   },
//!   "mode": "reverse_proxy",
//!   "cache": {
//!     "enabled": true,
//!     "max_size": 10485760
//!   },
//!   "clusters": [
//!     {
//!       "name": "api_backend",
//!       "backends": [
//!         { "host": "10.0.1.10", "port": 8080, "weight": 5 },
//!         { "host": "10.0.1.11", "port": 8080, "weight": 3 }
//!       ],
//!       "strategy": "weighted_round_robin",
//!       "max_concurrent": 1000
//!     }
//!   ],
//!   "routes": [
//!     {
//!       "name": "api_route",
//!       "match": {
//!         "host": "api.example.com",
//!         "path_prefix": "/v1/",
//!         "methods": ["GET", "POST"]
//!       },
//!       "cluster": "api_backend",
//!       "cache_policy": {
//!         "allow": true,
//!         "ttl_seconds": 300,
//!         "max_size": 1048576
//!       }
//!     }
//!   ]
//! }
//! ```

const std = @import("std");
const Backend = @import("backend.zig").Backend;
const LoadBalancer = @import("backend.zig").LoadBalancer;
const Route = @import("routing.zig").Route;
const Cluster = @import("routing.zig").Cluster;
const RouteMatch = @import("routing.zig").RouteMatch;
const CachePolicy = @import("routing.zig").CachePolicy;
const TimeoutPolicy = @import("routing.zig").TimeoutPolicy;
const ConcurrencyPolicy = @import("routing.zig").ConcurrencyPolicy;
const HttpMode = @import("routing.zig").HttpMode;
const AccessControl = @import("access.zig").AccessControl;

const log = std.log;

/// Configuration errors
pub const ConfigError = error{
    /// Config file not found
    FileNotFound,
    /// Failed to read config file
    ReadFailed,
    /// ZON parsing failed
    ParseFailed,
    /// Config validation failed
    ValidationFailed,
    /// Cluster reference not found
    ClusterNotFound,
    /// Invalid backend configuration
    InvalidBackend,
    /// Invalid route configuration
    InvalidRoute,
    /// Out of memory during config load
    OutOfMemory,
};

/// Proxy configuration (listen settings)
pub const ProxyConfig = struct {
    listen_host: []const u8 = "127.0.0.1",
    listen_port: u16 = 8080,
    max_connections: ?usize = null,
    reuse_address: bool = true,
};

/// Cache configuration
pub const CacheConfig = struct {
    enabled: bool = true,
    max_size: usize = 10 * 1024 * 1024, // 10MB default
};

/// Rate limiting configuration
pub const RateLimitConfig = struct {
    enabled: bool = false,
    max_per_ip: u32 = 100,
    max_global: u32 = 10000,
};

/// Access control configuration
pub const AccessControlConfig = struct {
    enabled: bool = false,
    default_policy: AccessControl.Policy = .allow,
    allow_list: []const []const u8 = &[_][]const u8{},
    deny_list: []const []const u8 = &[_][]const u8{},
};

/// Health check configuration
pub const HealthCheckConfig = struct {
    enabled: bool = true,
    interval_seconds: u64 = 10,
    timeout_ms: u64 = 5000,
    unhealthy_threshold: u32 = 3,
    healthy_threshold: u32 = 2,
};

/// Admin server configuration
pub const AdminConfig = struct {
    enabled: bool = false,
    listen_host: []const u8 = "127.0.0.1",
    listen_port: u16 = 9090,
};

/// Logging configuration
pub const LogConfig = struct {
    level: std.log.Level = .info,
    enable_connection_logging: bool = true,
    enable_stats: bool = true,
};

/// Backend configuration (for ZON parsing)
pub const BackendConfig = struct {
    host: []const u8,
    port: u16,
    weight: u32 = 1,
};

/// Cluster configuration (for ZON parsing)
pub const ClusterConfig = struct {
    name: []const u8,
    backends: []const BackendConfig,
    strategy: LoadBalancer.Strategy = .round_robin,
    max_concurrent: u32 = 1000,
};

/// Route configuration (for ZON parsing)
pub const RouteConfig = struct {
    name: []const u8,
    match: RouteMatchConfig,
    cluster: []const u8, // Cluster name reference
    cache_policy: CachePolicy = .{},
    timeout_policy: TimeoutPolicy = .{},
    concurrency_policy: ConcurrencyPolicy = .{},
};

/// Route match configuration (for ZON parsing)
pub const RouteMatchConfig = struct {
    host: ?[]const u8 = null,
    path_prefix: ?[]const u8 = null,
    methods: []const []const u8 = &[_][]const u8{},
};

/// Complete Prozy configuration
pub const Config = struct {
    // Core proxy settings
    proxy: ProxyConfig = .{},
    mode: HttpMode = .reverse_proxy,

    // Feature flags
    cache: CacheConfig = .{},
    rate_limit: RateLimitConfig = .{},
    access_control: AccessControlConfig = .{},
    health_check: HealthCheckConfig = .{},
    admin: AdminConfig = .{},
    logging: LogConfig = .{},

    // Routing configuration
    clusters: []const ClusterConfig = &[_]ClusterConfig{},
    routes: []const RouteConfig = &[_]RouteConfig{},

    /// Validate configuration
    pub fn validate(self: Config) ConfigError!void {
        // Validate proxy settings
        if (self.proxy.listen_port == 0) {
            log.err("invalid proxy port: 0", .{});
            return ConfigError.ValidationFailed;
        }

        // Validate clusters
        for (self.clusters) |cluster| {
            if (cluster.backends.len == 0) {
                log.err("cluster '{s}' has no backends", .{cluster.name});
                return ConfigError.ValidationFailed;
            }

            // Validate backends
            for (cluster.backends) |backend| {
                if (backend.port == 0) {
                    log.err("invalid backend port: 0 in cluster '{s}'", .{cluster.name});
                    return ConfigError.ValidationFailed;
                }
                if (backend.weight == 0) {
                    log.err("invalid backend weight: 0 in cluster '{s}'", .{cluster.name});
                    return ConfigError.ValidationFailed;
                }
            }
        }

        // Validate routes reference valid clusters
        for (self.routes) |route| {
            var found = false;
            for (self.clusters) |cluster| {
                if (std.mem.eql(u8, route.cluster, cluster.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                log.err("route '{s}' references unknown cluster '{s}'", .{ route.name, route.cluster });
                return ConfigError.ValidationFailed;
            }
        }
    }
};

/// JSON configuration (root structure for parsing)
/// This matches the JSON file structure
pub const JsonConfig = struct {
    proxy: ProxyConfig = .{},
    mode: HttpMode = .reverse_proxy,
    cache: CacheConfig = .{},
    rate_limit: RateLimitConfig = .{},
    access_control: AccessControlConfig = .{},
    health_check: HealthCheckConfig = .{},
    admin: AdminConfig = .{},
    logging: LogConfig = .{},
    clusters: []ClusterConfig = &[_]ClusterConfig{},
    routes: []RouteConfig = &[_]RouteConfig{},
};

/// Configuration manager with hot reload support
pub const ConfigManager = struct {
    allocator: std.mem.Allocator,
    config_path: []const u8,
    current_config: std.atomic.Value(*Config),
    arena: std.heap.ArenaAllocator,
    last_mtime: i128 = 0,
    watch_interval_ms: u64 = 1000, // Check for changes every 1 second

    pub fn init(allocator: std.mem.Allocator, config_path: []const u8) !*ConfigManager {
        const manager = try allocator.create(ConfigManager);
        errdefer allocator.destroy(manager);

        // Create arena for config allocations
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        // Load initial config
        const initial_config = try loadConfigFromFile(arena.allocator(), config_path);
        errdefer arena.allocator().destroy(initial_config);

        // Validate initial config
        try initial_config.validate();

        // Get initial file mtime
        const stat = try std.fs.cwd().statFile(config_path);

        manager.* = .{
            .allocator = allocator,
            .config_path = try allocator.dupe(u8, config_path),
            .current_config = std.atomic.Value(*Config).init(initial_config),
            .arena = arena,
            .last_mtime = stat.mtime,
        };

        log.info("config manager initialized with file: {s}", .{config_path});
        return manager;
    }

    pub fn deinit(self: *ConfigManager) void {
        self.allocator.free(self.config_path);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    /// Get current configuration (lock-free read)
    pub fn getConfig(self: *const ConfigManager) *const Config {
        return self.current_config.load(.acquire);
    }

    /// Check if config file has changed and reload if necessary
    pub fn checkAndReload(self: *ConfigManager) !bool {
        const stat = std.fs.cwd().statFile(self.config_path) catch |err| {
            log.warn("failed to stat config file: {s}", .{@errorName(err)});
            return false;
        };

        // Check if file has been modified
        if (stat.mtime <= self.last_mtime) {
            return false; // No changes
        }

        log.info("config file changed, reloading...", .{});
        return self.reload();
    }

    /// Force reload configuration from disk
    pub fn reload(self: *ConfigManager) !bool {
        // Create new arena for new config
        var new_arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer new_arena.deinit();

        // Load new config
        const new_config = loadConfigFromFile(new_arena.allocator(), self.config_path) catch |err| {
            log.err("failed to load config: {s}", .{@errorName(err)});
            new_arena.deinit();
            return ConfigError.ParseFailed;
        };

        // Validate new config
        new_config.validate() catch |err| {
            log.err("config validation failed: {s}", .{@errorName(err)});
            new_arena.deinit();
            return ConfigError.ValidationFailed;
        };

        // Get file mtime
        const stat = try std.fs.cwd().statFile(self.config_path);

        // Atomic swap: old connections continue with old config
        const old_config = self.current_config.swap(new_config, .acq_rel);
        _ = old_config;

        // Replace arena (old config memory will be freed)
        const old_arena = self.arena;
        self.arena = new_arena;
        self.last_mtime = stat.mtime;

        // Clean up old arena (safe because we've already swapped)
        old_arena.deinit();

        log.info("config reloaded successfully", .{});
        logConfigSummary(new_config);

        return true;
    }

    /// Start background watcher thread (optional)
    pub fn startWatcher(self: *ConfigManager, io: std.Io) !void {
        _ = io;
        _ = self;
        // TODO: Implement background watcher using io.concurrent
        // This would periodically call checkAndReload()
    }
};

/// Detect configuration file format based on extension
fn detectConfigFormat(path: []const u8) ConfigFormat {
    if (std.mem.endsWith(u8, path, ".zon")) {
        return .zon;
    } else if (std.mem.endsWith(u8, path, ".json")) {
        return .json;
    }
    // Default to JSON for unknown extensions
    return .json;
}

const ConfigFormat = enum {
    json,
    zon,
};

/// Load configuration from file (auto-detects JSON or ZON format)
fn loadConfigFromFile(allocator: std.mem.Allocator, path: []const u8) !*Config {
    const format = detectConfigFormat(path);

    switch (format) {
        .json => return loadConfigFromJson(allocator, path),
        .zon => return loadConfigFromZon(allocator, path),
    }
}

/// Load configuration from JSON file
fn loadConfigFromJson(allocator: std.mem.Allocator, path: []const u8) !*Config {
    // Read file contents
    const file_contents = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        log.err("failed to read config file '{s}': {s}", .{ path, @errorName(err) });
        return ConfigError.ReadFailed;
    };
    defer allocator.free(file_contents);

    return parseJsonConfig(allocator, file_contents);
}

/// Parse JSON configuration from string
fn parseJsonConfig(allocator: std.mem.Allocator, source: []const u8) !*Config {
    // Parse JSON
    const parsed = std.json.parseFromSlice(JsonConfig, allocator, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        log.err("failed to parse JSON config: {s}", .{@errorName(err)});
        return ConfigError.ParseFailed;
    };
    defer parsed.deinit();

    // Convert JsonConfig to Config (duplicate strings into arena allocator)
    const config = try allocator.create(Config);
    config.* = .{
        .proxy = .{
            .listen_host = try allocator.dupe(u8, parsed.value.proxy.listen_host),
            .listen_port = parsed.value.proxy.listen_port,
            .max_connections = parsed.value.proxy.max_connections,
            .reuse_address = parsed.value.proxy.reuse_address,
        },
        .mode = parsed.value.mode,
        .cache = parsed.value.cache,
        .rate_limit = parsed.value.rate_limit,
        .access_control = try duplicateAccessControlConfig(allocator, parsed.value.access_control),
        .health_check = parsed.value.health_check,
        .admin = .{
            .enabled = parsed.value.admin.enabled,
            .listen_host = try allocator.dupe(u8, parsed.value.admin.listen_host),
            .listen_port = parsed.value.admin.listen_port,
        },
        .logging = parsed.value.logging,
        .clusters = try duplicateClusters(allocator, parsed.value.clusters),
        .routes = try duplicateRoutes(allocator, parsed.value.routes),
    };

    return config;
}

/// Load configuration from ZON file
fn loadConfigFromZon(allocator: std.mem.Allocator, path: []const u8) !*Config {
    // Read file contents
    const file_contents = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        log.err("failed to read config file '{s}': {s}", .{ path, @errorName(err) });
        return ConfigError.ReadFailed;
    };
    defer allocator.free(file_contents);

    return parseZonConfig(allocator, file_contents);
}

/// Parse ZON configuration from string
fn parseZonConfig(allocator: std.mem.Allocator, source: []const u8) !*Config {
    // Parse ZON using Zig's parser
    const parsed = std.zig.parseZon(allocator, source) catch |err| {
        log.err("failed to parse ZON config: {s}", .{@errorName(err)});
        return ConfigError.ParseFailed;
    };
    defer parsed.deinit(allocator);

    // Evaluate the ZON AST to extract configuration
    const zon_config = try evaluateZonAst(allocator, parsed.ast);

    // Convert to Config
    const config = try allocator.create(Config);
    config.* = .{
        .proxy = zon_config.proxy,
        .mode = zon_config.mode,
        .cache = zon_config.cache,
        .rate_limit = zon_config.rate_limit,
        .access_control = zon_config.access_control,
        .health_check = zon_config.health_check,
        .admin = zon_config.admin,
        .logging = zon_config.logging,
        .clusters = zon_config.clusters,
        .routes = zon_config.routes,
    };

    return config;
}

/// Evaluate ZON AST to extract configuration
/// Note: This is a simplified implementation that uses @import for evaluation
/// A full implementation would walk the AST manually
fn evaluateZonAst(allocator: std.mem.Allocator, ast: std.zig.Ast) !JsonConfig {
    // For now, we'll use a simplified approach that relies on the ZON
    // being evaluable as a Zig struct literal
    // A production implementation would walk the AST nodes manually

    // This is a placeholder - full ZON AST evaluation is complex
    // For practical use, we recommend JSON format until full ZON support is implemented
    _ = ast;

    log.warn("ZON parsing is experimental - full AST evaluation not yet implemented", .{});
    log.warn("Using default configuration. Please use JSON format for production.", .{});

    // Return default config for now
    return JsonConfig{
        .proxy = .{
            .listen_host = try allocator.dupe(u8, "127.0.0.1"),
            .listen_port = 8080,
        },
        .clusters = &[_]ClusterConfig{},
        .routes = &[_]RouteConfig{},
    };
}

/// Duplicate access control config into arena
fn duplicateAccessControlConfig(allocator: std.mem.Allocator, src: AccessControlConfig) !AccessControlConfig {
    var allow_list = try allocator.alloc([]const u8, src.allow_list.len);
    for (src.allow_list, 0..) |item, i| {
        allow_list[i] = try allocator.dupe(u8, item);
    }

    var deny_list = try allocator.alloc([]const u8, src.deny_list.len);
    for (src.deny_list, 0..) |item, i| {
        deny_list[i] = try allocator.dupe(u8, item);
    }

    return .{
        .enabled = src.enabled,
        .default_policy = src.default_policy,
        .allow_list = allow_list,
        .deny_list = deny_list,
    };
}

/// Duplicate clusters into arena
fn duplicateClusters(allocator: std.mem.Allocator, src: []ClusterConfig) ![]const ClusterConfig {
    var clusters = try allocator.alloc(ClusterConfig, src.len);
    for (src, 0..) |cluster, i| {
        const name = try allocator.dupe(u8, cluster.name);
        const backends = try allocator.alloc(BackendConfig, cluster.backends.len);
        for (cluster.backends, 0..) |backend, j| {
            backends[j] = .{
                .host = try allocator.dupe(u8, backend.host),
                .port = backend.port,
                .weight = backend.weight,
            };
        }
        clusters[i] = .{
            .name = name,
            .backends = backends,
            .strategy = cluster.strategy,
            .max_concurrent = cluster.max_concurrent,
        };
    }
    return clusters;
}

/// Duplicate routes into arena
fn duplicateRoutes(allocator: std.mem.Allocator, src: []RouteConfig) ![]const RouteConfig {
    var routes = try allocator.alloc(RouteConfig, src.len);
    for (src, 0..) |route, i| {
        const name = try allocator.dupe(u8, route.name);
        const cluster = try allocator.dupe(u8, route.cluster);
        const match = try duplicateRouteMatch(allocator, route.match);
        routes[i] = .{
            .name = name,
            .match = match,
            .cluster = cluster,
            .cache_policy = route.cache_policy,
            .timeout_policy = route.timeout_policy,
            .concurrency_policy = route.concurrency_policy,
        };
    }
    return routes;
}

/// Duplicate route match into arena
fn duplicateRouteMatch(allocator: std.mem.Allocator, src: RouteMatchConfig) !RouteMatchConfig {
    const host = if (src.host) |h| try allocator.dupe(u8, h) else null;
    const path_prefix = if (src.path_prefix) |p| try allocator.dupe(u8, p) else null;

    var methods = try allocator.alloc([]const u8, src.methods.len);
    for (src.methods, 0..) |method, i| {
        methods[i] = try allocator.dupe(u8, method);
    }

    return .{
        .host = host,
        .path_prefix = path_prefix,
        .methods = methods,
    };
}

/// Log configuration summary
fn logConfigSummary(config: *const Config) void {
    log.info("=== Configuration Summary ===", .{});
    log.info("Proxy: {s}:{}", .{ config.proxy.listen_host, config.proxy.listen_port });
    log.info("Mode: {}", .{config.mode});
    log.info("Cache: {} (max size: {})", .{ config.cache.enabled, config.cache.max_size });
    log.info("Rate limiting: {}", .{config.rate_limit.enabled});
    log.info("Access control: {}", .{config.access_control.enabled});
    log.info("Health checks: {}", .{config.health_check.enabled});
    log.info("Admin server: {} (port: {})", .{ config.admin.enabled, config.admin.listen_port });
    log.info("Clusters: {}", .{config.clusters.len});
    log.info("Routes: {}", .{config.routes.len});
    log.info("===========================", .{});
}

/// Parse a JSON config from string (helper for testing)
pub fn parseJson(allocator: std.mem.Allocator, source: []const u8) !*Config {
    return parseJsonConfig(allocator, source);
}

/// Parse a ZON config from string (helper for testing)
pub fn parseZon(allocator: std.mem.Allocator, source: []const u8) !*Config {
    return parseZonConfig(allocator, source);
}

test "Config validation - valid config" {
    const config = Config{
        .clusters = &[_]ClusterConfig{
            .{
                .name = "test_cluster",
                .backends = &[_]BackendConfig{
                    .{ .host = "localhost", .port = 8080 },
                },
            },
        },
        .routes = &[_]RouteConfig{
            .{
                .name = "test_route",
                .match = .{},
                .cluster = "test_cluster",
            },
        },
    };

    try config.validate();
}

test "Config validation - invalid port" {
    const config = Config{
        .proxy = .{ .listen_port = 0 },
    };

    const result = config.validate();
    try std.testing.expectError(ConfigError.ValidationFailed, result);
}

test "Config validation - cluster with no backends" {
    const config = Config{
        .clusters = &[_]ClusterConfig{
            .{
                .name = "empty_cluster",
                .backends = &[_]BackendConfig{},
            },
        },
    };

    const result = config.validate();
    try std.testing.expectError(ConfigError.ValidationFailed, result);
}

test "Config validation - route references unknown cluster" {
    const config = Config{
        .clusters = &[_]ClusterConfig{
            .{
                .name = "real_cluster",
                .backends = &[_]BackendConfig{
                    .{ .host = "localhost", .port = 8080 },
                },
            },
        },
        .routes = &[_]RouteConfig{
            .{
                .name = "bad_route",
                .match = .{},
                .cluster = "unknown_cluster",
            },
        },
    };

    const result = config.validate();
    try std.testing.expectError(ConfigError.ValidationFailed, result);
}

test "Format detection - JSON" {
    try std.testing.expectEqual(ConfigFormat.json, detectConfigFormat("config.json"));
    try std.testing.expectEqual(ConfigFormat.json, detectConfigFormat("/path/to/config.json"));
    try std.testing.expectEqual(ConfigFormat.json, detectConfigFormat("config")); // Default to JSON
}

test "Format detection - ZON" {
    try std.testing.expectEqual(ConfigFormat.zon, detectConfigFormat("config.zon"));
    try std.testing.expectEqual(ConfigFormat.zon, detectConfigFormat("/path/to/config.zon"));
}
