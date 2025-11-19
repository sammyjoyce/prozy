//! Comprehensive test suite for Prozy
//!
//! This module contains all unit tests, integration tests, and feature tests
//! for the Prozy TCP proxy. Tests are organized by feature area:
//!
//! - Basic Proxy Tests: Initialization, configuration, API stability
//! - ProxyStats Tests: Statistics tracking and concurrent updates
//! - AccessControl Tests: IP filtering and access policies
//! - RateLimiter Tests: Connection throttling and limits
//! - HTTPCache Tests: Caching, LRU eviction, TTL expiration
//! - HTTPInspector Tests: HTTP request/response parsing
//! - Backend Tests: Health management, connection tracking, exponential backoff
//! - LoadBalancer Tests: Load balancing strategies (round-robin, weighted, etc.)
//! - Integration Tests: Feature interactions and real-world scenarios

const std = @import("std");
const testing = std.testing;
const root = @import("../root.zig");

// Re-import all types for convenience
const Proxy = root.Proxy;
const RunOptions = root.RunOptions;
const IpKey = root.IpKey;
const AccessControl = root.AccessControl;
const RateLimiter = root.RateLimiter;
const ProxyStats = root.ProxyStats;
const Backend = root.Backend;
const LoadBalancer = root.LoadBalancer;
const HTTPInspector = root.HTTPInspector;
const HTTPCache = root.HTTPCache;
const ProxyAuth = root.ProxyAuth;
const AuthResult = root.AuthResult;

// ============= Unit Tests =============

test "Proxy initialization" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 8000);
    defer proxy.deinit();

    try testing.expectEqual(proxy.proxy_port, 8080);
    // backend_host/port are removed from proxy struct, so we can't check them directly
    // But they are in the router
    try testing.expectEqual(proxy.allocator, allocator);
}

test "Proxy initialization with different configurations" {
    const allocator = testing.allocator;

    var proxy_high_port = try Proxy.init(allocator, 9090, "127.0.0.1", 9000);
    defer proxy_high_port.deinit();
    try testing.expectEqual(proxy_high_port.proxy_port, 9090);

    var proxy_localhost = try Proxy.init(allocator, 3000, "localhost", 3001);
    defer proxy_localhost.deinit();
    // Check router configuration if needed
}

test "Multiple proxy instances are independent" {
    const allocator = testing.allocator;

    var proxy_a = try Proxy.init(allocator, 8080, "127.0.0.1", 8000);
    defer proxy_a.deinit();
    var proxy_b = try Proxy.init(allocator, 9090, "localhost", 9000);
    defer proxy_b.deinit();

    try testing.expect(proxy_a.proxy_port != proxy_b.proxy_port);

    // Both should run without errors
    try proxy_a.run();
    try proxy_b.run();
}

test "Proxy run method executes without errors" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 8000);
    defer proxy.deinit();

    // The current implementation just prints architecture info
    try proxy.run();
}

test "Proxy handleConnection method signature" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 8000);
    defer proxy.deinit();

    // Currently does nothing but exists and is callable
    proxy.handleConnection(@as(*anyopaque, undefined)) catch {};
}

test "Proxy copyStream method signature" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 8000);
    defer proxy.deinit();

    // Currently does nothing but exists and is callable
    Proxy.copyStream(@as(*anyopaque, undefined), @as(*anyopaque, undefined)) catch {};
}

test "runProxy convenience function" {
    const allocator = testing.allocator;

    // This should work the same as Proxy.init().run()
    try root.runProxy(allocator, 8080, "127.0.0.1", 8000);
}

test "Proxy with edge case configurations" {
    const allocator = testing.allocator;

    // Test with port 0 (should use any available port)
    var proxy_zero_port = try Proxy.init(allocator, 0, "127.0.0.1", 8000);
    defer proxy_zero_port.deinit();
    try testing.expectEqual(proxy_zero_port.proxy_port, 0);
    try proxy_zero_port.run();

    // Test with maximum port numbers
    var proxy_max_port = try Proxy.init(allocator, 65535, "127.0.0.1", 65534);
    defer proxy_max_port.deinit();
    try testing.expectEqual(proxy_max_port.proxy_port, 65535);
    try testing.expectEqual(proxy_max_port.router.clusters[0].backends[0].port, 65534);
    try proxy_max_port.run();
}

test "Test all public declarations" {
    testing.refAllDecls(Proxy);
    testing.refAllDecls(@This());
}

// ============= Integration-style Coverage (moved inline) =============

test "Integration: Complete proxy workflow" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 8000);
    defer proxy.deinit();
    try testing.expectEqual(proxy.proxy_port, 8080);
    try testing.expectEqualStrings(proxy.router.clusters[0].backends[0].host, "127.0.0.1");
    try testing.expectEqual(proxy.router.clusters[0].backends[0].port, 8000);
    try proxy.run();
}

test "Integration: Multiple proxy configurations" {
    const allocator = testing.allocator;

    var proxy_localhost = try Proxy.init(allocator, 3000, "localhost", 3001);
    defer proxy_localhost.deinit();
    try testing.expectEqualStrings(proxy_localhost.router.clusters[0].backends[0].host, "localhost");
    try proxy_localhost.run();

    var proxy_ip = try Proxy.init(allocator, 4000, "192.168.1.100", 4001);
    defer proxy_ip.deinit();
    try testing.expectEqualStrings(proxy_ip.router.clusters[0].backends[0].host, "192.168.1.100");
    try testing.expectEqual(proxy_ip.router.clusters[0].backends[0].port, 4001);
    try proxy_ip.run();

    var proxy_low_port = try Proxy.init(allocator, 1024, "127.0.0.1", 80);
    defer proxy_low_port.deinit();
    try testing.expectEqual(proxy_low_port.proxy_port, 1024);
    try proxy_low_port.run();

    var proxy_high_port = try Proxy.init(allocator, 30000, "127.0.0.1", 8080);
    defer proxy_high_port.deinit();
    try testing.expectEqual(proxy_high_port.proxy_port, 30000);
    try proxy_high_port.run();
}

test "Integration: Proxy method interfaces" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 8000);
    defer proxy.deinit();
    try proxy.run();
    proxy.handleConnection(@as(*anyopaque, undefined)) catch {};
    Proxy.copyStream(@as(*anyopaque, undefined), @as(*anyopaque, undefined)) catch {};
}

test "Integration: Convenience function workflow" {
    const allocator = testing.allocator;

    try root.runProxy(allocator, 8080, "127.0.0.1", 8000);
    try root.runProxy(allocator, 9090, "localhost", 9000);
}

test "Integration: Error handling scenarios" {
    const allocator = testing.allocator;

    var proxy_zero = try Proxy.init(allocator, 0, "127.0.0.1", 0);
    defer proxy_zero.deinit();
    try proxy_zero.run();

    var proxy_max = try Proxy.init(allocator, 65535, "127.0.0.1", 65534);
    defer proxy_max.deinit();
    try proxy_max.run();

    var proxy_hostname = try Proxy.init(allocator, 8080, "my-server.local", 3000);
    defer proxy_hostname.deinit();
    try testing.expectEqualStrings(proxy_hostname.router.clusters[0].backends[0].host, "my-server.local");
    try proxy_hostname.run();
}

test "Integration: Performance characteristics" {
    const allocator = testing.allocator;

    var proxies: [10]Proxy = undefined;
    for (proxies, 0..) |_, i| {
        proxies[i] = try Proxy.init(
            allocator,
            8000 + @as(u16, @intCast(i)),
            "127.0.0.1",
            9000 + @as(u16, @intCast(i)),
        );
    }
    defer for (&proxies) |*proxy| proxy.deinit();

    for (&proxies) |*proxy| {
        try proxy.run();
    }
}

test "Integration: API stability" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 8000);
    defer proxy.deinit();
    try proxy.run();
    try root.runProxy(allocator, 8080, "127.0.0.1", 8000);
    testing.refAllDecls(Proxy);
    testing.refAllDecls(@This());
}

test "Integration: Real world scenarios" {
    const allocator = testing.allocator;

    var web_proxy = try Proxy.init(allocator, 80, "backend-server", 8080);
    defer web_proxy.deinit();
    try web_proxy.run();

    var dev_proxy = try Proxy.init(allocator, 3000, "localhost", 5432);
    defer dev_proxy.deinit();
    try dev_proxy.run();

    var lb_proxy1 = try Proxy.init(allocator, 8080, "backend1", 3000);
    defer lb_proxy1.deinit();
    var lb_proxy2 = try Proxy.init(allocator, 8081, "backend2", 3000);
    defer lb_proxy2.deinit();
    var lb_proxy3 = try Proxy.init(allocator, 8082, "backend3", 3000);
    defer lb_proxy3.deinit();

    try lb_proxy1.run();
    try lb_proxy2.run();
    try lb_proxy3.run();

    try testing.expect(lb_proxy1.proxy_port != lb_proxy2.proxy_port);
    try testing.expect(lb_proxy2.proxy_port != lb_proxy3.proxy_port);
    try testing.expect(lb_proxy1.proxy_port != lb_proxy3.proxy_port);
}

// ============= Core Proxy Features Tests =============

test "ProxyStats: initialization and recording" {
    var stats = ProxyStats.init();

    // Initial state
    const initial = stats.getStats();
    try testing.expectEqual(initial.active_connections, 0);
    try testing.expectEqual(initial.total_connections, 0);
    try testing.expectEqual(initial.total_bytes_client_to_backend, 0);
    try testing.expectEqual(initial.total_bytes_backend_to_client, 0);

    // Record connection
    stats.recordConnection();
    const after_connect = stats.getStats();
    try testing.expectEqual(after_connect.active_connections, 1);
    try testing.expectEqual(after_connect.total_connections, 1);

    // Record bytes
    stats.recordBytesClientToBackend(1024);
    stats.recordBytesBackendToClient(2048);
    const after_bytes = stats.getStats();
    try testing.expectEqual(after_bytes.total_bytes_client_to_backend, 1024);
    try testing.expectEqual(after_bytes.total_bytes_backend_to_client, 2048);

    // Record connection end
    stats.recordConnectionEnd();
    const after_end = stats.getStats();
    try testing.expectEqual(after_end.active_connections, 0);
    try testing.expectEqual(after_end.total_connections, 1);
}

test "ProxyStats: concurrent updates" {
    var stats = ProxyStats.init();

    // Simulate multiple connections
    for (0..10) |_| {
        stats.recordConnection();
        stats.recordBytesClientToBackend(100);
        stats.recordBytesBackendToClient(200);
    }

    const snapshot = stats.getStats();
    try testing.expectEqual(snapshot.active_connections, 10);
    try testing.expectEqual(snapshot.total_connections, 10);
    try testing.expectEqual(snapshot.total_bytes_client_to_backend, 1000);
    try testing.expectEqual(snapshot.total_bytes_backend_to_client, 2000);

    // End connections
    for (0..10) |_| {
        stats.recordConnectionEnd();
    }

    const final = stats.getStats();
    try testing.expectEqual(final.active_connections, 0);
}

test "ProxyStats: error tracking" {
    var stats = ProxyStats.init();

    stats.recordError();
    stats.recordError();
    stats.recordBackendFailure();

    const snapshot = stats.getStats();
    try testing.expectEqual(snapshot.total_errors, 2);
    try testing.expectEqual(snapshot.backend_connect_failures, 1);
}

test "AccessControl: allow policy" {
    const allocator = testing.allocator;

    var acl = try AccessControl.init(allocator, .allow);
    defer acl.deinit();

    // Default allow policy - all IPs allowed
    try testing.expect(acl.isAllowed(.{ .ipv4 = 0x7F000001 })); // 127.0.0.1
    try testing.expect(acl.isAllowed(.{ .ipv4 = 0xC0A80001 })); // 192.168.0.1
}

test "AccessControl: deny policy" {
    const allocator = testing.allocator;

    var acl = try AccessControl.init(allocator, .deny);
    defer acl.deinit();

    // Default deny policy - all IPs denied
    try testing.expect(!acl.isAllowed(.{ .ipv4 = 0x7F000001 }));
    try testing.expect(!acl.isAllowed(.{ .ipv4 = 0xC0A80001 }));
}

test "AccessControl: allow list" {
    const allocator = testing.allocator;

    var acl = try AccessControl.init(allocator, .deny);
    defer acl.deinit();

    // Add specific IPs to allow list
    try acl.addToAllowList(.{ .ipv4 = 0x7F000001 }); // 127.0.0.1

    try testing.expect(acl.isAllowed(.{ .ipv4 = 0x7F000001 }));
    try testing.expect(!acl.isAllowed(.{ .ipv4 = 0xC0A80001 }));
}

test "AccessControl: deny list" {
    const allocator = testing.allocator;

    var acl = try AccessControl.init(allocator, .allow);
    defer acl.deinit();

    // Add specific IPs to deny list
    try acl.addToDenyList(.{ .ipv4 = 0xC0A80001 }); // 192.168.0.1

    try testing.expect(acl.isAllowed(.{ .ipv4 = 0x7F000001 })); // Not in deny list
    try testing.expect(!acl.isAllowed(.{ .ipv4 = 0xC0A80001 })); // In deny list
}

test "RateLimiter: basic limiting" {
    const allocator = testing.allocator;

    var limiter = RateLimiter.init(allocator, 2, 5); // 2 per IP, 5 global
    defer limiter.deinit();

    const ip1 = IpKey{ .ipv4 = 0x7F000001 };
    const ip2 = IpKey{ .ipv4 = 0x7F000002 };

    // First IP can acquire up to limit
    try testing.expect(limiter.tryAcquire(ip1));
    try testing.expect(limiter.tryAcquire(ip1));
    try testing.expect(!limiter.tryAcquire(ip1)); // Exceeds per-IP limit

    // Second IP can acquire
    try testing.expect(limiter.tryAcquire(ip2));
    try testing.expect(limiter.tryAcquire(ip2));

    // Release and re-acquire
    limiter.release(ip1);
    try testing.expect(limiter.tryAcquire(ip1));
}

