# Prozy Configuration Examples

This directory contains example configurations for common proxy deployment patterns.

## Available Configurations

### 1. Simple Proxy (`simple_proxy.zig`)

**Use case**: Basic request forwarding, development, testing

**Features**:
- Basic TCP proxying
- No caching
- No security features
- Minimal overhead

**Build & Run**:
```bash
zig build-exe examples/configs/simple_proxy.zig --dep prozy --mod prozy::src/root.zig
./simple_proxy
```

---

### 2. Caching Proxy (`caching_proxy.zig`)

**Use case**: CDN, content delivery, static asset serving

**Features**:
- ✅ Large cache (1 GB default)
- ✅ LRU eviction
- ✅ TTL-based expiration
- ✅ High hit rates for static content

**Configuration**:
```zig
proxy.enableCaching(1024 * 1024 * 1024);  // 1 GB
```

**Tuning**:
- Increase cache size for more content
- Monitor hit rate with `proxy.getCacheStats()`
- Adjust based on working set size

---

### 3. Load Balanced Proxy (`load_balanced_proxy.zig`)

**Use case**: High availability, horizontal scaling, backend redundancy

**Features**:
- ✅ Multiple backends
- ✅ Weighted round-robin (or other strategies)
- ✅ Automatic health checks
- ✅ Failover on backend failure
- ✅ Optional caching

**Backend Strategies**:
- `.round_robin` - Even distribution
- `.weighted_round_robin` - Weight-based (shown)
- `.least_connections` - Route to least loaded
- `.random` - Random selection
- `.ip_hash` - Session affinity

**Configuration**:
```zig
var backends = [_]prozy.Backend{
    prozy.Backend.init("backend1", 3003, 2),  // weight: 2
    prozy.Backend.init("backend2", 3003, 1),  // weight: 1
};
proxy.enableLoadBalancing(&backends, .weighted_round_robin);
```

---

### 4. Secure Proxy (`secure_proxy.zig`)

**Use case**: Internal services, API gateway, security enforcement

**Features**:
- ✅ IP-based access control (whitelist)
- ✅ Deny-by-default policy
- ✅ Aggressive rate limiting
- ✅ Connection throttling

**Security Configuration**:
```zig
// Deny all by default
try proxy.enableAccessControl(.deny);

// Whitelist specific IPs
try acl.addAllowedIp(trusted_ip);

// Rate limiting
proxy.enableRateLimiting(50, 5000);  // 50/IP, 5K global
```

**Use cases**:
- Internal API proxying
- Restricted-access services
- Development/staging environments

---

### 5. Production Proxy (`production_proxy.zig`)

**Use case**: Production deployment, high-traffic services, mission-critical

**Features**:
- ✅ Load balancing (4 backends, weighted)
- ✅ Large cache (500 MB)
- ✅ Moderate rate limiting
- ✅ Access control (blocklist mode)
- ✅ Health checks with exponential backoff
- ✅ Auto-failover
- ✅ Comprehensive statistics

**Full Configuration**:
```zig
// 4 backends with different weights
var backends = [_]prozy.Backend{
    prozy.Backend.init("backend1", 3003, 3),  // Primary
    prozy.Backend.init("backend2", 3003, 2),
    prozy.Backend.init("backend3", 3003, 2),
    prozy.Backend.init("backend4", 3003, 1),  // Backup
};
proxy.enableLoadBalancing(&backends, .weighted_round_robin);

// 500 MB cache
proxy.enableCaching(500 * 1024 * 1024);

// 100 per IP, 50K global
proxy.enableRateLimiting(100, 50000);

// Allow all, block bad actors
try proxy.enableAccessControl(.allow);
try acl.addDeniedIp(malicious_ip);
```

---

### 6. Authentication Proxy (`auth_proxy.zig`)

**Use case**: Corporate proxy, API gateway, secured services, user authentication

**Features**:
- ✅ RFC 7235/7617 proxy authentication (Basic scheme)
- ✅ bcrypt password hashing (configurable cost)
- ✅ Constant-time credential comparison (timing attack prevention)
- ✅ Rate limiting for failed attempts (default: 5 max)
- ✅ Exponential backoff for brute force protection (1min → 64min)
- ✅ Per-IP and per-username tracking
- ✅ Authentication statistics
- ✅ Integration with access control and rate limiting

**Configuration**:
```zig
// Enable authentication with custom realm
try proxy.enableProxyAuthentication("Corporate Proxy", .{
    .basic_enabled = true,
    .digest_enabled = false,
    .max_failed_attempts = 5,
    .auth_timeout_ms = 30000,
    .bcrypt_cost = 12,  // 12 rounds = ~250ms per hash
});

// Add users (passwords automatically hashed with bcrypt)
try proxy.addAuthUser("admin", "admin123");
try proxy.addAuthUser("alice", "alicepass");
try proxy.addAuthUser("bob", "bobpass");
try proxy.addAuthUser("charlie", "charliepass");

// Optional: Combine with IP-based access control
try proxy.enableAccessControl(.allow);
try acl.addAllowedIp(trusted_network_ip);

// Optional: Add rate limiting
proxy.enableRateLimiting(100, 1000);
```

