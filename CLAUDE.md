# Prozy - Async TCP Proxy in Zig

Prozy is a demonstration of Zig's new async I/O capabilities, implementing a real TCP proxy using `std.Io.Threaded`, `io.concurrent()`, and `io.select()`.

## Project Overview

This project showcases:
- ✅ **True async I/O**: Using Zig's new `std.Io.Threaded` runtime
- ✅ **Concurrent connections**: `io.concurrent()` for parallel client handling  
- ✅ **Bidirectional proxying**: `io.select()` for duplex data flow
- ✅ **Buffered I/O**: Efficient stream readers/writers
- ✅ **Resource management**: Proper cleanup with defer statements
- ✅ **Cross-platform**: Works on Linux, macOS, and Windows

## Architecture

```
Client → Proxy (port 8080) → Backend Server (port 3003)
```

The proxy accepts TCP connections on port 8080 and forwards them to a backend server on port 3003, handling bidirectional data flow asynchronously.

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

# Run all tests
zig build test

# Run end-to-end integration test
zig build test_e2e
```

### Testing
```bash
# Unit tests (18 tests covering initialization, edge cases, API stability)
zig test src/root.zig

# Integration test (requires Bun test server)
zig build test_e2e

# Example demos
zig build async_demo_works
```

## Configuration

The proxy uses these default settings:
- **Listen port**: 8080
- **Listen host**: 127.0.0.1  
- **Backend host**: 127.0.0.1
- **Backend port**: 3003
- **Max connections**: Unlimited (except in tests)

## Implementation Details

### Core Components

1. **Proxy**: Main proxy struct with configuration and lifecycle management
2. **Io.Group**: Manages async client tasks and ensures proper cleanup
3. **handleClient**: Async function that handles individual client connections
4. **copyBidirectional**: Uses `io.concurrent()` and `io.select()` for duplex forwarding
5. **copyPipe**: Efficient buffered data copying with error handling

### Async Patterns

```zig
// Thread pool initialization
var threaded_io = std.Io.Threaded.init(allocator);
defer threaded_io.deinit();
const io = threaded_io.io();

// Concurrent client handling
connection_group.async(io, handleClient, .{
    client_stream, io, backend_host, backend_port, connect_timeout
});

// Bidirectional copying with io.select()
var future_c2b = io.concurrent(copyPipe, .{job_c2b}) catch |err| switch (err) {
    error.ConcurrencyUnavailable => { /* handle gracefully */ },
};
```

## Testing Strategy

### Unit Tests (18 tests)
- Proxy initialization with various configurations
- Edge cases (port 0, maximum ports, different hosts)
- API stability and method signatures
- Performance characteristics with multiple instances
- Real-world scenarios (web proxy, dev proxy, load balancer patterns)

### Integration Tests
- End-to-end HTTP proxying with Bun test server
- Multiple concurrent connections
- Error handling (backend unavailable, connection drops)
- Resource cleanup verification

### Example Applications
- `async_demo_works`: Demonstrates all async I/O capabilities
- `demo_complete`: Full proxy showcase with configuration
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

# Debug build
zig build -Doptimize=Debug

# Release build
zig build -Doptimize=ReleaseFast
```

## Known Limitations

1. **TCP only**: Currently supports TCP proxying (no UDP or HTTP-specific features)
2. **Simple forwarding**: No protocol inspection or request modification
3. **Memory usage**: Uses fixed-size buffers (4KB for connections, 8KB for copying)
4. **Error handling**: Basic error logging without sophisticated retry mechanisms

## Future Enhancements

- HTTP-aware proxying with header manipulation
- Dynamic backend configuration  
- Connection pooling and keep-alive
- Metrics and monitoring endpoints
- Unix domain socket support
- TLS termination

## License

This project is provided as a demonstration of Zig's async I/O capabilities.