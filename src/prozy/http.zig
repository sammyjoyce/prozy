const std = @import("std");
const log = std.log;

/// HTTP protocol inspector for header manipulation
pub const HTTPInspector = struct {
    add_forwarded_headers: bool = true,
    add_via_header: bool = true,
    proxy_name: []const u8 = "Prozy/1.0",

    pub fn init(add_forwarded: bool, add_via: bool, proxy_name: []const u8) HTTPInspector {
        return .{
            .add_forwarded_headers = add_forwarded,
            .add_via_header = add_via,
            .proxy_name = proxy_name,
        };
    }

    /// Parse HTTP request line (GET /path HTTP/1.1)
    pub fn parseRequestLine(buffer: []const u8) ?HTTPRequest {
        var it = std.mem.splitSequence(u8, buffer, "\r\n");
        const first_line = it.next() orelse return null;

        var parts = std.mem.splitSequence(u8, first_line, " ");
        const method = parts.next() orelse return null;
        const path = parts.next() orelse return null;
        const version = parts.next() orelse return null;

        return .{
            .method = method,
            .path = path,
            .version = version,
        };
    }

    pub const HTTPRequest = struct {
        method: []const u8,
        path: []const u8,
        version: []const u8,
    };

    pub const HTTPResponse = struct {
        version: []const u8,
        status_code: u16,
        status_text: []const u8,
        headers_end: usize, // Offset where headers end (after \r\n\r\n)
    };

    /// Parse HTTP response status line (HTTP/1.1 200 OK)
    pub fn parseResponseLine(buffer: []const u8) ?HTTPResponse {
        // Find first line terminator
        var it = std.mem.splitSequence(u8, buffer, "\r\n");
        const first_line = it.next() orelse return null;

        // Parse "HTTP/1.1 200 OK" format
        var parts = std.mem.splitSequence(u8, first_line, " ");
        const version = parts.next() orelse return null;
        const status_code_str = parts.next() orelse return null;
        const status_text = parts.rest();

        // Validate HTTP version
        if (!std.mem.startsWith(u8, version, "HTTP/")) return null;

        // Parse status code as u16
        const status_code = std.fmt.parseInt(u16, status_code_str, 10) catch return null;

        // Validate status code range (100-599)
        if (status_code < 100 or status_code >= 600) return null;

        // Find headers end marker (\r\n\r\n)
        const headers_end = findHeadersEnd(buffer) orelse return null;

        return .{
            .version = version,
            .status_code = status_code,
            .status_text = status_text,
            .headers_end = headers_end,
        };
    }

    /// Find the end of HTTP headers (offset after \r\n\r\n)
    pub fn findHeadersEnd(buffer: []const u8) ?usize {
        const marker = "\r\n\r\n";
        if (std.mem.indexOf(u8, buffer, marker)) |idx| {
            return idx + marker.len;
        }
        return null;
    }

    /// Check if buffer contains a complete HTTP response
    pub fn isCompleteResponse(buffer: []const u8) bool {
        // First, check if we have complete headers
        const headers_end = findHeadersEnd(buffer) orelse return false;

        // Extract headers section
        const headers_section = buffer[0..headers_end];

        // Check for Content-Length header
        if (findHeader(headers_section, "Content-Length")) |content_length_str| {
            const content_length = std.fmt.parseInt(usize, content_length_str, 10) catch return false;
            const expected_total = headers_end + content_length;
            return buffer.len >= expected_total;
        }

        // Check for Transfer-Encoding: chunked
        if (findHeader(headers_section, "Transfer-Encoding")) |transfer_encoding| {
            if (std.mem.indexOf(u8, transfer_encoding, "chunked") != null) {
                // For chunked encoding, look for terminating chunk (0\r\n\r\n)
                const body_start = headers_end;
                if (body_start >= buffer.len) return false;
                const body = buffer[body_start..];
                return std.mem.endsWith(u8, body, "0\r\n\r\n");
            }
        }

        // If no Content-Length or Transfer-Encoding, assume complete after headers
        // (This handles HTTP/1.0 responses without Content-Length where connection closes)
        return true;
    }

    /// Find a header value in the headers section (case-insensitive)
    pub fn findHeader(headers: []const u8, name: []const u8) ?[]const u8 {
        var it = std.mem.splitSequence(u8, headers, "\r\n");
        _ = it.next(); // Skip status line

        while (it.next()) |line| {
            if (line.len == 0) break; // End of headers

            const colon_idx = std.mem.indexOf(u8, line, ":") orelse continue;
            const header_name = line[0..colon_idx];

            // Case-insensitive comparison
            if (std.ascii.eqlIgnoreCase(header_name, name)) {
                var value = line[colon_idx + 1 ..];
                // Trim leading whitespace
                while (value.len > 0 and (value[0] == ' ' or value[0] == '\t')) {
                    value = value[1..];
                }
                return value;
            }
        }
        return null;
    }
};