**Build & Run**:
```bash
# Build the auth proxy example
zig build auth_proxy

# Run the proxy
./zig-out/bin/auth_proxy
```

**Testing**:
```bash
# Test without credentials (expect 407)
curl -v --proxy http://127.0.0.1:8080 http://example.com

# Test with valid credentials (expect success)
curl -v --proxy http://127.0.0.1:8080 -U admin:admin123 http://example.com

# Test with invalid credentials (expect 407 + rate limiting)
curl -v --proxy http://127.0.0.1:8080 -U admin:wrong http://example.com

# Test multiple failures to trigger exponential backoff
for i in {1..6}; do
  curl --proxy http://127.0.0.1:8080 -U admin:wrong http://example.com
  sleep 1
done
```

**Security Features**:
- **Password Hashing**: bcrypt with configurable cost (default: 12 rounds)
  - 4 rounds = ~1ms per hash (fast, but weaker)
  - 12 rounds = ~250ms per hash (recommended, good balance)
  - 15 rounds = ~2s per hash (very secure, but slow)
- **Timing Attack Prevention**: Constant-time comparison prevents timing side-channels
- **Brute Force Protection**: Exponential backoff after failed attempts
  - Attempt 1: No delay
  - Attempt 2-5: 1min, 2min, 4min, 8min delay
  - Attempt 6+: 16min, 32min, 64min delay (progressive slowdown)
- **Rate Limiting**: Maximum failed attempts before blocking (default: 5)
- **Per-IP Tracking**: Each IP address tracked separately
- **Per-Username Tracking**: Each username tracked separately

**Use Cases**:
- Corporate proxy server with user authentication
- API gateway requiring credentials
- Development proxy with access control
- Secured internal services
- Multi-tenant proxy with user isolation

**Statistics Monitoring**:
```zig
if (proxy.getAuthStats()) |stats| {
    std.debug.print("Total auth requests: {d}\n", .{stats.total_auth_requests});
    std.debug.print("Successful auths: {d}\n", .{stats.successful_auths});
    std.debug.print("Failed auths: {d}\n", .{stats.failed_auths});
    std.debug.print("Blocked IPs: {d}\n", .{stats.blocked_ips});
    std.debug.print("Active sessions: {d}\n", .{stats.active_sessions});
    std.debug.print("Success rate: {d:.2}%\n", .{stats.success_rate * 100});
}
```

**RFC Compliance**:
- ✅ RFC 7235 (HTTP Authentication Framework for proxies)
- ✅ RFC 7617 (Basic HTTP Authentication Scheme)
- ⏳ RFC 7616 (Digest Access Authentication) - Planned for Phase 2
- ⏳ RFC 6750 (Bearer Token Usage) - Planned for Phase 2

---

## Building Custom Configurations

### Step 1: Copy a Template

```bash
cp examples/configs/simple_proxy.zig my_custom_proxy.zig
```

### Step 2: Customize

Edit `my_custom_proxy.zig` to add your features:

```zig
const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var proxy = prozy.Proxy.init(allocator, 8080, "0.0.0.0", 3003);
    defer proxy.deinit();

    // Add your custom configuration here
    proxy.enableCaching(/* size */);
    proxy.enableRateLimiting(/* per_ip */, /* global */);
    // ... etc

    try proxy.runWithIoOptions(io, .{});
}
```

### Step 3: Build

```bash
# Development build
zig build-exe my_custom_proxy.zig --dep prozy --mod prozy::src/root.zig

# Production build
zig build-exe -O ReleaseFast my_custom_proxy.zig --dep prozy --mod prozy::src/root.zig
```

### Step 4: Run

```bash
./my_custom_proxy
```

---

## Environment Variables

Use environment variables for runtime configuration:

```zig
const listen_port = try std.fmt.parseInt(u16,
    std.process.getEnvVarOwned(allocator, "PROZY_PORT") catch "8080",
    10
);

const backend_host = std.process.getEnvVarOwned(allocator, "BACKEND_HOST")
    catch "localhost";
```

Run with environment variables:

```bash
PROZY_PORT=9090 BACKEND_HOST=api.internal ./my_custom_proxy
```

---

## Configuration Checklist

When creating a custom configuration, consider:

- [ ] **Listen address**: Internal (127.0.0.1) or public (0.0.0.0)?
- [ ] **Port**: Privileged (<1024) or user port (≥1024)?
- [ ] **Caching**: Enable? What size? (based on working set)
- [ ] **Load balancing**: Multiple backends? Which strategy?
- [ ] **Access control**: Allow-all or deny-all? Whitelist/blacklist?
- [ ] **Rate limiting**: What limits? (based on expected traffic)
- [ ] **Monitoring**: Log level? Statistics export?
- [ ] **Security**: Run as non-root? Firewall rules? TLS termination?

---

## Next Steps

- Review [DEPLOYMENT.md](../DEPLOYMENT.md) for production deployment guide
- Review [SECURITY.md](../SECURITY.md) for security hardening
- Check [examples/](../examples/) for more advanced usage patterns
- Read [CLAUDE.md](../CLAUDE.md) for coding style guide (if extending Prozy)

---

**Need help?** Open a [GitHub Discussion](https://github.com/sammyjoyce/prozy/discussions) or check the [README](../README.md).