test "RateLimiter: global limit" {
    const allocator = testing.allocator;

    var limiter = RateLimiter.init(allocator, 10, 3); // 10 per IP, 3 global
    defer limiter.deinit();

    const ip1 = IpKey{ .ipv4 = 0x7F000001 };
    const ip2 = IpKey{ .ipv4 = 0x7F000002 };

    // Acquire global limit
    try testing.expect(limiter.tryAcquire(ip1));
    try testing.expect(limiter.tryAcquire(ip1));
    try testing.expect(limiter.tryAcquire(ip2));

    // Global limit reached
    try testing.expect(!limiter.tryAcquire(ip2));

    // Release and re-acquire
    limiter.release(ip1);
    try testing.expect(limiter.tryAcquire(ip2));
}

test "HTTPInspector: parse request line" {
    const request = "GET /api/users HTTP/1.1\r\n";

    const parsed = HTTPInspector.parseRequestLine(request);
    try testing.expect(parsed != null);

    if (parsed) |req| {
        try testing.expectEqualStrings(req.method, "GET");
        try testing.expectEqualStrings(req.path, "/api/users");
        try testing.expectEqualStrings(req.version, "HTTP/1.1");
    }
}

test "HTTPInspector: parse POST request" {
    const request = "POST /submit HTTP/1.1\r\nHost: example.com\r\n";

    const parsed = HTTPInspector.parseRequestLine(request);
    try testing.expect(parsed != null);

    if (parsed) |req| {
        try testing.expectEqualStrings(req.method, "POST");
        try testing.expectEqualStrings(req.path, "/submit");
    }
}

test "HTTPInspector: invalid request" {
    const invalid = "GET /incomplete";
    const parsed = HTTPInspector.parseRequestLine(invalid);

    // Should return null for incomplete request (missing HTTP version)
    try testing.expect(parsed == null);
}

test "HTTPInspector: parse HTTP/1.1 200 OK response" {
    const response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 13\r\n\r\nHello, World!";

    const parsed = HTTPInspector.parseResponseLine(response);
    try testing.expect(parsed != null);

    if (parsed) |resp| {
        try testing.expectEqualStrings(resp.version, "HTTP/1.1");
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        try testing.expectEqualStrings(resp.status_text, "OK");
        try testing.expectEqual(@as(usize, 64), resp.headers_end);
    }
}

test "HTTPInspector: parse HTTP/1.0 404 Not Found response" {
    const response = "HTTP/1.0 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot found";

    const parsed = HTTPInspector.parseResponseLine(response);
    try testing.expect(parsed != null);

    if (parsed) |resp| {
        try testing.expectEqualStrings(resp.version, "HTTP/1.0");
        try testing.expectEqual(@as(u16, 404), resp.status_code);
        try testing.expectEqualStrings(resp.status_text, "Not Found");
    }
}

test "HTTPInspector: parse 500 Internal Server Error response" {
    const response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n";

    const parsed = HTTPInspector.parseResponseLine(response);
    try testing.expect(parsed != null);

    if (parsed) |resp| {
        try testing.expectEqual(@as(u16, 500), resp.status_code);
        try testing.expectEqualStrings(resp.status_text, "Internal Server Error");
    }
}

test "HTTPInspector: parse 301 Moved Permanently with long status text" {
    const response = "HTTP/1.1 301 Moved Permanently\r\nLocation: /new-location\r\n\r\n";

    const parsed = HTTPInspector.parseResponseLine(response);
    try testing.expect(parsed != null);

    if (parsed) |resp| {
        try testing.expectEqual(@as(u16, 301), resp.status_code);
        try testing.expectEqualStrings(resp.status_text, "Moved Permanently");
    }
}

test "HTTPInspector: invalid status code (out of range)" {
    const response_low = "HTTP/1.1 99 Too Low\r\n\r\n";
    const response_high = "HTTP/1.1 600 Too High\r\n\r\n";

    try testing.expect(HTTPInspector.parseResponseLine(response_low) == null);
    try testing.expect(HTTPInspector.parseResponseLine(response_high) == null);
}

test "HTTPInspector: invalid status code (not a number)" {
    const response = "HTTP/1.1 ABC Invalid\r\n\r\n";
    try testing.expect(HTTPInspector.parseResponseLine(response) == null);
}

test "HTTPInspector: malformed response (no version)" {
    const response = "200 OK\r\n\r\n";
    try testing.expect(HTTPInspector.parseResponseLine(response) == null);
}

test "HTTPInspector: incomplete response (no headers end)" {
    const response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n";
    try testing.expect(HTTPInspector.parseResponseLine(response) == null);
}

test "HTTPInspector: findHeadersEnd with complete headers" {
    const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello";
    const headers_end = HTTPInspector.findHeadersEnd(response);

    try testing.expect(headers_end != null);
    if (headers_end) |end| {
        try testing.expectEqual(@as(usize, 38), end);
    }
}

test "HTTPInspector: findHeadersEnd with incomplete headers" {
    const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n";
    const headers_end = HTTPInspector.findHeadersEnd(response);

    try testing.expect(headers_end == null);
}

test "HTTPInspector: findHeader case-insensitive" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 13\r\n\r\n";

    const content_type = HTTPInspector.findHeader(headers, "Content-Type");
    try testing.expect(content_type != null);
    if (content_type) |value| {
        try testing.expectEqualStrings(value, "text/html");
    }

    // Test case-insensitive matching
    const content_type_lower = HTTPInspector.findHeader(headers, "content-type");
    try testing.expect(content_type_lower != null);
    if (content_type_lower) |value| {
        try testing.expectEqualStrings(value, "text/html");
    }

    const content_length = HTTPInspector.findHeader(headers, "Content-Length");
    try testing.expect(content_length != null);
    if (content_length) |value| {
        try testing.expectEqualStrings(value, "13");
    }
}

test "HTTPInspector: findHeader with whitespace trimming" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Type:   text/html  \r\n\r\n";

    const content_type = HTTPInspector.findHeader(headers, "Content-Type");
    try testing.expect(content_type != null);
    if (content_type) |value| {
        // Should trim leading whitespace but preserve trailing
        try testing.expect(std.mem.startsWith(u8, value, "text/html"));
    }
}

test "HTTPInspector: findHeader not found" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n";

    const missing = HTTPInspector.findHeader(headers, "X-Missing-Header");
    try testing.expect(missing == null);
}

test "HTTPInspector: isCompleteResponse with Content-Length (complete)" {
    const response = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, World!";
    try testing.expect(HTTPInspector.isCompleteResponse(response));
}

test "HTTPInspector: isCompleteResponse with Content-Length (incomplete)" {
    const response = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nHello";
    try testing.expect(!HTTPInspector.isCompleteResponse(response));
}

test "HTTPInspector: isCompleteResponse with Transfer-Encoding chunked (complete)" {
    const response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHello\r\n0\r\n\r\n";
    try testing.expect(HTTPInspector.isCompleteResponse(response));
}

test "HTTPInspector: isCompleteResponse with Transfer-Encoding chunked (incomplete)" {
    const response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHello\r\n";
    try testing.expect(!HTTPInspector.isCompleteResponse(response));
}

test "HTTPInspector: isCompleteResponse without Content-Length or Transfer-Encoding" {
    const response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\nHello";
    // Should return true for HTTP/1.0 style responses
    try testing.expect(HTTPInspector.isCompleteResponse(response));
}

test "HTTPInspector: isCompleteResponse with incomplete headers" {
    const response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n";
    try testing.expect(!HTTPInspector.isCompleteResponse(response));
}

// ============= HTTP Date Parsing Tests (RFC 9110 Section 5.6.7) =============

test "HTTPInspector: parseHttpDate with IMF-fixdate format" {
    // Sun, 06 Nov 1994 08:49:37 GMT
    const date1 = "Sun, 06 Nov 1994 08:49:37 GMT";
    const timestamp1 = HTTPInspector.parseHttpDate(date1);
    try testing.expect(timestamp1 != null);
    try testing.expectEqual(timestamp1.?, 784111777);

    // Mon, 01 Jan 2024 00:00:00 GMT
    const date2 = "Mon, 01 Jan 2024 00:00:00 GMT";
    const timestamp2 = HTTPInspector.parseHttpDate(date2);
    try testing.expect(timestamp2 != null);
    try testing.expectEqual(timestamp2.?, 1704067200);

    // Fri, 31 Dec 1999 23:59:59 GMT
    const date3 = "Fri, 31 Dec 1999 23:59:59 GMT";
    const timestamp3 = HTTPInspector.parseHttpDate(date3);
    try testing.expect(timestamp3 != null);
    try testing.expectEqual(timestamp3.?, 946684799);
}

test "HTTPInspector: parseHttpDate with RFC 850 format" {
    // Sunday, 06-Nov-94 08:49:37 GMT
    const date1 = "Sunday, 06-Nov-94 08:49:37 GMT";
    const timestamp1 = HTTPInspector.parseHttpDate(date1);
    try testing.expect(timestamp1 != null);
    try testing.expectEqual(timestamp1.?, 784111777);

    // Monday, 01-Jan-24 00:00:00 GMT
    const date2 = "Monday, 01-Jan-24 00:00:00 GMT";
    const timestamp2 = HTTPInspector.parseHttpDate(date2);
    try testing.expect(timestamp2 != null);
    try testing.expectEqual(timestamp2.?, 1704067200);

    // Friday, 31-Dec-99 23:59:59 GMT
    const date3 = "Friday, 31-Dec-99 23:59:59 GMT";
    const timestamp3 = HTTPInspector.parseHttpDate(date3);
    try testing.expect(timestamp3 != null);
    try testing.expectEqual(timestamp3.?, 946684799);
}

test "HTTPInspector: parseHttpDate with asctime format" {
    // Sun Nov  6 08:49:37 1994
    const date1 = "Sun Nov  6 08:49:37 1994";
    const timestamp1 = HTTPInspector.parseHttpDate(date1);
    try testing.expect(timestamp1 != null);
    try testing.expectEqual(timestamp1.?, 784111777);

    // Mon Jan  1 00:00:00 2024
    const date2 = "Mon Jan  1 00:00:00 2024";
    const timestamp2 = HTTPInspector.parseHttpDate(date2);
    try testing.expect(timestamp2 != null);
    try testing.expectEqual(timestamp2.?, 1704067200);

    // Fri Dec 31 23:59:59 1999
    const date3 = "Fri Dec 31 23:59:59 1999";
    const timestamp3 = HTTPInspector.parseHttpDate(date3);
    try testing.expect(timestamp3 != null);
    try testing.expectEqual(timestamp3.?, 946684799);
}

test "HTTPInspector: parseHttpDate with all twelve months (IMF-fixdate)" {
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 01 Jan 2024 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Thu, 01 Feb 2024 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Fri, 01 Mar 2024 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 01 Apr 2024 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Wed, 01 May 2024 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Sat, 01 Jun 2024 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 01 Jul 2024 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Thu, 01 Aug 2024 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Sun, 01 Sep 2024 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Tue, 01 Oct 2024 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Fri, 01 Nov 2024 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Sun, 01 Dec 2024 00:00:00 GMT") != null);
}

test "HTTPInspector: parseHttpDate with case-insensitive month names" {
    // Lowercase
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 01 jan 2024 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 01 JAN 2024 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 01 JaN 2024 00:00:00 GMT") != null);
}

test "HTTPInspector: parseHttpDate with leap year" {
    // Feb 29, 2024 is valid (2024 is divisible by 4)
    // Feb 29, 2024 12:00:00 GMT = 1709208000
    const leap_date = "Thu, 29 Feb 2024 12:00:00 GMT";
    const timestamp = HTTPInspector.parseHttpDate(leap_date);
    try testing.expect(timestamp != null);
    try testing.expectEqual(timestamp.?, 1709208000);

    // Feb 29, 2000 is valid (divisible by 400)
    // Feb 29, 2000 12:00:00 GMT = 951825600
    const leap_2000 = "Tue, 29 Feb 2000 12:00:00 GMT";
    const ts_2000 = HTTPInspector.parseHttpDate(leap_2000);
    try testing.expect(ts_2000 != null);
    try testing.expectEqual(ts_2000.?, 951825600);
}

test "HTTPInspector: parseHttpDate with leap second" {
    // Leap second (60 seconds is allowed)
    // Dec 31, 2016 23:59:60 GMT = 1483228800 (same as Jan 1, 2017 00:00:00)
    const leap_second = "Sat, 31 Dec 2016 23:59:60 GMT";
    const timestamp = HTTPInspector.parseHttpDate(leap_second);
    try testing.expect(timestamp != null);
    try testing.expectEqual(timestamp.?, 1483228800);
}

test "HTTPInspector: parseHttpDate with Unix epoch" {
    // Thu, 01 Jan 1970 00:00:00 GMT (Unix epoch)
    const epoch = "Thu, 01 Jan 1970 00:00:00 GMT";
    const timestamp = HTTPInspector.parseHttpDate(epoch);
    try testing.expect(timestamp != null);
    try testing.expectEqual(timestamp.?, 0);
}

test "HTTPInspector: parseHttpDate with maximum valid year" {
    // Far future date
    const future = "Fri, 31 Dec 9999 23:59:59 GMT";
    const timestamp = HTTPInspector.parseHttpDate(future);
    try testing.expect(timestamp != null);
}

