const std = @import("std");
const IpKey = @import("transport.zig").IpKey;
const IpKeyContext = @import("transport.zig").IpKeyContext;

/// Access control for IP-based filtering
/// Supports allow/deny lists with configurable default policy
pub const AccessControl = struct {
    const IpSet = std.HashMap(IpKey, void, IpKeyContext, std.hash_map.default_max_load_percentage);

    allocator: std.mem.Allocator,
    allow_list: ?IpSet = null,
    deny_list: ?IpSet = null,
    default_policy: Policy = .allow,

    pub const Policy = enum {
        allow,
        deny,
    };

    pub fn init(allocator: std.mem.Allocator, default_policy: Policy) !AccessControl {
        return .{
            .allocator = allocator,
            .allow_list = null,
            .deny_list = null,
            .default_policy = default_policy,
        };
    }

    pub fn deinit(self: *AccessControl) void {
        if (self.allow_list) |*list| list.deinit();
        if (self.deny_list) |*list| list.deinit();
    }

    pub fn addToAllowList(self: *AccessControl, ip: IpKey) !void {
        if (self.allow_list == null) {
            self.allow_list = IpSet.init(self.allocator);
        }
        try self.allow_list.?.put(ip, {});
    }

    pub fn addToDenyList(self: *AccessControl, ip: IpKey) !void {
        if (self.deny_list == null) {
            self.deny_list = IpSet.init(self.allocator);
        }
        try self.deny_list.?.put(ip, {});
    }

    pub fn isAllowed(self: *const AccessControl, ip: IpKey) bool {
        // Check deny list first
        if (self.deny_list) |list| {
            if (list.contains(ip)) return false;
        }

        // Check allow list
        if (self.allow_list) |list| {
            if (list.contains(ip)) return true;
            // If allow list exists but IP not in it, deny (whitelist mode)
            return false;
        }

        // Fall back to default policy
        return self.default_policy == .allow;
    }
};

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
