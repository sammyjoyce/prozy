# Prozy Architecture Map

## Overview

Prozy is an enterprise-ready async TCP proxy built with Zig's async I/O system. This document maps out the complete architecture and request flow.

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CLIENT (TCP Connection)                              │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PROXY MAIN (std.Io.Threaded Runtime)                      │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  Listen Socket (127.0.0.1:8080)                                        │ │
│  │         │                                                               │ │
│  │         ▼                                                               │ │
│  │  Accept Connection                                                     │ │
│  │         │                                                               │ │
│  │         ▼                                                               │ │
│  │  Io.Group (Connection Pool) ──────► Spawn Async Task                  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│               ACCESS CONTROL & RATE LIMITING LAYER                           │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  1. Extract Client IP (IPv4/IPv6 with CRC32 hashing)                  │ │
│  │  2. Check Access Control (Allow/Deny Lists)                           │ │
│  │  3. Check Rate Limiter (Per-IP + Global Limits)                       │ │
│  │                                                                         │ │
│  │  ┌──────────────────┐          ┌──────────────────┐                   │ │
│  │  │ Access Control   │          │  Rate Limiter    │                   │ │
│  │  │ ├─ Allow List    │          │ ├─ Per-IP Count  │                   │ │
│  │  │ ├─ Deny List     │          │ ├─ Global Count  │                   │ │
│  │  │ └─ Default Policy│          │ └─ Max Limits    │                   │ │
│  │  └──────────────────┘          └──────────────────┘                   │ │
│  │                                                                         │ │
│  │  ✗ Denied/Rate Limited ──► Reject Connection ──► Cleanup              │ │
│  │  ✓ Allowed ──────────────────────────┐                                │ │
│  └──────────────────────────────────────┼────────────────────────────────┘ │
└───────────────────────────────────────────┼──────────────────────────────────┘
                                            │
                                            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                   REQUEST PROCESSING & CACHING LAYER                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  1. Buffer Initial Request (8KB) ◄─── Prevents Data Loss              │ │
│  │  2. Parse HTTP Request Line (Method + Path)                           │ │
│  │  3. Check if GET Request                                              │ │
│  │                                                                         │ │
│  │  ┌──────────────────────────────────────────────────────────┐         │ │
│  │  │           HTTP Cache (LRU with RwLock)                   │         │ │
│  │  │  ├─ Hash Key: Method + Path (Wyhash)                     │         │ │
│  │  │  ├─ O(1) Eviction (Doubly-Linked List)                   │         │ │
│  │  │  ├─ TTL Expiration (Unix Timestamp)                      │         │ │
│  │  │  ├─ Concurrent Reads (RwLock)                            │         │ │
│  │  │  └─ Stats: Hits, Misses, Hit Rate                        │         │ │
│  │  └──────────────────────────────────────────────────────────┘         │ │
│  │                                                                         │ │
│  │  GET + Cache Hit ──► Serve Cached Response ──► Client                 │ │
│  │  GET + Cache Miss ──► Continue to Load Balancer                       │ │
│  │  Non-GET ─────────► Continue to Load Balancer                         │ │
│  └────────────────────────────────────────┬───────────────────────────────┘ │
└───────────────────────────────────────────┼──────────────────────────────────┘
                                            │
                                            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                  LOAD BALANCING & BACKEND SELECTION                          │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  Load Balancer Strategies:                                            │ │