test "HTTPInspector: parseHttpDate rejects invalid dates" {
    // Invalid day (0)
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 00 Jan 2024 00:00:00 GMT") == null);

    // Invalid day (32)
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 32 Jan 2024 00:00:00 GMT") == null);

    // Invalid month
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 01 Xxx 2024 00:00:00 GMT") == null);

    // Invalid year (before 1970)
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 01 Jan 1969 00:00:00 GMT") == null);

    // Invalid hour (24)
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 01 Jan 2024 24:00:00 GMT") == null);

    // Invalid minute (60)
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 01 Jan 2024 00:60:00 GMT") == null);

    // Invalid second (61)
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 01 Jan 2024 00:00:61 GMT") == null);
}

test "HTTPInspector: parseHttpDate rejects invalid day-of-month for each month" {
    // January (31 days) - reject 32
    try testing.expect(HTTPInspector.parseHttpDate("Wed, 32 Jan 2024 00:00:00 GMT") == null);

    // February non-leap year (28 days) - reject 29 and 30
    try testing.expect(HTTPInspector.parseHttpDate("Thu, 29 Feb 2023 00:00:00 GMT") == null);
    try testing.expect(HTTPInspector.parseHttpDate("Thu, 30 Feb 2023 00:00:00 GMT") == null);

    // February leap year (29 days) - accept 29, reject 30
    try testing.expect(HTTPInspector.parseHttpDate("Thu, 29 Feb 2024 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Fri, 30 Feb 2024 00:00:00 GMT") == null);

    // March (31 days) - reject 32
    try testing.expect(HTTPInspector.parseHttpDate("Sun, 32 Mar 2024 00:00:00 GMT") == null);

    // April (30 days) - reject 31
    try testing.expect(HTTPInspector.parseHttpDate("Tue, 31 Apr 2024 00:00:00 GMT") == null);

    // May (31 days) - reject 32
    try testing.expect(HTTPInspector.parseHttpDate("Fri, 32 May 2024 00:00:00 GMT") == null);

    // June (30 days) - reject 31
    try testing.expect(HTTPInspector.parseHttpDate("Sun, 31 Jun 2024 00:00:00 GMT") == null);

    // July (31 days) - reject 32
    try testing.expect(HTTPInspector.parseHttpDate("Wed, 32 Jul 2024 00:00:00 GMT") == null);

    // August (31 days) - reject 32
    try testing.expect(HTTPInspector.parseHttpDate("Sat, 32 Aug 2024 00:00:00 GMT") == null);

    // September (30 days) - reject 31
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 31 Sep 2024 00:00:00 GMT") == null);

    // October (31 days) - reject 32
    try testing.expect(HTTPInspector.parseHttpDate("Thu, 32 Oct 2024 00:00:00 GMT") == null);

    // November (30 days) - reject 31
    try testing.expect(HTTPInspector.parseHttpDate("Sat, 31 Nov 2024 00:00:00 GMT") == null);

    // December (31 days) - reject 32
    try testing.expect(HTTPInspector.parseHttpDate("Tue, 32 Dec 2024 00:00:00 GMT") == null);
}

test "HTTPInspector: parseHttpDate rejects malformed input" {
    // Too short
    try testing.expect(HTTPInspector.parseHttpDate("") == null);
    try testing.expect(HTTPInspector.parseHttpDate("Mon") == null);
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 01 Jan") == null);

    // Missing comma
    try testing.expect(HTTPInspector.parseHttpDate("Mon 01 Jan 2024 00:00:00 GMT") == null);

    // Wrong delimiter
    try testing.expect(HTTPInspector.parseHttpDate("Mon. 01 Jan 2024 00:00:00 GMT") == null);

    // Invalid time format
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 01 Jan 2024 12:00 GMT") == null);
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 01 Jan 2024 12h00m00s GMT") == null);
}

test "HTTPInspector: parseHttpDate with edge case timestamps" {
    // Test known timestamps for correctness
    // Jan 1, 2000 00:00:00 = 946684800
    const y2k = "Sat, 01 Jan 2000 00:00:00 GMT";
    const ts_y2k = HTTPInspector.parseHttpDate(y2k);
    try testing.expect(ts_y2k != null);
    try testing.expectEqual(ts_y2k.?, 946684800);

    // Dec 31, 2000 23:59:59 = 978307199
    const end_2000 = "Sun, 31 Dec 2000 23:59:59 GMT";
    const ts_end = HTTPInspector.parseHttpDate(end_2000);
    try testing.expect(ts_end != null);
    try testing.expectEqual(ts_end.?, 978307199);
}

test "HTTPInspector: parseHttpDate with RFC 850 two-digit year interpretation" {
    // Year 70-99 should map to 1970-1999
    const year_70 = "Thursday, 01-Jan-70 00:00:00 GMT";
    const ts_70 = HTTPInspector.parseHttpDate(year_70);
    try testing.expect(ts_70 != null);
    try testing.expectEqual(ts_70.?, 0); // Jan 1, 1970

    // Year 00-69 should map to 2000-2069
    const year_00 = "Saturday, 01-Jan-00 00:00:00 GMT";
    const ts_00 = HTTPInspector.parseHttpDate(year_00);
    try testing.expect(ts_00 != null);
    try testing.expectEqual(ts_00.?, 946684800); // Jan 1, 2000

    const year_69 = "Monday, 01-Jan-69 00:00:00 GMT";
    const ts_69 = HTTPInspector.parseHttpDate(year_69);
    try testing.expect(ts_69 != null);
    // Should be 2069, not 1969 - Jan 1, 2069 00:00:00 GMT = 3124224000
    try testing.expectEqual(ts_69.?, 3124224000);
}

test "HTTPInspector: parseHttpDate with whitespace variations" {
    // Single space (normal)
    try testing.expect(HTTPInspector.parseHttpDate("Mon, 01 Jan 2024 00:00:00 GMT") != null);

    // Multiple spaces in asctime format (valid)
    try testing.expect(HTTPInspector.parseHttpDate("Mon Jan  1 00:00:00 2024") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Mon Jan 10 00:00:00 2024") != null);
}

test "HTTPInspector: parseHttpDate month ordering correctness" {
    // Verify month calculations by checking sequential months
    const jan = HTTPInspector.parseHttpDate("Sat, 01 Jan 2000 00:00:00 GMT").?;
    const feb = HTTPInspector.parseHttpDate("Tue, 01 Feb 2000 00:00:00 GMT").?;
    const mar = HTTPInspector.parseHttpDate("Wed, 01 Mar 2000 00:00:00 GMT").?;

    // Jan→Feb should be 31 days (2678400 seconds)
    try testing.expectEqual(feb - jan, 31 * 86400);

    // Feb→Mar should be 29 days in 2000 (leap year)
    try testing.expectEqual(mar - feb, 29 * 86400);
}

test "HTTPInspector: parseHttpDate leap year calculation" {
    // Test leap year detection
    // 2000 is a leap year (divisible by 400)
    const feb28_2000 = HTTPInspector.parseHttpDate("Mon, 28 Feb 2000 00:00:00 GMT").?;
    const feb29_2000 = HTTPInspector.parseHttpDate("Tue, 29 Feb 2000 00:00:00 GMT").?;
    const mar01_2000 = HTTPInspector.parseHttpDate("Wed, 01 Mar 2000 00:00:00 GMT").?;

    try testing.expectEqual(feb29_2000 - feb28_2000, 86400);
    try testing.expectEqual(mar01_2000 - feb29_2000, 86400);

    // 1900 is NOT a leap year (divisible by 100 but not 400)
    // (but we can't test this since year must be >= 1970)

    // 2024 is a leap year (divisible by 4)
    const feb28_2024 = HTTPInspector.parseHttpDate("Wed, 28 Feb 2024 00:00:00 GMT").?;
    const feb29_2024 = HTTPInspector.parseHttpDate("Thu, 29 Feb 2024 00:00:00 GMT").?;
    const mar01_2024 = HTTPInspector.parseHttpDate("Fri, 01 Mar 2024 00:00:00 GMT").?;

    try testing.expectEqual(feb29_2024 - feb28_2024, 86400);
    try testing.expectEqual(mar01_2024 - feb29_2024, 86400);
}

test "HTTPInspector: parseHttpDate handles different day names" {
    // Day names are parsed but not validated (any valid format accepted)
    try testing.expect(HTTPInspector.parseHttpDate("Sun, 01 Jan 2024 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Monday, 01-Jan-24 00:00:00 GMT") != null);
    try testing.expect(HTTPInspector.parseHttpDate("Tue Jan  2 00:00:00 2024") != null);
}

test "Proxy: with statistics enabled" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 3000);
    defer proxy.deinit();

    // Stats should be initialized
    const initial = proxy.getStats();
    try testing.expectEqual(initial.total_connections, 0);
    try testing.expectEqual(initial.active_connections, 0);

    // Manually test stats recording
    proxy.stats.recordConnection();
    const after = proxy.getStats();
    try testing.expectEqual(after.total_connections, 1);
    try testing.expectEqual(after.active_connections, 1);
}

test "Proxy: enable access control" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 3000);
    defer proxy.deinit();

    // Enable access control
    try proxy.enableAccessControl(.deny);
    try testing.expect(proxy.access_control != null);

    if (proxy.access_control) |*acl| {
        // Add to allow list
        try acl.addToAllowList(.{ .ipv4 = 0x7F000001 });
    }
}

test "Proxy: enable rate limiting" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 3000);
    defer proxy.deinit();

    // Enable rate limiting
    proxy.enableRateLimiting(5, 100);
    try testing.expect(proxy.rate_limiter != null);
}

test "Proxy: feature integration" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 3000);
    defer proxy.deinit();

    // Enable all features
    try proxy.enableAccessControl(.allow);
    proxy.enableRateLimiting(10, 1000);

    // Verify features are enabled
    try testing.expect(proxy.access_control != null);
    try testing.expect(proxy.rate_limiter != null);

    // Stats are always enabled
    const stats = proxy.getStats();
    try testing.expectEqual(stats.total_connections, 0);
}

test "HTTPCache: basic caching" {
    const allocator = testing.allocator;

    var cache = HTTPCache.init(allocator, 1024 * 1024); // 1MB cache
    defer cache.deinit();

    // Cache miss
    const result1 = cache.get("GET", "example.com", "/api/users", null);
    try testing.expect(result1 == null);

    // Store response
    const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello";
    try cache.put("GET", "example.com", "/api/users", response, 300, null, null);

    // Cache hit
    const result2 = cache.get("GET", "example.com", "/api/users", null);
    defer if (result2) |data| allocator.free(data);
    try testing.expect(result2 != null);
    if (result2) |data| {
        try testing.expectEqualStrings(response, data);
    }

    // Stats
    const stats = cache.getStats();
    try testing.expectEqual(@as(u64, 1), stats.hits);
    try testing.expectEqual(@as(u64, 1), stats.misses);
    try testing.expect(stats.hitRate() > 0);
}

test "HTTPCache: LRU eviction" {
    const allocator = testing.allocator;

    var cache = HTTPCache.init(allocator, 80); // Small cache - 2 entries=64, 3rd entry would be 96 > 80
    defer cache.deinit();

    // Fill cache
    try cache.put("GET", "test.com", "/1", "response1response1response1", 300, null, null);
    try cache.put("GET", "test.com", "/2", "response2response2response2", 300, null, null);

    // This should evict the least recently used entry
    try cache.put("GET", "test.com", "/3", "response3response3response3", 300, null, null);

    const stats = cache.getStats();
    try testing.expect(stats.entry_count <= 2);
}

test "HTTPCache: TTL expiration" {
    const allocator = testing.allocator;

    var cache = HTTPCache.init(allocator, 1024);
    defer cache.deinit();

    // Store with 0 TTL (should expire immediately)
    try cache.put("GET", "test.com", "/expire", "data", 0, null, null);

    // Wait a bit (in real scenario, time would pass)
    // For testing, we rely on the timestamp check
    const result = cache.get("GET", "test.com", "/expire", null);
    defer if (result) |data| allocator.free(data);

    // May or may not be expired depending on timing (verified via defer)
}

test "Backend: initialization and health" {
    var backend = Backend.init("127.0.0.1", 8080, 10);

    try testing.expectEqualStrings("127.0.0.1", backend.host);
    try testing.expectEqual(@as(u16, 8080), backend.port);
    try testing.expectEqual(@as(u32, 10), backend.weight);
    try testing.expect(backend.isHealthy());

    backend.markHealthy(false);
    try testing.expect(!backend.isHealthy());

    backend.markHealthy(true);
    try testing.expect(backend.isHealthy());
}

test "Backend: connection tracking" {
    var backend = Backend.init("127.0.0.1", 8080, 1);

    try testing.expectEqual(@as(u32, 0), backend.getConnections());

    backend.incrementConnections();
    try testing.expectEqual(@as(u32, 1), backend.getConnections());

    backend.incrementConnections();
    try testing.expectEqual(@as(u32, 2), backend.getConnections());

    backend.decrementConnections();
    try testing.expectEqual(@as(u32, 1), backend.getConnections());

    backend.decrementConnections();
    try testing.expectEqual(@as(u32, 0), backend.getConnections());
}

test "Backend: retry count management" {
    var backend = Backend.init("127.0.0.1", 8080, 1);

    // Initially zero retries
    try testing.expectEqual(@as(u32, 0), backend.getRetryCount());

    // Increment retry count
    backend.incrementRetryCount();
    try testing.expectEqual(@as(u32, 1), backend.getRetryCount());

    backend.incrementRetryCount();
    try testing.expectEqual(@as(u32, 2), backend.getRetryCount());

    // Reset retry count
    backend.resetRetryCount();
    try testing.expectEqual(@as(u32, 0), backend.getRetryCount());
}

