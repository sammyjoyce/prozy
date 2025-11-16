//! IP address key for rate limiting and access control
//! Prevents IPv6 hash collisions by using full 128-bit address

const std = @import("std");
const Io = std.Io;
const net = Io.net;

/// IP address key for rate limiting and access control
/// Prevents IPv6 hash collisions by using full 128-bit address
pub const IpKey = union(enum) {
    ipv4: u32,
    ipv6: u128,

    pub fn fromAddress(address: net.IpAddress) IpKey {
        return switch (address) {
            .ip4 => |ip4| .{ .ipv4 = bytesToU32(ip4.bytes) },
            .ip6 => |ip6| .{ .ipv6 = bytesToU128(ip6.bytes) },
        };
    }

    pub fn hash(self: IpKey) u64 {
        return switch (self) {
            .ipv4 => |v4| @as(u64, v4),
            .ipv6 => |v6| std.hash.Wyhash.hash(0, std.mem.asBytes(&v6)),
        };
    }

    pub fn eql(self: IpKey, other: IpKey) bool {
        if (@as(std.meta.Tag(IpKey), self) != @as(std.meta.Tag(IpKey), other)) {
            return false;
        }
        return switch (self) {
            .ipv4 => |v4| v4 == other.ipv4,
            .ipv6 => |v6| v6 == other.ipv6,
        };
    }

    fn bytesToU32(bytes: [4]u8) u32 {
        return (@as(u32, bytes[0]) << 24) |
            (@as(u32, bytes[1]) << 16) |
            (@as(u32, bytes[2]) << 8) |
            (@as(u32, bytes[3]));
    }

    fn bytesToU128(bytes: [16]u8) u128 {
        var result: u128 = 0;
        for (bytes, 0..) |byte, i| {
            result |= @as(u128, byte) << @intCast((15 - i) * 8);
        }
        return result;
    }

    pub fn format(self: IpKey, comptime fmt: []const u8, options: anytype, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .ipv4 => |v4| try writer.print("IPv4:{any}", .{v4}),
            .ipv6 => |v6| try writer.print("IPv6:{x}", .{v6}),
        }
    }
};

// Context for IpKey HashMap
pub const IpKeyContext = struct {
    pub fn hash(_: IpKeyContext, key: IpKey) u64 {
        return key.hash();
    }

    pub fn eql(_: IpKeyContext, a: IpKey, b: IpKey) bool {
        return a.eql(b);
    }
};
