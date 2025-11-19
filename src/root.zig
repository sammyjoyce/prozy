//! Prozy: A simple TCP proxy
//!
//! This is a production-grade async TCP proxy using Zig's new std.Io runtime.
//! It demonstrates the expected pattern from the 0.16 era async APIs: create an
//! Io executor at the edge (usually `main`), then pass it through the
//! application just like an allocator so the implementation can target
//! Threaded, io_uring, kqueue, or any future backend without code changes.
//!
//! The proxy showcases the core patterns needed:
//! - TCP socket listening and accepting with std.Io.net
//! - Bidirectional data copying coordinated via io.concurrent/io.select
//! - Structured concurrency via Io.Group and explicit cancellation
//!
//! ## Known Limitations and Roadmap
//!
//! ### Request Handling
//! - **Keep-Alive & Pipelining**: Currently, the proxy closes the connection after one request.
//!   Support for persistent connections (HTTP Keep-Alive) and pipelining is scheduled for Phase 2.
//!
//! ### Protocol Support
//! - **HTTP/1.1 Only**: No HTTP/2 or WebSocket support yet.
//! - **No TLS Termination**: The proxy expects plain HTTP. Use a frontend load balancer (ALB, Nginx)
//!   for TLS termination. `X-Forwarded-Proto` is respected.
//!
//! ### Cache Compliance (RFC 9111)
//! - **Partial Implementation**: `Cache-Control` parsing and basic LRU are implemented.
//!   Phase 3 will add `Vary` header support, `ETag` validation, and proper `Date`/`Expires` handling.
//! - **Revalidation**: `stale-while-revalidate` is not yet implemented.
//!
//! ### Resilience
//! - **Reactive Health Checks**: Backends are marked unhealthy only after a connection failure.
//!   Proactive background probing is scheduled for Phase 4.
//!
//! ### Performance
//! - **Fixed Buffer Sizes**: Uses 8KB buffers for headers and 4KB for bodies.
//! - **Locking**: Cache uses shared locks for reads, but the single-threaded nature of the current
//!   `std.Io` runtime (in `main.zig`) means we rely on non-blocking I/O rather than OS threads.

const std = @import("std");

// Transport layer
const transport = @import("prozy/transport.zig");
pub const IpKey = transport.IpKey;
pub const IpKeyContext = transport.IpKeyContext;

// Statistics
const stats = @import("prozy/stats.zig");
pub const ProxyStats = stats.ProxyStats;

// Access control
const access = @import("prozy/access.zig");
pub const AccessControl = access.AccessControl;
pub const RateLimiter = access.RateLimiter;

// Authentication
const auth = @import("prozy/auth.zig");
pub const ProxyAuth = auth.ProxyAuth;
pub const AuthResult = auth.ProxyAuth.AuthResult;
pub const BasicCredentials = auth.BasicCredentials;

// HTTP layer
const http = @import("prozy/http.zig");
pub const HTTPInspector = http.HTTPInspector;
pub const HTTPCache = http.HTTPCache;

// Backend layer
const backend = @import("prozy/backend.zig");
pub const Backend = backend.Backend;
pub const LoadBalancer = backend.LoadBalancer;

// Routing layer (Phase 3)
const routing = @import("prozy/routing.zig");
pub const HttpMode = routing.HttpMode;
pub const Route = routing.Route;
pub const RouteMatch = routing.RouteMatch;
pub const Cluster = routing.Cluster;
pub const CachePolicy = routing.CachePolicy;
pub const TimeoutPolicy = routing.TimeoutPolicy;
pub const TransformPolicy = routing.TransformPolicy;
pub const ConcurrencyPolicy = routing.ConcurrencyPolicy;
pub const RoutingDecision = routing.RoutingDecision;
pub const URI = routing.URI;
pub const Semaphore = routing.Semaphore;

const router = @import("prozy/router.zig");
pub const Router = router.Router;
pub const RouterError = router.RouterError;

// Admin and management
const admin = @import("prozy/admin.zig");
pub const AdminServer = admin.AdminServer;

const health = @import("prozy/health.zig");
pub const HealthMonitor = health.HealthMonitor;

// Configuration hot reload
const config = @import("prozy/config.zig");
pub const Config = config.Config;
pub const ConfigManager = config.ConfigManager;
pub const ConfigLease = config.ConfigManager.ConfigLease;
pub const ProxyConfig = config.ProxyConfig;
pub const BackendConfig = config.BackendConfig;
pub const ClusterConfig = config.ClusterConfig;
pub const RouteConfig = config.RouteConfig;

// Proxy core
const proxy = @import("prozy/proxy.zig");
pub const RunOptions = proxy.RunOptions;
pub const Proxy = proxy.Proxy;
pub const runProxy = proxy.runProxy;
pub const runProxyWithIo = proxy.runProxyWithIo;

// Import tests for `zig build test`
test {
    std.testing.refAllDecls(@This());
    _ = @import("prozy/tests.zig");
}