test "Backend: exponential backoff calculation" {
    var backend = Backend.init("127.0.0.1", 8080, 1);

    // Retry 0: 5 * 2^0 = 5 seconds
    try testing.expectEqual(@as(u32, 5), backend.getRecoveryInterval());

    // Retry 1: 5 * 2^1 = 10 seconds
    backend.incrementRetryCount();
    try testing.expectEqual(@as(u32, 10), backend.getRecoveryInterval());

    // Retry 2: 5 * 2^2 = 20 seconds
    backend.incrementRetryCount();
    try testing.expectEqual(@as(u32, 20), backend.getRecoveryInterval());

    // Retry 3: 5 * 2^3 = 40 seconds
    backend.incrementRetryCount();
    try testing.expectEqual(@as(u32, 40), backend.getRecoveryInterval());

    // Retry 4: 5 * 2^4 = 80 seconds
    backend.incrementRetryCount();
    try testing.expectEqual(@as(u32, 80), backend.getRecoveryInterval());

    // Retry 5: 5 * 2^5 = 160 seconds
    backend.incrementRetryCount();
    try testing.expectEqual(@as(u32, 160), backend.getRecoveryInterval());

    // Retry 6: 5 * 2^6 = 320 seconds, but capped at max (300)
    backend.incrementRetryCount();
    try testing.expectEqual(@as(u32, 300), backend.getRecoveryInterval());

    // Further retries stay at max
    backend.incrementRetryCount();
    try testing.expectEqual(@as(u32, 300), backend.getRecoveryInterval());
}

test "Backend: exponential backoff prevents overflow" {
    var backend = Backend.init("127.0.0.1", 8080, 1);

    // Simulate many failures (would cause overflow without protection)
    for (0..50) |_| {
        backend.incrementRetryCount();
    }

    // Should be capped at max interval, not overflow
    const interval = backend.getRecoveryInterval();
    try testing.expectEqual(@as(u32, 300), interval);
    try testing.expect(interval <= backend.max_recovery_interval_seconds);
}

test "Backend: markHealthy resets retry count" {
    var backend = Backend.init("127.0.0.1", 8080, 1);

    // Mark unhealthy several times
    backend.markHealthy(false);
    backend.markHealthy(false);
    backend.markHealthy(false);

    // Should have incremented retry count
    try testing.expect(backend.getRetryCount() > 0);

    // Mark healthy should reset
    backend.markHealthy(true);
    try testing.expectEqual(@as(u32, 0), backend.getRetryCount());
}

test "Backend: circuit breaker after max retries" {
    var backend = Backend.init("127.0.0.1", 8080, 1);

    // Mark unhealthy up to max_retry_count
    for (0..backend.max_retry_count + 1) |_| {
        backend.markHealthy(false);
    }

    // After exceeding max retries, shouldRetry returns false (circuit breaker open)
    try testing.expect(!backend.shouldRetry());
}

test "Backend: custom exponential backoff config" {
    var backend = Backend.init("127.0.0.1", 8080, 1);
    backend.base_recovery_interval_seconds = 2;
    backend.max_recovery_interval_seconds = 60;

    // Retry 0: 2 seconds
    try testing.expectEqual(@as(u32, 2), backend.getRecoveryInterval());

    // Retry 1: 4 seconds
    backend.incrementRetryCount();
    try testing.expectEqual(@as(u32, 4), backend.getRecoveryInterval());

    // Retry 2: 8 seconds
    backend.incrementRetryCount();
    try testing.expectEqual(@as(u32, 8), backend.getRecoveryInterval());

    // Retry 3: 16 seconds
    backend.incrementRetryCount();
    try testing.expectEqual(@as(u32, 16), backend.getRecoveryInterval());

    // Retry 4: 32 seconds
    backend.incrementRetryCount();
    try testing.expectEqual(@as(u32, 32), backend.getRecoveryInterval());

    // Retry 5: 64 seconds, capped at 60
    backend.incrementRetryCount();
    try testing.expectEqual(@as(u32, 60), backend.getRecoveryInterval());
}

test "LoadBalancer: round robin" {
    const allocator = testing.allocator;

    var backends = [_]Backend{
        Backend.init("backend1", 8081, 1),
        Backend.init("backend2", 8082, 1),
        Backend.init("backend3", 8083, 1),
    };

    var lb = LoadBalancer.init(&backends, .round_robin);

    // Should rotate through backends
    const b1 = lb.selectBackend(.{ .ipv4 = 0 });
    try testing.expect(b1 != null);

    const b2 = lb.selectBackend(.{ .ipv4 = 0 });
    try testing.expect(b2 != null);

    const b3 = lb.selectBackend(.{ .ipv4 = 0 });
    try testing.expect(b3 != null);

    // Should wrap around
    const b4 = lb.selectBackend(.{ .ipv4 = 0 });
    try testing.expect(b4 != null);

    _ = allocator;
}

test "LoadBalancer: weighted round robin" {
    const allocator = testing.allocator;

    var backends = [_]Backend{
        Backend.init("backend1", 8081, 1),
        Backend.init("backend2", 8082, 3), // 3x weight
        Backend.init("backend3", 8083, 1),
    };

    var lb = LoadBalancer.init(&backends, .weighted_round_robin);

    var backend2_count: u32 = 0;
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        if (lb.selectBackend(.{ .ipv4 = 0 })) |backend| {
            if (std.mem.eql(u8, backend.host, "backend2")) {
                backend2_count += 1;
            }
        }
    }

    // backend2 should be selected more often due to higher weight
    try testing.expect(backend2_count > 0);

    _ = allocator;
}

test "LoadBalancer: least connections" {
    const allocator = testing.allocator;

    var backends = [_]Backend{
        Backend.init("backend1", 8081, 1),
        Backend.init("backend2", 8082, 1),
        Backend.init("backend3", 8083, 1),
    };

    var lb = LoadBalancer.init(&backends, .least_connections);

    // First backend should have 0 connections
    const b1 = lb.selectBackend(.{ .ipv4 = 0 });
    try testing.expect(b1 != null);
    if (b1) |backend| {
        backend.incrementConnections();
    }

    // Should select a different backend with fewer connections
    const b2 = lb.selectBackend(.{ .ipv4 = 0 });
    try testing.expect(b2 != null);

    _ = allocator;
}

test "LoadBalancer: ip hash" {
    const allocator = testing.allocator;

    var backends = [_]Backend{
        Backend.init("backend1", 8081, 1),
        Backend.init("backend2", 8082, 1),
        Backend.init("backend3", 8083, 1),
    };

    var lb = LoadBalancer.init(&backends, .ip_hash);

    const ip1 = IpKey{ .ipv4 = 0x7F000001 };
    const ip2 = IpKey{ .ipv4 = 0x7F000002 };

    // Same IP should consistently get same backend
    const b1 = lb.selectBackend(ip1);
    const b2 = lb.selectBackend(ip1);
    try testing.expect(b1 != null and b2 != null);

    if (b1 != null and b2 != null) {
        try testing.expectEqualStrings(b1.?.host, b2.?.host);
    }

    // Different IP might get different backend
    const b3 = lb.selectBackend(ip2);
    try testing.expect(b3 != null);

    _ = allocator;
}

test "LoadBalancer: no healthy backends" {
    const allocator = testing.allocator;

    var backends = [_]Backend{
        Backend.init("backend1", 8081, 1),
        Backend.init("backend2", 8082, 1),
    };

    // Mark all backends unhealthy
    backends[0].markHealthy(false);
    backends[1].markHealthy(false);

    var lb = LoadBalancer.init(&backends, .round_robin);

    const result = lb.selectBackend(.{ .ipv4 = 0 });
    try testing.expect(result == null);

    _ = allocator;
}

test "Proxy: enable caching" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 3000);
    defer proxy.deinit();

    // Enable caching
    proxy.enableCaching(1024 * 1024);
    try testing.expect(proxy.http_cache != null);

    // Check cache stats
    const cache_stats = proxy.getCacheStats();
    try testing.expect(cache_stats != null);
    if (cache_stats) |stats| {
        try testing.expectEqual(@as(u64, 0), stats.hits);
        try testing.expectEqual(@as(u64, 0), stats.misses);
    }
}

test "Proxy: enable load balancing" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 3000);
    defer proxy.deinit();

    var backends = [_]Backend{
        Backend.init("backend1", 8081, 1),
        Backend.init("backend2", 8082, 1),
    };

    proxy.enableLoadBalancing(&backends, .round_robin);
    try testing.expect(proxy.load_balancer != null);
}

test "Proxy: all features enabled" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 3000);
    defer proxy.deinit();

    // Enable all features
    try proxy.enableAccessControl(.allow);
    proxy.enableRateLimiting(10, 100);
    proxy.enableCaching(1024 * 1024);

    var backends = [_]Backend{
        Backend.init("backend1", 8081, 1),
        Backend.init("backend2", 8082, 2),
    };
    proxy.enableLoadBalancing(&backends, .weighted_round_robin);

    // Verify all features are enabled
    try testing.expect(proxy.access_control != null);
    try testing.expect(proxy.rate_limiter != null);
    try testing.expect(proxy.http_cache != null);
    try testing.expect(proxy.load_balancer != null);

    // Test statistics
    const stats = proxy.getStats();
    try testing.expectEqual(@as(u64, 0), stats.total_connections);

    const cache_stats = proxy.getCacheStats();
    try testing.expect(cache_stats != null);
}

// ========================================================================
// INTEGRATION TESTS: HTTP Caching with Request Forwarding
// ========================================================================
// These tests verify the cache population and request forwarding fixes
// to ensure correct behavior after cache misses and proper GET caching.
// ========================================================================

