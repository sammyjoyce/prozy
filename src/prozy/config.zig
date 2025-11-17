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
const builtin = @import("builtin");
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

fn logValidationError(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.err(fmt, args);
    }
}

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
            logValidationError("invalid proxy port: 0", .{});
            return ConfigError.ValidationFailed;
        }

        // Validate clusters
        for (self.clusters) |cluster| {
            if (cluster.backends.len == 0) {
                logValidationError("cluster '{s}' has no backends", .{cluster.name});
                return ConfigError.ValidationFailed;
            }

            // Validate backends
            for (cluster.backends) |backend| {
                if (backend.port == 0) {
                    logValidationError("invalid backend port: 0 in cluster '{s}'", .{cluster.name});
                    return ConfigError.ValidationFailed;
                }
                if (backend.weight == 0) {
                    logValidationError("invalid backend weight: 0 in cluster '{s}'", .{cluster.name});
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
                logValidationError("route '{s}' references unknown cluster '{s}'", .{ route.name, route.cluster });
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
    last_mtime: std.Io.Timestamp = .{ .nanoseconds = 0 },
    watch_interval_ms: u64 = 1000, // Check for changes every 1 second
    active_readers: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    retired_head: ?*RetiredArena = null,
    retired_tail: ?*RetiredArena = null,
    retired_lock: std.Thread.Mutex = .{},

    const RetiredArena = struct {
        arena: std.heap.ArenaAllocator,
        next: ?*RetiredArena = null,
    };

    pub const ConfigLease = struct {
        manager: *ConfigManager,
        config: *const Config,
        released: bool = false,

        /// Borrow the underlying config pointer.
        pub fn get(self: *const ConfigLease) *const Config {
            return self.config;
        }

        /// Release the lease so the manager can reclaim retired arenas.
        pub fn release(self: *ConfigLease) void {
            if (self.released) return;
            self.released = true;
            self.manager.releaseReader();
        }
    };

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
            .active_readers = std.atomic.Value(usize).init(0),
            .retired_head = null,
            .retired_tail = null,
            .retired_lock = .{},
        };

        log.info("config manager initialized with file: {s}", .{config_path});
        return manager;
    }

    pub fn deinit(self: *ConfigManager) void {
        self.allocator.free(self.config_path);
        self.arena.deinit();
        self.drainRetiredArenas();
        std.debug.assert(self.active_readers.load(.acquire) == 0);
        self.allocator.destroy(self);
    }

    /// Get current configuration (lock-free read)
    pub fn getConfig(self: *const ConfigManager) ConfigLease {
        const manager = @constCast(self);
        _ = manager.active_readers.fetchAdd(1, .acq_rel);
        const ptr = manager.current_config.load(.acquire);
        return .{
            .manager = manager,
            .config = ptr,
        };
    }

    /// Check if config file has changed and reload if necessary
    pub fn checkAndReload(self: *ConfigManager) !bool {
        const stat = std.fs.cwd().statFile(self.config_path) catch |err| {
            log.warn("failed to stat config file: {s}", .{@errorName(err)});
            return false;
        };

        // Check if file has been modified
        if (stat.mtime.nanoseconds <= self.last_mtime.nanoseconds) {
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

        var retired_node = try self.createRetiredArenaNode();

        // Atomic swap: old connections continue with old config
        const old_config = self.current_config.swap(new_config, .acq_rel);
        _ = old_config;

        // Replace arena (old config memory will be freed)
        retired_node.arena = self.arena;
        self.arena = new_arena;
        self.last_mtime = stat.mtime;

        self.enqueueRetiredArena(retired_node);
        self.tryCleanupRetiredArenas();

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

    fn createRetiredArenaNode(self: *ConfigManager) !*RetiredArena {
        const node = try self.allocator.create(RetiredArena);
        node.* = .{ .arena = undefined, .next = null };
        return node;
    }

    fn enqueueRetiredArena(self: *ConfigManager, node: *RetiredArena) void {
        self.retired_lock.lock();
        defer self.retired_lock.unlock();

        if (self.retired_tail) |tail| {
            tail.next = node;
        } else {
            self.retired_head = node;
        }
        self.retired_tail = node;
    }

    fn releaseReader(self: *ConfigManager) void {
        const prev = self.active_readers.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
        if (prev == 1) {
            self.tryCleanupRetiredArenas();
        }
    }

    fn tryCleanupRetiredArenas(self: *ConfigManager) void {
        if (self.active_readers.load(.acquire) != 0) {
            return;
        }
        self.drainRetiredArenas();
    }

    fn drainRetiredArenas(self: *ConfigManager) void {
        self.retired_lock.lock();
        const head = self.retired_head;
        self.retired_head = null;
        self.retired_tail = null;
        self.retired_lock.unlock();

        var cursor = head;
        while (cursor) |node| {
            var arena = node.arena;
            arena.deinit();
            const next = node.next;
            self.allocator.destroy(node);
            cursor = next;
        }
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
    const file_contents = std.fs.cwd().readFileAlloc(
        path,
        allocator,
        std.Io.Limit.limited(10 * 1024 * 1024),
    ) catch |err| {
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
    const file_contents = std.fs.cwd().readFileAlloc(
        path,
        allocator,
        std.Io.Limit.limited(10 * 1024 * 1024),
    ) catch |err| {
        log.err("failed to read config file '{s}': {s}", .{ path, @errorName(err) });
        return ConfigError.ReadFailed;
    };
    defer allocator.free(file_contents);

    return parseZonConfig(allocator, file_contents);
}

/// Parse ZON configuration from string
fn parseZonConfig(allocator: std.mem.Allocator, source: []const u8) !*Config {
    const zon_source = try allocator.allocSentinel(u8, source.len, 0);
    defer allocator.free(zon_source);
    std.mem.copyForwards(u8, zon_source[0..source.len], source);

    var ast = std.zig.Ast.parse(allocator, zon_source, .zon) catch |err| {
        log.err("failed to parse ZON config: {s}", .{@errorName(err)});
        return ConfigError.ParseFailed;
    };
    defer ast.deinit(allocator);

    if (ast.errors.len != 0) {
        const parse_error = ast.errors[0];
        const token_text = ast.tokenSlice(parse_error.token);
        log.err(
            "failed to parse ZON config: {s} near '{s}'",
            .{ @tagName(parse_error.tag), token_text },
        );
        return ConfigError.ParseFailed;
    }

    // Evaluate the ZON AST to extract configuration
    const zon_config = try evaluateZonAst(allocator, ast);

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
fn evaluateZonAst(allocator: std.mem.Allocator, ast: std.zig.Ast) ConfigError!JsonConfig {
    if (ast.mode != .zon) {
        log.err("expected ZON AST but received mode {s}", .{@tagName(ast.mode)});
        return ConfigError.ParseFailed;
    }

    var zoir = std.zig.ZonGen.generate(allocator, ast, .{}) catch |err| switch (err) {
        error.OutOfMemory => return ConfigError.OutOfMemory,
    };
    defer zoir.deinit(allocator);

    const zon_options: std.zon.parse.Options = .{
        .ignore_unknown_fields = true,
        .free_on_error = true,
    };

    var diagnostics = std.zon.parse.Diagnostics{};
    defer releaseZonDiagnostics(&diagnostics, allocator);

    const zon_config = std.zon.parse.fromZoirAlloc(JsonConfig, allocator, ast, zoir, &diagnostics, zon_options) catch |err| switch (err) {
        error.OutOfMemory => return ConfigError.OutOfMemory,
        error.ParseZon => {
            logZonDiagnostics(&diagnostics);
            return ConfigError.ParseFailed;
        },
    };

    return zon_config;
}

fn releaseZonDiagnostics(diag: *std.zon.parse.Diagnostics, allocator: std.mem.Allocator) void {
    diag.ast = .{
        .source = "",
        .tokens = .empty,
        .nodes = .empty,
        .extra_data = &.{},
        .mode = .zon,
        .errors = &.{},
    };
    diag.zoir = .{
        .nodes = .empty,
        .extra = &.{},
        .limbs = &.{},
        .string_bytes = &.{},
        .compile_errors = &.{},
        .error_notes = &.{},
    };
    diag.deinit(allocator);
}

fn logZonDiagnostics(diag: *const std.zon.parse.Diagnostics) void {
    var iterator = diag.iterateErrors();
    var reported = false;
    while (iterator.next()) |err| {
        reported = true;
        const loc = err.getLocation(diag);
        log.err(
            "failed to evaluate ZON config at {d}:{d}: {f}",
            .{ loc.line + 1, loc.column + 1, err.fmtMessage(diag) },
        );
        var notes = err.iterateNotes(diag);
        while (notes.next()) |note| {
            const note_loc = note.getLocation(diag);
            log.err(
                "  note {d}:{d}: {f}",
                .{ note_loc.line + 1, note_loc.column + 1, note.fmtMessage(diag) },
            );
        }
    }
    if (!reported) {
        log.err("failed to evaluate ZON config: invalid data or syntax", .{});
    }
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

test "ZON parsing - full configuration coverage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\ .{
        \\     .proxy = .{
        \\         .listen_host = "0.0.0.0",
        \\         .listen_port = 9090,
        \\         .max_connections = 123,
        \\         .reuse_address = false,
        \\     },
        \\     .mode = .forward_proxy,
        \\     .cache = .{
        \\         .enabled = true,
        \\         .max_size = 512,
        \\     },
        \\     .rate_limit = .{
        \\         .enabled = true,
        \\         .max_per_ip = 5,
        \\         .max_global = 10,
        \\     },
        \\     .access_control = .{
        \\         .enabled = true,
        \\         .default_policy = .deny,
        \\         .allow_list = .{"10.0.0.1"},
        \\         .deny_list = .{"20.0.0.1"},
        \\     },
        \\     .health_check = .{
        \\         .enabled = false,
        \\         .interval_seconds = 30,
        \\         .timeout_ms = 100,
        \\         .unhealthy_threshold = 7,
        \\         .healthy_threshold = 3,
        \\     },
        \\     .admin = .{
        \\         .enabled = true,
        \\         .listen_host = "127.0.0.1",
        \\         .listen_port = 7777,
        \\     },
        \\     .logging = .{
        \\         .level = .debug,
        \\         .enable_connection_logging = false,
        \\         .enable_stats = false,
        \\     },
        \\     .clusters = .{
        \\         .{
        \\             .name = "alpha",
        \\             .backends = .{
        \\                 .{ .host = "10.0.0.5", .port = 80, .weight = 2 },
        \\             },
        \\             .strategy = .round_robin,
        \\             .max_concurrent = 42,
        \\         },
        \\     },
        \\     .routes = .{
        \\         .{
        \\             .name = "route_one",
        \\             .match = .{
        \\                 .host = "service.local",
        \\                 .path_prefix = "/api",
        \\                 .methods = .{"GET", "POST"},
        \\             },
        \\             .cluster = "alpha",
        \\             .cache_policy = .{
        \\                 .allow = true,
        \\                 .ttl_seconds = 9,
        \\                 .max_size = 10,
        \\             },
        \\             .timeout_policy = .{
        \\                 .connect_timeout_ms = 1,
        \\                 .request_timeout_ms = 2,
        \\                 .response_timeout_ms = 3,
        \\                 .idle_timeout_seconds = 4,
        \\             },
        \\             .concurrency_policy = .{
        \\                 .max_concurrent = 11,
        \\                 .max_queue_depth = 12,
        \\                 .reject_when_full = true,
        \\             },
        \\         },
        \\     },
        \\ }
    ;

    const config = try parseZon(allocator, source);

    try std.testing.expectEqualStrings("0.0.0.0", config.proxy.listen_host);
    try std.testing.expectEqual(@as(u16, 9090), config.proxy.listen_port);
    try std.testing.expectEqual(@as(?usize, 123), config.proxy.max_connections);
    try std.testing.expect(!config.proxy.reuse_address);

    try std.testing.expectEqual(HttpMode.forward_proxy, config.mode);

    try std.testing.expect(config.cache.enabled);
    try std.testing.expectEqual(@as(usize, 512), config.cache.max_size);

    try std.testing.expect(config.rate_limit.enabled);
    try std.testing.expectEqual(@as(u32, 5), config.rate_limit.max_per_ip);
    try std.testing.expectEqual(@as(u32, 10), config.rate_limit.max_global);

    try std.testing.expect(config.access_control.enabled);
    try std.testing.expectEqual(AccessControl.Policy.deny, config.access_control.default_policy);
    try std.testing.expectEqual(@as(usize, 1), config.access_control.allow_list.len);
    try std.testing.expectEqualStrings("10.0.0.1", config.access_control.allow_list[0]);
    try std.testing.expectEqual(@as(usize, 1), config.access_control.deny_list.len);
    try std.testing.expectEqualStrings("20.0.0.1", config.access_control.deny_list[0]);

    try std.testing.expect(!config.health_check.enabled);
    try std.testing.expectEqual(@as(u64, 30), config.health_check.interval_seconds);
    try std.testing.expectEqual(@as(u64, 100), config.health_check.timeout_ms);
    try std.testing.expectEqual(@as(u32, 7), config.health_check.unhealthy_threshold);
    try std.testing.expectEqual(@as(u32, 3), config.health_check.healthy_threshold);

    try std.testing.expect(config.admin.enabled);
    try std.testing.expectEqualStrings("127.0.0.1", config.admin.listen_host);
    try std.testing.expectEqual(@as(u16, 7777), config.admin.listen_port);

    try std.testing.expectEqual(std.log.Level.debug, config.logging.level);
    try std.testing.expect(!config.logging.enable_connection_logging);
    try std.testing.expect(!config.logging.enable_stats);

    try std.testing.expectEqual(@as(usize, 1), config.clusters.len);
    const cluster = config.clusters[0];
    try std.testing.expectEqualStrings("alpha", cluster.name);
    try std.testing.expectEqual(@as(usize, 1), cluster.backends.len);
    try std.testing.expectEqualStrings("10.0.0.5", cluster.backends[0].host);
    try std.testing.expectEqual(@as(u16, 80), cluster.backends[0].port);
    try std.testing.expectEqual(@as(u32, 2), cluster.backends[0].weight);
    try std.testing.expectEqual(LoadBalancer.Strategy.round_robin, cluster.strategy);
    try std.testing.expectEqual(@as(u32, 42), cluster.max_concurrent);

    try std.testing.expectEqual(@as(usize, 1), config.routes.len);
    const route = config.routes[0];
    try std.testing.expectEqualStrings("route_one", route.name);
    try std.testing.expectEqualStrings("alpha", route.cluster);
    try std.testing.expectEqualStrings("service.local", route.match.host.?);
    try std.testing.expectEqualStrings("/api", route.match.path_prefix.?);
    try std.testing.expectEqual(@as(usize, 2), route.match.methods.len);
    try std.testing.expectEqualStrings("GET", route.match.methods[0]);
    try std.testing.expectEqualStrings("POST", route.match.methods[1]);

    try std.testing.expect(route.cache_policy.allow);
    try std.testing.expectEqual(@as(u32, 9), route.cache_policy.ttl_seconds);
    try std.testing.expectEqual(@as(usize, 10), route.cache_policy.max_size);

    try std.testing.expectEqual(@as(u64, 1), route.timeout_policy.connect_timeout_ms);
    try std.testing.expectEqual(@as(u64, 2), route.timeout_policy.request_timeout_ms);
    try std.testing.expectEqual(@as(u64, 3), route.timeout_policy.response_timeout_ms);
    try std.testing.expectEqual(@as(i64, 4), route.timeout_policy.idle_timeout_seconds);

    try std.testing.expectEqual(@as(u32, 11), route.concurrency_policy.max_concurrent);
    try std.testing.expectEqual(@as(u32, 12), route.concurrency_policy.max_queue_depth);
    try std.testing.expect(route.concurrency_policy.reject_when_full);
}
