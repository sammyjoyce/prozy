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
//! ## Operating Modes
//!
//! Prozy supports two operating modes:
//!
//! ### HTTP Proxy Mode (L7) - NEW!
//! - **HTTP keep-alive**: Multiple requests on the same TCP connection
//! - **Request-level routing**: Per-request backend selection based on method/host/path
//! - **Connection header handling**: Respects Connection: keep-alive and Connection: close
//! - **Host-aware caching**: Cache keys include Host header for multi-tenant isolation
//! - **Sequential processing**: Clean request → route → forward → response → next request
//!
//! ### TCP Tunnel Mode (L4) - Legacy
//! - **One HTTP request per TCP connection**: Each connection carries a single HTTP request
//! - **Bidirectional byte streaming**: Full-duplex data flow with io.select()
//! - **Connection-level routing**: Backend selected once per TCP connection
//! - **30-second timeout**: After one direction completes, waits up to 30s for the other
//!
//! ## Known Limitations and Assumptions
//!
//! ### Protocol Support
//! - **HTTP/1.1 only**: No TLS/SSL termination, WebSocket support, or HTTP/2.
//! - **TCP-only**: No UDP support. Adding UDP would require significant changes.
//! - **HTTP pipelining**: Not supported (sequential request/response only)
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
//! - **HTTP mode**: Per-request routing with backend health checking
//! - **TCP tunnel mode**: Per-connection routing (backend selected once)
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

// Proxy core
const proxy = @import("prozy/proxy.zig");
pub const RunOptions = proxy.RunOptions;
pub const Proxy = proxy.Proxy;
pub const runProxy = proxy.runProxy;
pub const runProxyWithIo = proxy.runProxyWithIo;
pub const HttpMode = proxy.HttpMode;
pub const RoutingDecision = proxy.RoutingDecision;

// Import tests for `zig build test`
test {
    std.testing.refAllDecls(@This());
    _ = @import("prozy/tests.zig");
}