│  │  ├─ Round Robin          : Even distribution                          │ │
│  │  ├─ Weighted Round Robin : Weight-based traffic shaping               │ │
│  │  ├─ Least Connections    : Route to least loaded backend              │ │
│  │  ├─ Random              : Random selection for load distribution      │ │
│  │  └─ IP Hash             : Consistent hashing for session affinity     │ │
│  │                                                                         │ │
│  │  Backend Selection (Two-Pass Algorithm):                              │ │
│  │    Pass 1: Select from Healthy Backends                               │ │
│  │    Pass 2: If no healthy, check Retry Candidates                      │ │
│  │                                                                         │ │
│  │  ┌──────────────────────────────────────────────────────────┐         │ │
│  │  │              Backend Pool                                │         │ │
│  │  │  ┌──────────────────────────────────────────────────┐    │         │ │
│  │  │  │ Backend 1 (3003)                                 │    │         │ │
│  │  │  │ ├─ Health Status: Healthy/Unhealthy              │    │         │ │
│  │  │  │ ├─ Active Connections: 42                        │    │         │ │
│  │  │  │ ├─ Retry Count: 0                                │    │         │ │
│  │  │  │ ├─ Weight: 1                                     │    │         │ │
│  │  │  │ └─ Exponential Backoff: 5s → 10s → ... → 300s    │    │         │ │
│  │  │  └──────────────────────────────────────────────────┘    │         │ │
│  │  │  ┌──────────────────────────────────────────────────┐    │         │ │
│  │  │  │ Backend 2 (3004)                                 │    │         │ │
│  │  │  │ ├─ Health Status: Unhealthy                      │    │         │ │
│  │  │  │ ├─ Retry Count: 3                                │    │         │ │
│  │  │  │ ├─ Backoff Interval: 40s                         │    │         │ │
│  │  │  │ └─ Circuit Breaker: @ 5 retries                  │    │         │ │
│  │  │  └──────────────────────────────────────────────────┘    │         │ │
│  │  │  ┌──────────────────────────────────────────────────┐    │         │ │
│  │  │  │ Backend N (300X)                                 │    │         │ │
│  │  │  │ └─ ...                                           │    │         │ │
│  │  │  └──────────────────────────────────────────────────┘    │         │ │
│  │  └──────────────────────────────────────────────────────────┘         │ │
│  │                                                                         │ │
│  │  No Healthy Backend ──► Reject Connection ──► Cleanup                 │ │
│  │  Backend Selected ─────────────────────────┐                          │ │
│  └────────────────────────────────────────────┼──────────────────────────┘ │
└───────────────────────────────────────────────┼──────────────────────────────┘
                                                │
                                                ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                BACKEND CONNECTION & DATA TRANSFER LAYER                      │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  1. Connect to Backend (with timeout)                                 │ │
│  │     ├─ Success ─► Continue                                            │ │
│  │     └─ Failed ──► Mark Backend Unhealthy (incr retry count) ──► Cleanup│ │
│  │                                                                         │ │
│  │  2. Forward Buffered Request (8KB from cache check)                   │ │
│  │                                                                         │ │
│  │  3. Bidirectional Copy (io.concurrent + io.select)                    │ │
│  │     ┌───────────────────────────────────────────────────────┐         │ │
│  │     │  Client ──► Backend (Future C2B)                      │         │ │
│  │     │     └─ io.concurrent(copyPipe, job_c2b)               │         │ │
│  │     │                                                         │         │ │
│  │     │  Backend ──► Client (Future B2C)                      │         │ │
│  │     │     └─ io.concurrent(copyPipe, job_b2c)               │         │ │
│  │     │                                                         │         │ │
│  │     │  Wait for Both: io.select([future_c2b, future_b2c])   │         │ │
│  │     │                                                         │         │ │
│  │     │  ┌─────────────────────────────────────────────┐      │         │ │
│  │     │  │  Buffered Stream I/O (4KB buffers)          │      │         │ │
│  │     │  │  ├─ Client Reader  → Backend Writer         │      │         │ │
│  │     │  │  └─ Backend Reader → Client Writer          │      │         │ │
│  │     │  └─────────────────────────────────────────────┘      │         │ │
│  │     └───────────────────────────────────────────────────────┘         │ │
│  │                                                                         │ │
│  │  4. Record Statistics (Atomic Operations)                             │ │
│  │     ├─ Bytes Transferred: Client ↔ Backend                            │ │
│  │     └─ Connection Duration                                            │ │
│  │                                                                         │ │
│  │  5. Cleanup                                                            │ │
│  │     ├─ Close Client & Backend Connections                             │ │
│  │     ├─ Release Rate Limiter Slot                                      │ │
│  │     └─ Decrement Backend Connection Counter                           │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘

                                     │
                                     ▼
          ┌──────────────────────────────────────────────────────┐
          │          BACKEND SERVERS                             │
          │  ┌────────────┐  ┌────────────┐  ┌────────────┐     │
          │  │  Server 1  │  │  Server 2  │  │  Server N  │     │
          │  │  :3003     │  │  :3004     │  │  :300X     │     │
          │  └────────────┘  └────────────┘  └────────────┘     │
          └──────────────────────────────────────────────────────┘