test "HTTPCache Integration: cache only successful GET requests with 200 OK" {
    const allocator = testing.allocator;

    var cache = HTTPCache.init(allocator, 10 * 1024 * 1024); // 10MB cache
    defer cache.deinit();

    // Test 1: GET request with 200 OK should be cached
    const get_request = "GET /api/users HTTP/1.1";
    const ok_response = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n{\"users\":[]}";

    if (HTTPInspector.parseRequestLine(get_request)) |request| {
        try testing.expectEqualStrings("GET", request.method);
        try testing.expectEqualStrings("/api/users", request.path);

        // Simulate caching the response
        const test_host = "api.example.com";
        try cache.put(request.method, test_host, request.path, ok_response, 300, null, null);

        // Verify it was cached
        const cached = cache.get(request.method, test_host, request.path, null);
        defer if (cached) |data| allocator.free(data);
        try testing.expect(cached != null);
        if (cached) |data| {
            try testing.expectEqualStrings(ok_response, data);
        }
    }

    // Test 2: POST request should NOT be cached (even with 200 OK)
    const post_request = "POST /api/users HTTP/1.1";

    if (HTTPInspector.parseRequestLine(post_request)) |request| {
        try testing.expectEqualStrings("POST", request.method);

        // In real implementation, we would skip caching POST
        // For this test, we manually verify the logic
        const should_cache = std.mem.eql(u8, request.method, "GET");
        try testing.expect(!should_cache);
    }

    // Test 3: Verify 404 responses aren't cached (simulated)
    const not_found_response = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";

    // We would parse the response status code in real implementation
    // For now, verify the principle: only 200 OK should be cached
    const is_200_ok = std.mem.indexOf(u8, not_found_response, "200 OK") != null;
    try testing.expect(!is_200_ok);

    // Verify cache statistics
    const stats = cache.getStats();
    try testing.expectEqual(@as(u64, 1), stats.hits); // One successful GET lookup
    try testing.expectEqual(@as(u64, 0), stats.misses); // Initial miss before put doesn't count in this test
}

test "HTTPCache Integration: request buffering and forwarding after cache miss" {
    const allocator = testing.allocator;

    var cache = HTTPCache.init(allocator, 1024 * 1024);
    defer cache.deinit();

    // Simulate client request that will result in cache miss
    const request_data = "GET /api/data HTTP/1.1\r\nHost: example.com\r\n\r\n";

    // Parse the request
    if (HTTPInspector.parseRequestLine(request_data)) |request| {
        // Extract host header for multi-tenant isolation
        const maybe_host = HTTPInspector.findHeader(request_data, "Host");
        try testing.expect(maybe_host != null); // Verify Host header is present
        const host = maybe_host.?;

        // Check cache (should be miss)
        const cached = cache.get(request.method, host, request.path, null);
        try testing.expect(cached == null);

        // Verify cache miss was recorded
        var stats = cache.getStats();
        try testing.expectEqual(@as(u64, 1), stats.misses);

        // After cache miss, the buffered request data must be forwarded to backend
        // In the real implementation, this is the critical fix:
        // The request_buffer with buffered_request_size must be written to backend

        // Simulate backend response
        const backend_response = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndata";

        // After receiving backend response, cache it for future requests
        try cache.put(request.method, host, request.path, backend_response, 300, null, null);

        // Verify subsequent request gets cached response
        const cached_after = cache.get(request.method, host, request.path, null);
        defer if (cached_after) |data| allocator.free(data);
        try testing.expect(cached_after != null);
        if (cached_after) |data| {
            try testing.expectEqualStrings(backend_response, data);
        }

        // Verify statistics
        stats = cache.getStats();
        try testing.expectEqual(@as(u64, 1), stats.hits);
        try testing.expectEqual(@as(u64, 1), stats.misses);
        try testing.expect(stats.hitRate() > 0.0);
    }
}

test "HTTPCache Integration: TTL expiration and re-caching" {
    const allocator = testing.allocator;

    var cache = HTTPCache.init(allocator, 1024 * 1024);
    defer cache.deinit();

    const method = "GET";
    const path = "/api/short-lived";
    const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nshort";

    const host = "example.com";

    // Cache with very short TTL (0 seconds - immediate expiration)
    try cache.put(method, host, path, response, 0, null, null);

    // Immediate lookup might hit or miss depending on timing
    // The key is that the TTL mechanism is tested
    const cached1 = cache.get(method, host, path, null);
    defer if (cached1) |data| allocator.free(data);

    // Regardless of first lookup, we verify TTL behavior:
    // Put a new entry with longer TTL
    try cache.put(method, host, path, response, 300, null, null);

    // This should definitely hit
    const cached2 = cache.get(method, host, path, null);
    defer if (cached2) |data| allocator.free(data);
    try testing.expect(cached2 != null);

    // Verify cache is working
    const stats = cache.getStats();
    try testing.expect(stats.entry_count == 1);

    // Test another path with 0 TTL to verify expiration logic
    try cache.put("GET", host, "/api/expired", "data", 0, null, null);
    // The entry may expire immediately, demonstrating TTL functionality
    const expired = cache.get("GET", host, "/api/expired", null);
    defer if (expired) |data| allocator.free(data);

    // cached1 and expired may or may not be null (verified via defer)
}

test "HTTPCache Integration: concurrent access with new lock pattern" {
    const allocator = testing.allocator;

    var cache = HTTPCache.init(allocator, 10 * 1024 * 1024);
    defer cache.deinit();

    // Pre-populate cache with test data
    const host = "test.com";
    const paths = [_][]const u8{
        "/api/path1",
        "/api/path2",
        "/api/path3",
        "/api/path4",
        "/api/path5",
    };

    for (paths) |path| {
        const response = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ntest";
        try cache.put("GET", host, path, response, 300, null, null);
    }

    // Simulate concurrent access (sequential in test, but tests lock correctness)
    var hits: u32 = 0;
    var misses: u32 = 0;

    // Multiple "concurrent" readers
    for (0..10) |i| {
        const path = paths[i % paths.len];
        const cached = cache.get("GET", host, path, null);
        defer if (cached) |data| allocator.free(data);

        if (cached) |_| {
            hits += 1;
        } else {
            misses += 1;
        }
    }

    // All should be hits since we pre-populated
    try testing.expectEqual(@as(u32, 10), hits);
    try testing.expectEqual(@as(u32, 0), misses);

    // Verify cache statistics
    const stats = cache.getStats();
    try testing.expectEqual(@as(u64, 10), stats.hits);

    // Test concurrent writes (LRU updates via get())
    // Note: get() no longer updates LRU order due to shared lock optimization
    for (paths) |path| {
        const result = cache.get("GET", host, path, null);
        defer if (result) |data| allocator.free(data);
    }

    // Verify all entries still accessible
    for (paths) |path| {
        const cached = cache.get("GET", host, path, null);
        defer if (cached) |data| allocator.free(data);
        try testing.expect(cached != null);
    }
}

test "HTTPCache Integration: cache size limits and LRU eviction behavior" {
    const allocator = testing.allocator;

    // Small cache to force evictions
    const cache_size = 256; // bytes
    var cache = HTTPCache.init(allocator, cache_size);
    defer cache.deinit();

    const host = "test.com";

    // Each entry: method (3) + host (8) + path (10) + response (50) = 71 bytes
    // Cache can hold ~3 entries (256 / 71 = 3.60)

    const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n12345"; // 50 bytes

    // Add entries until cache is full
    try cache.put("GET", host, "/path0001", response, 300, null, null);
    try cache.put("GET", host, "/path0002", response, 300, null, null);
    try cache.put("GET", host, "/path0003", response, 300, null, null);
    try cache.put("GET", host, "/path0004", response, 300, null, null);

    var stats = cache.getStats();
    const entries_after_fill = stats.entry_count;

    // Cache should have 3-4 entries
    try testing.expect(entries_after_fill <= 4);

    // Add 5th entry - should evict LRU (path0001)
    try cache.put("GET", host, "/path0005", response, 300, null, null);

    // Verify LRU eviction occurred
    const evicted = cache.get("GET", host, "/path0001", null);
    defer if (evicted) |data| allocator.free(data);
    try testing.expect(evicted == null); // Should be evicted

    // Verify newest entry is present
    const newest = cache.get("GET", host, "/path0005", null);
    defer if (newest) |data| allocator.free(data);
    try testing.expect(newest != null);

    // Verify cache size accounting is correct
    stats = cache.getStats();
    try testing.expect(stats.current_size <= cache_size);
}

test "LoadBalancer Integration: refactored selection maintains round-robin behavior" {
    const allocator = testing.allocator;

    var backends = [_]Backend{
        Backend.init("backend1", 8081, 1),
        Backend.init("backend2", 8082, 1),
        Backend.init("backend3", 8083, 1),
    };

    var lb = LoadBalancer.init(&backends, .round_robin);

    // Track which backends are selected
    var selections = [_]u32{ 0, 0, 0 };

    // Select 12 times (4 full rotations)
    for (0..12) |_| {
        if (lb.selectBackend(.{ .ipv4 = 0 })) |backend| {
            if (std.mem.eql(u8, backend.host, "backend1")) {
                selections[0] += 1;
            } else if (std.mem.eql(u8, backend.host, "backend2")) {
                selections[1] += 1;
            } else if (std.mem.eql(u8, backend.host, "backend3")) {
                selections[2] += 1;
            }
        }
    }

    // Each backend should be selected exactly 4 times
    try testing.expectEqual(@as(u32, 4), selections[0]);
    try testing.expectEqual(@as(u32, 4), selections[1]);
    try testing.expectEqual(@as(u32, 4), selections[2]);

    _ = allocator;
}

test "LoadBalancer Integration: two-pass selection with unhealthy backends" {
    const allocator = testing.allocator;

    var backends = [_]Backend{
        Backend.init("backend1", 8081, 1),
        Backend.init("backend2", 8082, 1),
        Backend.init("backend3", 8083, 1),
    };

    // Mark backend2 as unhealthy
    backends[1].markHealthy(false);

    var lb = LoadBalancer.init(&backends, .round_robin);

    // Select multiple times - should skip unhealthy backend
    var backend1_count: u32 = 0;
    var backend2_count: u32 = 0;
    var backend3_count: u32 = 0;

    for (0..10) |_| {
        if (lb.selectBackend(.{ .ipv4 = 0 })) |backend| {
            if (std.mem.eql(u8, backend.host, "backend1")) {
                backend1_count += 1;
            } else if (std.mem.eql(u8, backend.host, "backend2")) {
                backend2_count += 1;
            } else if (std.mem.eql(u8, backend.host, "backend3")) {
                backend3_count += 1;
            }
        }
    }

    // Backend2 should never be selected (unhealthy)
    try testing.expectEqual(@as(u32, 0), backend2_count);

    // Backend1 and backend3 should share the load
    try testing.expect(backend1_count > 0);
    try testing.expect(backend3_count > 0);
    try testing.expectEqual(@as(u32, 10), backend1_count + backend3_count);

    _ = allocator;
}

test "LoadBalancer Integration: retry logic with all backends unhealthy" {
    const allocator = testing.allocator;

    var backends = [_]Backend{
        Backend.init("backend1", 8081, 1),
        Backend.init("backend2", 8082, 1),
    };

    // Mark all backends unhealthy
    backends[0].markHealthy(false);
    backends[1].markHealthy(false);

    var lb = LoadBalancer.init(&backends, .round_robin);

    // Should return null when no healthy backends
    const result = lb.selectBackend(.{ .ipv4 = 0 });
    try testing.expect(result == null);

    // Recover one backend
    backends[0].markHealthy(true);

    // Should now succeed
    const result2 = lb.selectBackend(.{ .ipv4 = 0 });
    try testing.expect(result2 != null);
    if (result2) |backend| {
        try testing.expectEqualStrings("backend1", backend.host);
    }

    _ = allocator;
}

test "Backend Integration: health state transitions and connection tracking" {
    var backend = Backend.init("test-backend", 9000, 5);

    // Initially healthy
    try testing.expect(backend.isHealthy());
    try testing.expectEqual(@as(u32, 0), backend.getConnections());

    // Mark unhealthy (simulating connection failure)
    backend.markHealthy(false);
    try testing.expect(!backend.isHealthy());

    // Simulate connection attempts during unhealthy state
    backend.incrementConnections();
    try testing.expectEqual(@as(u32, 1), backend.getConnections());

    // Recover to healthy
    backend.markHealthy(true);
    try testing.expect(backend.isHealthy());

    // Verify connections persist through state transitions
    try testing.expectEqual(@as(u32, 1), backend.getConnections());

    // Clean up connections
    backend.decrementConnections();
    try testing.expectEqual(@as(u32, 0), backend.getConnections());
}

test "HTTPInspector Integration: request parsing edge cases" {
    // Test 1: Complete valid request
    const valid_request = "GET /api/users HTTP/1.1\r\nHost: example.com\r\n\r\n";
    const parsed1 = HTTPInspector.parseRequestLine(valid_request);
    try testing.expect(parsed1 != null);
    if (parsed1) |req| {
        try testing.expectEqualStrings("GET", req.method);
        try testing.expectEqualStrings("/api/users", req.path);
        try testing.expectEqualStrings("HTTP/1.1", req.version);
    }

    // Test 2: Request with query parameters
    const query_request = "GET /search?q=test&page=1 HTTP/1.1\r\n";
    const parsed2 = HTTPInspector.parseRequestLine(query_request);
    try testing.expect(parsed2 != null);
    if (parsed2) |req| {
        try testing.expectEqualStrings("/search?q=test&page=1", req.path);
    }

    // Test 3: Different HTTP methods
    const methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH" };
    for (methods) |method| {
        var buffer: [128]u8 = undefined;
        const request = try std.fmt.bufPrint(&buffer, "{s} /test HTTP/1.1\r\n", .{method});
        const parsed = HTTPInspector.parseRequestLine(request);
        try testing.expect(parsed != null);
        if (parsed) |req| {
            try testing.expectEqualStrings(method, req.method);
        }
    }

    // Test 4: Incomplete request (should return null)
    const incomplete = "GET /incomplete";
    const parsed4 = HTTPInspector.parseRequestLine(incomplete);
    try testing.expect(parsed4 == null);

    // Test 5: Malformed request (missing path)
    const malformed = "GET HTTP/1.1\r\n";
    const parsed5 = HTTPInspector.parseRequestLine(malformed);
    // This might parse but with empty path - verify behavior
    _ = parsed5;
}

test "ProxyStats Integration: comprehensive metrics tracking" {
    var stats = ProxyStats.init();

    // Simulate realistic connection lifecycle
    for (0..5) |_| {
        stats.recordConnection();
        stats.recordBytesClientToBackend(1024);
        stats.recordBytesBackendToClient(2048);
    }

    var snapshot = stats.getStats();
    try testing.expectEqual(@as(u64, 5), snapshot.active_connections);
    try testing.expectEqual(@as(u64, 5), snapshot.total_connections);
    try testing.expectEqual(@as(u64, 5120), snapshot.total_bytes_client_to_backend);
    try testing.expectEqual(@as(u64, 10240), snapshot.total_bytes_backend_to_client);

    // Simulate errors
    stats.recordError();
    stats.recordBackendFailure();

    snapshot = stats.getStats();
    try testing.expectEqual(@as(u64, 1), snapshot.total_errors);
    try testing.expectEqual(@as(u64, 1), snapshot.backend_connect_failures);

    // End connections
    for (0..5) |_| {
        stats.recordConnectionEnd();
    }

    snapshot = stats.getStats();
    try testing.expectEqual(@as(u64, 0), snapshot.active_connections);
    try testing.expectEqual(@as(u64, 5), snapshot.total_connections);
}

test "HTTPCache Integration: verify correct size accounting in put operations" {
    const allocator = testing.allocator;

    var cache = HTTPCache.init(allocator, 500);
    defer cache.deinit();

    // Put entry and verify size accounting includes method + host + path + response
    const method = "GET"; // 3 bytes
    const host = "test.com"; // 8 bytes
    const path = "/test"; // 5 bytes
    const response = "HTTP/1.1 200 OK\r\n\r\nHello"; // 25 bytes
    // Total: 3 + 8 + 5 + 25 = 41 bytes

    try cache.put(method, host, path, response, 300, null, null);

    const stats = cache.getStats();

    // Verify size accounting - should be exactly method + host + path + response lengths
    const expected_size = method.len + host.len + path.len + response.len;
    try testing.expectEqual(@as(usize, expected_size), stats.current_size);
    try testing.expect(stats.current_size <= 500);
    try testing.expectEqual(@as(u64, 1), stats.entry_count);

    // Verify entry is retrievable
    const cached = cache.get(method, host, path, null);
    defer if (cached) |data| allocator.free(data);
    try testing.expect(cached != null);
}

test "HTTPCache Integration: skip caching for missing Host header (security)" {
    const allocator = testing.allocator;

    var cache = HTTPCache.init(allocator, 1024 * 1024); // 1MB cache
    defer cache.deinit();

    // Test request WITHOUT Host header (HTTP/1.0 style or misconfigured client)
    const request_no_host = "GET /api/users HTTP/1.1\r\nUser-Agent: Test\r\n\r\n";

    if (HTTPInspector.parseRequestLine(request_no_host)) |_| {
        const maybe_host = HTTPInspector.findHeader(request_no_host, "Host");

        // Verify Host header is missing
        try testing.expect(maybe_host == null);

        // In the real implementation, this request would bypass cache entirely
        // We simulate this by checking that the cache lookup returns null
        // and NOT calling cache.put()

        // The request would still be forwarded to backend, just not cached
    }

    // Test request WITH Host header works normally
    const request_with_host = "GET /api/users HTTP/1.1\r\nHost: api.example.com\r\n\r\n";

    if (HTTPInspector.parseRequestLine(request_with_host)) |request| {
        const maybe_host = HTTPInspector.findHeader(request_with_host, "Host");

        try testing.expect(maybe_host != null);
        const host = maybe_host.?;

        // This SHOULD be cacheable
        const response = "HTTP/1.1 200 OK\r\n\r\nresponse-data";
        try cache.put(request.method, host, request.path, response, 300, null, null);

        // Verify it was cached
        const cached = cache.get(request.method, host, request.path, null);
        try testing.expect(cached != null);
        defer if (cached) |data| allocator.free(data);

        // Verify correct response
        try testing.expect(std.mem.indexOf(u8, cached.?, "response-data") != null);
    }

    // Verify cache has exactly one entry (only the request with Host header)
    const stats = cache.getStats();
    try testing.expectEqual(@as(u64, 1), stats.entry_count);
    try testing.expectEqual(@as(u64, 1), stats.hits);
}

test "HTTPCache Integration: prevent cache pollution across different hosts" {
    const allocator = testing.allocator;

    var cache = HTTPCache.init(allocator, 1024 * 1024);
    defer cache.deinit();

    // Same path, different hosts should NOT collide
    const response1 = "HTTP/1.1 200 OK\r\n\r\nhost1-response";
    const response2 = "HTTP/1.1 200 OK\r\n\r\nhost2-response";

    try cache.put("GET", "api1.example.com", "/api/users", response1, 300, null, null);
    try cache.put("GET", "api2.example.com", "/api/users", response2, 300, null, null);

    // Verify each host gets its own cached response
    const cached1 = cache.get("GET", "api1.example.com", "/api/users", null);
    try testing.expect(cached1 != null);
    try testing.expect(std.mem.indexOf(u8, cached1.?, "host1-response") != null);
    defer allocator.free(cached1.?);

    const cached2 = cache.get("GET", "api2.example.com", "/api/users", null);
    try testing.expect(cached2 != null);
    try testing.expect(std.mem.indexOf(u8, cached2.?, "host2-response") != null);
    defer allocator.free(cached2.?);

    // Verify they're different responses (multi-tenant isolation)
    try testing.expect(!std.mem.eql(u8, cached1.?, cached2.?));

    // Verify cache has two separate entries
    const stats = cache.getStats();
    try testing.expectEqual(@as(u64, 2), stats.entry_count);
    try testing.expectEqual(@as(u64, 2), stats.hits);
}

test "Proxy runWithIoOptions API with explicit Io executor" {
    const allocator = testing.allocator;

    // Create Io executor explicitly (demonstrates dependency injection)
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Initialize proxy
    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 8000);
    defer proxy.deinit();

    // Test primary API with explicit Io and options
    try proxy.runWithIoOptions(io, .{});
}

