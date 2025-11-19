//! Health Monitor: Proactive backend health monitoring
//!
//! Provides periodic health checks for backends using:
//! - Background async task
//! - TCP connection probes
//! - Proactive failure detection
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

pub const HealthMonitor = struct {
    allocator: mem.Allocator,
    backends: []*Backend,
    check_interval_ms: u64,
    connect_timeout_ms: u64,
    shutdown_requested: *std.atomic.Value(bool),

    /// Initialize health monitor
    pub fn init(
        allocator: mem.Allocator,
        backends: []*Backend,
        check_interval_ms: u64,
        connect_timeout_ms: u64,
        shutdown_requested: *std.atomic.Value(bool),
    ) HealthMonitor {
        return .{
            .allocator = allocator,
            .backends = backends,
            .check_interval_ms = check_interval_ms,
            .connect_timeout_ms = connect_timeout_ms,
            .shutdown_requested = shutdown_requested,
        };
    }

    /// Start the health monitor in a background task
    /// Returns the future for the running task
    pub fn start(self: *HealthMonitor, io: Io, group: *Io.Group) !void {
        _ = group.async(io, run, .{self, io});
    }

    /// Run health check loop (blocks until shutdown)
    pub fn run(self: *HealthMonitor, io: Io) void {
        if (!builtin.is_test) {
            log.info("health monitor started (interval: {}ms, backends: {})", .{ self.check_interval_ms, self.backends.len });
        }

        while (!self.shutdown_requested.load(.monotonic)) {
            // Check all backends
            for (self.backends) |backend| {
                self.checkBackend(io, backend);
                
                // Yield to allow other tasks to run (prevent starvation in tight loops)
                // Io.yield(io) would be nice, but sleep is implicit yield.
            }

            // Sleep for check interval
            // We sleep after checking all to space out checks
            const sleep_duration = Duration.fromMilliseconds(@intCast(self.check_interval_ms));
            Io.sleep(io, sleep_duration, .awake) catch {};
        }

        if (!builtin.is_test) {
            log.info("health monitor stopped", .{});
        }
    }

    /// Check a single backend's health
    fn checkBackend(self: *HealthMonitor, io: Io, backend: *Backend) void {
        const timeout: Timeout = .{
            .duration = .{
                .raw = Duration.fromMilliseconds(@intCast(self.connect_timeout_ms)),
                .clock = .awake,
            },
        };

        // Attempt TCP connection
        // TODO: In Phase 5 (TLS), this should do a TLS handshake if configured
        const stream = connectToBackend(io, backend.host, backend.port, timeout) catch |err| {
            // Connection failed
            const was_healthy = backend.isHealthy();
            backend.markHealthy(false);
            
            if (was_healthy and !builtin.is_test) {
                log.warn("health check failed for {s}:{} - marked DOWN ({s})", .{
                    backend.host, backend.port, @errorName(err)
                });
            }
            return;
        };
        defer stream.close(io);

        // Connection succeeded
        const was_unhealthy = !backend.isHealthy();
        backend.markHealthy(true);

        if (was_unhealthy and !builtin.is_test) {
            log.info("health check succeeded for {s}:{} - marked UP", .{
                backend.host, backend.port
            });
        }
    }
};

// Tests
test "HealthMonitor initialization" {
    const allocator = std.testing.allocator;

    var b1 = Backend.init("127.0.0.1", 3003, 1);
    var b2 = Backend.init("127.0.0.1", 3004, 1);
    var backends = [_]*Backend{ &b1, &b2 };

    var shutdown_flag = std.atomic.Value(bool).init(false);

    const monitor = HealthMonitor.init(
        allocator,
        backends[0..],
        5000, // 5 second interval
        1000, // 1 second timeout
        &shutdown_flag,
    );

    try std.testing.expectEqual(@as(u64, 5000), monitor.check_interval_ms);
    try std.testing.expectEqual(@as(u64, 1000), monitor.connect_timeout_ms);
    try std.testing.expectEqual(@as(usize, 2), monitor.backends.len);
}

test "HealthMonitor respects shutdown flag" {
    const allocator = std.testing.allocator;

    var b1 = Backend.init("127.0.0.1", 3003, 1);
    var backends = [_]*Backend{ &b1 };

    var shutdown_flag = std.atomic.Value(bool).init(true); // Already shutdown

    var monitor = HealthMonitor.init(
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
    monitor.run(io);
}