```

## Component Details

### 1. Proxy Main (src/root.zig:1046-1361)
**Responsibilities:**
- Initialize async I/O runtime (`std.Io.Threaded`)
- Listen on configured port (default: 8080)
- Accept incoming TCP connections
- Spawn async tasks for each connection via `Io.Group`

**Key Fields:**
```zig
allocator: std.mem.Allocator
proxy_port: u16
backend_host: []const u8
backend_port: u16
stats: ProxyStats
access_control: ?AccessControl
rate_limiter: ?RateLimiter
http_inspector: HTTPInspector
http_cache: ?HTTPCache
load_balancer: ?LoadBalancer
```

### 2. Access Control (src/root.zig:86-144)
**Responsibilities:**
- IP-based filtering with allow/deny lists
- Default policy configuration (allow-all or deny-all)
- IPv4 and IPv6 support (IPv6 uses CRC32 hashing)

**Data Structures:**
```zig
allow_list: ?IpSet  // HashMap<u32, void>
deny_list: ?IpSet   // HashMap<u32, void>
default_policy: Policy  // .allow or .deny
```

**Algorithm:**
1. Check deny list first → reject if found
2. Check allow list → accept if found
3. If allow list exists but IP not in it → reject (whitelist mode)
4. Fall back to default policy

### 3. Rate Limiter (src/root.zig:146-201)
**Responsibilities:**
- Per-IP connection rate limiting
- Global connection throttling
- Thread-safe acquire/release with mutex

**Data Structures:**
```zig
connections_per_ip: HashMap<u32, u32>
max_per_ip: u32
max_global: u32
current_global: Atomic<u32>
mutex: std.Thread.Mutex
```

**Algorithm:**
1. Lock mutex (prevent race conditions)
2. Check global limit → reject if exceeded
3. Check per-IP limit → reject if exceeded
4. Acquire: increment counters
5. Release: decrement counters

### 4. HTTP Cache (src/root.zig:344-614)
**Responsibilities:**
- O(1) LRU cache for GET responses
- TTL-based expiration
- Concurrent read access with RwLock
- Automatic eviction when memory limit reached

**Data Structures:**
```zig
cache: HashMap<u64, *CacheNode>  // Key: Wyhash(method + path)
max_size: usize
current_size: Atomic<usize>
hits: Atomic<u64>
misses: Atomic<u64>
rwlock: std.Thread.RwLock
head: ?*CacheNode  // MRU (Most Recently Used)
tail: ?*CacheNode  // LRU (Least Recently Used)
```

**Cache Node (Doubly-Linked List):**
```zig
struct CacheNode {
    key: u64
    response: []u8
    method: []u8
    path: []u8
    created_at: i64  // Unix timestamp
    ttl: u32         // Time to live (seconds)
    size: usize
    access_count: u32
    prev: ?*CacheNode
    next: ?*CacheNode
}
```

**Algorithm:**
- **Get (src/root.zig:411-438):**
  1. Hash key: `Wyhash(method + path)`
  2. Lock (write lock - modifies LRU order)
  3. Check if expired → evict if TTL exceeded
  4. Move to front of LRU list (mark as MRU)
  5. Increment access count
  6. Return response (or null if miss/expired)

- **Put (src/root.zig:440-516):**
  1. Don't cache if response > 50% of max size
  2. Lock (write lock)
  3. Evict old entry if exists
  4. Evict LRU entries until space available
  5. Allocate and copy data (response, method, path)
  6. Create new node with current timestamp
  7. Add to front of LRU list (head)
  8. Update cache size

- **LRU Eviction (src/root.zig:566-589):**
  1. Remove from tail of linked list (LRU)
  2. Remove from hash map
  3. Decrement size counter
  4. Free allocated memory

### 5. Backend (src/root.zig:616-744)
**Responsibilities:**
- Backend server configuration
- Health status tracking
- Exponential backoff for recovery
- Active connection monitoring
- Circuit breaker pattern

**Data Structures:**
```zig
host: []const u8
port: u16
weight: u32
healthy: Atomic<bool>
active_connections: Atomic<u32>
unhealthy_since: Atomic<i64>  // Unix timestamp
retry_count: Atomic<u32>
max_retry_count: u32 = 5
base_recovery_interval_seconds: u32 = 5
max_recovery_interval_seconds: u32 = 300
```

**Exponential Backoff Algorithm (src/root.zig:669-694, 723-743):**
```
Formula: base * 2^retry_count (capped at max)

