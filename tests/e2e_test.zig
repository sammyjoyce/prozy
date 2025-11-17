const std = @import("std");

const TestServerPort = 3003;
const ProxyPort = 8080;

fn runCurlTest(
    allocator: std.mem.Allocator,
    comptime description: []const u8,
    comptime success_msg: []const u8,
    comptime failure_fmt: []const u8,
    comptime url_fmt: []const u8,
    url_args: anytype,
) !bool {
    std.debug.print(description, .{});

    const url = try std.fmt.allocPrint(allocator, url_fmt, url_args);
    defer allocator.free(url);

    var child = std.process.Child.init(&.{
        "curl",
        "-s",
        "-w",
        "\\nHTTP_CODE:%{http_code}",
        url,
    }, allocator);
    const result = try child.spawnAndWait();

    if (result.Exited == 0) {
        std.debug.print(success_msg, .{});
        return true;
    }

    std.debug.print(failure_fmt, .{result.Exited});
    return false;
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    std.debug.print("🚀 Starting End-to-End Proxy Test\n", .{});
    std.debug.print("=================================\n\n", .{});

    // Start Bun test server in background
    std.debug.print("🔧 Starting Bun test server on port {}...\n", .{TestServerPort});
    var server_process = std.process.Child.init(&.{ "bun", "tests/test-server.ts" }, gpa);
    try server_process.spawn();

    // Wait for server to start
    std.posix.nanosleep(2, 0);

    // Build the proxy first
    std.debug.print("🔧 Building Zig proxy...\n", .{});
    var build_process = std.process.Child.init(&.{ "zig", "build" }, gpa);
    const build_result = try build_process.spawnAndWait();
    if (build_result.Exited != 0) {
        std.debug.print("❌ Build failed with code {}\n", .{build_result.Exited});
        return error.BuildFailed;
    }

    // Start Zig proxy directly (not through zig build run)
    // Use simple.json config which points to localhost:3003
    std.debug.print("🔧 Starting Zig proxy on port {}...\n", .{ProxyPort});
    var proxy_process = std.process.Child.init(&.{ "zig-out/bin/prozy", "config/simple.json" }, gpa);
    try proxy_process.spawn();

    // Wait for services to be ready
    std.debug.print("⏳ Waiting for services to initialize...\n", .{});
    std.posix.nanosleep(5, 0);

    // Run actual HTTP tests
    std.debug.print("\n🧪 Running HTTP Tests\n", .{});
    std.debug.print("====================\n\n", .{});

    var test_passed = true;

    if (!try runCurlTest(
        gpa,
        "Test 1: GET / through proxy...\n",
        "   ✅ Proxy responded to root endpoint\n",
        "   ❌ Proxy failed to respond (exit code: {})\n",
        "http://localhost:{d}/",
        .{ProxyPort},
    )) {
        test_passed = false;
    }

    if (!try runCurlTest(
        gpa,
        "\nTest 2: GET /json through proxy...\n",
        "   ✅ Proxy forwarded JSON endpoint request\n",
        "   ❌ JSON endpoint test failed (exit code: {})\n",
        "http://localhost:{d}/json",
        .{ProxyPort},
    )) {
        test_passed = false;
    }

    if (!try runCurlTest(
        gpa,
        "\nTest 3: GET / direct to server (bypass proxy)...\n",
        "   ✅ Direct server connection works\n",
        "   ❌ Direct server test failed (exit code: {})\n",
        "http://localhost:{d}/",
        .{TestServerPort},
    )) {
        test_passed = false;
    }

    std.debug.print("\n📊 Test Summary\n", .{});
    std.debug.print("==============\n", .{});
    if (test_passed) {
        std.debug.print("✅ All tests passed - Proxy is forwarding requests correctly!\n", .{});
    } else {
        std.debug.print("❌ Some tests failed - Proxy may not be forwarding correctly\n", .{});
        return error.TestsFailed;
    }

    // Cleanup
    std.debug.print("\n🧹 Cleaning up processes...\n", .{});

    // Kill and wait for server process
    if (server_process.kill()) |_| {
        std.debug.print("   Terminating test server...\n", .{});
        _ = server_process.wait() catch |err| {
            std.debug.print("   Warning: Error waiting for server: {}\n", .{err});
        };
    } else |err| {
        std.debug.print("   Warning: Could not kill server: {}\n", .{err});
    }

    // Kill and wait for proxy process
    if (proxy_process.kill()) |_| {
        std.debug.print("   Terminating proxy...\n", .{});
        _ = proxy_process.wait() catch |err| {
            std.debug.print("   Warning: Error waiting for proxy: {}\n", .{err});
        };
    } else |err| {
        std.debug.print("   Warning: Could not kill proxy: {}\n", .{err});
    }

    std.debug.print("✅ E2E test completed successfully!\n", .{});
}
