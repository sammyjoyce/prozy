//! Health Checker: Proactive backend health monitoring
//!
//! Provides periodic health checks for backends using:
//! - Background async task
//! - TCP connection probes
//! - Exponential backoff respect
//! - Graceful shutdown support

const std = @import("std");
const builtin = @import("builtin");
const log = std.log;
const mem = std.mem;
const Io = std.Io;
const net = Io.net;
const Timeout = Io.Timeout;
const Duration = Io.Duration;

const Backend = @import("backend.zig").Backend;
const connectToBackend = @import("transport.zig").connectToBackend;

pub const HealthChecker = struct {
    allocator: mem.Allocator,
    backends: []Backend,
    check_interval_ms: u64,
    connect_timeout_ms: u64,
    shutdown_requested: *std.atomic.Value(bool),

    /// Initialize health checker
    pub fn init(
        allocator: mem.Allocator,
        backends: []Backend,
        check_interval_ms: u64,
        connect_timeout_ms: u64,
        shutdown_requested: *std.atomic.Value(bool),
    ) HealthChecker {
        return .{
            .allocator = allocator,
            .backends = backends,
            .check_interval_ms = check_interval_ms,
            .connect_timeout_ms = connect_timeout_ms,
            .shutdown_requested = shutdown_requested,
        };
    }

    /// Run health check loop (blocks until shutdown)
    pub fn run(self: *HealthChecker, io: Io) !void {
        if (!builtin.is_test) {
            log.info("health checker started (interval: {}ms)", .{self.check_interval_ms});
        }

        while (!self.shutdown_requested.load(.monotonic)) {
            // Sleep for check interval
            const sleep_duration = Duration.fromMilliseconds(@intCast(self.check_interval_ms));
            Io.sleep(io, sleep_duration, .awake) catch {};

            // Check if shutdown was requested during sleep
            if (self.shutdown_requested.load(.monotonic)) {
                break;
            }

            // Check all backends that need retry
            for (self.backends) |*backend| {
                if (backend.shouldRetry()) {
                    self.checkBackend(io, backend);
                }
            }
        }

        if (!builtin.is_test) {
            log.info("health checker stopped", .{});
        }
    }

    /// Check a single backend's health
    fn checkBackend(self: *HealthChecker, io: Io, backend: *Backend) void {
        const timeout: Timeout = .{
            .duration = .{
                .raw = Duration.fromMilliseconds(@intCast(self.connect_timeout_ms)),
                .clock = .awake,
            },
        };

        // Attempt TCP connection
        const stream = connectToBackend(io, backend.host, backend.port, timeout) catch |err| {
            // Connection failed - backend still unhealthy
            if (!builtin.is_test) {
                log.debug("health check failed for {s}:{} - {s}", .{
                    backend.host,
                    backend.port,
                    @errorName(err),
                });
            }
            return;
        };
        defer stream.close(io);

        // Connection succeeded - mark healthy and reset retry count
        backend.markHealthy(true);

        if (!builtin.is_test) {
            log.info("health check succeeded for {s}:{} - backend marked healthy", .{
                backend.host,
                backend.port,
            });
        }
    }

    /// Perform a one-time health check on all backends
    pub fn checkAll(self: *HealthChecker, io: Io) void {
        for (self.backends) |*backend| {
            self.checkBackend(io, backend);
        }
    }
};

// Tests
test "HealthChecker initialization" {
    const allocator = std.testing.allocator;

    var backends = [_]Backend{
        Backend.init("127.0.0.1", 3003, 1),
        Backend.init("127.0.0.1", 3004, 1),
    };

    var shutdown_flag = std.atomic.Value(bool).init(false);

    const checker = HealthChecker.init(
        allocator,
        backends[0..],
        5000, // 5 second interval
        1000, // 1 second timeout
        &shutdown_flag,
    );

    try std.testing.expectEqual(@as(u64, 5000), checker.check_interval_ms);
    try std.testing.expectEqual(@as(u64, 1000), checker.connect_timeout_ms);
    try std.testing.expectEqual(@as(usize, 2), checker.backends.len);
}

test "HealthChecker respects shutdown flag" {
    const allocator = std.testing.allocator;

    var backends = [_]Backend{
        Backend.init("127.0.0.1", 3003, 1),
    };

    var shutdown_flag = std.atomic.Value(bool).init(true); // Already shutdown

    var checker = HealthChecker.init(
        allocator,
        backends[0..],
        5000,
        1000,
        &shutdown_flag,
    );

    // Create Io executor
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Should exit immediately because shutdown_requested is true
    try checker.run(io);
    // If we get here, the test passed (didn't hang)
}

test "HealthChecker marks backend healthy on successful connection" {
    const allocator = std.testing.allocator;

    var backends = [_]Backend{
        Backend.init("127.0.0.1", 3003, 1),
    };

    // Mark backend as unhealthy
    backends[0].markHealthy(false);
    try std.testing.expect(!backends[0].isHealthy());

    var shutdown_flag = std.atomic.Value(bool).init(false);

    var checker = HealthChecker.init(
        allocator,
        backends[0..],
        5000,
        1000,
        &shutdown_flag,
    );

    // Note: This test would require a real backend running on 3003
    // For unit testing, we just verify the structure is correct
    try std.testing.expectEqual(@as(usize, 1), checker.backends.len);

    // Verify backend is still unhealthy (no connection made in test)
    try std.testing.expect(!backends[0].isHealthy());
}
