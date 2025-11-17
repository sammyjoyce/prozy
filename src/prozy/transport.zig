const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Timeout = Io.Timeout;
const mem = std.mem;

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

    /// Convert IpKey to dotted decimal notation (IPv4) or hex notation (IPv6)
    /// Suitable for use in HTTP headers like X-Forwarded-For
    /// Buffer must be at least 46 bytes for IPv6 (45 chars + null terminator)
    pub fn toStringAlloc(self: IpKey, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        switch (self) {
            .ipv4 => |v4| {
                // Convert u32 back to bytes
                const bytes = [4]u8{
                    @intCast((v4 >> 24) & 0xFF),
                    @intCast((v4 >> 16) & 0xFF),
                    @intCast((v4 >> 8) & 0xFF),
                    @intCast(v4 & 0xFF),
                };
                try buf.writer().print("{}.{}.{}.{}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
            },
            .ipv6 => |v6| {
                // Simple hex representation (not compressed)
                try buf.writer().print("{x:0>32}", .{v6});
            },
        }

        return try buf.toOwnedSlice();
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

pub fn resolveListenAddress(host: []const u8, port: u16) !net.IpAddress {
    if (net.Ip4Address.parse(host, port)) |ip4| {
        return .{ .ip4 = ip4 };
    } else |_| {}

    if (net.Ip6Address.parse(host, port)) |ip6| {
        return .{ .ip6 = ip6 };
    } else |_| {}

    if (host.len == 0 or mem.eql(u8, host, "*") or mem.eql(u8, host, "0.0.0.0")) {
        return .{ .ip4 = net.Ip4Address.unspecified(port) };
    }

    return .{ .ip4 = net.Ip4Address.loopback(port) };
}

pub fn connectToBackend(io: Io, host: []const u8, port: u16, timeout: Timeout) !net.Stream {
    if (net.Ip4Address.parse(host, port)) |ip4| {
        return (net.IpAddress{ .ip4 = ip4 }).connect(io, .{ .mode = .stream, .timeout = timeout });
    } else |_| {}

    if (net.Ip6Address.parse(host, port)) |ip6| {
        return (net.IpAddress{ .ip6 = ip6 }).connect(io, .{ .mode = .stream, .timeout = timeout });
    } else |_| {}

    const host_name = try net.HostName.init(host);
    return host_name.connect(io, port, .{ .mode = .stream, .timeout = timeout });
}

pub fn extractClientIp(address: net.IpAddress) IpKey {
    return IpKey.fromAddress(address);
}