Timeline:
Retry 0: 5s   (5 * 2^0 = 5)
Retry 1: 10s  (5 * 2^1 = 10)
Retry 2: 20s  (5 * 2^2 = 20)
Retry 3: 40s  (5 * 2^3 = 40)
Retry 4: 80s  (5 * 2^4 = 80)
Retry 5: 160s (5 * 2^5 = 160)
Retry 6+: 300s (capped at max)

Circuit Breaker: max_retry_count = 5
```

**Health Management:**
- **Mark Unhealthy:** Record timestamp, increment retry count
- **Mark Healthy:** Reset timestamp and retry count to 0
- **Should Retry:** Check if backoff interval has passed AND retry count < max

### 6. Load Balancer (src/root.zig:746-1044)
**Responsibilities:**
- Traffic distribution across backends
- 5 selection strategies
- Two-pass selection (healthy first, retry candidates second)
- Backend health awareness

**Strategies:**

1. **Round Robin (src/root.zig:820-829):**
   - Even distribution across all backends
   - Atomic index increment for thread safety
   - Simple modulo arithmetic

2. **Weighted Round Robin (src/root.zig:831-879):**
   - Weight-based traffic shaping
   - Higher weight = more connections
   - Cycle through backends proportionally

3. **Least Connections (src/root.zig:881-949):**
   - Route to backend with fewest active connections
   - Load-aware selection
   - Prevents overloading single backend

4. **Random (src/root.zig:951-1001):**
   - Random backend selection
   - Good for load distribution
   - Stateless approach

5. **IP Hash (src/root.zig:1003-1044):**
   - Consistent hashing for session affinity
   - Same client IP → same backend
   - Hash IP address to select backend

**Two-Pass Selection Algorithm (src/root.zig:784-818):**
```
Pass 1: Select from healthy backends only
  └─ Use strategy-specific selector
  └─ Eligibility: backend.isHealthy() == true

Pass 2: If no healthy backend found, check retry candidates
  └─ Use same strategy-specific selector
  └─ Eligibility: backend.shouldRetry() == true
      └─ Checks exponential backoff interval
      └─ Checks circuit breaker (retry_count <= max)

Result: Selected backend or null (no healthy/retryable backends)
```

### 7. Request Processing Flow (src/root.zig:1363-1590)

**handleClientWithFeatures (src/root.zig:1363-1590):**

1. **Access Control:**
   - Extract client IP from socket address
   - Check IP against allow/deny lists
   - Reject if denied

2. **Rate Limiting:**
   - Try to acquire rate limit slot
   - Check both per-IP and global limits
   - Reject if exceeded

3. **Statistics:**
   - Record connection start
   - Increment active connections counter

4. **Request Buffering (8KB):**
   - Read initial request into buffer
   - Prevents data loss when cache checking
   - Critical fix: buffered data forwarded on cache miss

5. **HTTP Parsing:**
   - Parse request line: `GET /path HTTP/1.1`
   - Extract method and path
   - Check if GET request

6. **Cache Check (GET requests only):**
   - Hash key: method + path
   - Check cache for existing response
   - If HIT: serve cached response, end connection
   - If MISS: continue to backend

7. **Load Balancing:**
   - Select backend using configured strategy
   - Check backend health
   - Check retry eligibility (exponential backoff)
   - If no healthy backend: reject connection

8. **Backend Connection:**
   - Connect to selected backend with timeout
   - If FAILED: mark backend unhealthy, increment retry count
   - If SUCCESS: continue

9. **Forward Buffered Request:**
   - Write buffered 8KB request to backend
   - Prevents data loss from cache check step

10. **Bidirectional Copy:**
    - Spawn two concurrent tasks:
      - Client → Backend (Future C2B)
      - Backend → Client (Future B2C)
    - Use `io.concurrent()` for parallel execution
    - Use `io.select()` to wait for both
    - Record bytes transferred

11. **Cleanup:**
    - Close client and backend connections
    - Release rate limiter slot
    - Decrement backend connection counter
    - Record connection end

### 8. Bidirectional Copy (src/root.zig:1591-1730)

**copyBidirectional (src/root.zig:1591-1625):**
```zig
fn copyBidirectional(
    io: Io,
    client_reader: *Reader,
    backend_writer: *Writer,
    backend_reader: *Reader,
    client_writer: *Writer,
) void {
    // Create pipe jobs
    const job_c2b = PipeJob{ .reader = client_reader, .writer = backend_writer };
    const job_b2c = PipeJob{ .reader = backend_reader, .writer = client_writer };

    // Spawn concurrent tasks
    var future_c2b = io.concurrent(copyPipe, .{job_c2b}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            // Fallback: sequential copy
            sequentialCopy(job_c2b);
            sequentialCopy(job_b2c);
            return;
        },
    };

    var future_b2c = io.concurrent(copyPipe, .{job_b2c}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            // Cancel first future, fallback to sequential
            future_c2b.cancel();
            sequentialCopy(job_c2b);
            sequentialCopy(job_b2c);
            return;
        },
    };

    // Wait for both to complete
    _ = io.select(&[_]Io.Future{future_c2b, future_b2c});
}
```

**copyPipe (src/root.zig:1645-1673):**
- Buffered I/O with 4KB buffer
- Read from source, write to destination
- Loop until EOF or error
- Track total bytes transferred

### 9. Proxy Statistics (src/root.zig:28-84)

**Atomic Counters (Thread-Safe):**
```zig
active_connections: Atomic<u64>
total_connections: Atomic<u64>
total_bytes_client_to_backend: Atomic<u64>
total_bytes_backend_to_client: Atomic<u64>
total_errors: Atomic<u64>
backend_connect_failures: Atomic<u64>
```

**Operations:**
- `recordConnection()`: Increment active and total
- `recordConnectionEnd()`: Decrement active
- `recordBytesClientToBackend()`: Add bytes
- `recordBytesBackendToClient()`: Add bytes
- `recordError()`: Increment error counter
- `recordBackendFailure()`: Increment failure counter
- `getStats()`: Snapshot of all metrics

## Async I/O Patterns

### Io.Threaded Runtime
- Cross-platform thread pool
- Abstracts over io_uring (Linux), kqueue (BSD/macOS), IOCP (Windows)
- Created once at application startup
- Passed down through application like an allocator

### Structured Concurrency with Io.Group
```zig
var connection_group = Io.Group.init(io);
defer connection_group.deinit(io);

