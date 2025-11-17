//! Router: The central switchboard for request routing
//!
//! The Router holds all routing configuration (routes, clusters, mode)
//! and provides the routeRequest() API that picks a backend based on
//! HTTP request details.

const std = @import("std");
const routing = @import("routing.zig");
const HTTPInspector = @import("http.zig").HTTPInspector;
const IpKey = @import("transport.zig").IpKey;

const HttpMode = routing.HttpMode;
const Route = routing.Route;
const Cluster = routing.Cluster;
const RoutingDecision = routing.RoutingDecision;
const URI = routing.URI;

pub const RouterError = error{
    NoRoute,
    NoCluster,
    NoHealthyBackend,
    ClusterAtCapacity,
    InvalidURI,
    InvalidRequest,
};

/// The Router manages all routing configuration
pub const Router = struct {
    allocator: std.mem.Allocator,

    /// Operating mode
    mode: HttpMode,

    /// Routing table
    routes: []Route,

    /// Backend clusters
    clusters: []Cluster,

    /// Default route (optional)
    default_route: ?*Route = null,

    pub fn init(
        allocator: std.mem.Allocator,
        mode: HttpMode,
        routes: []Route,
        clusters: []Cluster,
    ) Router {
        return .{
            .allocator = allocator,
            .mode = mode,
            .routes = routes,
            .clusters = clusters,
        };
    }

    /// Route an HTTP request to a backend
    pub fn routeRequest(
        self: *Router,
        req: *const HTTPInspector.HTTPRequest,
        headers: []const u8,
        client_ip: IpKey,
    ) RouterError!RoutingDecision {
        // Extract host from headers (required for routing)
        const host = HTTPInspector.findHeader(headers, "Host") orelse "";

        // Handle forward proxy mode
        if (self.mode == .forward_proxy) {
            return self.routeForwardProxy(req, client_ip);
        }

        // Handle CONNECT tunnel mode
        if (self.mode == .tunnel_only) {
            return self.routeTunnel(req, client_ip);
        }

        // Reverse proxy mode: match routes
        return self.routeReverseProxy(req, host, client_ip);
    }

    fn routeReverseProxy(
        self: *Router,
        req: *const HTTPInspector.HTTPRequest,
        host: []const u8,
        client_ip: IpKey,
    ) RouterError!RoutingDecision {
        // Try to match against configured routes
        for (self.routes) |*route| {
            if (route.match.matches(req.method, host, req.path)) {
                return self.buildDecision(route, client_ip);
            }
        }

        // Try default route if configured
        if (self.default_route) |route| {
            return self.buildDecision(route, client_ip);
        }

        return error.NoRoute;
    }

    fn routeForwardProxy(
        self: *Router,
        req: *const HTTPInspector.HTTPRequest,
        client_ip: IpKey,
    ) RouterError!RoutingDecision {
        // In forward proxy mode, the path is an absolute URI
        // e.g. "GET http://example.com/path HTTP/1.1"
        const uri = URI.parse(req.path) catch return error.InvalidURI;

        // Try to match against configured routes using parsed URI
        for (self.routes) |*route| {
            if (route.match.matches(req.method, uri.host, uri.path)) {
                return self.buildDecision(route, client_ip);
            }
        }

        // Try default route if configured
        if (self.default_route) |route| {
            return self.buildDecision(route, client_ip);
        }

        return error.NoRoute;
    }

    fn routeTunnel(
        self: *Router,
        req: *const HTTPInspector.HTTPRequest,
        client_ip: IpKey,
    ) RouterError!RoutingDecision {
        // CONNECT method requires special handling
        if (!std.mem.eql(u8, req.method, "CONNECT")) {
            return error.InvalidRequest;
        }

        // For CONNECT, path is "host:port"
        // Try to match against configured routes
        for (self.routes) |*route| {
            if (route.match.matches(req.method, req.path, req.path)) {
                return self.buildDecision(route, client_ip);
            }
        }

        // Try default route if configured
        if (self.default_route) |route| {
            return self.buildDecision(route, client_ip);
        }

        return error.NoRoute;
    }

    fn buildDecision(
        self: *Router,
        route: *Route,
        client_ip: IpKey,
    ) RouterError!RoutingDecision {
        // Find the cluster
        const cluster = self.findCluster(route.cluster.name) orelse return error.NoCluster;

        // Try to acquire a connection slot
        if (!cluster.tryAcquire()) {
            if (route.concurrency_policy.reject_when_full) {
                return error.ClusterAtCapacity;
            }
            // TODO: Queue the request instead of failing immediately
            return error.ClusterAtCapacity;
        }

        // Select a backend from the cluster
        const backend = cluster.selectBackend(client_ip) orelse {
            cluster.release();
            return error.NoHealthyBackend;
        };

        return .{
            .backend = backend,
            .cluster = cluster,
            .cache_allowed = route.cache_policy.allow,
            .cache_ttl = route.cache_policy.ttl_seconds,
            .cache_max_size = route.cache_policy.max_size,
            .transform = route.transform_policy,
            .timeouts = route.timeout_policy,
        };
    }

    fn findCluster(self: *Router, name: []const u8) ?*Cluster {
        for (self.clusters) |*cluster| {
            if (std.mem.eql(u8, cluster.name, name)) {
                return cluster;
            }
        }
        return null;
    }

    /// Release a connection slot when done
    pub fn releaseConnection(self: *Router, cluster_name: []const u8) void {
        if (self.findCluster(cluster_name)) |cluster| {
            cluster.release();
        }
    }
};

