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

    try proxy.runWithIo(io);
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
