# Prozy Architecture Documentation

This directory contains comprehensive architecture documentation for the Prozy TCP proxy.

## Files

### Visual Diagrams (GraphViz)

1. **`prozy-architecture.dot`** - Complete request flow diagram
   - Shows entire request lifecycle from client to backend
   - Includes all decision points, components, and data flows
   - Color-coded by component type and flow direction
   - Detailed annotations for key patterns

2. **`prozy-components.dot`** - Component relationship diagram
   - Simplified view of main architectural components
   - Shows dependencies and interactions
   - Focuses on structure rather than flow

### Documentation

3. **`ARCHITECTURE.md`** - Comprehensive architecture guide
   - Detailed component descriptions with code references
   - Request flow diagrams (ASCII art)
   - Algorithm explanations
   - Performance characteristics
   - Design decision rationale

## Generating Visual Diagrams

### Prerequisites

Install GraphViz on your system:

```bash
# Debian/Ubuntu
sudo apt-get install graphviz

# macOS (Homebrew)
brew install graphviz

# Windows (Chocolatey)
choco install graphviz

# Fedora/RHEL
sudo dnf install graphviz
```

### Generate Images

```bash
# Generate PNG images
dot -Tpng prozy-architecture.dot -o prozy-architecture.png
dot -Tpng prozy-components.dot -o prozy-components.png

# Generate SVG (scalable, better for web)
dot -Tsvg prozy-architecture.dot -o prozy-architecture.svg
dot -Tsvg prozy-components.dot -o prozy-components.svg

# Generate PDF (best for printing)
dot -Tpdf prozy-architecture.dot -o prozy-architecture.pdf
dot -Tpdf prozy-components.dot -o prozy-components.pdf

# Generate all formats
make diagrams  # If Makefile exists
```

### Online Rendering

If you don't have GraphViz installed, you can use online tools:

1. **GraphvizOnline**: https://dreampuf.github.io/GraphvizOnline/
   - Copy the `.dot` file contents
   - Paste into the editor
   - View/download rendered diagram

2. **Edotor**: https://edotor.net/
   - Upload `.dot` file or paste contents
   - Export as PNG/SVG/PDF

3. **Viz.js**: https://viz-js.com/
   - Paste `.dot` file contents
   - Download rendered image

## Architecture Overview

### High-Level Flow

```
Client → Proxy (8080) → Load Balancer → Backend Pool (3003, 3004, ...)
              ↓
        [Access Control]
        [Rate Limiter]
        [HTTP Cache]
        [Statistics]
```

### Key Components

| Component | Purpose | Key Features |
|-----------|---------|--------------|
| **Proxy Core** | Main proxy logic | Io as first-class parameter, std.Io.Threaded, Io.Group, async tasks |
| **Access Control** | IP filtering | Allow/deny lists, IPv4/IPv6 support |
| **Rate Limiter** | Connection throttling | Per-IP + global limits, thread-safe |
| **HTTP Cache** | Response caching | O(1) LRU, TTL, RwLock concurrency |
| **Load Balancer** | Traffic distribution | 5 strategies, health-aware |
| **Backend Pool** | Backend management | Health tracking, exponential backoff |
| **Proxy Stats** | Monitoring | Atomic counters, real-time metrics |

### Request Flow Stages

1. **Accept** - Listen on port 8080, spawn async task
2. **Security** - Check access control and rate limits
3. **Parse** - Buffer and parse HTTP request (8KB)
4. **Cache** - Check cache for GET requests (hit → serve, miss → continue)
5. **Select** - Choose backend via load balancing strategy
6. **Connect** - Connect to backend with health checking
7. **Forward** - Send buffered request to backend
8. **Copy** - Bidirectional async copy (io.concurrent + io.select)
9. **Monitor** - Record statistics (bytes, connections, errors)
10. **Cleanup** - Release resources, update counters

## Code References

All components are implemented in `src/root.zig`:

```
ProxyStats:       Lines 28-84      (Statistics)
AccessControl:    Lines 86-144     (IP filtering)
RateLimiter:      Lines 146-201    (Throttling)
HTTPInspector:    Lines 203-342    (Parsing)
HTTPCache:        Lines 344-614    (LRU cache)
Backend:          Lines 616-744    (Health management)
LoadBalancer:     Lines 746-1044   (Routing)
Proxy:            Lines 1046-1361  (Main struct)
handleClient*:    Lines 1363-1590  (Connection handling)
copyBidirectional: Lines 1591-1730 (Async I/O)
Tests:            Lines 1732+      (40+ unit tests)
```

## Performance Highlights

| Metric | Value | Notes |
|--------|-------|-------|
| Concurrency | Unlimited* | *Limited by OS file descriptors |
| Memory/connection | ~16KB | 4KB+4KB buffers + 8KB request buffer |
| Cache lookup | O(1) | Hash map + linked list |
| LRU eviction | O(1) | Tail removal |
| Cache hit latency | <1ms | Direct memory response |
| Cache miss latency | <2ms | Includes buffering |
| Backend recovery | 5s-300s | Exponential backoff |
| LB overhead | <100μs | Two-pass O(N) selection |

## Design Patterns

### 1. Structured Concurrency (Io.Group)
- Spawns async tasks for connections
- Automatic cancellation on group deinit
- Resource safety guarantees

### 2. Exponential Backoff
- Prevents thundering herd on recovery
- Formula: `base * 2^retry_count` (capped)
- Circuit breaker at 5 retries

### 3. Two-Pass Backend Selection
- Pass 1: Try healthy backends
- Pass 2: Try retry-eligible (backoff passed)
- Maximizes availability

### 4. Request Buffering
- 8KB buffer for initial request
- Enables cache checking without data loss
- Forwarded to backend on cache miss

### 5. O(1) LRU Cache
- Doubly-linked list for MRU/LRU tracking
- Hash map for O(1) lookup
- RwLock for concurrent reads

### 6. Atomic Statistics
- Lock-free counters with monotonic ordering
- Thread-safe concurrent updates
- Real-time metrics

### 7. Io as First-Class Parameter
- `Io` executor passed explicitly to enable flexible backend selection
- Four-level API hierarchy: `runWithIoOptions()` → `runWithIo()` → `run()` → `runWithDefaults()`
- Dependency injection for testing with mock Io implementations
- Follows Zig 0.16.x recommended async I/O patterns
- Decouples I/O strategy from application logic

## References

- **README.md** - Quick start guide and feature overview
- **CLAUDE.md** - Coding style guide and design principles
- **src/root.zig** - Complete implementation
- **examples/** - Demo applications showing features
- **tests/** - Integration and unit tests

## License

This documentation is part of the Prozy project and is provided as a demonstration of Zig's async I/O capabilities with enterprise-ready proxy features.
