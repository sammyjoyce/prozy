//! Prozy: A production-ready async TCP proxy library
//!
//! This is the public API for the Prozy library. It provides a clean,
//! modular interface for building TCP and HTTP proxies using Zig's
//! new std.Io runtime.
//!
//! ## Architecture
//!
//! The library is organized into several modules:
//! - **core/**: Protocol-agnostic components (IP handling, stats, access control, rate limiting, backends, load balancing)
//! - **tcp/**: Generic TCP operations (bidirectional copy, server)
//! - **http/**: HTTP-specific features (inspector, cache, pipeline)
//! - **app/**: High-level "products" (proxy_core, http_proxy)
//!
//! ## Quick Start
//!
//! ```zig
//! const std = @import("std");
//! const prozy = @import("prozy");
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!     const allocator = gpa.allocator();
//!
//!     // Create async I/O runtime
//!     var threaded_io = std.Io.Threaded.init(allocator);
//!     defer threaded_io.deinit();
//!     const io = threaded_io.io();
//!
//!     // Create and run HTTP proxy
//!     var proxy = prozy.Proxy.init(allocator, 8080, "127.0.0.1", 3003);
//!     defer proxy.deinit();
//!     try proxy.runWithIo(io);
//! }
//! ```

const std = @import("std");

// ============= Core Modules =============
// Protocol-agnostic components

const ip_key_mod = @import("core/ip_key.zig");
pub const IpKey = ip_key_mod.IpKey;
pub const IpKeyContext = ip_key_mod.IpKeyContext;

const stats_mod = @import("core/stats.zig");
pub const ProxyStats = stats_mod.ProxyStats;

const access_control_mod = @import("core/access_control.zig");
pub const AccessControl = access_control_mod.AccessControl;

const rate_limiter_mod = @import("core/rate_limiter.zig");
pub const RateLimiter = rate_limiter_mod.RateLimiter;

const backend_mod = @import("core/backend.zig");
pub const Backend = backend_mod.Backend;

const load_balancer_mod = @import("core/load_balancer.zig");
pub const LoadBalancer = load_balancer_mod.LoadBalancer;

// ============= HTTP Modules =============
// HTTP-specific features

const http_inspector_mod = @import("http/inspector.zig");
pub const HTTPInspector = http_inspector_mod.HTTPInspector;

const http_cache_mod = @import("http/cache.zig");
pub const HTTPCache = http_cache_mod.HTTPCache;

// ============= TCP Modules =============
// Generic TCP operations

const tcp_copy_mod = @import("tcp/copy.zig");
pub const copyBidirectional = tcp_copy_mod.copyBidirectional;
pub const copyBidirectionalWithStats = tcp_copy_mod.copyBidirectionalWithStats;
pub const copyPipe = tcp_copy_mod.copyPipe;
pub const copyPipeWithStats = tcp_copy_mod.copyPipeWithStats;
pub const copyPipeWithCaching = tcp_copy_mod.copyPipeWithCaching;

// ============= Application Modules =============
// High-level proxy implementations

const proxy_core_mod = @import("app/proxy_core.zig");
pub const RunOptions = proxy_core_mod.RunOptions;

const http_proxy_mod = @import("app/http_proxy.zig");
pub const HttpProxy = http_proxy_mod.HttpProxy;

// Maintain backward compatibility: export HttpProxy as Proxy
pub const Proxy = HttpProxy;

// ============= Convenience Functions =============
// High-level API for common use cases

/// Run a basic HTTP proxy with default options
/// This is a convenience function that sets up the I/O runtime internally
pub fn runProxy(
    allocator: std.mem.Allocator,
    proxy_port: u16,
    backend_host: []const u8,
    backend_port: u16,
) !void {
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var proxy = Proxy.init(allocator, proxy_port, backend_host, backend_port);
    defer proxy.deinit();

    try proxy.runWithIo(io);
}

/// Run a HTTP proxy with custom I/O executor
/// Use this when you want to manage the I/O runtime yourself
pub fn runProxyWithIo(
    allocator: std.mem.Allocator,
    proxy_port: u16,
    backend_host: []const u8,
    backend_port: u16,
    io: std.Io,
) !void {
    var proxy = Proxy.init(allocator, proxy_port, backend_host, backend_port);
    defer proxy.deinit();

    try proxy.runWithIo(io);
}

/// Run a HTTP proxy with custom options and I/O executor
/// This provides full control over all proxy configuration
pub fn runProxyWithIoOptions(
    allocator: std.mem.Allocator,
    proxy_port: u16,
    backend_host: []const u8,
    backend_port: u16,
    io: std.Io,
    options: RunOptions,
) !void {
    var proxy = Proxy.init(allocator, proxy_port, backend_host, backend_port);
    defer proxy.deinit();

    try proxy.runWithIoOptions(io, options);
}

// ============= Tests =============

test "root exports are accessible" {
    // This test ensures all public exports are accessible
    const testing = std.testing;

    // Core types
    _ = IpKey;
    _ = IpKeyContext;
    _ = ProxyStats;
    _ = AccessControl;
    _ = RateLimiter;
    _ = Backend;
    _ = LoadBalancer;

    // HTTP types
    _ = HTTPInspector;
    _ = HTTPCache;

    // TCP functions
    _ = copyBidirectional;
    _ = copyBidirectionalWithStats;
    _ = copyPipe;
    _ = copyPipeWithStats;
    _ = copyPipeWithCaching;

    // Application types
    _ = RunOptions;
    _ = HttpProxy;
    _ = Proxy;

    // Convenience functions
    _ = runProxy;
    _ = runProxyWithIo;
    _ = runProxyWithIoOptions;

    try testing.expect(true);
}
