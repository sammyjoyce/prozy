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
//! ## Known Limitations and Assumptions
//!
//! ### Request Handling
//! - **One HTTP request per TCP connection**: The proxy assumes each TCP connection
//!   carries a single HTTP request. HTTP keep-alive and pipelining are NOT supported.
//!   Subsequent requests in the same connection will bypass cache checking and request
//!   inspection.
//!
//! ### Protocol Support
//! - **HTTP-only**: Currently designed for HTTP traffic. No TLS/SSL termination,
//!   WebSocket support, or HTTP/2.
//! - **TCP-only**: No UDP support. Adding UDP would require significant changes.
//!
//! ### Connection Handling
//! - **30-second timeout**: After one direction of a connection completes, the proxy
//!   waits up to 30 seconds for the other direction before timing out and canceling.
//!   Implemented using io.concurrent(sleep, ...) combined with io.select() for concurrent
//!   timeout enforcement. Prevents hung connections during HTTP keep-alive scenarios.
//! - **Full close only**: No TCP half-close support. Both directions are closed together.
//!
//! ### Cache Behavior
//! - **GET requests only**: Only GET requests are cached. POST/PUT/DELETE bypass cache.
//! - **Basic cacheability**: Cache does NOT respect Cache-Control, Vary, or other
//!   HTTP caching headers. All GET responses are cached with a fixed TTL.
//! - **No cache population from backend**: Currently, responses from backends are
//!   streamed directly to clients but NOT buffered and stored in the cache for future
//!   requests. This is planned for a future release.
//! - **Fixed-size buffers**: Request headers are buffered in an 8KB buffer. Headers
//!   larger than 8KB will cause cache checking to fail (request still forwarded).
//!
//! ### Load Balancing
//! - **Reactive health checks**: Backend health is determined by connection success/
//!   failure only. No proactive health checks, HTTP 5xx tracking, or timeout detection.
//! - **Connection-level routing**: Load balancing decision is made per connection,
//!   not per request (consistent with one-request-per-connection assumption).
//!
//! ### Security
//! - **No X-Forwarded-For handling**: Client IP is extracted from TCP socket only.
//!   If behind another proxy, all clients appear to come from the proxy's IP.
//! - **Trusted backend assumption**: No validation of backend responses or protection
//!   against malicious backends.
//!
//! ### Performance
//! - **Fixed buffer sizes**: 4KB client buffers, 4KB backend buffers, 8KB request buffer
//! - **Per-chunk byte counting**: Statistics are updated per 8KB chunk (atomic operations)
//! - **Approximate LRU**: Cache get() does NOT update LRU order for performance
//!   (uses lockShared instead of write lock)

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
