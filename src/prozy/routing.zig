//! Routing and transformation infrastructure for Phase 3
//!
//! This module implements:
//! - Forward proxy, reverse proxy, and CONNECT tunnel modes
//! - Per-route policies (caching, timeouts, transformations, concurrency)
//! - Request/response transformation hooks
//! - Backpressure and concurrency limits

const std = @import("std");
const Backend = @import("backend.zig").Backend;
const LoadBalancer = @import("backend.zig").LoadBalancer;
const HTTPInspector = @import("http.zig").HTTPInspector;
const IpKey = @import("transport.zig").IpKey;

/// HTTP proxy operating mode
pub const HttpMode = enum {
    /// Reverse proxy: clients send origin-form requests (GET /path HTTP/1.1)
    /// Routes to backends based on Host header and path matching
    reverse_proxy,

    /// Forward proxy: clients send absolute-form requests (GET http://example.com/path HTTP/1.1)
    /// Extracts origin from request line and routes accordingly
    forward_proxy,

    /// CONNECT tunnel: for HTTPS proxying
    /// Responds with 200 Connection Established and passes raw bytes
    tunnel_only,
};

/// Route matching criteria
pub const RouteMatch = struct {
    /// Host to match (exact match). Null means "match any host"
    host: ?[]const u8 = null,

    /// Path prefix to match. Null means "match any path"
    path_prefix: ?[]const u8 = null,

    /// HTTP methods to match (empty slice means "match any method")
    methods: []const []const u8 = &[_][]const u8{},

    /// Match a request against this criteria
    pub fn matches(self: RouteMatch, method: []const u8, host: []const u8, path: []const u8) bool {
        // Check host match
        if (self.host) |expected_host| {
            if (!std.mem.eql(u8, host, expected_host)) return false;
        }

        // Check path prefix match
        if (self.path_prefix) |prefix| {
            if (!std.mem.startsWith(u8, path, prefix)) return false;
        }

        // Check method match (empty slice means match all methods)
        if (self.methods.len > 0) {
            var found = false;
            for (self.methods) |allowed_method| {
                if (std.mem.eql(u8, method, allowed_method)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        return true;
    }
};

/// Cache policy for a route
pub const CachePolicy = struct {
    /// Whether caching is allowed for this route
    allow: bool = true,

    /// TTL for cache entries (seconds)
    ttl_seconds: u32 = 300,

    /// Max cacheable response size (bytes)
    max_size: usize = 1024 * 1024, // 1MB default
};

/// Timeout policy for a route
pub const TimeoutPolicy = struct {
    /// Backend connection timeout (milliseconds)
    connect_timeout_ms: u64 = 5000,

    /// Request read timeout (milliseconds)
    request_timeout_ms: u64 = 30000,

    /// Response read timeout (milliseconds)
    response_timeout_ms: u64 = 60000,

    /// Bidirectional copy timeout (seconds)
    idle_timeout_seconds: i64 = 30,
};

/// Transformation hooks for request/response modification
pub const TransformPolicy = struct {
    /// Request transformation function (optional)
    request: ?RequestTransformFn = null,

    /// Response transformation function (optional)
    response: ?ResponseTransformFn = null,

    pub const RequestTransformFn = *const fn (
        allocator: std.mem.Allocator,
        req: *HTTPInspector.HTTPRequest,
        headers: []const u8,
    ) anyerror!void;

    pub const ResponseTransformFn = *const fn (
        allocator: std.mem.Allocator,
        req: *const HTTPInspector.HTTPRequest,
        resp_head: *HTTPInspector.HTTPResponse,
        body: []const u8,
    ) anyerror!void;
};

/// Concurrency limits for a route/cluster
pub const ConcurrencyPolicy = struct {
    /// Whether to reject immediately (503) or queue when at capacity
    reject_when_full: bool = false,
};

/// Cluster reference (by name)
pub const ClusterRef = struct {
    name: []const u8,
};

/// A routing rule
pub const Route = struct {
    /// Human-readable name for this route
    name: []const u8,

    /// Match criteria for this route
    match: RouteMatch,

    /// Backend cluster to use
    cluster: ClusterRef,

    /// Cache policy
    cache_policy: CachePolicy = .{},

    /// Timeout policy
    timeout_policy: TimeoutPolicy = .{},

    /// Transformation policy
    transform_policy: TransformPolicy = .{},

    /// Concurrency policy
    concurrency_policy: ConcurrencyPolicy = .{},
};

/// A backend cluster with multiple servers
pub const Cluster = struct {
    /// Human-readable name for this cluster
    name: []const u8,

    /// Backend servers in this cluster
    backends: []Backend,

    /// Load balancing strategy
    strategy: LoadBalancer.Strategy = .round_robin,

    /// Per-cluster load balancer instance
    load_balancer: LoadBalancer,

    /// Concurrency control semaphore
    semaphore: Semaphore,

    pub fn init(
        name: []const u8,
        backends: []Backend,
        strategy: LoadBalancer.Strategy,
        max_concurrent: u32,
    ) Cluster {
        return .{
            .name = name,
            .backends = backends,
            .strategy = strategy,
            .load_balancer = LoadBalancer.init(backends, strategy),
            .semaphore = Semaphore.init(max_concurrent),
        };
    }

    /// Select a backend from this cluster
    pub fn selectBackend(self: *Cluster, client_ip: IpKey) ?*Backend {
        return self.load_balancer.selectBackend(client_ip);
    }

    /// Try to acquire a connection slot
    pub fn tryAcquire(self: *Cluster) bool {
        return self.semaphore.tryAcquire();
    }

    /// Release a connection slot
    pub fn release(self: *Cluster) void {
        self.semaphore.release();
    }

    /// Acquire a connection slot, waiting if necessary
    pub fn acquire(self: *Cluster, timeout_ms: u64) bool {
        return self.semaphore.acquire(timeout_ms);
    }
};

/// Semaphore for concurrency control with timeout support
pub const Semaphore = struct {
    max: u32,
    current: u32,
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,

    pub fn init(max: u32) Semaphore {
        return .{
            .max = max,
            .current = 0,
            .mutex = .{},
            .cond = .{},
        };
    }

    pub fn tryAcquire(self: *Semaphore) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.current < self.max) {
            self.current += 1;
            return true;
        }
        return false;
    }

    pub fn acquire(self: *Semaphore, timeout_ms: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const timeout_ns = timeout_ms * std.time.ns_per_ms;
        var timer = std.time.Timer.start() catch return false;

        while (self.current >= self.max) {
            const elapsed = timer.read();
            if (elapsed >= timeout_ns) return false;

            const remaining = timeout_ns - elapsed;

            // timedWait returns error on timeout or spurious wakeups?
            // In Zig std, timedWait usually returns void and we check condition.
            // Or it returns error.Timeout.
            // Let's assume standard pattern: wait and re-check condition.
            self.cond.timedWait(&self.mutex, remaining) catch |err| {
                if (err == error.Timeout) return false;
                // Other errors (spurious?) -> loop again
            };
        }

        self.current += 1;
        return true;
    }

    pub fn release(self: *Semaphore) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.current > 0) {
            self.current -= 1;
            self.cond.signal();
        }
    }

    pub fn available(self: *Semaphore) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.current < self.max) self.max - self.current else 0;
    }
};

