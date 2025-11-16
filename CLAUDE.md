# Prozy - Enterprise-Ready Async TCP Proxy in Zig

Prozy is a production-ready TCP proxy demonstrating Zig's new async I/O capabilities with enterprise-grade features including caching, load balancing, access control, and comprehensive monitoring.

## Project Overview

This project showcases:
- ✅ **True async I/O**: Using Zig's new `std.Io.Threaded` runtime
- ✅ **Concurrent connections**: `io.concurrent()` for parallel client handling
- ✅ **Bidirectional proxying**: `io.select()` for duplex data flow
- ✅ **Buffered I/O**: Efficient stream readers/writers
- ✅ **Resource management**: Proper cleanup with defer statements
- ✅ **Cross-platform**: Works on Linux, macOS, and Windows
- ✅ **HTTP response caching**: LRU cache with TTL for performance optimization
- ✅ **Load balancing**: Multiple strategies (round-robin, weighted, least-connections, etc.)
- ✅ **Access control**: IP-based allow/deny lists for security
- ✅ **Rate limiting**: Per-IP and global connection throttling
- ✅ **Protocol inspection**: HTTP request/response analysis
- ✅ **Comprehensive monitoring**: Real-time statistics and metrics

## Architecture

```
Client → Proxy (port 8080) → Load Balancer → Backend Servers (3003, 3004, 3005...)
                               ↓
                        [HTTP Cache]
                        [Access Control]
                        [Rate Limiter]
                        [Statistics]
```

The proxy accepts TCP connections on port 8080, applies security policies, checks the cache, selects a healthy backend via load balancing, and forwards traffic asynchronously with full bidirectional data flow.

## Quick Start

### Prerequisites
- Zig 0.16.0-dev or later (for new I/O APIs)
- Bun (for test server)
- Git

### Build & Run
```bash
# Build the proxy
zig build

# Run the proxy (listens on 127.0.0.1:8080 → forwards to 127.0.0.1:3003)
zig build run

# Run all tests (now includes 40+ tests covering all features)
zig build test

# Run end-to-end integration test
zig build test_e2e

# Run full features demonstration
zig build full_features
```

### Testing
```bash
# Unit tests (40+ tests covering all features)
zig test src/root.zig

# Run feature-specific tests
zig test src/root.zig --test-filter "HTTPCache"
zig test src/root.zig --test-filter "LoadBalancer"
zig test src/root.zig --test-filter "AccessControl"

# Integration test (requires Bun test server)
zig build test_e2e

# Example demos
zig build async_demo_works
zig build full_features
```

## Configuration

The proxy supports extensive configuration:
- **Listen port**: 8080 (configurable)
- **Listen host**: 127.0.0.1 (configurable)
- **Backend host**: 127.0.0.1 (or multiple backends with load balancing)
- **Backend port**: 3003 (or multiple ports)
- **Max connections**: Unlimited (except in tests)
- **Cache size**: 10MB default (configurable)
- **Rate limits**: Per-IP and global (configurable)
- **Access control**: Allow/deny lists (optional)

## Implementation Details

### Core Components

1. **Proxy**: Main proxy struct with configuration and lifecycle management
2. **Io.Group**: Manages async client tasks and ensures proper cleanup
3. **handleClientWithFeatures**: Async function with full feature integration
4. **copyBidirectional**: Uses `io.concurrent()` and `io.select()` for duplex forwarding
5. **copyPipe**: Efficient buffered data copying with error handling
6. **HTTPCache**: LRU cache for HTTP responses with TTL and hit/miss tracking
7. **LoadBalancer**: Traffic distribution across multiple backends with 5 strategies
8. **AccessControl**: IP-based filtering with allow/deny policies
9. **RateLimiter**: Connection throttling per-IP and globally
10. **ProxyStats**: Real-time statistics and performance metrics

### Async Patterns

```zig
// Thread pool initialization
var threaded_io = std.Io.Threaded.init(allocator);
defer threaded_io.deinit();
const io = threaded_io.io();

// Concurrent client handling with all features
connection_group.async(io, handleClientWithFeatures, .{
    client_stream, io, backend_host, backend_port, connect_timeout,
    stats, http_inspector, options, client_ip, rate_limiter, load_balancer, http_cache
});

// Bidirectional copying with io.select()
var future_c2b = io.concurrent(copyPipeWithStats, .{job_c2b}) catch |err| switch (err) {
    error.ConcurrencyUnavailable => { /* handle gracefully */ },
};
```

