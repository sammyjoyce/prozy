//! Backend server configuration for load balancing with health tracking
//! and exponential backoff recovery.

const std = @import("std");

const log = std.log;

/// Global monotonic timestamp fallback used when system clock fails.
/// Used by Backend health tracking to ensure recovery works even if system clock fails.
var global_fallback_timestamp: std.atomic.Value(i64) = std.atomic.Value(i64).init(1);

/// Get current Unix timestamp in seconds
fn getTimestamp() i64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch |err| {
        log.warn("clock_gettime() failed: {s}, backend health recovery may be disabled", .{@errorName(err)});
        return 0;
    };
    return ts.sec;
}

/// Backend server configuration for load balancing
pub const Backend = struct {
    host: []const u8,
    port: u16,
    weight: u32 = 1,
    healthy: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    unhealthy_since: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    // Exponential backoff configuration for health recovery
    retry_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    max_retry_count: u32 = 5, // Maximum retries before circuit breaker opens
    base_recovery_interval_seconds: u32 = 5, // Base interval for exponential backoff
    max_recovery_interval_seconds: u32 = 300, // Max interval (5 minutes)

    // Deprecated: kept for backward compatibility, not used internally
    recovery_interval_seconds: u32 = 30,

    pub fn init(host: []const u8, port: u16, weight: u32) Backend {
        return .{
            .host = host,
            .port = port,
            .weight = weight,
        };
    }

    pub fn markHealthy(self: *Backend, healthy: bool) void {
        self.healthy.store(healthy, .monotonic);
        if (!healthy) {
            // Record when backend became unhealthy.
            // This timestamp is used by shouldRetry() for exponential backoff.
            var now = getTimestamp();

            // Use fallback monotonic counter if clock_gettime fails
            if (now == 0) {
                now = global_fallback_timestamp.fetchAdd(1, .monotonic);
                log.warn("clock_gettime failed for backend {s}:{}, using fallback timestamp: {}", .{ self.host, self.port, now });
            }

            self.unhealthy_since.store(now, .monotonic);
            // Increment retry count for exponential backoff
            self.incrementRetryCount();
        } else {
            // Reset unhealthy timestamp and retry count when recovered
            self.unhealthy_since.store(0, .monotonic);
            self.resetRetryCount();
        }
    }

    pub fn isHealthy(self: *const Backend) bool {
        return self.healthy.load(.monotonic);
    }

    /// Check if backend should be retried (for health recovery)
    /// Uses exponential backoff to prevent thundering herd problem
    pub fn shouldRetry(self: *const Backend) bool {
        if (self.isHealthy()) return true;

        // Check if we've exceeded max retry count (circuit breaker)
        const retries = self.retry_count.load(.monotonic);
        if (retries > self.max_retry_count) return false;

        // Check if recovery interval has passed
        const unhealthy_timestamp = self.unhealthy_since.load(.monotonic);

        // If unhealthy_timestamp is 0, it means either:
        // (1) Backend never marked as unhealthy (initial state), or
        // (2) clock_gettime() failed and we couldn't record the timestamp.
        // In either case, we conservatively return false to prevent
        // thundering herd. See markHealthy() for logging on clock failures.
        if (unhealthy_timestamp == 0) return false;

        const now = getTimestamp();
        const seconds_unhealthy = now - unhealthy_timestamp;

        // Use exponential backoff interval
        const recovery_interval = self.getRecoveryInterval();
        return seconds_unhealthy >= recovery_interval;
    }

    pub fn incrementConnections(self: *Backend) void {
        _ = self.active_connections.fetchAdd(1, .monotonic);
    }

    pub fn decrementConnections(self: *Backend) void {
        _ = self.active_connections.fetchSub(1, .monotonic);
    }

    pub fn getConnections(self: *const Backend) u32 {
        return self.active_connections.load(.monotonic);
    }

    /// Increment retry count for exponential backoff
    pub fn incrementRetryCount(self: *Backend) void {
        _ = self.retry_count.fetchAdd(1, .monotonic);
    }

    /// Reset retry count when backend recovers
    pub fn resetRetryCount(self: *Backend) void {
        self.retry_count.store(0, .monotonic);
    }

    /// Get current retry count
    pub fn getRetryCount(self: *const Backend) u32 {
        return self.retry_count.load(.monotonic);
    }

    /// Calculate recovery interval using exponential backoff
    /// Formula: base * min(2^retry_count, max_interval / base)
    /// Prevents thundering herd by spreading out retry attempts
    pub fn getRecoveryInterval(self: *const Backend) u32 {
        const retries = self.retry_count.load(.monotonic);
        const base = self.base_recovery_interval_seconds;
        const max = self.max_recovery_interval_seconds;

        // Calculate 2^retry_count using bit shift for efficiency
        // Cap at 32 to prevent overflow (2^32 would overflow u32)
        const exponent = @min(retries, 31);
        const backoff_multiplier: u32 = @as(u32, 1) << @intCast(exponent);

        // Calculate interval with overflow protection
        const uncapped_interval = if (backoff_multiplier > max / base)
            max
        else
            base * backoff_multiplier;

        return @min(uncapped_interval, max);
    }
};
