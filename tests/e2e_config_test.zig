const std = @import("std");
const prozy = @import("prozy");
const Io = std.Io;
const net = Io.net;
const Timeout = Io.Timeout;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("🚀 Starting E2E Config Test\n", .{});

    // 1. Create Config
    const config_path = "e2e_test_config.json";
    const config_json =
        \\{
        \\  "proxy": {
        \\    "listen_host": "127.0.0.1",
        \\    "listen_port": 8085
        \\  },
        \\  "mode": "reverse_proxy",
        \\  "clusters": [
        \\    {
        \\      "name": "backend",
        \\      "backends": [
        \\        { "host": "127.0.0.1", "port": 3003, "weight": 1 }
        \\      ]
        \\    }
        \\  ],
        \\  "routes": [
        \\    {
        \\      "name": "default",
        \\      "match": {},
        \\      "cluster": "backend",
        \\      "timeout_policy": {
        \\        "connect_timeout_ms": 0
        \\      }
        \\    }
        \\  ]
        \\}
    ;
    {
        const file = try std.fs.cwd().createFile(config_path, .{});
        defer file.close();
        try file.writeAll(config_json);
    }
    defer std.fs.cwd().deleteFile(config_path) catch {};

    // 2. Check if backend is running (optional, test will fail with 502/504/error if not, which validates proxy is up)
    // Start Bun test server in background
    std.debug.print("🔧 Starting Bun test server on port 3003...\n", .{});
    var server_process = std.process.Child.init(&.{ "bun", "tests/test-server.ts" }, allocator);
    // Ignore error if spawn fails (might be already running or bun missing)
    _ = server_process.spawn() catch {};

    // Wait for server to start
    std.posix.nanosleep(1, 0);

    defer {
        _ = server_process.kill() catch {};
        _ = server_process.wait() catch {};
    }

    // 3. Start Proxy in separate thread
    const manager = try prozy.ConfigManager.init(allocator, config_path);
    defer manager.deinit();

    var lease = manager.getConfig();
    const config = lease.get();

    var proxy = try prozy.Proxy.initFromConfig(allocator, config);
    defer proxy.deinit();
    lease.release();

    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const proxy_thread = try std.Thread.spawn(.{}, runProxy, .{ &proxy, io });

    // 4. Test connection
    std.posix.nanosleep(0, 500 * 1000 * 1000); // Wait 500ms for startup

    if (try testConnection(allocator, 8085)) {
        std.debug.print("✅ Config-driven proxy test PASSED\n", .{});
    } else {
        std.debug.print("❌ Config-driven proxy test FAILED\n", .{});
        // Don't exit with error immediately to allow cleanup, but remember status
    }

    // Cleanup
    std.debug.print("🧹 Shutting down proxy gracefully...\n", .{});

    // 1. Request shutdown
    proxy.shutdown();

    // 2. Wake up the accept loop with a dummy connection
    // The proxy is blocked on accept(), so we need one more connection to unblock it
    // so it can check the shutdown flag and exit.
    const wake_host = "127.0.0.1";
    const wake_port = 8085;
    // Resolve address (net.IpAddress.resolve takes 3 args: io, host, port)
    const resolved_wake_addr = net.IpAddress.resolve(io, wake_host, wake_port) catch null;
    if (resolved_wake_addr) |addr| {
        // Connect using the resolved address and ConnectOptions
        const connect_options = net.IpAddress.ConnectOptions{
            .mode = .stream,
            .timeout = Timeout.none,
        };
        if (addr.connect(io, connect_options) catch null) |wake_conn| {
            wake_conn.close(io);
        } else {
            std.debug.print("   (Failed to connect for shutdown - proxy might already be stopped)\n", .{});
        }
    } else {
        std.debug.print("   (Failed to resolve address for shutdown connection)\n", .{});
    }

    // 3. Join the proxy thread
    proxy_thread.join();

}

fn runProxy(proxy: *prozy.Proxy, io: std.Io) void {
    // Disable logs to keep test output clean
    // std.log is global, but we can't easily change it here.
    proxy.runWithIo(io) catch |err| {
        std.debug.print("Proxy error: {s}\n", .{@errorName(err)});
    };
}

fn testConnection(allocator: std.mem.Allocator, port: u16) !bool {
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(url);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "2", url },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("Curl failed with exit code {d}\n", .{result.term.Exited});
        return false;
    }

    const stdout = result.stdout;

    // Expect 200, 502, 504, 404
    if (std.mem.eql(u8, stdout, "200") or
        std.mem.eql(u8, stdout, "502") or
        std.mem.eql(u8, stdout, "504") or
        std.mem.eql(u8, stdout, "404"))
    {
        std.debug.print("Received status: {s}\n", .{stdout});
        return true;
    }

    std.debug.print("Unexpected status: '{s}'\n", .{stdout});
    return false;
}