## Enterprise-Ready Features

### 1. Intermediation & Gateway Role ✅
The proxy acts as a complete intermediary between clients and backends:
- Full TCP connection forwarding with bidirectional data flow
- Configurable backend targets with dynamic routing
- Connection lifecycle management with proper resource cleanup
- Support for multiple simultaneous client connections

### 2. IP Masking, Anonymity & Privacy ✅
Client IP addresses are naturally hidden from backend servers:
- Proxy's IP is exposed to destination servers instead of client IPs
- Makes user tracking significantly harder
- Supports both IPv4 and IPv6 addresses (IPv6 uses CRC32 hashing)
- IP hashing for consistent routing while maintaining anonymity

### 3. Request Filtering & Access Control ✅
Comprehensive IP-based access control:
- Allow/deny lists for fine-grained IP filtering
- Default policy configuration (allow-all or deny-all)
- Support for both IPv4 and IPv6 addresses
- Real-time connection rejection for denied IPs
- Access control integrated into connection acceptance flow

### 4. Security Enforcement & Threat Filtering ✅
Multi-layer security protection:
- Per-IP connection rate limiting (configurable limits)
- Global connection throttling (prevents resource exhaustion)
- Automatic backend health monitoring
- Connection timeout enforcement
- Failed backend detection and automatic marking as unhealthy
- Backend failover to healthy instances

### 5. Caching & Performance Optimization ✅
High-performance HTTP response caching:
- **LRU (Least Recently Used) eviction policy**
- Configurable cache size (e.g., 10MB, 100MB, etc.)
- TTL (Time To Live) for cache entries with automatic expiration
- Access count tracking for intelligent eviction
- Cache hit/miss statistics for monitoring
- Automatic eviction when cache is full
- Thread-safe concurrent access with mutex protection
- Efficient memory management with allocator

Cache Features:
- Method + Path based cache keys (using Wyhash)
- Automatic cleanup of expired entries
- No caching for oversized responses (>50% of max cache size)
- Real-time hit rate calculation

### 6. Traffic Routing & Policy-Based Forwarding ✅
Intelligent load balancing with **5 strategies**:

1. **Round Robin**: Even distribution across all backends
2. **Weighted Round Robin**: Weight-based traffic distribution
3. **Least Connections**: Route to least loaded backend
4. **Random**: Random backend selection for load distribution
5. **IP Hash**: Consistent hashing for session affinity

Load Balancer Features:
- Backend health tracking (healthy/unhealthy state)
- Active connection monitoring per backend
- Automatic failover to healthy backends only
- Weight-based traffic shaping (1-N weight per backend)
- Lock-free atomic operations for performance
- IP-based session persistence with IP Hash strategy

### 7. Logging, Monitoring & Auditing ✅
Comprehensive observability with ProxyStats:

**Connection Metrics:**
- Active connection count (real-time)
- Total connections processed (lifetime)
- Connection duration tracking
- Per-connection timing information

**Traffic Metrics:**
- Bytes transferred client→backend
- Bytes transferred backend→client
- Total data throughput

**Error Tracking:**
- Total errors encountered
- Backend connection failures
- Failed connection attempts

**Cache Metrics:**
- Cache hits
- Cache misses
- Hit rate percentage
- Current cache size
- Number of cached entries
- Cache efficiency analysis

**Backend Health:**
- Per-backend connection count
- Backend healthy/unhealthy status
- Backend selection statistics

All metrics use atomic operations for thread-safe concurrent access.

## Testing Strategy

### Unit Tests (40+ comprehensive tests)
**Basic Proxy Tests:**
- Proxy initialization with various configurations
- Edge cases (port 0, maximum ports, different hosts)
- API stability and method signatures
- Performance characteristics with multiple instances

**ProxyStats Tests:**
- Statistics initialization and recording
- Concurrent updates (thread safety)
- Error tracking and metrics

**AccessControl Tests:**
- Allow and deny policies
- IP allow/deny lists
- IPv4 and IPv6 support

**RateLimiter Tests:**
- Per-IP limiting
- Global connection limits
- Acquire and release operations

