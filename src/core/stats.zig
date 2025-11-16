//! Connection statistics for monitoring and observability

const std = @import("std");

/// Connection statistics for monitoring and observability
pub const ProxyStats = struct {
    active_connections: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_connections: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_bytes_client_to_backend: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_bytes_backend_to_client: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    backend_connect_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init() ProxyStats {
        return .{};
    }

    pub fn recordConnection(self: *ProxyStats) void {
        _ = self.active_connections.fetchAdd(1, .monotonic);
        _ = self.total_connections.fetchAdd(1, .monotonic);
    }

    pub fn recordConnectionEnd(self: *ProxyStats) void {
        _ = self.active_connections.fetchSub(1, .monotonic);
    }

    pub fn recordBytesClientToBackend(self: *ProxyStats, bytes: u64) void {
        _ = self.total_bytes_client_to_backend.fetchAdd(bytes, .monotonic);
    }

    pub fn recordBytesBackendToClient(self: *ProxyStats, bytes: u64) void {
        _ = self.total_bytes_backend_to_client.fetchAdd(bytes, .monotonic);
    }

    pub fn recordError(self: *ProxyStats) void {
        _ = self.total_errors.fetchAdd(1, .monotonic);
    }

    pub fn recordBackendFailure(self: *ProxyStats) void {
        _ = self.backend_connect_failures.fetchAdd(1, .monotonic);
    }

    pub fn getStats(self: *const ProxyStats) StatsSnapshot {
        return .{
            .active_connections = self.active_connections.load(.monotonic),
            .total_connections = self.total_connections.load(.monotonic),
            .total_bytes_client_to_backend = self.total_bytes_client_to_backend.load(.monotonic),
            .total_bytes_backend_to_client = self.total_bytes_backend_to_client.load(.monotonic),
            .total_errors = self.total_errors.load(.monotonic),
            .backend_connect_failures = self.backend_connect_failures.load(.monotonic),
        };
    }

    pub const StatsSnapshot = struct {
        active_connections: u64,
        total_connections: u64,
        total_bytes_client_to_backend: u64,
        total_bytes_backend_to_client: u64,
        total_errors: u64,
        backend_connect_failures: u64,
    };
};
