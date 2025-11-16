//! Proxy Core Configuration
//!
//! This module contains shared configuration and options for the proxy.

const std = @import("std");
const Io = std.Io;
const Timeout = Io.Timeout;

/// Configuration options for running the proxy server
pub const RunOptions = struct {
    /// Host/interface to bind the proxy listener to. Default is loopback.
    listen_host: []const u8 = "127.0.0.1",
    /// Set a hard cap on accepted connections (useful for examples/tests).
    max_connections: ?usize = null,
    /// Allow reusing the listen socket if the process restarts quickly.
    reuse_address: bool = true,
    /// Backend dial timeout configuration (default: blocking/no timeout).
    connect_timeout: Timeout = .none,
    /// Enable statistics tracking
    enable_stats: bool = true,
    /// Enable access control (requires acl to be configured)
    enable_access_control: bool = false,
    /// Enable rate limiting (requires rate_limiter to be configured)
    enable_rate_limiting: bool = false,
    /// Enable HTTP header inspection and manipulation
    enable_http_inspection: bool = true,
    /// Enable detailed connection logging
    enable_connection_logging: bool = true,
    /// Enable HTTP response caching for performance optimization
    enable_caching: bool = true,
    /// Enable load balancing across multiple backends
    enable_load_balancing: bool = false,
};