// Spawn async task for each connection
connection_group.async(io, handleClientWithFeatures, .{
    client_stream, io, backend_host, backend_port, ...
});

// Cancellation: connection_group.deinit() cancels all tasks
```

### Concurrent Operations with io.concurrent()
```zig
// Spawn concurrent task
var future = io.concurrent(myFunction, .{arg1, arg2}) catch |err| switch (err) {
    error.ConcurrencyUnavailable => {
        // Fallback to sequential execution
        myFunction(arg1, arg2);
        return;
    },
};

// Future can be:
// - Awaited: future.await()
// - Cancelled: future.cancel()
// - Selected with others: io.select(&[_]Future{future1, future2})
```

### Multi-Future Coordination with io.select()
```zig
// Wait for ANY of the futures to complete
const completed_index = io.select(&[_]Io.Future{future1, future2, future3});

// Wait for ALL futures to complete
_ = io.select(&[_]Io.Future{future1, future2});
```

## Key Design Decisions

### 1. Request Buffering for Cache Checking
**Problem:** Reading initial request to check cache consumes data from stream
**Solution:** 8KB buffer holds initial request, forwarded to backend on cache miss
**Location:** src/root.zig:1382, 1423-1466

### 2. Exponential Backoff for Health Recovery
**Problem:** Thundering herd when backends recover
**Solution:** Exponential backoff (5s → 300s) with circuit breaker
**Location:** src/root.zig:625-743

### 3. Two-Pass Backend Selection
**Problem:** All backends might be unhealthy
**Solution:** First try healthy, then try retry-eligible with backoff
**Location:** src/root.zig:784-818

### 4. RwLock for Cache Concurrency
**Problem:** Mutex serializes all cache reads
**Solution:** RwLock allows multiple concurrent readers
**Note:** Cache get() uses write lock (modifies LRU order)
**Location:** src/root.zig:384, 411-438

### 5. O(1) LRU Eviction
**Problem:** Finding LRU entry should be fast
**Solution:** Doubly-linked list with head=MRU, tail=LRU
**Location:** src/root.zig:346-357, 525-589

### 6. Atomic Statistics
**Problem:** Multiple threads updating stats concurrently
**Solution:** Atomic operations with monotonic ordering
**Location:** src/root.zig:29-84

## Performance Characteristics

| Aspect | Metric | Notes |
|--------|--------|-------|
| Concurrency | Unlimited | Limited by OS file descriptors |
| Memory per connection | ~16KB baseline | 4KB client + 4KB backend + 8KB request buffer |
| Cache memory | Configurable | 10MB default, scales to GB |
| Cache lookup | O(1) | Hash map + LRU linked list |
| LRU eviction | O(1) | Tail removal from linked list |
| Latency (cache hit) | <1ms | Direct memory response |
| Latency (cache miss) | <2ms | Buffering + forwarding |
| Backend recovery | Exponential | 5s → 10s → 20s → 40s → 80s → 160s → 300s |
| Load balancer overhead | O(N) | Two-pass selection, typically <100μs |

## File Organization

```
prozy/
├── src/
│   ├── main.zig              # Entry point, creates Io runtime
│   └── root.zig              # All proxy logic
│       ├── ProxyStats        (28-84)      # Statistics & monitoring
│       ├── AccessControl     (86-144)     # IP filtering
│       ├── RateLimiter       (146-201)    # Connection throttling
│       ├── HTTPInspector     (203-342)    # HTTP parsing
│       ├── HTTPCache         (344-614)    # LRU cache with TTL
│       ├── Backend           (616-744)    # Backend config & health
│       ├── LoadBalancer      (746-1044)   # Traffic routing
│       ├── Proxy             (1046-1361)  # Main proxy struct
│       ├── handleClient*     (1363-1590)  # Connection handling
│       ├── copyBidirectional (1591-1730)  # Async I/O copying
│       └── Tests             (1732+)      # 40+ unit tests
├── examples/
│   ├── async_io_demo.zig           # Async I/O capabilities demo
│   ├── full_features_demo.zig      # All proxy features showcase
│   ├── http_response_parsing_demo.zig # HTTP parsing utilities
│   └── configs/                    # Proxy configuration templates
│       ├── simple_proxy.zig
│       ├── caching_proxy.zig
│       ├── load_balanced_proxy.zig
│       ├── secure_proxy.zig
│       └── production_proxy.zig
├── tests/
│   ├── e2e_test.zig                 # Integration tests
│   └── test-server.ts               # Bun test server (port 3003)
└── build.zig                        # Build configuration
```

## Request Flow Summary

```
Client Connection
    │
    ▼