/// The result of routing a request
pub const RoutingDecision = struct {
    /// Selected backend
    backend: *Backend,

    /// Associated cluster
    cluster: *Cluster,

    /// Whether caching is allowed
    cache_allowed: bool,

    /// Cache TTL (if caching allowed)
    cache_ttl: u32,

    /// Max cacheable size
    cache_max_size: usize,

    /// Transformation policy
    transform: TransformPolicy,

    /// Timeout policy
    timeouts: TimeoutPolicy,
};

/// Parse an absolute URI (for forward proxy mode)
pub const URI = struct {
    scheme: []const u8,
    host: []const u8,
    port: ?u16,
    path: []const u8,

    /// Parse an absolute-form URI: http://example.com:8080/path
    pub fn parse(uri: []const u8) !URI {
        // Find scheme
        const scheme_end = std.mem.indexOf(u8, uri, "://") orelse return error.InvalidURI;
        const scheme = uri[0..scheme_end];

        // Find authority (host:port)
        const authority_start = scheme_end + 3;
        const path_start = std.mem.indexOfPos(u8, uri, authority_start, "/") orelse uri.len;
        const authority = uri[authority_start..path_start];
        const path = if (path_start < uri.len) uri[path_start..] else "/";

        // Parse host and port
        var host: []const u8 = undefined;
        var port: ?u16 = null;

        if (std.mem.indexOf(u8, authority, ":")) |port_sep| {
            host = authority[0..port_sep];
            const port_str = authority[port_sep + 1 ..];
            port = try std.fmt.parseInt(u16, port_str, 10);
        } else {
            host = authority;
            // Default ports based on scheme
            port = if (std.mem.eql(u8, scheme, "http"))
                @as(u16, 80)
            else if (std.mem.eql(u8, scheme, "https"))
                @as(u16, 443)
            else
                null;
        }

        return .{
            .scheme = scheme,
            .host = host,
            .port = port,
            .path = path,
        };
    }
};