test "Router reverse proxy basic routing" {
    const allocator = std.testing.allocator;

    // Create a test backend
    const backend = @import("backend.zig").Backend.init("127.0.0.1", 3003, 1);

    // Create a cluster with the backend
    var backends = [_]@import("backend.zig").Backend{backend};
    const cluster = Cluster.init("test-cluster", &backends, .round_robin, 10);

    // Create a route
    const route = Route{
        .name = "api-route",
        .match = .{
            .host = "api.example.com",
            .path_prefix = "/v1",
            .methods = &[_][]const u8{"GET"},
        },
        .cluster = .{ .name = "test-cluster" },
    };

    // Create router
    var routes = [_]Route{route};
    var clusters = [_]Cluster{cluster};
    var router = Router.init(allocator, .reverse_proxy, &routes, &clusters);

    // Test request
    const req = HTTPInspector.HTTPRequest{
        .method = "GET",
        .path = "/v1/users",
        .version = "HTTP/1.1",
    };
    const headers = "GET /v1/users HTTP/1.1\r\nHost: api.example.com\r\n\r\n";
    const client_ip = IpKey{ .ipv4 = 0x7F000001 }; // 127.0.0.1

    // Route the request
    const decision = try router.routeRequest(&req, headers, client_ip);

    // Verify decision
    try std.testing.expect(decision.cache_allowed);
    try std.testing.expectEqual(@as(u32, 300), decision.cache_ttl);

    // Release the connection
    router.releaseConnection("test-cluster");
}

test "Router no matching route" {
    const allocator = std.testing.allocator;

    const backend = @import("backend.zig").Backend.init("127.0.0.1", 3003, 1);
    var backends = [_]@import("backend.zig").Backend{backend};
    const cluster = Cluster.init("test-cluster", &backends, .round_robin, 10);

    const route = Route{
        .name = "api-route",
        .match = .{
            .host = "api.example.com",
            .path_prefix = "/v1",
        },
        .cluster = .{ .name = "test-cluster" },
    };

    var routes = [_]Route{route};
    var clusters = [_]Cluster{cluster};
    var router = Router.init(allocator, .reverse_proxy, &routes, &clusters);

    // Request that doesn't match any route
    const req = HTTPInspector.HTTPRequest{
        .method = "GET",
        .path = "/v2/users",
        .version = "HTTP/1.1",
    };
    const headers = "GET /v2/users HTTP/1.1\r\nHost: other.example.com\r\n\r\n";
    const client_ip = IpKey{ .ipv4 = 0x7F000001 };

    // Should fail to route
    const result = router.routeRequest(&req, headers, client_ip);
    try std.testing.expectError(error.NoRoute, result);
}

test "Router forward proxy URI parsing" {
    const allocator = std.testing.allocator;

    const backend = @import("backend.zig").Backend.init("127.0.0.1", 8080, 1);
    var backends = [_]@import("backend.zig").Backend{backend};
    const cluster = Cluster.init("forward-cluster", &backends, .round_robin, 10);

    // Wildcard route for forward proxy
    const route = Route{
        .name = "forward-all",
        .match = .{
            .host = null, // Match any host
            .path_prefix = null, // Match any path
        },
        .cluster = .{ .name = "forward-cluster" },
    };

    var routes = [_]Route{route};
    var clusters = [_]Cluster{cluster};
    var router = Router.init(allocator, .forward_proxy, &routes, &clusters);

    // Forward proxy request with absolute URI
    const req = HTTPInspector.HTTPRequest{
        .method = "GET",
        .path = "http://example.com/path/to/resource",
        .version = "HTTP/1.1",
    };
    const headers = "GET http://example.com/path/to/resource HTTP/1.1\r\n\r\n";
    const client_ip = IpKey{ .ipv4 = 0x7F000001 };

    // Route the request
    const decision = try router.routeRequest(&req, headers, client_ip);

    // Verify decision
    try std.testing.expectEqualStrings("127.0.0.1", decision.backend.host);
    try std.testing.expectEqual(@as(u16, 8080), decision.backend.port);

    // Release the connection
    router.releaseConnection("forward-cluster");
}
