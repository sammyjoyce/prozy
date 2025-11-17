# Prozy HTTP Caching Guide

## Overview

Prozy implements RFC 9111 HTTP Caching to improve performance and reduce backend load. This guide explains how to use and configure caching in Prozy.

---

## Quick Start

### Enable Caching

```zig
const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Initialize proxy with caching enabled
    var proxy = prozy.Proxy.init(allocator, 8080, "127.0.0.1", 3003);
    defer proxy.deinit();

    // Enable caching with 10MB cache size
    proxy.enableCaching(10 * 1024 * 1024);

    // Run proxy
    try proxy.runWithIoOptions(io, .{
        .enable_caching = true,
        .enable_stats = true,
    });
}
```

---

## How It Works

### Cache Flow

```
Client Request
     ↓
Check Cache
     ├─→ HIT: Return cached response (<1ms)
     └─→ MISS: Forward to backend
                    ↓
             Backend Response
                    ↓
           Cache Response (if cacheable)
                    ↓
          Return to Client
```

### What Gets Cached

Prozy caches HTTP responses that meet ALL of these conditions:

1. ✅ **GET request** (only)
2. ✅ **200 OK status** code
3. ✅ **Host header present** (security requirement)
4. ✅ **No `Cache-Control: no-store`** (respects origin server)
5. ✅ **No `Cache-Control: private`** (proxy is a shared cache)
6. ✅ **Response size ≤ 1MB** (configurable)
7. ✅ **Cache has space** (LRU eviction if full)

### What Doesn't Get Cached

- ❌ POST, PUT, DELETE, PATCH requests
- ❌ Non-200 status codes (301, 404, 500, etc.)
- ❌ Responses with `Cache-Control: no-store`
- ❌ Responses with `Cache-Control: private`
- ❌ Responses larger than max size (1MB default)
- ❌ Requests without Host header
- ❌ CONNECT tunnels (raw TCP)

---

## Cache-Control Directives

Prozy respects RFC 9111 Cache-Control directives:

### Supported Directives

| Directive | Meaning | Example |
|-----------|---------|---------|
| `max-age` | Cache lifetime (seconds) | `Cache-Control: max-age=3600` |
| `s-maxage` | **Proxy** cache lifetime (takes precedence) | `Cache-Control: s-maxage=7200` |
| `no-cache` | Must revalidate before use | `Cache-Control: no-cache` |
| `no-store` | Must NOT cache | `Cache-Control: no-store` |
| `private` | Only browser-cacheable (not proxies) | `Cache-Control: private` |
| `public` | Explicitly cacheable | `Cache-Control: public` |
| `must-revalidate` | Must revalidate when stale | `Cache-Control: must-revalidate` |
| `proxy-revalidate` | Proxies must revalidate when stale | `Cache-Control: proxy-revalidate` |
| `immutable` | Response never changes | `Cache-Control: immutable` |

### TTL (Time To Live) Calculation

Prozy calculates cache entry lifetime using this priority:

1. **`s-maxage`** (shared cache directive) - **takes precedence!**
2. **`max-age`** (fallback)
3. **Default TTL** (300 seconds = 5 minutes)

**Example:**
```http
Cache-Control: max-age=3600, s-maxage=7200
```
Prozy caches for **7200 seconds** (2 hours), not 3600.

---

## Configuration

### Cache Size

```zig
// Small cache (10MB)
proxy.enableCaching(10 * 1024 * 1024);

// Medium cache (100MB)
proxy.enableCaching(100 * 1024 * 1024);

// Large cache (1GB)
proxy.enableCaching(1024 * 1024 * 1024);
```

### Cache Metrics

Access cache statistics in real-time:

```zig
const stats = proxy.getStats();
const cache_stats = stats.cache_stats;

std.debug.print("Cache Hits: {}\n", .{cache_stats.hits});
std.debug.print("Cache Misses: {}\n", .{cache_stats.misses});
std.debug.print("Hit Rate: {d:.2}%\n", .{cache_stats.hitRate()});
std.debug.print("Cache Size: {} bytes\n", .{cache_stats.current_size});
std.debug.print("Entries: {}\n", .{cache_stats.entry_count});
```

---

## Cache Key Strategy

