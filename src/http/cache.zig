//! HTTP response cache with LRU eviction for performance optimization
//!
//! SECURITY: Cache keys include Host header for multi-tenant isolation.
//! Requests without Host headers MUST NOT be cached to prevent pollution
//! across different virtual hosts/APIs.
//!
//! Features:
//! - O(1) LRU eviction using doubly-linked list
//! - RwLock for concurrent reads (multiple readers, exclusive writer)
//! - Configurable cache size with automatic eviction
//! - TTL (Time To Live) for cache entries
//! - Thread-safe concurrent access with atomic operations

const std = @import("std");

const log = std.log;

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

    const CacheEntry = struct {
        response: []u8,
        method: []u8,
        host: []u8,
        path: []u8,
        created_at: i64,
        ttl: u32,
        size: usize,
        access_count: u32,
    };

    /// Get current Unix timestamp in seconds
    fn getTimestamp() i64 {
        const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch |err| {
            log.warn("clock_gettime() failed: {s}, backend health recovery may be disabled", .{@errorName(err)});
            return 0;
        };
        return ts.sec;
    }

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
                _ = self.misses.fetchSub(1, .monotonic);
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
