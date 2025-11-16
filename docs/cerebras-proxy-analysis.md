# Cerebras-Proxy Analysis: Required Prozy Capabilities

## Executive Summary

The cerebras-proxy is a **Layer 7 HTTP application proxy** with intelligent API key management. Unlike Prozy's current TCP-level forwarding, cerebras-proxy requires deep HTTP protocol awareness, stateful request/response modification, and sophisticated error-driven key rotation.

---

## Core Architecture Differences

### Current Prozy
- **Layer 4 (TCP)**: Stream forwarding with bidirectional copying
- **Stateless routing**: Load balancer selects backends without request inspection
- **No modification**: Data passes through unchanged
- **Simple caching**: Based on HTTP method + host + path

### Cerebras-Proxy Style
- **Layer 7 (HTTP)**: Full request/response parsing and modification
- **Stateful key management**: Sticky sessions with error-driven rotation
- **Active modification**: JSON body manipulation, header injection
- **Semantic understanding**: HTTP status codes drive control flow

---

## Required New Capabilities

### 1. HTTP Protocol Parser & Generator

**What it needs:**
```
HTTP Request:
├── Request Line: "POST /chat/completions HTTP/1.1"
├── Headers: Key-Value pairs (Host, Content-Type, etc.)
├── Body: Raw bytes (often JSON)
└── Parsing capabilities:
    ├── Extract method, path, version
    ├── Parse all headers into hashmap
    ├── Read body (handle Content-Length/chunked)
    └── Reconstruct modified request

HTTP Response:
├── Status Line: "HTTP/1.1 200 OK"
├── Headers: Key-Value pairs
├── Body: Raw bytes
└── Status code extraction for control flow
```

**Implementation needs:**
- HTTP/1.1 request parser (method, path, headers, body)
- HTTP/1.1 response parser (status code, headers, body)
- Header manipulation (add/remove/modify)
- Request/response serialization back to wire format
- Content-Length recalculation after body modification

**Prozy impact:**
- Currently operates on raw TCP streams
- Would need `HTTPRequest` and `HTTPResponse` structs
- Parser must handle chunked encoding, keep-alive, etc.

---

### 2. JSON Request/Response Modification

**What cerebras-proxy does:**

```python
# Reads JSON request body
request_data = json.loads(request_body)

# Modifies the structure
request_data['messages'].append({
    "role": "tool",
    "tool_call_id": "call_123",
    "content": "failed"
})

# Serializes back
modified_body = json.dumps(request_data).encode('utf-8')

# Updates Content-Length header
headers["Content-Length"] = str(len(modified_body))
```

**Implementation needs:**
- JSON parser (zig has `std.json`)
- JSON serializer with compact formatting
- Deep copy of JSON structures for modification
- Validation that modifications produce valid JSON
- Memory management for dynamic JSON objects

**Prozy impact:**
- Current cache only reads request path, doesn't parse body
- Would need JSON parsing infrastructure
- Memory allocations for dynamic JSON modification

---

### 3. Stateful API Key Manager

**Core state structure:**

```zig
const KeyState = struct {
    key: []const u8,              // The actual API key
    name: []const u8,             // Human-readable name
    rate_limited_until: i64,      // Unix timestamp
    error_count: std.atomic.Value(u32),

    fn isAvailable(self: *const KeyState) bool {
        const now = std.time.timestamp();
        return now >= self.rate_limited_until;
    }
};

const ApiKeyManager = struct {
    key_states: []KeyState,
    current_index: std.atomic.Value(usize),
    lock: std.Thread.Mutex,
    cooldown_seconds: u32,

    // STICKY KEY SELECTION (not round-robin!)
    fn getCurrentKey(self: *ApiKeyManager) ![]const u8 {
        // 1. Try current key
        // 2. If rate-limited, find next available
        // 3. If ALL rate-limited, WAIT for soonest
        // 4. Return key (never fails)
    }

    // ERROR-DRIVEN ROTATION
    fn markKeyRateLimited(self: *ApiKeyManager, api_key: []const u8) !void {
        // 1. Find key by value
        // 2. Set rate_limited_until = now + cooldown
        // 3. Increment error_count
        // 4. Rotate to next index
    }
};
```