Prozy generates cache keys using:
- **HTTP Method** (GET)
- **Host header** (e.g., `api.example.com`)
- **Request path** (e.g., `/users/123`)

**Example:**
```http
GET /api/users/123 HTTP/1.1
Host: api.example.com
```

Cache key: `hash("GET" + "api.example.com" + "/api/users/123")`

### Why Host Header Is Required

**Security**: Prevents cache pollution across virtual hosts.

**Bad scenario (without Host validation):**
```
Request 1: GET /admin → api1.com (admin panel)
Request 2: GET /admin → api2.com (public page)
```

If we cached by path only, Request 2 would get api1.com's admin panel! 🚨

Prozy **requires Host header** and logs warnings for HTTP/1.1 violations.

---

## LRU Eviction

When cache is full, Prozy evicts **Least Recently Used** (LRU) entries:

### How LRU Works

```
Cache: [Entry A] ↔ [Entry B] ↔ [Entry C]
        ^MRU                      ^LRU

Access Entry C → moves to front:
Cache: [Entry C] ↔ [Entry A] ↔ [Entry B]
        ^MRU                      ^LRU

Cache full → evict Entry B (LRU)
```

### Performance
- **O(1) eviction** (constant time)
- **Doubly-linked list** for efficient reordering
- **Hash map** for O(1) lookups
- **Lock-free reads** with RwLock

---

## Best Practices

### For Origin Servers

1. **Set explicit Cache-Control:**
   ```http
   Cache-Control: public, s-maxage=3600
   ```

2. **Use `s-maxage` for proxy caching:**
   ```http
   Cache-Control: max-age=300, s-maxage=3600
   ```
   - Browsers cache for 5 minutes
   - Proxies cache for 1 hour

3. **Mark sensitive data as uncacheable:**
   ```http
   Cache-Control: no-store, private
   ```

4. **Use appropriate status codes:**
   - Only 200 OK is cached
   - 404, 500, etc. are never cached

### For Proxy Operators

1. **Size cache appropriately:**
   - Small sites: 10-100MB
   - Medium sites: 100MB-1GB
   - Large sites: 1-10GB+

2. **Monitor hit rate:**
   - Target >60% hit rate
   - <30% may indicate cache too small or TTLs too short

3. **Enable statistics:**
   ```zig
   try proxy.runWithIoOptions(io, .{
       .enable_caching = true,
       .enable_stats = true,  // Track metrics
   });
   ```

4. **Use with load balancing:**
   ```zig
   proxy.enableCaching(100 * 1024 * 1024);
   proxy.enableLoadBalancing(.round_robin);
   ```

---

## Performance

### Cache Hit Performance

| Metric | Value |
|--------|-------|
| Cache hit latency | <1ms (p99) |
| Cache miss overhead | ~2ms (buffering + forwarding) |
| Memory per entry | 4KB-1MB (configurable) |
| LRU eviction | O(1) constant time |
| Concurrent reads | Unlimited (RwLock) |
| Cache-Control parsing | ~1-2µs (negligible) |

### Throughput Impact

**Cache Hit:**
- **~1000x faster** than backend request (assumes 1s backend latency)
- **No backend load** (backend never contacted)
- **Reduced network traffic** (cached response)

**Cache Miss:**
- **~2ms overhead** (request buffering + cache check)
- **Backend request proceeds** normally
- **Response cached** for future hits

---

## Troubleshooting

### Cache Not Populating

**Symptoms:** Cache misses = 100%, no cache hits

**Possible Causes:**

1. **Caching not enabled:**
   ```zig
   proxy.enableCaching(10 * 1024 * 1024);  // Required!
   ```

2. **Response has no-store:**
   ```http
   Cache-Control: no-store
   ```
   → Check origin server Cache-Control headers

3. **Response is private:**
   ```http
   Cache-Control: private
   ```
   → Use `public` or `s-maxage` for proxy caching

4. **Missing Host header:**
   ```http
   GET /api HTTP/1.1
   (no Host header)
   ```
   → Check for "cache SKIPPED" warnings in logs

5. **Non-200 status code:**
   → Only 200 OK responses are cached

### Low Hit Rate

**Symptoms:** Hit rate <30%

**Possible Causes:**