test "RouteMatch.matches basic" {
    const route = RouteMatch{
        .host = "api.example.com",
        .path_prefix = "/v1",
        .methods = &[_][]const u8{ "GET", "POST" },
    };

    try std.testing.expect(route.matches("GET", "api.example.com", "/v1/users"));
    try std.testing.expect(route.matches("POST", "api.example.com", "/v1/users"));
    try std.testing.expect(!route.matches("DELETE", "api.example.com", "/v1/users"));
    try std.testing.expect(!route.matches("GET", "other.example.com", "/v1/users"));
    try std.testing.expect(!route.matches("GET", "api.example.com", "/v2/users"));
}

test "RouteMatch.matches wildcard" {
    const route = RouteMatch{
        .host = null, // Match any host
        .path_prefix = null, // Match any path
        .methods = &[_][]const u8{}, // Match any method
    };

    try std.testing.expect(route.matches("GET", "any.host.com", "/any/path"));
    try std.testing.expect(route.matches("POST", "other.host.com", "/other/path"));
}

test "URI.parse http" {
    const uri = try URI.parse("http://example.com:8080/path/to/resource");
    try std.testing.expectEqualStrings("http", uri.scheme);
    try std.testing.expectEqualStrings("example.com", uri.host);
    try std.testing.expectEqual(@as(?u16, 8080), uri.port);
    try std.testing.expectEqualStrings("/path/to/resource", uri.path);
}

test "URI.parse http default port" {
    const uri = try URI.parse("http://example.com/path");
    try std.testing.expectEqualStrings("http", uri.scheme);
    try std.testing.expectEqualStrings("example.com", uri.host);
    try std.testing.expectEqual(@as(?u16, 80), uri.port);
    try std.testing.expectEqualStrings("/path", uri.path);
}

test "URI.parse https default port" {
    const uri = try URI.parse("https://example.com/path");
    try std.testing.expectEqualStrings("https", uri.scheme);
    try std.testing.expectEqualStrings("example.com", uri.host);
    try std.testing.expectEqual(@as(?u16, 443), uri.port);
    try std.testing.expectEqualStrings("/path", uri.path);
}

test "Semaphore basic" {
    var sem = Semaphore.init(3);

    try std.testing.expect(sem.tryAcquire());
    try std.testing.expect(sem.tryAcquire());
    try std.testing.expect(sem.tryAcquire());
    try std.testing.expect(!sem.tryAcquire()); // Should fail, at capacity

    sem.release();
    try std.testing.expect(sem.tryAcquire()); // Should succeed now
}

test "Semaphore available" {
    var sem = Semaphore.init(5);

    try std.testing.expectEqual(@as(u32, 5), sem.available());

    _ = sem.tryAcquire();
    try std.testing.expectEqual(@as(u32, 4), sem.available());

    _ = sem.tryAcquire();
    try std.testing.expectEqual(@as(u32, 3), sem.available());

    sem.release();
    try std.testing.expectEqual(@as(u32, 4), sem.available());
}