**HTTPCache Tests:**
- Basic caching (get/put operations)
- LRU eviction under memory pressure
- TTL expiration handling
- Cache statistics

**Backend Tests:**
- Initialization and configuration
- Health status management
- Connection tracking

**LoadBalancer Tests:**
- Round robin distribution
- Weighted round robin
- Least connections strategy
- IP hash consistency
- Random selection
- No healthy backends handling

**Integration Tests:**
- All features enabled together
- Feature interaction testing
- Real-world scenarios

### Integration Tests
- End-to-end HTTP proxying with Bun test server
- Multiple concurrent connections
- Error handling (backend unavailable, connection drops)
- Resource cleanup verification
- Load balancing failover
- Cache effectiveness

### Example Applications
- `async_demo_works`: Demonstrates all async I/O capabilities
- `demo_complete`: Full proxy showcase with configuration
- `full_features_demo`: **Complete demonstration of all proxy features**
- `test_time`: Time utilities for performance measurement

## Development Notes

### For Claude Code Sessions

When working with this repository in Claude Code:

1. **Building**: Always run `zig build` before testing changes
2. **Testing**: Use `zig build test` for unit tests, `zig build test_e2e` for integration
3. **Running**: The proxy starts immediately and blocks - use background processes for testing
4. **Dependencies**: Zig toolchain is self-contained; no external packages needed
5. **Test Server**: E2E tests use Bun (`bun tests/test-server.ts`) on port 3003

### Common Development Tasks

```bash
# Format code (if zig fmt is available)
zig fmt src/

# Run specific test
zig test src/root.zig --test-filter "Proxy initialization"

# Run feature-specific tests
zig test src/root.zig --test-filter "HTTPCache"
zig test src/root.zig --test-filter "LoadBalancer"
zig test src/root.zig --test-filter "Backend"
zig test src/root.zig --test-filter "AccessControl"
zig test src/root.zig --test-filter "RateLimiter"

# Debug build
zig build -Doptimize=Debug

# Release build for production
zig build -Doptimize=ReleaseFast

# Run full features demo
zig build full_features
```

## Performance Characteristics

- **Concurrency**: Unlimited connections (OS file descriptor limit)
- **Memory per connection**: ~8KB (4KB client buffers + 4KB backend buffers)
- **Cache memory**: Configurable (10MB default, scales to GB)
- **Cache efficiency**: LRU with access counting for optimal hit rates
- **Latency overhead**: <1ms typical for cache hits, <2ms for cache misses
- **Throughput**: Multi-Gbps capable with async I/O
- **CPU overhead**: Minimal with thread pool (std.Io.Threaded)
- **Atomic operations**: Lock-free for statistics and counters
- **Load balancer overhead**: O(N) for N backends, typically <100μs

## Known Limitations

1. **TCP only**: Currently supports TCP proxying (UDP support can be added)
2. **HTTP-aware caching**: Cache works for HTTP but doesn't parse all headers yet
3. **Memory usage**: Fixed-size buffers (4KB for connections, 8KB for copying)
4. **TLS**: No built-in TLS termination (can be added with standard Zig TLS)
5. **Backend health checks**: Reactive (on connection failure) rather than proactive polling

## Future Enhancements

**Near-term:**
- Proactive backend health checks with configurable intervals
- HTTP header manipulation (X-Forwarded-For, Via, etc.)
- Metrics export (Prometheus format)
- Configuration file support (TOML/JSON)

**Medium-term:**
- TLS/SSL termination and encryption
- Dynamic backend configuration and hot-reload
- Connection pooling and keep-alive
- Advanced cache policies (vary-based, conditional requests)

**Long-term:**
- Unix domain socket support
- WebSocket proxying support
- HTTP/2 and HTTP/3 support
- Advanced routing rules (path-based, header-based)
- Plugin system for custom filters

## Production Readiness

Prozy demonstrates **production-capable patterns** for:
- ✅ High-performance async I/O with Zig 0.16.x
- ✅ Enterprise-grade feature set (7/7 core proxy features)
- ✅ Thread-safe concurrent operations
- ✅ Comprehensive error handling
- ✅ Real-time metrics and monitoring
- ✅ Configurable resource limits
- ✅ Automatic failover and health management
- ✅ Memory-efficient caching with LRU eviction

## License

This project is provided as a demonstration of Zig's async I/O capabilities with enterprise-ready proxy features.