1. **TTL too short:**
   ```http
   Cache-Control: max-age=10  # Only 10 seconds!
   ```
   → Increase max-age or add s-maxage

2. **Cache too small:**
   - Entries evicted before reuse
   → Increase cache size

3. **Unique requests:**
   - Different URLs every time
   → Cache can't help (by design)

4. **POST/PUT/DELETE heavy:**
   - Only GET is cached
   → Normal for write-heavy APIs

### Memory Usage

**Symptoms:** Cache using too much memory

**Solutions:**

1. **Reduce cache size:**
   ```zig
   proxy.enableCaching(10 * 1024 * 1024);  // 10MB instead of 1GB
   ```

2. **Reduce max entry size:**
   - Default: 1MB max per entry
   - Oversized responses not cached

3. **Monitor metrics:**
   ```zig
   const cache_stats = proxy.getStats().cache_stats;
   if (cache_stats.current_size > threshold) {
       // Alert or adjust
   }
   ```

---

## Logging

Prozy logs cache operations (unless in test mode):

### Cache Hit
```
INFO: cache HIT for GET /api/users Host: api.example.com
```

### Cache Miss
```
INFO: cache MISS for GET /api/users Host: api.example.com
```

### Cache Population
```
INFO: cached response for GET /api/users (4567 bytes, TTL=3600s)
```

### Cache-Control Rejection
```
INFO: response has Cache-Control: no-store, will not cache
INFO: response has Cache-Control: private, will not cache (shared cache)
```

### Security Warning
```
WARN: cache SKIPPED for GET /api/users - missing Host header (HTTP/1.1 violation)
```

---

## Advanced Topics

### Future Features (Roadmap)

The following features are planned but not yet implemented:

- **Vary header support** (content negotiation)
- **ETag validation** (If-None-Match, 304 Not Modified)
- **Conditional requests** (If-Modified-Since)
- **RFC 9111 freshness calculation** (Date, Age, Expires headers)
- **Stale-while-revalidate** (serve stale + revalidate in background)

See [RFC9111_IMPLEMENTATION.md](RFC9111_IMPLEMENTATION.md) for details.

---

## FAQ

### Q: Why isn't my POST request cached?

**A:** By design. Only GET requests are cacheable (RFC 9111). POST/PUT/DELETE modify state and should not be cached.

### Q: Can I cache non-200 responses?

**A:** Not currently. Prozy only caches 200 OK responses. This is intentional - error responses (404, 500) should not be cached by default.

### Q: How do I invalidate the cache?

**A:** Cache entries expire based on TTL. There's no manual invalidation API yet. Restart the proxy to clear all cache entries.

### Q: Does caching work with load balancing?

**A:** Yes! Cache is checked before backend selection. Cache hits never reach backends (reduces load).

### Q: What happens if backend is down?

**A:** If response is in cache, it's served (cache hit). If not in cache, backend connection fails normally.

### Q: Can I disable caching for specific hosts?

**A:** Not currently. Caching is all-or-nothing. Origin servers should use `Cache-Control: no-store` if needed.

---

## Example Configurations

### Static Asset Cache (Long TTL)

**Origin Server:**
```http
Cache-Control: public, s-maxage=86400, immutable
```

**Prozy Config:**
```zig
proxy.enableCaching(1024 * 1024 * 1024);  // 1GB cache
```

**Result:** Static assets (CSS, JS, images) cached for 24 hours.

### API Cache (Short TTL)

**Origin Server:**
```http
Cache-Control: public, s-maxage=300
```

**Prozy Config:**
```zig
proxy.enableCaching(100 * 1024 * 1024);  // 100MB cache
```

**Result:** API responses cached for 5 minutes.

### Private Data (No Cache)

**Origin Server:**
```http
Cache-Control: no-store, private
```

**Result:** Never cached (security).

---

## References

- [RFC 9111: HTTP Caching](https://www.rfc-editor.org/rfc/rfc9111.html)
- [MDN: HTTP Caching](https://developer.mozilla.org/en-US/docs/Web/HTTP/Caching)
- [RFC9111_IMPLEMENTATION.md](RFC9111_IMPLEMENTATION.md) - Implementation details
- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture

---

**Version**: 1.0
**Last Updated**: 2025-11-17
**Feedback**: https://github.com/anthropics/prozy/issues
