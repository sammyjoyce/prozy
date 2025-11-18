const std = @import("std");
const prozy = @import("prozy");
const Io = std.Io;
const net = Io.net;

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    _ = args.skip(); // Skip binary name

    var connections: u32 = 50;
    var duration_s: u64 = 10;
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 8080;
    var skip_setup = false;

    // Simple arg parsing
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--connections") or std.mem.eql(u8, arg, "-c")) {
            const val = args.next() orelse return error.MissingArgument;
            connections = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, arg, "--duration") or std.mem.eql(u8, arg, "-d")) {
            const val = args.next() orelse return error.MissingArgument;
            duration_s = try std.fmt.parseInt(u64, val, 10);
        } else if (std.mem.eql(u8, arg, "--host")) {
            host = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            const val = args.next() orelse return error.MissingArgument;
            port = try std.fmt.parseInt(u16, val, 10);
        } else if (std.mem.eql(u8, arg, "--skip-setup")) {
            skip_setup = true;
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            std.debug.print("Usage: benchmark [--connections N] [--duration S] [--host H] [--port P] [--skip-setup]\n", .{});
            return;
        }
    }

    var server_process: ?std.process.Child = null;
    var proxy_thread: ?std.Thread = null;

    // Use a thread-safe GPA for the proxy since it performs concurrent allocations (caching, etc.)
    // ArenaAllocator is NOT thread-safe and causes races/panics in threaded workloads.
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const proxy_alloc = gpa_state.allocator();

    // We need to keep the proxy alive
    var proxy_ptr: *prozy.Proxy = undefined;

    if (!skip_setup) {
        std.debug.print("🔧 Setting up test environment...\n", .{});

        // Check if backend port is already in use
        var backend_running = false;
        const check_addr = try net.Ip4Address.parse("127.0.0.1", 3003);
        const addr_any = net.IpAddress{ .ip4 = check_addr };

        // We need a temporary IO runtime for checking
        var temp_io = Io.Threaded.init(gpa);
        defer temp_io.deinit();

        if (addr_any.connect(temp_io.io(), .{ .mode = .stream }) catch null) |conn| {
            conn.close(temp_io.io());
            backend_running = true;
            std.debug.print("   • Backend already running on port 3003 (skipping spawn)\n", .{});
        }

        if (!backend_running) {
            // 1. Start Backend (Bun)
            std.debug.print("   • Starting Bun test server on port 3003...\n", .{});
            server_process = std.process.Child.init(&.{ "bun", "tests/test-server.ts" }, gpa);
            server_process.?.spawn() catch |err| {
                std.debug.print("   ⚠️ Failed to start bun: {s} (Assuming backend is already running or not needed)\n", .{@errorName(err)});
                server_process = null;
            };
        }

        // 2. Start Proxy
        std.debug.print("   • Starting Prozy on port {d} -> 3003...\n", .{port});
        // Use fixed backend for benchmark
        const backend_host = "127.0.0.1";
        const backend_port = 3003;

        proxy_ptr = try proxy_alloc.create(prozy.Proxy);
        proxy_ptr.* = try prozy.Proxy.init(proxy_alloc, port, backend_host, backend_port);

        // Workaround: Disable connect timeout on default route to avoid std panic on Posix
        // (std.Io.Threaded connect with timeout is not implemented yet)
        if (proxy_ptr.router.routes.len > 0) {
            proxy_ptr.router.routes[0].timeout_policy.connect_timeout_ms = 0;
        }

        // Enable features for realistic benchmark
        proxy_ptr.enableCaching(10 * 1024 * 1024); // 10MB cache
        proxy_ptr.enableRateLimiting(10000, 100000); // High limits

        const io_thread_func = struct {
            fn run(p: *prozy.Proxy) !void {
                var thread_io = Io.Threaded.init(std.heap.page_allocator); // New allocator for thread
                defer thread_io.deinit();
                try p.runWithIo(thread_io.io());
            }
        }.run;

        proxy_thread = try std.Thread.spawn(.{}, io_thread_func, .{proxy_ptr});

        // Wait for startup
        std.posix.nanosleep(1, 0);
    }

    defer {
        if (server_process) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }
        // Only detach if we haven't joined yet (proxy_thread not null)
        // We will set proxy_thread to null after joining manually
        if (proxy_thread) |thread| {
            thread.detach();
        }
    }

    std.debug.print("🚀 Starting Prozy Benchmark\n", .{});
    std.debug.print("---------------------------\n", .{});
    std.debug.print("Connections: {}\n", .{connections});
    std.debug.print("Duration:    {}s\n", .{duration_s});
    std.debug.print("Target:      {s}:{}\n\n", .{ host, port });

    var threaded_io = Io.Threaded.init(gpa);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Resolve address (Simple IP parsing)
    var ip_addr: net.IpAddress = undefined;

    if (std.mem.eql(u8, host, "localhost")) {
        ip_addr = .{ .ip4 = net.Ip4Address.loopback(port) };
    } else if (net.Ip4Address.parse(host, port) catch null) |ip4| {
        ip_addr = .{ .ip4 = ip4 };
    } else if (net.Ip6Address.parse(host, port) catch null) |ip6| {
        ip_addr = .{ .ip6 = ip6 };
    } else {
        std.debug.print("Hostname resolution not supported for '{s}'. Please use IP address.\n", .{host});
        return error.InvalidIpAddress;
    }

    // Statistics
    var total_requests: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
    var total_errors: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
    var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

    // Launch clients
    var clients = try gpa.alloc(Io.Future(void), connections);
    defer gpa.free(clients);

    const start_time = getMilliTimestamp();

    for (0..connections) |i| {
        clients[i] = try io.concurrent(clientTask, .{ io, ip_addr, &running, &total_requests, &total_errors });
    }

    // Run for duration
    std.posix.nanosleep(duration_s, 0);
    running.store(false, .monotonic);

    // Wait for clients
    for (clients) |*client| {
        client.await(io);
    }

    const end_time = getMilliTimestamp();
    const elapsed_ms = end_time - start_time;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

    const req_count = total_requests.load(.monotonic);
    const err_count = total_errors.load(.monotonic);

    const rps = @as(f64, @floatFromInt(req_count)) / elapsed_s;

    std.debug.print("\n📊 Results:\n", .{});
    std.debug.print("   Time elapsed:   {d:.2}s\n", .{elapsed_s});
    std.debug.print("   Total requests: {}\n", .{req_count});
    std.debug.print("   Total errors:   {}\n", .{err_count});
    std.debug.print("   Throughput:     {d:.2} req/s\n", .{rps});
    if (req_count > 0) {
        std.debug.print("   Latency (avg):  {d:.2} ms (theoretical)\n", .{(elapsed_s * 1000.0 * @as(f64, @floatFromInt(connections))) / @as(f64, @floatFromInt(req_count))});
    }

    // CLEANUP: Stop the proxy cleanly to avoid memory leaks
    if (!skip_setup) {
        std.debug.print("\n🧹 Shutting down proxy...\n", .{});

        // 1. Request shutdown
        proxy_ptr.shutdown();

        // 2. Wake up the accept loop with a dummy connection
        // The proxy is blocked on accept(), so we need one more connection to unblock it
        // so it can check the shutdown flag and exit.
        if (net.Ip4Address.parse("127.0.0.1", port) catch null) |wake_addr4| {
            const wake_addr = net.IpAddress{ .ip4 = wake_addr4 };
            if (wake_addr.connect(io, .{ .mode = .stream }) catch null) |wake_conn| {
                wake_conn.close(io);
            } else {
                std.debug.print("   (Failed to connect for shutdown - proxy might already be stopped)\n", .{});
            }
        }

        // 3. Join the proxy thread
        if (proxy_thread) |thread| {
            thread.join();
            proxy_thread = null; // Prevent defer from detaching
        }

        // 4. Deinitialize proxy resources
        proxy_ptr.deinit();
        proxy_alloc.destroy(proxy_ptr);

        std.debug.print("✨ Shutdown complete\n", .{});
    }
}