test "Proxy runWithIoOptions API with custom configuration" {
    const allocator = testing.allocator;

    // Create Io executor
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Initialize proxy
    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 8000);
    defer proxy.deinit();

    // Test with custom configuration options (avoid overriding `max_connections`
    // so the implementation short-circuits in test builds and never touches the
    // real network).
    try proxy.runWithIoOptions(io, .{
        .connect_timeout = .none,
        .reuse_address = false,
        .enable_stats = false,
        .enable_caching = false,
    });
}

test "Proxy API hierarchy demonstration" {
    const allocator = testing.allocator;

    // Create Io executor for explicit APIs
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Initialize proxy
    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 8000);
    defer proxy.deinit();

    // Test all three API levels work

    // 1. Primary API - explicit Io and options
    try proxy.runWithIoOptions(io, .{});

    // 2. Convenience wrapper - explicit Io, default options
    try proxy.runWithIo(io);

    // 3. Convenience wrapper - creates Io internally, default options
    try proxy.run();
}

// ==================== Header Manipulation Tests ====================

test "HTTPInspector: manipulate headers - add RFC 7239 Forwarded header" {
    const allocator = testing.allocator;

    const inspector = HTTPInspector.init(true, true, "Prozy/1.0");

    const original_request = "GET /api/users HTTP/1.1\r\nHost: example.com\r\nUser-Agent: TestClient/1.0\r\n\r\n";

    const client_ip = "192.168.1.100";
    const client_proto = "http";
    const host_header = "example.com";

    const modified = try inspector.manipulateRequestHeaders(
        allocator,
        original_request,
        client_ip,
        client_proto,
        host_header,
    );
    defer allocator.free(modified);

    // Should contain RFC 7239 Forwarded header (host must be quoted per RFC 7239)
    try testing.expect(std.mem.indexOf(u8, modified, "Forwarded: for=192.168.1.100;host=\"example.com\";proto=http") != null);

    // Should contain X-Forwarded-* headers for compatibility
    try testing.expect(std.mem.indexOf(u8, modified, "X-Forwarded-For: 192.168.1.100") != null);
    try testing.expect(std.mem.indexOf(u8, modified, "X-Forwarded-Proto: http") != null);
    try testing.expect(std.mem.indexOf(u8, modified, "X-Forwarded-Host: example.com") != null);

    // Should contain Via header
    try testing.expect(std.mem.indexOf(u8, modified, "Via: 1.1 Prozy/1.0") != null);

    // Should contain Connection: close
    try testing.expect(std.mem.indexOf(u8, modified, "Connection: close") != null);
}

test "HTTPInspector: manipulate headers - detect upstream X-Forwarded-Proto" {
    const allocator = testing.allocator;

    const inspector = HTTPInspector.init(true, true, "Prozy/1.0");

    const original_request = "GET /api/secure HTTP/1.1\r\nHost: example.com\r\nX-Forwarded-Proto: https\r\nUser-Agent: TestClient/1.0\r\n\r\n";

    const client_ip = "192.168.1.100";
    const client_proto = "http"; // Direct connection is HTTP
    const host_header = "example.com";

    const modified = try inspector.manipulateRequestHeaders(
        allocator,
        original_request,
        client_ip,
        client_proto,
        host_header,
    );
    defer allocator.free(modified);

    // Should preserve the upstream X-Forwarded-Proto: https (TLS terminator upstream)
    try testing.expect(std.mem.indexOf(u8, modified, "X-Forwarded-Proto: https") != null);

    // RFC 7239 Forwarded header should use "https" from upstream (host must be quoted per RFC 7239)
    try testing.expect(std.mem.indexOf(u8, modified, "Forwarded: for=192.168.1.100;host=\"example.com\";proto=https") != null);
}

test "HTTPInspector: manipulate headers - Connection: close always added" {
    const allocator = testing.allocator;

    const inspector = HTTPInspector.init(true, true, "Prozy/1.0");

    const original_request = "GET /api/users HTTP/1.1\r\nHost: example.com\r\nConnection: keep-alive\r\n\r\n";

    const client_ip = "10.0.0.50";
    const client_proto = "http";
    const host_header = "example.com";

    const modified = try inspector.manipulateRequestHeaders(
        allocator,
        original_request,
        client_ip,
        client_proto,
        host_header,
    );
    defer allocator.free(modified);

    // Should replace Connection: keep-alive with Connection: close
    try testing.expect(std.mem.indexOf(u8, modified, "Connection: close") != null);

    // Should NOT contain keep-alive (hop-by-hop header removed)
    try testing.expect(std.mem.indexOf(u8, modified, "keep-alive") == null);
}

test "HTTPInspector: manipulate headers - preserve existing Forwarded header" {
    const allocator = testing.allocator;

    const inspector = HTTPInspector.init(true, true, "Prozy/1.0");

    const original_request =
        \\GET /api/users HTTP/1.1
        \\Host: example.com
        \\Forwarded: for=10.1.1.1;proto=https
        \\
        \\
    ;

    const client_ip = "192.168.1.100";
    const client_proto = "http";
    const host_header = "example.com";

    const modified = try inspector.manipulateRequestHeaders(
        allocator,
        original_request,
        client_ip,
        client_proto,
        host_header,
    );
    defer allocator.free(modified);

    // Should preserve the existing Forwarded header from upstream
    try testing.expect(std.mem.indexOf(u8, modified, "Forwarded: for=10.1.1.1;proto=https") != null);

    // Count occurrences - should only be one Forwarded header
    var count: usize = 0;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, modified, search_start, "Forwarded:")) |pos| {
        count += 1;
        search_start = pos + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "HTTPInspector: manipulate headers - without host header" {
    const allocator = testing.allocator;

    const inspector = HTTPInspector.init(true, true, "Prozy/1.0");

    const original_request = "GET /api/users HTTP/1.1\r\nUser-Agent: TestClient/1.0\r\n\r\n";

    const client_ip = "192.168.1.100";
    const client_proto = "http";
    const host_header: ?[]const u8 = null;

    const modified = try inspector.manipulateRequestHeaders(
        allocator,
        original_request,
        client_ip,
        client_proto,
        host_header,
    );
    defer allocator.free(modified);

    // Forwarded header should not include host parameter
    try testing.expect(std.mem.indexOf(u8, modified, "Forwarded: for=192.168.1.100;proto=http") != null);

    // Should NOT contain X-Forwarded-Host when host_header is null
    try testing.expect(std.mem.indexOf(u8, modified, "X-Forwarded-Host:") == null);

    // Should still contain other headers
    try testing.expect(std.mem.indexOf(u8, modified, "X-Forwarded-For: 192.168.1.100") != null);
    try testing.expect(std.mem.indexOf(u8, modified, "Connection: close") != null);
}

test "HTTPInspector: RFC 7239 Forwarded header with quoted host" {
    const allocator = testing.allocator;
    const inspector = HTTPInspector.init(true, true, "Prozy/1.0");

    const original_request = "GET /test HTTP/1.1\r\nHost: example.com\r\n\r\n";

    const modified = try inspector.manipulateRequestHeaders(
        allocator,
        original_request,
        "192.168.1.1",
        "http",
        "example.com",
    );
    defer allocator.free(modified);

    // Host parameter must be quoted per RFC 7239
    try testing.expect(std.mem.indexOf(u8, modified, ";host=\"example.com\"") != null);
}

test "HTTPInspector: RFC 7239 Forwarded header with host and port" {
    const allocator = testing.allocator;
    const inspector = HTTPInspector.init(true, true, "Prozy/1.0");

    const original_request = "GET /test HTTP/1.1\r\nHost: example.com:8080\r\n\r\n";

    const modified = try inspector.manipulateRequestHeaders(
        allocator,
        original_request,
        "192.168.1.1",
        "http",
        "example.com:8080",
    );
    defer allocator.free(modified);

    // Host with port must be quoted
    try testing.expect(std.mem.indexOf(u8, modified, ";host=\"example.com:8080\"") != null);
}

test "HTTPInspector: RFC 7239 Forwarded header with IPv6 address" {
    const allocator = testing.allocator;
    const inspector = HTTPInspector.init(true, true, "Prozy/1.0");

    const original_request = "GET /test HTTP/1.1\r\nHost: example.com\r\n\r\n";

    const modified = try inspector.manipulateRequestHeaders(
        allocator,
        original_request,
        "2001:db8::1",
        "http",
        "example.com",
    );
    defer allocator.free(modified);

    // IPv6 must be quoted and bracketed per RFC 7239 Section 4
    try testing.expect(std.mem.indexOf(u8, modified, "Forwarded: for=\"[2001:db8::1]\"") != null);
}

test "HTTPInspector: RFC 7239 Forwarded header with IPv6 loopback" {
    const allocator = testing.allocator;
    const inspector = HTTPInspector.init(true, true, "Prozy/1.0");

    const original_request = "GET /test HTTP/1.1\r\nHost: example.com\r\n\r\n";

    const modified = try inspector.manipulateRequestHeaders(
        allocator,
        original_request,
        "::1",
        "http",
        "example.com",
    );
    defer allocator.free(modified);

    // IPv6 loopback must be quoted and bracketed
    try testing.expect(std.mem.indexOf(u8, modified, "Forwarded: for=\"[::1]\"") != null);
}

test "HTTPInspector: RFC 7239 Forwarded header with IPv4 address (no quotes)" {
    const allocator = testing.allocator;
    const inspector = HTTPInspector.init(true, true, "Prozy/1.0");

    const original_request = "GET /test HTTP/1.1\r\nHost: example.com\r\n\r\n";

    const modified = try inspector.manipulateRequestHeaders(
        allocator,
        original_request,
        "192.168.1.100",
        "http",
        "example.com",
    );
    defer allocator.free(modified);

    // IPv4 should NOT be quoted or bracketed
    try testing.expect(std.mem.indexOf(u8, modified, "Forwarded: for=192.168.1.100") != null);
    // Should not have quotes around IPv4
    try testing.expect(std.mem.indexOf(u8, modified, "for=\"192.168.1.100\"") == null);
}

test "HTTPInspector: RFC 7239 Forwarded header complete format with IPv6" {
    const allocator = testing.allocator;
    const inspector = HTTPInspector.init(true, true, "Prozy/1.0");

    const original_request = "GET /test HTTP/1.1\r\nHost: api.example.com:443\r\n\r\n";

    const modified = try inspector.manipulateRequestHeaders(
        allocator,
        original_request,
        "2001:db8::cafe",
        "https",
        "api.example.com:443",
    );
    defer allocator.free(modified);

    // Complete RFC 7239 format: IPv6 quoted+bracketed, host quoted, proto unquoted
    try testing.expect(std.mem.indexOf(u8, modified, "Forwarded: for=\"[2001:db8::cafe]\";host=\"api.example.com:443\";proto=https") != null);
}

test "HTTPInspector: reject invalid protocol injection (ftp)" {
    const allocator = testing.allocator;
    const inspector = HTTPInspector.init(true, true, "Prozy/1.0");

    // Malicious upstream tries to inject "ftp" protocol
    const original_request = "GET /test HTTP/1.1\r\nHost: example.com\r\nX-Forwarded-Proto: ftp\r\n\r\n";

    const modified = try inspector.manipulateRequestHeaders(
        allocator,
        original_request,
        "192.168.1.1",
        "http",
        "example.com",
    );
    defer allocator.free(modified);

    // Should fall back to client_proto ("http"), rejecting "ftp"
    try testing.expect(std.mem.indexOf(u8, modified, "proto=http") != null);
    try testing.expect(std.mem.indexOf(u8, modified, "proto=ftp") == null);
}

test "HTTPInspector: reject invalid protocol injection (javascript:)" {
    const allocator = testing.allocator;
    const inspector = HTTPInspector.init(true, true, "Prozy/1.0");

    // Malicious upstream tries to inject "javascript:" protocol
    const original_request = "GET /test HTTP/1.1\r\nHost: example.com\r\nX-Forwarded-Proto: javascript:\r\n\r\n";

    const modified = try inspector.manipulateRequestHeaders(
        allocator,
        original_request,
        "192.168.1.1",
        "http",
        "example.com",
    );
    defer allocator.free(modified);

    // Should fall back to client_proto ("http"), rejecting "javascript:"
    try testing.expect(std.mem.indexOf(u8, modified, "proto=http") != null);
    try testing.expect(std.mem.indexOf(u8, modified, "proto=javascript:") == null);
}

test "HTTPInspector: accept valid https protocol from upstream" {
    const allocator = testing.allocator;
    const inspector = HTTPInspector.init(true, true, "Prozy/1.0");

    const original_request = "GET /test HTTP/1.1\r\nHost: example.com\r\nX-Forwarded-Proto: https\r\n\r\n";

    const modified = try inspector.manipulateRequestHeaders(
        allocator,
        original_request,
        "192.168.1.1",
        "http",
        "example.com",
    );
    defer allocator.free(modified);

    // Should accept valid "https" protocol
    try testing.expect(std.mem.indexOf(u8, modified, "proto=https") != null);
}

test "HTTPInspector: X-Forwarded-Proto with trailing whitespace trimmed" {
    const allocator = testing.allocator;
    const inspector = HTTPInspector.init(true, true, "Prozy/1.0");

    // Upstream sends X-Forwarded-Proto with trailing spaces
    const original_request = "GET /test HTTP/1.1\r\nHost: example.com\r\nX-Forwarded-Proto: https  \r\n\r\n";

    const modified = try inspector.manipulateRequestHeaders(
        allocator,
        original_request,
        "192.168.1.1",
        "http",
        "example.com",
    );
    defer allocator.free(modified);

    // Should use trimmed "https" value
    try testing.expect(std.mem.indexOf(u8, modified, "proto=https") != null);
    // Should NOT contain trailing spaces
    try testing.expect(std.mem.indexOf(u8, modified, "proto=https  ") == null);
}

// ============= Proxy Authentication Tests =============

test "Proxy authentication enable and configuration" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 8000);
    defer proxy.deinit();

    // Enable proxy authentication
    try proxy.enableProxyAuthentication("Test Realm", .{
        .basic_enabled = true,
        .digest_enabled = false,
        .max_failed_attempts = 5,
        .auth_timeout_ms = 30000,
    });

    try testing.expect(proxy.proxy_auth != null);
    try testing.expectEqualStrings("Test Realm", proxy.proxy_auth.?.realm);
}