Listen & Accept (Io.Group)
    │
    ▼
Extract Client IP
    │
    ▼
Access Control Check ──────► Denied? ──► Reject
    │ Allowed
    ▼
Rate Limit Check ──────────► Exceeded? ──► Reject
    │ OK
    ▼
Record Connection Stats
    │
    ▼
Buffer Request (8KB)
    │
    ▼
Parse HTTP Request
    │
    ▼
GET Request? ──────► No ───────────────────────┐
    │ Yes                                       │
    ▼                                           │
Check Cache ────► Hit? ──► Serve & End         │
    │ Miss                                      │
    ▼                                           │
Select Backend ◄────────────────────────────────┘
    │
    ▼
Healthy Backend? ──────► No ──► Retry Eligible? ──► No ──► Reject
    │ Yes                            │ Yes
    ▼                                │
Connect to Backend ◄─────────────────┘
    │
    ▼
Success? ──────► No ──► Mark Unhealthy ──► Reject
    │ Yes
    ▼
Forward Buffered Request
    │
    ▼
Bidirectional Copy (io.concurrent + io.select)
    ├─ Client → Backend (Future C2B)
    └─ Backend → Client (Future B2C)
    │
    ▼
Record Stats (Bytes, Duration)
    │
    ▼
Cleanup (Close, Release Limits, Decrement Counters)
```

## Visualization

To generate visual diagrams from `prozy-architecture.dot`:

```bash
# Install GraphViz
sudo apt-get install graphviz  # Debian/Ubuntu
brew install graphviz           # macOS
choco install graphviz          # Windows

# Generate PNG
dot -Tpng prozy-architecture.dot -o prozy-architecture.png

# Generate SVG
dot -Tsvg prozy-architecture.dot -o prozy-architecture.svg

# Generate PDF
dot -Tpdf prozy-architecture.dot -o prozy-architecture.pdf
```

## References

- **CLAUDE.md**: Coding style guide and design principles
- **README.md**: Quick start and feature overview
- **src/root.zig**: Complete implementation with inline documentation
