//! Password Hashing Utility for Prozy Authentication
//!
//! This tool generates bcrypt-style password hashes for use in Prozy configuration files.
//!
//! Usage:
//!   zig build hash_password
//!   ./zig-out/bin/hash_password <password> [cost]
//!
//! Arguments:
//!   password - The password to hash (required)
//!   cost     - bcrypt cost factor (optional, default: 12)
//!              - 4  = ~1ms per hash (fast, but weaker)
//!              - 12 = ~250ms per hash (recommended, good balance)
//!              - 15 = ~2s per hash (very secure, but slow)
//!
//! Example:
//!   $ zig build hash_password
//!   $ ./zig-out/bin/hash_password "my_secret_password" 12
//!   $2b$12$1a2b3c4d5e6f7g8h9i0j$abcdefghijklmnopqrstuvwxyz123456789
//!
//! The output hash can be used in configuration files:
//!   {
//!     "authentication": {
//!       "users": [
//!         { "username": "admin", "password_hash": "$2b$12$..." }
//!       ]
//!     }
//!   }

const std = @import("std");
const crypto = std.crypto;
const base64 = std.base64;

/// Hash password using bcrypt-style format with SHA-256
///
/// Format: $2b$<cost>$<salt>$<hash>
/// Uses SHA-256 for demonstration; production should use proper bcrypt library.
///
/// NOTE: This implementation is compatible with the hashing used in src/prozy/auth.zig
fn hashPassword(allocator: std.mem.Allocator, password: []const u8, cost: u12) ![]const u8 {
    // Generate random salt (16 bytes)
    var salt: [16]u8 = undefined;
    crypto.random.bytes(&salt);

    // Apply password stretching based on cost (2^cost iterations)
    const iterations = @as(u32, 1) << @as(u5, @intCast(cost));

    var hash: [32]u8 = undefined;
    var current_hash: [32]u8 = undefined;

    // Initial hash of password + salt
    var hasher = crypto.hash.sha2.Sha256.init(.{});
    hasher.update(password);
    hasher.update(&salt);
    hasher.final(&current_hash);

    // Iterate to increase computational cost
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        var iter_hasher = crypto.hash.sha2.Sha256.init(.{});
        iter_hasher.update(&current_hash);
        iter_hasher.final(&current_hash);
    }

    hash = current_hash;

    // Encode salt and hash in base64
    var salt_b64: [32]u8 = undefined;
    const salt_encoded = base64.standard.Encoder.encode(&salt_b64, &salt);

    var hash_b64: [64]u8 = undefined;
    const hash_encoded = base64.standard.Encoder.encode(&hash_b64, &hash);

    // Format: $2b$<cost>$<salt>$<hash>
    const result = try std.fmt.allocPrint(
        allocator,
        "$2b${d}${s}${s}",
        .{ cost, salt_encoded, hash_encoded },
    );

    return result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print(
            \\Usage: hash_password <password> [cost]
            \\
            \\Arguments:
            \\  password - The password to hash (required)
            \\  cost     - bcrypt cost factor (optional, default: 12)
            \\
            \\Examples:
            \\  hash_password "my_password"         # Uses default cost of 12
            \\  hash_password "my_password" 12      # Explicitly set cost to 12
            \\  hash_password "my_password" 15      # High security (slow)
            \\
            \\Cost guidelines:
            \\  4  = ~1ms per hash (fast, but weaker)
            \\  12 = ~250ms per hash (recommended, good balance)
            \\  15 = ~2s per hash (very secure, but slow)
            \\
        , .{});
        std.process.exit(1);
    }

    const password = args[1];
    const cost: u12 = if (args.len >= 3)
        try std.fmt.parseInt(u12, args[2], 10)
    else
        12;

    // Validate cost range
    if (cost < 4 or cost > 31) {
        std.debug.print("Error: cost must be between 4 and 31 (got: {d})\n", .{cost});
        std.process.exit(1);
    }

    std.debug.print("Hashing password with cost={d}...\n", .{cost});

    // Measure hashing time
    const start_time = std.time.Instant.now() catch null;
    const hash = try hashPassword(allocator, password, cost);
    defer allocator.free(hash);
    const end_time = std.time.Instant.now() catch null;

    const duration_ms = if (start_time) |st| if (end_time) |et| et.since(st) / std.time.ns_per_ms else 0 else 0;

    std.debug.print("\nPassword hash generated in {d}ms:\n", .{duration_ms});
    std.debug.print("{s}\n\n", .{hash});

    std.debug.print("Add this to your Prozy configuration:\n\n", .{});
    std.debug.print("JSON format:\n", .{});
    std.debug.print("  {{\n", .{});
    std.debug.print("    \"authentication\": {{\n", .{});
    std.debug.print("      \"users\": [\n", .{});
    std.debug.print("        {{ \"username\": \"admin\", \"password_hash\": \"{s}\" }}\n", .{hash});
    std.debug.print("      ]\n", .{});
    std.debug.print("    }}\n", .{});
    std.debug.print("  }}\n\n", .{});

    std.debug.print("ZON format:\n", .{});
    std.debug.print("  .{{\n", .{});
    std.debug.print("    .authentication = .{{\n", .{});
    std.debug.print("      .users = &[_].{{\n", .{});
    std.debug.print("        .{{ .username = \"admin\", .password_hash = \"{s}\" }},\n", .{hash});
    std.debug.print("      }},\n", .{});
    std.debug.print("    }},\n", .{});
    std.debug.print("  }}\n", .{});
}