/// Get current Unix timestamp in seconds (public utility for HTTP and backend modules)
pub fn getTimestamp() i64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch |err| {
        log.warn("clock_gettime() failed: {s}, backend health recovery may be disabled", .{@errorName(err)});
        return 0;
    };
    return ts.sec;
}

/// HTTP response cache with LRU eviction for performance optimization
///
/// SECURITY: Cache keys include Host header for multi-tenant isolation.
/// Requests without Host headers MUST NOT be cached to prevent pollution
/// across different virtual hosts/APIs.
pub const HTTPCache = struct {
    const CacheNode = struct {
        key: u64,
        response: []u8,
        method: []u8,
        host: []u8,
        path: []u8,
        created_at: i64,
        ttl: u32,
        size: usize,
        access_count: u32,
        prev: ?*CacheNode,
        next: ?*CacheNode,
    };

    allocator: std.mem.Allocator,
    cache: std.AutoHashMap(u64, *CacheNode),
    max_size: usize,
    current_size: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    hits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    misses: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rwlock: std.Thread.RwLock = .{},
    head: ?*CacheNode = null,
    tail: ?*CacheNode = null,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) HTTPCache {
        return .{
            .allocator = allocator,
            .cache = std.AutoHashMap(u64, *CacheNode).init(allocator),
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *HTTPCache) void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

        var it = self.cache.iterator();
        while (it.next()) |kv| {
            const node = kv.value_ptr.*;
            self.allocator.free(node.response);
            self.allocator.free(node.method);
            self.allocator.free(node.host);
            self.allocator.free(node.path);
            self.allocator.destroy(node);
        }
        self.cache.deinit();
    }

    /// Get cached response (returns owned copy that caller must free)
    ///
    /// IMPORTANT CHANGES:
    /// - Now includes Host header in cache key for multi-tenant isolation
    /// - Uses lockShared() for concurrent reads (high performance)
    /// - Does NOT update LRU order to avoid write lock contention
    /// - Expired entries are detected but not evicted (cleanup happens during put)
    /// - Returns an OWNED COPY to prevent use-after-free (caller must free!)
    ///
    /// This design prioritizes safety and read performance over zero-copy efficiency.
    /// The copy overhead is acceptable for cached responses since we avoid network I/O.
    pub fn get(self: *HTTPCache, method: []const u8, host: []const u8, path: []const u8) ?[]u8 {
        const key = hashKey(method, host, path);

        // Use shared (read) lock for concurrent reads
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();

        if (self.cache.get(key)) |node| {
            // Check if expired (read-only check)
            const now = getTimestamp();
            const elapsed = now - node.created_at;
            // Cast ttl to i64 to avoid signed/unsigned comparison issues
            // Also guard against negative elapsed time (clock adjustments)
            if (elapsed >= 0 and elapsed > @as(i64, node.ttl)) {
                // Don't evict here, just return null
                // Eviction will happen on next put() or during periodic cleanup
                _ = self.misses.fetchAdd(1, .monotonic);
                return null;
            }

            // Don't update LRU order (read-only path for concurrency)
            // Access count is not updated to avoid write contention
            _ = self.hits.fetchAdd(1, .monotonic);

            // CRITICAL: Copy response to prevent use-after-free
            // The caller holds no lock after we return, so another thread
            // could evict this entry and free the buffer. Return an owned copy.
            const response_copy = self.allocator.alloc(u8, node.response.len) catch {
                // Allocation failed, treat as cache miss
                // Only decrement hits (incremented at line 252)
                // Don't decrement misses (never incremented in this path)
                _ = self.hits.fetchSub(1, .monotonic);
                return null;
            };
            @memcpy(response_copy, node.response);
            return response_copy;
        }

        _ = self.misses.fetchAdd(1, .monotonic);
        return null;
    }

    pub fn put(self: *HTTPCache, method: []const u8, host: []const u8, path: []const u8, response: []const u8, ttl: u32) !void {
        const key = hashKey(method, host, path);

        // Don't cache if response is too large
        if (response.len > self.max_size / 2) {
            return;
        }

        self.rwlock.lock();
        defer self.rwlock.unlock();

        // Evict old entry if exists
        if (self.cache.get(key)) |existing_node| {
            self.evictNode(existing_node);
        }

        // Check if we need to evict to make space
        const total_new_size = response.len + method.len + host.len + path.len;
        while (self.current_size.load(.monotonic) + total_new_size > self.max_size and self.cache.count() > 0) {
            self.evictLRU();
        }

        // Allocate and copy data
        // Each errdefer only frees the allocation immediately preceding it to avoid double-free
        const response_copy = try self.allocator.alloc(u8, response.len);
        errdefer self.allocator.free(response_copy);
        @memcpy(response_copy, response);

        const method_copy = try self.allocator.alloc(u8, method.len);
        errdefer self.allocator.free(method_copy);
        @memcpy(method_copy, method);

        const host_copy = try self.allocator.alloc(u8, host.len);
        errdefer self.allocator.free(host_copy);
        @memcpy(host_copy, host);

        const path_copy = try self.allocator.alloc(u8, path.len);
        errdefer self.allocator.free(path_copy);
        @memcpy(path_copy, path);

        // Create new node
        const node = try self.allocator.create(CacheNode);
        errdefer {
            self.allocator.free(response_copy);
            self.allocator.free(method_copy);
            self.allocator.free(host_copy);
            self.allocator.free(path_copy);
            self.allocator.destroy(node);
        }

        node.* = .{
            .key = key,
            .response = response_copy,
            .method = method_copy,
            .host = host_copy,
            .path = path_copy,
            .created_at = getTimestamp(),
            .ttl = ttl,
            .size = response.len + method.len + host.len + path.len,
            .access_count = 0,
            .prev = null,
            .next = null,
        };

        // Add to cache map
        self.cache.put(key, node) catch |err| {
            self.allocator.free(response_copy);
            self.allocator.free(method_copy);
            self.allocator.free(host_copy);
            self.allocator.free(path_copy);
            self.allocator.destroy(node);
            return err;
        };

        // Add to front of LRU list
        self.addToFront(node);
        _ = self.current_size.fetchAdd(node.size, .monotonic);
    }

    fn hashKey(method: []const u8, host: []const u8, path: []const u8) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(method);
        hasher.update(host);
        hasher.update(path);
        return hasher.final();
    }

    /// Add node to front of LRU list (most recently used)
    fn addToFront(self: *HTTPCache, node: *CacheNode) void {
        node.next = self.head;
        node.prev = null;

        if (self.head) |head| {
            head.prev = node;
        }
        self.head = node;

        if (self.tail == null) {
            self.tail = node;
        }
    }

    /// Remove node from LRU list
    fn removeFromList(self: *HTTPCache, node: *CacheNode) void {
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.head = node.next;
        }

        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.tail = node.prev;
        }

        node.prev = null;
        node.next = null;
    }

    /// Move node to front of LRU list (mark as most recently used)
    fn moveToFront(self: *HTTPCache, node: *CacheNode) void {
        if (self.head == node) return; // Already at front

        self.removeFromList(node);
        self.addToFront(node);
    }

    /// Evict LRU entry (from tail) - O(1) operation
    fn evictLRU(self: *HTTPCache) void {
        if (self.tail) |tail_node| {
            self.evictNode(tail_node);
        }
    }

    /// Evict specific node
    fn evictNode(self: *HTTPCache, node: *CacheNode) void {
        // Remove from linked list
        self.removeFromList(node);

        // Remove from hash map
        _ = self.cache.remove(node.key);

        // Update size
        _ = self.current_size.fetchSub(node.size, .monotonic);

        // Free memory
        self.allocator.free(node.response);
        self.allocator.free(node.method);
        self.allocator.free(node.host);
        self.allocator.free(node.path);
        self.allocator.destroy(node);
    }

    pub fn getStats(self: *const HTTPCache) CacheStats {
        return .{
            .hits = self.hits.load(.monotonic),
            .misses = self.misses.load(.monotonic),
            .current_size = self.current_size.load(.monotonic),
            .entry_count = self.cache.count(),
            .max_size = self.max_size,
        };
    }

    pub const CacheStats = struct {
        hits: u64,
        misses: u64,
        current_size: usize,
        entry_count: usize,
        max_size: usize,

        pub fn hitRate(self: CacheStats) f64 {
            const total = self.hits + self.misses;
            if (total == 0) return 0.0;
            return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total)) * 100.0;
        }
    };
};
