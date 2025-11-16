//! Rate limiter for connection control

const std = @import("std");
const ip_key = @import("ip_key.zig");

const IpKey = ip_key.IpKey;
const IpKeyContext = ip_key.IpKeyContext;

/// Rate limiter for connection control
/// FIXED: Now uses IpKey to prevent IPv6 hash collisions
pub const RateLimiter = struct {
    const IpConnectionCount = std.HashMap(IpKey, u32, IpKeyContext, std.hash_map.default_max_load_percentage);

    connections_per_ip: IpConnectionCount,
    max_per_ip: u32,
    max_global: u32,
    current_global: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, max_per_ip: u32, max_global: u32) RateLimiter {
        return .{
            .connections_per_ip = IpConnectionCount.init(allocator),
            .max_per_ip = max_per_ip,
            .max_global = max_global,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.connections_per_ip.deinit();
    }

    pub fn tryAcquire(self: *RateLimiter, ip: IpKey) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check global limit (inside mutex to prevent race condition)
        const current = self.current_global.load(.monotonic);
        if (current >= self.max_global) return false;

        // Check per-IP limit
        const count = self.connections_per_ip.get(ip) orelse 0;
        if (count >= self.max_per_ip) return false;

        // Acquire
        self.connections_per_ip.put(ip, count + 1) catch return false;
        _ = self.current_global.fetchAdd(1, .monotonic);
        return true;
    }

    /// Release a rate limit slot for an IP address
    ///
    /// CRITICAL FIX: Prevents HashMap leak on OOM
    /// - When count == 1: remove() entry entirely (avoids rehashing)
    /// - When count > 1: put() will never fail (existing key, no allocation)
    /// - Global counter is ALWAYS decremented to prevent leaks
    ///
    /// Previous implementation: put() could fail during HashMap rehashing,
    /// causing global counter leak and eventual rate limit exhaustion.
    pub fn release(self: *RateLimiter, ip: IpKey) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.connections_per_ip.get(ip)) |count| {
            if (count > 0) {
                if (count == 1) {
                    // Remove entry entirely to avoid HashMap rehashing issues
                    _ = self.connections_per_ip.remove(ip);
                } else {
                    // Decrement existing entry (should never fail - not adding new key)
                    self.connections_per_ip.put(ip, count - 1) catch unreachable;
                }
                // Always decrement global counter
                _ = self.current_global.fetchSub(1, .monotonic);
            }
        }
    }
};