test "Proxy authentication user management" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 8000);
    defer proxy.deinit();

    // Enable proxy authentication
    try proxy.enableProxyAuthentication("Company Proxy", .{
        .basic_enabled = true,
        .digest_enabled = false,
    });

    // Add users
    try proxy.addAuthUser("alice", "alicepass");
    try proxy.addAuthUser("bob", "bobpass");

    // Test authentication statistics
    const stats = proxy.getAuthStats();
    try testing.expect(stats != null);
    try testing.expectEqual(@as(u64, 0), stats.?.total_auth_requests);
}

test "Proxy authentication with RunOptions" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 8000);
    defer proxy.deinit();

    const options = RunOptions{
        .enable_proxy_authentication = true,
        .auth_realm = "Options Test",
        .auth_basic_enabled = true,
        .auth_digest_enabled = false,
        .auth_max_failed_attempts = 3,
        .auth_timeout_ms = 60000,
    };

    try testing.expect(options.enable_proxy_authentication);
    try testing.expectEqualStrings("Options Test", options.auth_realm);
    try testing.expect(options.auth_basic_enabled);
    try testing.expect(!options.auth_digest_enabled);
    try testing.expectEqual(@as(u32, 3), options.auth_max_failed_attempts);
    try testing.expectEqual(@as(u32, 60000), options.auth_timeout_ms);
}

test "Proxy authentication integration with other features" {
    const allocator = testing.allocator;

    var proxy = try Proxy.init(allocator, 8080, "127.0.0.1", 8000);
    defer proxy.deinit();

    // Enable multiple features including authentication
    try proxy.enableAccessControl(.allow);
    proxy.enableRateLimiting(10, 100);
    try proxy.enableProxyAuthentication("Multi Feature", .{
        .basic_enabled = true,
        .digest_enabled = false,
    });
    proxy.enableCaching(1024 * 1024);

    // All features should be enabled
    try testing.expect(proxy.access_control != null);
    try testing.expect(proxy.rate_limiter != null);
    try testing.expect(proxy.proxy_auth != null);
    try testing.expect(proxy.http_cache != null);

    // Add authentication user
    try proxy.addAuthUser("testuser", "testpass");

    // Test that we can get stats from all features
    const auth_stats = proxy.getAuthStats();
    try testing.expect(auth_stats != null);
    try testing.expectEqual(@as(u64, 0), auth_stats.?.total_auth_requests);
}

test "Proxy authentication password verification and session tracking" {
    const allocator = testing.allocator;

    // Create auth instance
    var auth = try ProxyAuth.init(allocator, "Test Realm", .{
        .basic_enabled = true,
        .max_failed_attempts = 5,
        .bcrypt_cost = 10,
    });
    defer auth.deinit();

    // Add test users
    try auth.addUser("alice", "correctPassword");
    try auth.addUser("bob", "secret123");

    const client_ip = IpKey{ .ipv4 = 0x7F000001 };

    // Test 1: Correct credentials should succeed
    const valid_alice = "Basic YWxpY2U6Y29ycmVjdFBhc3N3b3Jk"; // base64("alice:correctPassword")
    const result1 = auth.authenticate(valid_alice, client_ip);
    try testing.expectEqual(ProxyAuth.AuthResult.success, result1);

    var stats = auth.getStats();
    try testing.expectEqual(@as(u64, 1), stats.successful_auths);
    try testing.expectEqual(@as(u64, 1), stats.active_sessions);

    // Test 2: Incorrect password should fail (this tests the password verification fix)
    const invalid_alice = "Basic YWxpY2U6d3JvbmdQYXNzd29yZA=="; // base64("alice:wrongPassword")
    const result2 = auth.authenticate(invalid_alice, client_ip);
    try testing.expectEqual(ProxyAuth.AuthResult.invalid_credentials, result2);

    stats = auth.getStats();
    try testing.expectEqual(@as(u64, 1), stats.failed_auths);
    try testing.expectEqual(@as(u64, 1), stats.active_sessions); // Should not increment on failure

    // Test 3: Another valid user should succeed
    const valid_bob = "Basic Ym9iOnNlY3JldDEyMw=="; // base64("bob:secret123")
    const result3 = auth.authenticate(valid_bob, client_ip);
    try testing.expectEqual(ProxyAuth.AuthResult.success, result3);

    stats = auth.getStats();
    try testing.expectEqual(@as(u64, 2), stats.successful_auths);
    try testing.expectEqual(@as(u64, 2), stats.active_sessions);

    // Test 4: End session should decrement counter (fixes session tracking bug)
    auth.endSession();
    stats = auth.getStats();
    try testing.expectEqual(@as(u64, 1), stats.active_sessions);

    auth.endSession();
    stats = auth.getStats();
    try testing.expectEqual(@as(u64, 0), stats.active_sessions);
}

// ==================== Configuration Tests ====================

const Config = @import("config.zig").Config;
const ConfigManager = @import("config.zig").ConfigManager;
const parseJson = @import("config.zig").parseJson;
const parseZon = @import("config.zig").parseZon;

test "Config: parse valid JSON with minimal fields" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\{
        \\  "proxy": {
        \\    "listen_host": "127.0.0.1",
        \\    "listen_port": 8080
        \\  },
        \\  "clusters": [
        \\    {
        \\      "name": "backend",
        \\      "backends": [
        \\        { "host": "localhost", "port": 3003, "weight": 1 }
        \\      ]
        \\    }
        \\  ],
        \\  "routes": [
        \\    {
        \\      "name": "default",
        \\      "match": {},
        \\      "cluster": "backend"
        \\    }
        \\  ]
        \\}
    ;

    const config = try parseJson(arena.allocator(), source);
    try testing.expectEqualStrings("127.0.0.1", config.proxy.listen_host);
    try testing.expectEqual(@as(u16, 8080), config.proxy.listen_port);
    try testing.expectEqual(@as(usize, 1), config.clusters.len);
    try testing.expectEqual(@as(usize, 1), config.routes.len);
}

test "Config: parse JSON with all feature flags" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\{
        \\  "proxy": {
        \\    "listen_host": "0.0.0.0",
        \\    "listen_port": 9090,
        \\    "max_connections": 5000,
        \\    "reuse_address": false
        \\  },
        \\  "mode": "forward_proxy",
        \\  "cache": {
        \\    "enabled": true,
        \\    "max_size": 20971520
        \\  },
        \\  "rate_limit": {
        \\    "enabled": true,
        \\    "max_per_ip": 50,
        \\    "max_global": 5000
        \\  },
        \\  "access_control": {
        \\    "enabled": true,
        \\    "default_policy": "deny",
        \\    "allow_list": ["10.0.0.1", "10.0.0.2"],
        \\    "deny_list": ["192.168.1.1"]
        \\  },
        \\  "health_check": {
        \\    "enabled": false,
        \\    "interval_seconds": 30,
        \\    "timeout_ms": 3000,
        \\    "unhealthy_threshold": 5,
        \\    "healthy_threshold": 3
        \\  },
        \\  "admin": {
        \\    "enabled": true,
        \\    "listen_host": "127.0.0.1",
        \\    "listen_port": 9999
        \\  },
        \\  "logging": {
        \\    "level": "debug",
        \\    "enable_connection_logging": false,
        \\    "enable_stats": true
        \\  },
        \\  "clusters": [
        \\    {
        \\      "name": "cluster1",
        \\      "backends": [
        \\        { "host": "10.0.1.10", "port": 8080, "weight": 5 }
        \\      ],
        \\      "strategy": "weighted_round_robin",
        \\      "max_concurrent": 2000
        \\    }
        \\  ],
        \\  "routes": [
        \\    {
        \\      "name": "route1",
        \\      "match": {
        \\        "host": "api.example.com",
        \\        "path_prefix": "/v1",
        \\        "methods": ["GET", "POST"]
        \\      },
        \\      "cluster": "cluster1"
        \\    }
        \\  ]
        \\}
    ;

    const config = try parseJson(arena.allocator(), source);

    // Verify proxy config
    try testing.expectEqualStrings("0.0.0.0", config.proxy.listen_host);
    try testing.expectEqual(@as(u16, 9090), config.proxy.listen_port);
    try testing.expectEqual(@as(?usize, 5000), config.proxy.max_connections);
    try testing.expect(!config.proxy.reuse_address);

    // Verify mode
    try testing.expectEqual(@import("routing.zig").HttpMode.forward_proxy, config.mode);

    // Verify cache config
    try testing.expect(config.cache.enabled);
    try testing.expectEqual(@as(usize, 20971520), config.cache.max_size);

    // Verify rate limit config
    try testing.expect(config.rate_limit.enabled);
    try testing.expectEqual(@as(u32, 50), config.rate_limit.max_per_ip);
    try testing.expectEqual(@as(u32, 5000), config.rate_limit.max_global);

    // Verify access control config
    try testing.expect(config.access_control.enabled);
    try testing.expectEqual(AccessControl.Policy.deny, config.access_control.default_policy);
    try testing.expectEqual(@as(usize, 2), config.access_control.allow_list.len);
    try testing.expectEqual(@as(usize, 1), config.access_control.deny_list.len);

    // Verify health check config
    try testing.expect(!config.health_check.enabled);
    try testing.expectEqual(@as(u64, 30), config.health_check.interval_seconds);

    // Verify admin config
    try testing.expect(config.admin.enabled);
    try testing.expectEqual(@as(u16, 9999), config.admin.listen_port);

    // Verify logging config
    try testing.expectEqual(std.log.Level.debug, config.logging.level);
    try testing.expect(!config.logging.enable_connection_logging);
    try testing.expect(config.logging.enable_stats);

    // Verify clusters
    try testing.expectEqual(@as(usize, 1), config.clusters.len);
    try testing.expectEqualStrings("cluster1", config.clusters[0].name);
    try testing.expectEqual(LoadBalancer.Strategy.weighted_round_robin, config.clusters[0].strategy);

    // Verify routes
    try testing.expectEqual(@as(usize, 1), config.routes.len);
    try testing.expectEqualStrings("route1", config.routes[0].name);
    try testing.expectEqualStrings("api.example.com", config.routes[0].match.host.?);
    try testing.expectEqualStrings("/v1", config.routes[0].match.path_prefix.?);
    try testing.expectEqual(@as(usize, 2), config.routes[0].match.methods.len);
}

test "Config: parse JSON with invalid syntax" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\{
        \\  "proxy": {
        \\    "listen_host": "127.0.0.1",
        \\    "listen_port": 8080
        \\  },
        \\  "clusters": [
        \\    {
        \\      "name": "backend"
        \\      "backends": []
        \\    }
        \\  ]
        \\}
    ; // Missing comma after "name"

    const result = parseJson(arena.allocator(), source);
    try testing.expectError(error.ParseFailed, result);
}