**Key differences from Prozy's LoadBalancer:**

| Feature | Prozy LoadBalancer | Cerebras ApiKeyManager |
|---------|-------------------|------------------------|
| Selection | Algorithm-based (RR, LC, etc.) | Sticky until error |
| Trigger | Every request | Only on 429/500 errors |
| State | Connection counts | Rate limit timestamps |
| Waiting | Fail if no healthy backend | **Wait for next available** |
| Recovery | Exponential backoff on connection | Fixed cooldown on HTTP 429 |

**Implementation needs:**
- Per-key timestamp tracking
- Async sleep/wait when all keys unavailable
- Thread-safe key rotation
- Find "soonest available" key algorithm

---

### 4. HTTP Status Code-Driven Control Flow

**Cerebras-proxy retry logic:**

```python
for attempt in range(max_retries):
    api_key = await key_manager.get_current_key()  # May wait!

    response = await forward_request(api_key)

    if response.status == 429:  # Rate limited
        await key_manager.mark_key_rate_limited(api_key)
        continue  # Retry with next key

    if response.status == 500:  # Server error
        await key_manager.mark_key_rate_limited(api_key)
        continue  # Retry with next key

    if response.status < 400:  # Success
        await key_manager.mark_key_success(api_key)

    return response  # Return (don't retry 4xx client errors)
```

**Implementation needs:**
- Parse HTTP response before returning to client
- Match status code against retry criteria
- Retry loop with key rotation
- Max retries = `key_count * 2`
- Different handling for 2xx, 4xx, 5xx

**Prozy impact:**
- Current `copyBidirectional` is blind TCP forwarding
- Would need to buffer and parse backend response
- Make retry decision before sending to client
- Can't stream response until we know status code

---

### 5. Request/Response Logging Infrastructure

**Cerebras-proxy log structure:**

```json
{
  "timestamp": "2025-11-16T14:30:22.123456",
  "request_id": "abc123de",
  "request": {
    "method": "POST",
    "path": "chat/completions",
    "headers": {
      "Content-Type": "application/json",
      "Authorization": "[REDACTED]"
    },
    "body": {
      "model": "llama3.1-70b",
      "messages": [...]
    }
  },
  "response": {
    "status": 200,
    "headers": {"Content-Type": "application/json"},
    "body": {"id": "chat-...", "choices": [...]}
  },
  "duration_ms": 1234.56
}
```

**Implementation needs:**
- Generate unique request IDs (UUID)
- Timestamp tracking (start/end)
- Duration calculation
- Directory organization by date (`logs/2025-11-16/`)
- JSON serialization of logs
- Header redaction (Authorization)
- Binary data handling (base64 encoding)
- Async file I/O

**Prozy impact:**
- Current logging is minimal (stdout only)
- Would need persistent log storage
- Privacy considerations (redacting sensitive data)
- Disk I/O overhead

---

### 6. Status Monitoring Endpoint

**Internal endpoint handling:**

```zig
// In proxy handler:
if (std.mem.eql(u8, request.path, "/_status")) {
    return handleStatusEndpoint();
}

fn handleStatusEndpoint() !HTTPResponse {
    const status = try api_key_manager.getStatus();
    const json_body = try std.json.stringify(status, .{});

    return HTTPResponse{
        .status = 200,
        .headers = &[_]Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = json_body,
    };
}
```

**Status response structure:**

```json
{
  "keys": [
    {
      "name": "key1",
      "available": true,
      "rate_limited_for": 0.0,
      "error_count": 0
    },
    {
      "name": "key2",
      "available": false,
      "rate_limited_for": 45.2,
      "error_count": 3
    }
  ],
  "current_key": "key1"
}
```