fn clientTask(io: Io, addr: net.IpAddress, running: *std.atomic.Value(bool), requests: *std.atomic.Value(usize), errors: *std.atomic.Value(usize)) void {
    // Use / (simple text response)
    const request = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var buf: [4096]u8 = undefined;

    while (running.load(.monotonic)) {
        doRequest(io, addr, request, &buf) catch {
            _ = errors.fetchAdd(1, .monotonic);
            // Don't tight loop on error
            // std.time.sleep(1 * std.time.ms_per_s);
            // Can't sleep in async easily without io.sleep, but we are in a task
            // But we don't have access to sleep here unless we use io.concurrent(sleep)
            continue;
        };
        _ = requests.fetchAdd(1, .monotonic);
    }
}

fn doRequest(io: Io, addr: net.IpAddress, request: []const u8, buf: []u8) !void {
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    // Write request
    var write_buf: [4096]u8 = undefined;
    var w = stream.writer(io, &write_buf);
    try Io.Writer.writeAll(&w.interface, request);
    try Io.Writer.flush(&w.interface);

    // Read response (just drain it)
    var read_buf: [4096]u8 = undefined;
    var r = stream.reader(io, &read_buf);

    while (true) {
        var slices = [_][]u8{buf};
        const n = r.interface.readVec(&slices) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
    }
}

fn getMilliTimestamp() i64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divFloor(ts.nsec, 1000000);
}