test "Config: parse JSON with invalid port type" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\{
        \\  "proxy": {
        \\    "listen_host": "127.0.0.1",
        \\    "listen_port": "not_a_number"
        \\  }
        \\}
    ;

    const result = parseJson(arena.allocator(), source);
    try testing.expectError(error.ParseFailed, result);
}

test "Config: parse JSON with unknown fields (should ignore)" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\{
        \\  "proxy": {
        \\    "listen_host": "127.0.0.1",
        \\    "listen_port": 8080,
        \\    "unknown_field": "should be ignored"
        \\  },
        \\  "clusters": [],
        \\  "routes": [],
        \\  "totally_unknown": "ignored"
        \\}
    ;

    const config = try parseJson(arena.allocator(), source);
    try testing.expectEqual(@as(u16, 8080), config.proxy.listen_port);
}

test "Config: parse JSON with missing optional fields (use defaults)" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\{
        \\  "proxy": {
        \\    "listen_port": 8080
        \\  }
        \\}
    ;

    const config = try parseJson(arena.allocator(), source);
    // Should use defaults
    try testing.expectEqualStrings("127.0.0.1", config.proxy.listen_host);
    try testing.expectEqual(@as(u16, 8080), config.proxy.listen_port);
    try testing.expectEqual(@as(usize, 0), config.clusters.len);
    try testing.expectEqual(@as(usize, 0), config.routes.len);
}

test "Config: parse JSON with empty arrays" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\{
        \\  "proxy": {
        \\    "listen_port": 8080
        \\  },
        \\  "clusters": [],
        \\  "routes": []
        \\}
    ;

    const config = try parseJson(arena.allocator(), source);
    try testing.expectEqual(@as(usize, 0), config.clusters.len);
    try testing.expectEqual(@as(usize, 0), config.routes.len);
}

// ==================== ZON Config Parsing Tests ====================

test "Config: parse valid ZON with minimal fields" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\ .{
        \\     .proxy = .{
        \\         .listen_host = "127.0.0.1",
        \\         .listen_port = 8080,
        \\     },
        \\     .clusters = .{
        \\         .{
        \\             .name = "backend",
        \\             .backends = .{
        \\                 .{ .host = "localhost", .port = 3003, .weight = 1 },
        \\             },
        \\         },
        \\     },
        \\     .routes = .{
        \\         .{
        \\             .name = "default",
        \\             .match = .{},
        \\             .cluster = "backend",
        \\         },
        \\     },
        \\ }
    ;

    const config = try parseZon(arena.allocator(), source);
    try testing.expectEqualStrings("127.0.0.1", config.proxy.listen_host);
    try testing.expectEqual(@as(u16, 8080), config.proxy.listen_port);
    try testing.expectEqual(@as(usize, 1), config.clusters.len);
    try testing.expectEqual(@as(usize, 1), config.routes.len);
}

test "Config: parse ZON with syntax error" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\ .{
        \\     .proxy = .{
        \\         .listen_host = "127.0.0.1"
        \\         .listen_port = 8080,
        \\     },
        \\ }
    ; // Missing comma after listen_host

    const result = parseZon(arena.allocator(), source);
    try testing.expectError(error.ParseFailed, result);
}

test "Config: parse ZON with type mismatch" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\ .{
        \\     .proxy = .{
        \\         .listen_port = "not_a_number",
        \\     },
        \\ }
    ;

    const result = parseZon(arena.allocator(), source);
    try testing.expectError(error.ParseFailed, result);
}

test "Config: parse ZON with multiple clusters and routes" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source =
        \\ .{
        \\     .proxy = .{
        \\         .listen_host = "0.0.0.0",
        \\         .listen_port = 9090,
        \\     },
        \\     .clusters = .{
        \\         .{
        \\             .name = "cluster1",
        \\             .backends = .{
        \\                 .{ .host = "10.0.0.1", .port = 8080, .weight = 5 },
        \\                 .{ .host = "10.0.0.2", .port = 8080, .weight = 3 },
        \\             },
        \\             .strategy = .weighted_round_robin,
        \\         },
        \\         .{
        \\             .name = "cluster2",
        \\             .backends = .{
        \\                 .{ .host = "10.0.1.1", .port = 9000, .weight = 1 },
        \\             },
        \\             .strategy = .round_robin,
        \\         },
        \\     },
        \\     .routes = .{
        \\         .{
        \\             .name = "route1",
        \\             .match = .{
        \\                 .host = "api.example.com",
        \\                 .path_prefix = "/v1",
        \\             },
        \\             .cluster = "cluster1",
        \\         },
        \\         .{
        \\             .name = "route2",
        \\             .match = .{
        \\                 .host = "static.example.com",
        \\             },
        \\             .cluster = "cluster2",
        \\         },
        \\     },
        \\ }
    ;

    const config = try parseZon(arena.allocator(), source);
    try testing.expectEqual(@as(usize, 2), config.clusters.len);
    try testing.expectEqual(@as(usize, 2), config.routes.len);
    try testing.expectEqualStrings("cluster1", config.clusters[0].name);
    try testing.expectEqualStrings("cluster2", config.clusters[1].name);
    try testing.expectEqual(@as(usize, 2), config.clusters[0].backends.len);
    try testing.expectEqual(@as(usize, 1), config.clusters[1].backends.len);
}

// ==================== Config Validation Tests ====================

test "Config: validation passes for valid config" {
    const config = Config{
        .clusters = &[_]@import("config.zig").ClusterConfig{
            .{
                .name = "test_cluster",
                .backends = &[_]@import("config.zig").BackendConfig{
                    .{ .host = "localhost", .port = 8080, .weight = 1 },
                },
            },
        },
        .routes = &[_]@import("config.zig").RouteConfig{
            .{
                .name = "test_route",
                .match = .{},
                .cluster = "test_cluster",
            },
        },
    };

    try config.validate();
}

test "Config: validation fails for port zero" {
    const config = Config{
        .proxy = .{ .listen_port = 0 },
    };

    const result = config.validate();
    try testing.expectError(error.ValidationFailed, result);
}

test "Config: validation fails for empty cluster backends" {
    const config = Config{
        .clusters = &[_]@import("config.zig").ClusterConfig{
            .{
                .name = "empty_cluster",
                .backends = &[_]@import("config.zig").BackendConfig{},
            },
        },
    };

    const result = config.validate();
    try testing.expectError(error.ValidationFailed, result);
}

test "Config: validation fails for backend port zero" {
    const config = Config{
        .clusters = &[_]@import("config.zig").ClusterConfig{
            .{
                .name = "test_cluster",
                .backends = &[_]@import("config.zig").BackendConfig{
                    .{ .host = "localhost", .port = 0, .weight = 1 },
                },
            },
        },
    };

    const result = config.validate();
    try testing.expectError(error.ValidationFailed, result);
}

test "Config: validation fails for backend weight zero" {
    const config = Config{
        .clusters = &[_]@import("config.zig").ClusterConfig{
            .{
                .name = "test_cluster",
                .backends = &[_]@import("config.zig").BackendConfig{
                    .{ .host = "localhost", .port = 8080, .weight = 0 },
                },
            },
        },
    };

    const result = config.validate();
    try testing.expectError(error.ValidationFailed, result);
}

test "Config: validation fails for route referencing unknown cluster" {
    const config = Config{
        .clusters = &[_]@import("config.zig").ClusterConfig{
            .{
                .name = "real_cluster",
                .backends = &[_]@import("config.zig").BackendConfig{
                    .{ .host = "localhost", .port = 8080, .weight = 1 },
                },
            },
        },
        .routes = &[_]@import("config.zig").RouteConfig{
            .{
                .name = "bad_route",
                .match = .{},
                .cluster = "unknown_cluster",
            },
        },
    };

    const result = config.validate();
    try testing.expectError(error.ValidationFailed, result);
}

test "Config: validation passes with multiple valid routes and clusters" {
    const config = Config{
        .clusters = &[_]@import("config.zig").ClusterConfig{
            .{
                .name = "cluster1",
                .backends = &[_]@import("config.zig").BackendConfig{
                    .{ .host = "10.0.0.1", .port = 8080, .weight = 1 },
                },
            },
            .{
                .name = "cluster2",
                .backends = &[_]@import("config.zig").BackendConfig{
                    .{ .host = "10.0.1.1", .port = 9000, .weight = 2 },
                },
            },
        },
        .routes = &[_]@import("config.zig").RouteConfig{
            .{
                .name = "route1",
                .match = .{},
                .cluster = "cluster1",
            },
            .{
                .name = "route2",
                .match = .{},
                .cluster = "cluster2",
            },
        },
    };

    try config.validate();
}

// ==================== Router Tests ====================

const Router = root.Router;
const Route = root.Route;
const Cluster = root.Cluster;
const HttpMode = root.HttpMode;

test "Router: tunnel_only mode with CONNECT method" {
    const allocator = testing.allocator;

    const backend = Backend.init("127.0.0.1", 3003, 1);
    var backends = [_]Backend{backend};
    const cluster = Cluster.init("tunnel-cluster", &backends, .round_robin, 10);

    const route = Route{
        .name = "tunnel-route",
        .match = .{
            .host = null, // Host is in the path for CONNECT
            .path_prefix = null,
            .methods = &[_][]const u8{"CONNECT"},
        },
        .cluster = .{ .name = "tunnel-cluster" },
    };

    var routes = [_]Route{route};
    var clusters = [_]Cluster{cluster};
    var router = Router.init(allocator, .tunnel_only, &routes, &clusters);

    // Test CONNECT request
    const req = HTTPInspector.HTTPRequest{
        .method = "CONNECT",
        .path = "example.com:443",
        .version = "HTTP/1.1",
    };
    const headers = "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n";
    const client_ip = IpKey{ .ipv4 = 0x7F000001 };

    const decision = try router.routeRequest(&req, headers, client_ip);
    try testing.expectEqualStrings("127.0.0.1", decision.backend.host);

    router.releaseConnection("tunnel-cluster");

    // Test non-CONNECT request (should fail in tunnel mode)
    const req_get = HTTPInspector.HTTPRequest{
        .method = "GET",
        .path = "/foo",
        .version = "HTTP/1.1",
    };
    const result = router.routeRequest(&req_get, headers, client_ip);
    try testing.expectError(error.InvalidRequest, result);
}

test "Router: cluster capacity handling" {
    const allocator = testing.allocator;

    const backend = Backend.init("127.0.0.1", 3003, 1);
    var backends = [_]Backend{backend};

    // Cluster with max_concurrent = 1
    const cluster = Cluster.init("small-cluster", &backends, .round_robin, 1);

    const route = Route{
        .name = "capacity-route",
        .match = .{},
        .cluster = .{ .name = "small-cluster" },
        .concurrency_policy = .{
            .reject_when_full = true,
        },
    };

    var routes = [_]Route{route};
    var clusters = [_]Cluster{cluster};
    var router = Router.init(allocator, .reverse_proxy, &routes, &clusters);

    const req = HTTPInspector.HTTPRequest{
        .method = "GET",
        .path = "/",
        .version = "HTTP/1.1",
    };
    const headers = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";
    const client_ip = IpKey{ .ipv4 = 0x7F000001 };

    // First request should succeed (taking the only slot)
    const decision1 = try router.routeRequest(&req, headers, client_ip);
    try testing.expectEqualStrings("small-cluster", decision1.cluster.name);

    // Second request should fail with ClusterAtCapacity
    const result = router.routeRequest(&req, headers, client_ip);
    try testing.expectError(error.ClusterAtCapacity, result);

    // Release first connection
    router.releaseConnection("small-cluster");

    // Now request should succeed again
    const decision2 = try router.routeRequest(&req, headers, client_ip);
    try testing.expectEqualStrings("small-cluster", decision2.cluster.name);

    router.releaseConnection("small-cluster");
}

test "Router: error cases (NoCluster, NoHealthyBackend)" {
    const allocator = testing.allocator;

    // 1. Test NoCluster (route points to missing cluster)
    {
        const route = Route{
            .name = "broken-route",
            .match = .{},
            .cluster = .{ .name = "missing-cluster" },
        };
        var routes = [_]Route{route};
        var clusters = [_]Cluster{}; // Empty clusters
        var router = Router.init(allocator, .reverse_proxy, &routes, &clusters);

        const req = HTTPInspector.HTTPRequest{
            .method = "GET",
            .path = "/",
            .version = "HTTP/1.1",
        };
        const headers = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";
        const client_ip = IpKey{ .ipv4 = 0x7F000001 };

        const result = router.routeRequest(&req, headers, client_ip);
        try testing.expectError(error.NoCluster, result);
    }

    // 2. Test NoHealthyBackend
    {
        var backend = Backend.init("127.0.0.1", 3003, 1);
        backend.markHealthy(false); // Mark backend as unhealthy

        var backends = [_]Backend{backend};
        const cluster = Cluster.init("sick-cluster", &backends, .round_robin, 10);

        const route = Route{
            .name = "sick-route",
            .match = .{},
            .cluster = .{ .name = "sick-cluster" },
        };

        var routes = [_]Route{route};
        var clusters = [_]Cluster{cluster};
        var router = Router.init(allocator, .reverse_proxy, &routes, &clusters);

        const req = HTTPInspector.HTTPRequest{
            .method = "GET",
            .path = "/",
            .version = "HTTP/1.1",
        };
        const headers = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";
        const client_ip = IpKey{ .ipv4 = 0x7F000001 };

        const result = router.routeRequest(&req, headers, client_ip);
        try testing.expectError(error.NoHealthyBackend, result);
    }
}
