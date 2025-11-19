//! Demonstration of HTTP response parsing for cache population
//! This example shows how to use HTTPInspector to parse HTTP responses
//! and populate the cache with complete responses.

const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== HTTP Response Parsing Demo ===\n\n", .{});

    // Example 1: Parse a simple HTTP/1.1 200 OK response
    const response1 = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n{\"status\":\"success\",\"id\":1}";

    std.debug.print("Example 1: Simple HTTP/1.1 200 OK\n", .{});
    std.debug.print("Response:\n{s}\n\n", .{response1});

    if (prozy.HTTPInspector.parseResponseLine(response1)) |parsed| {
        std.debug.print("✓ Parsed successfully!\n", .{});
        std.debug.print("  Version: {s}\n", .{parsed.version});
        std.debug.print("  Status Code: {d}\n", .{parsed.status_code});
        std.debug.print("  Status Text: {s}\n", .{parsed.status_text});
        std.debug.print("  Headers End: {d}\n", .{parsed.headers_end});

        // Extract body
        const body = response1[parsed.headers_end..];
        std.debug.print("  Body: {s}\n", .{body});
    } else {
        std.debug.print("✗ Failed to parse\n", .{});
    }
    std.debug.print("\n", .{});

    // Example 2: Check if response is complete with Content-Length
    const response2 = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 12\r\n\r\nHello, World";

    std.debug.print("Example 2: Complete response check (Content-Length)\n", .{});
    std.debug.print("Response length: {d} bytes\n", .{response2.len});

    const is_complete2 = prozy.HTTPInspector.isCompleteResponse(response2);
    std.debug.print("✓ Is complete: {}\n", .{is_complete2});
    std.debug.print("\n", .{});

    // Example 3: Check incomplete response
    const incomplete = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nShort";

    std.debug.print("Example 3: Incomplete response (expecting 100 bytes, got 5)\n", .{});
    const is_complete3 = prozy.HTTPInspector.isCompleteResponse(incomplete);
    std.debug.print("✓ Is complete: {}\n", .{is_complete3});
    std.debug.print("\n", .{});

    // Example 4: Chunked transfer encoding (complete)
    const chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHello\r\n0\r\n\r\n";

    std.debug.print("Example 4: Chunked transfer encoding (complete)\n", .{});
    const is_complete4 = prozy.HTTPInspector.isCompleteResponse(chunked);
    std.debug.print("✓ Is complete: {}\n", .{is_complete4});
    std.debug.print("\n", .{});

    // Example 5: Extract specific headers
    const response5 = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: max-age=3600\r\nContent-Length: 13\r\n\r\n{\"data\":true}";

    std.debug.print("Example 5: Header extraction\n", .{});

    if (prozy.HTTPInspector.findHeadersEnd(response5)) |headers_end| {
        const headers_section = response5[0..headers_end];

        if (prozy.HTTPInspector.findHeader(headers_section, "Content-Type")) |content_type| {
            std.debug.print("  Content-Type: {s}\n", .{content_type});
        }

        if (prozy.HTTPInspector.findHeader(headers_section, "Cache-Control")) |cache_control| {
            std.debug.print("  Cache-Control: {s}\n", .{cache_control});
        }

        // Case-insensitive lookup
        if (prozy.HTTPInspector.findHeader(headers_section, "content-length")) |content_length| {
            std.debug.print("  content-length (lowercase): {s}\n", .{content_length});
        }
    }
    std.debug.print("\n", .{});

    // Example 6: Cache population workflow
    std.debug.print("Example 6: Cache population workflow\n", .{});

    var cache = prozy.HTTPCache.init(allocator, 1024 * 1024); // 1MB cache
    defer cache.deinit();

    const cache_key_method = "GET";
    const cache_key_host = "api.example.com";
    const cache_key_path = "/api/users/123";
    const cache_response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 28\r\n\r\n{\"id\":123,\"name\":\"John Doe\"}";

    // Step 1: Parse the response
    if (prozy.HTTPInspector.parseResponseLine(cache_response)) |parsed| {
        std.debug.print("  ✓ Response parsed: {s} {d}\n", .{ parsed.version, parsed.status_code });

        // Step 2: Check if response is complete
        if (prozy.HTTPInspector.isCompleteResponse(cache_response)) {
            std.debug.print("  ✓ Response is complete\n", .{});

            // Step 3: Cache only successful responses (2xx status codes)
            if (parsed.status_code >= 200 and parsed.status_code < 300) {
                std.debug.print("  ✓ Status code {d} is cacheable\n", .{parsed.status_code});

                // Step 4: Populate cache (including host for multi-tenant isolation)
                try cache.put(cache_key_method, cache_key_host, cache_key_path, cache_response, 3600, null, null);
                std.debug.print("  ✓ Cached response for {s} {s}{s}\n", .{ cache_key_method, cache_key_host, cache_key_path });

                // Step 5: Retrieve from cache
                if (cache.get(cache_key_method, cache_key_host, cache_key_path, null, false)) |cached| {
                    defer allocator.free(cached.response);
                    std.debug.print("  ✓ Retrieved from cache: {d} bytes\n", .{cached.response.len});
                    const stats = cache.getStats();
                    std.debug.print("  ✓ Hit rate: {d:.2}%\n", .{stats.hitRate() * 100});
                }
            }
        } else {
            std.debug.print("  ✗ Response is incomplete\n", .{});
        }
    }

    std.debug.print("\n=== Demo Complete ===\n", .{});
}