**Implementation needs:**
- Route internal endpoints (don't forward to backend)
- Generate JSON responses
- Calculate time remaining (`rate_limited_until - now`)
- Thread-safe state reading

---

## Feature Comparison Matrix

| Feature | Current Prozy | Cerebras-Proxy | Complexity |
|---------|---------------|----------------|------------|
| **Protocol Layer** | TCP (Layer 4) | HTTP (Layer 7) | ⭐⭐⭐⭐⭐ High |
| **Request Parsing** | None (raw streams) | Full HTTP + JSON | ⭐⭐⭐⭐ Medium-High |
| **Backend Selection** | Load balancing algorithms | Sticky + error-driven | ⭐⭐⭐ Medium |
| **Request Modification** | None | JSON body manipulation | ⭐⭐⭐⭐ Medium-High |
| **Error Handling** | Connection-level | HTTP status code-level | ⭐⭐⭐ Medium |
| **Retry Logic** | Exponential backoff | Status-driven with waiting | ⭐⭐⭐ Medium |
| **Caching** | HTTP response cache (GET) | None | N/A |
| **Logging** | Minimal stats | Full request/response audit | ⭐⭐ Low-Medium |
| **Monitoring** | ProxyStats | `/_status` endpoint | ⭐⭐ Low-Medium |

---

## Architecture Proposal for Prozy

### Option 1: HTTP-Aware Proxy Mode (New Feature)

Add HTTP support alongside existing TCP mode:

```zig
pub const ProxyMode = enum {
    tcp,   // Current behavior: blind forwarding
    http,  // New: HTTP parsing + modification
};

pub const Proxy = struct {
    mode: ProxyMode,

    // For HTTP mode only:
    api_key_manager: ?*ApiKeyManager,
    request_modifier: ?*RequestModifier,
    http_logger: ?*HTTPLogger,
};
```

**Pros:**
- Maintains backward compatibility
- Clear separation of concerns
- Can optimize TCP mode separately

**Cons:**
- More complex codebase
- Two code paths to maintain

---

### Option 2: HTTP Middleware Layer

Keep TCP core, add optional HTTP layer:

```zig
// Middleware chain
const middleware = [_]*Middleware{
    &http_parser,        // Parses HTTP from TCP stream
    &api_key_injector,   // Adds Authorization header
    &json_modifier,      // Modifies request bodies
    &retry_handler,      // Retries on 429/500
    &response_logger,    // Logs to filesystem
};

// In handleClient:
for (middleware) |mw| {
    try mw.process(&request, &response);
}
```

**Pros:**
- Composable features
- Easy to add new middleware
- Clean architecture

**Cons:**
- Performance overhead from layers
- Complex state management across middleware

---

### Option 3: Separate HTTP Proxy (prozy-http)

Create a new binary specifically for HTTP proxying:

```
prozy/
├── src/
│   ├── root.zig          // TCP proxy (current)
│   └── http/
│       ├── http_proxy.zig    // HTTP-aware proxy
│       ├── http_parser.zig   // Request/response parsing
│       ├── api_keys.zig      // Key management
│       └── json_modifier.zig // Body modification
```

**Pros:**
- No impact on existing TCP proxy
- Can use different async patterns for HTTP
- Simpler to reason about

**Cons:**
- Code duplication (stats, config, etc.)
- Two binaries to maintain

---

## Technical Challenges

### 1. **Buffering Requirements**

**Problem:** Can't stream response until we know the status code.

Current Prozy:
```zig
// Stream data as it arrives (zero buffering)
while (true) {
    const n = try client.read(buf);
    try backend.writeAll(buf[0..n]);
}
```

HTTP-aware proxy:
```zig
// Must buffer entire response to read status code
const response = try bufferedRead(backend);  // Could be MB/GB!
const status = parseStatusCode(response);

if (status == 429) {
    // Retry with different key - discard this response
} else {
    // Forward to client
    try client.writeAll(response);
}
```

**Solutions:**
- Set max response size for retry (e.g., 10MB)
- For large responses, disable retries
- Use chunked reading with early status line parsing

---

### 2. **Async Sleep/Wait for Key Availability**

```python
# Python (easy with asyncio)
await asyncio.sleep(wait_time)

# Zig (need to integrate with I/O runtime)
try io.sleep(wait_time_ns);  // How to implement?
```

**Implementation:**
- Use `std.time.sleep()` for simple blocking wait
- Or integrate with `io.concurrent()` for async wait
- Must not block other connections

---

### 3. **JSON Parsing Performance**

**Cerebras-proxy uses:**
- `json.loads()` - parse to Python dict
- Modify in-place
- `json.dumps()` - serialize back

**Zig options:**
- `std.json.parseFromSlice()` - allocates, parses to structs
- `std.json.Value` - dynamic JSON tree
- Memory management for deep copies

**Challenge:** Unknown JSON structure at compile time.

---

### 4. **Content-Length Recalculation**

```zig
// After modifying body:
const original_length = request.headers.get("Content-Length");
const new_length = modified_body.len;

try request.headers.put("Content-Length",
    try std.fmt.allocPrint(allocator, "{d}", .{new_length}));
```

**Edge cases:**
- Chunked transfer encoding (no Content-Length)
- Compression (gzip, brotli)
- Multipart bodies

---

## Recommended Implementation Roadmap

If you wanted to add cerebras-proxy functionality to Prozy:

### Phase 1: HTTP Foundation (2-3 weeks)
- [ ] HTTP/1.1 request parser
- [ ] HTTP/1.1 response parser
- [ ] Header manipulation
- [ ] Request/response serialization
- [ ] Tests for HTTP parsing

### Phase 2: API Key Management (1 week)
- [ ] ApiKeyManager struct
- [ ] Sticky key selection
- [ ] Error-driven rotation
- [ ] Cooldown tracking
- [ ] Wait for available key
- [ ] Tests for key rotation

### Phase 3: JSON Modification (1 week)
- [ ] JSON request body parsing
- [ ] JSON modification utilities
- [ ] Content-Length recalculation
- [ ] Tests for body modification

### Phase 4: Retry Logic (1 week)
- [ ] Status code extraction
- [ ] Retry loop with key rotation
- [ ] Max retries enforcement
- [ ] Tests for retry scenarios

### Phase 5: Logging & Monitoring (1 week)
- [ ] Request/response logging
- [ ] Log directory organization
- [ ] Header redaction
- [ ] `/_status` endpoint
- [ ] Tests for logging

### Phase 6: Integration & Testing (1-2 weeks)
- [ ] End-to-end HTTP proxy test
- [ ] Performance testing
- [ ] Memory leak detection
- [ ] Documentation

**Total estimated effort: 8-10 weeks for full cerebras-proxy parity**

---

## Key Architectural Decisions Needed

1. **HTTP parsing library:**
   - Build from scratch using `std.mem.tokenize()`?
   - Use existing Zig HTTP library (zap, httpz)?
   - Hand-rolled minimal parser for specific use case?

2. **JSON handling:**
   - `std.json` with dynamic Value?
   - Strongly-typed structs (limited flexibility)?
   - External JSON library?

3. **Async I/O integration:**
   - Use existing `std.Io.Threaded` runtime?
   - Add async sleep support?
   - Thread pool for blocking operations?

4. **Memory management:**
   - Arena allocator per request (simple cleanup)?
   - Manual allocations with careful defers?
   - Pool of reusable buffers?

---

## Conclusion

Achieving cerebras-proxy functionality with Prozy requires **fundamental architectural changes**:

1. **Move from Layer 4 to Layer 7**: TCP → HTTP
2. **Add state management**: Stateless routing → Stateful key management
3. **Enable modification**: Transparent forwarding → Active request/response manipulation
4. **Semantic awareness**: Byte streams → HTTP status codes drive logic

This is essentially **building a new application-layer proxy** rather than extending the current TCP proxy. The two use cases (TCP forwarding vs HTTP API key management) have different requirements and optimizations.

**Recommendation:** If you need cerebras-proxy functionality, consider:
- Creating a separate `prozy-http` project specifically for HTTP proxying
- Using Python/Go for faster development (like cerebras-proxy does)
- Or using Prozy as a learning vehicle to explore HTTP proxy implementation in Zig

The current Prozy is excellent for TCP proxying with caching and load balancing. Adding full HTTP semantics would be a major undertaking that might compromise its current strengths.
