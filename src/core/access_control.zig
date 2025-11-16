//! Access Control List for IP-based filtering

const std = @import("std");
const ip_key = @import("ip_key.zig");

const IpKey = ip_key.IpKey;
const IpKeyContext = ip_key.IpKeyContext;

/// Access Control List for IP-based filtering
/// FIXED: Now uses IpKey to prevent IPv6 hash collisions
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
