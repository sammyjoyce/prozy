# Prozy Production Deployment Guide

This guide covers deploying Prozy in production environments, including configuration, monitoring, security hardening, and operational best practices.

## Table of Contents

- [Quick Start](#quick-start)
- [System Requirements](#system-requirements)
- [Building for Production](#building-for-production)
- [Configuration](#configuration)
- [Deployment Patterns](#deployment-patterns)
- [Monitoring and Observability](#monitoring-and-observability)
- [Security Hardening](#security-hardening)
- [Performance Tuning](#performance-tuning)
- [High Availability](#high-availability)
- [Troubleshooting](#troubleshooting)

## Quick Start

### Minimal Production Deployment

```bash
# 1. Build optimized binary
zig build -Doptimize=ReleaseFast

# 2. Copy binary to deployment location
cp zig-out/bin/prozy /usr/local/bin/

# 3. Create configuration (see Configuration section)
# 4. Run with systemd or your process manager
```

## System Requirements

### Minimum Requirements

- **OS**: Linux (kernel 4.0+), macOS (10.15+), Windows (10+)
- **CPU**: 2 cores
- **RAM**: 512 MB (base) + (16 KB × max_connections)
- **Disk**: 50 MB for binary + cache size
- **Network**: 1 Gbps NIC recommended

### Recommended for Production

- **OS**: Linux (kernel 5.10+) with io_uring support
- **CPU**: 4+ cores for high throughput
- **RAM**: 4 GB+ for large cache and many connections
- **Disk**: SSD for cache storage (if persistent)
- **Network**: 10 Gbps NIC for multi-Gbps throughput

### File Descriptor Limits

Prozy needs 2 file descriptors per connection (client + backend). Set limits appropriately:

```bash
# Check current limits
ulimit -n

# Set higher limit (add to /etc/security/limits.conf)
* soft nofile 65536
* hard nofile 65536

# For systemd services, add to unit file:
LimitNOFILE=65536
```

## Building for Production

### Release Build

```bash
# Optimized for speed (recommended)
zig build -Doptimize=ReleaseFast

# Optimized for size
zig build -Doptimize=ReleaseSmall

# With safety checks (slightly slower but recommended for critical deployments)
zig build -Doptimize=ReleaseSafe
```

### Static Binary

Zig produces static binaries by default. Verify:

```bash
ldd zig-out/bin/prozy
# Should show: "not a dynamic executable" or minimal dependencies
```

### Cross-Compilation

Build for different platforms:

```bash
# Linux x86_64
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast

# Linux ARM64 (for AWS Graviton, etc.)
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseFast

# macOS x86_64
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast

# macOS ARM64 (Apple Silicon)
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast
```

## Configuration

### Programmatic Configuration

Prozy is configured programmatically in Zig. Create a custom `main.zig`:

```zig
const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Initialize async runtime
    var threaded_io = std.Io.Threaded.init(allocator);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Create proxy instance
    var proxy = prozy.Proxy.init(allocator, 8080, "127.0.0.1", 3003);
    defer proxy.deinit();

    // Enable caching (10 MB)
    proxy.enableCaching(10 * 1024 * 1024);

    // Enable rate limiting (100 per IP, 1000 global)
    proxy.enableRateLimiting(100, 1000);

    // Enable access control
    try proxy.enableAccessControl(.allow);
    if (proxy.access_control) |*acl| {
        // Add allowed IPs
        try acl.addAllowedIp(std.Io.net.IpAddress.parseIp4("10.0.0.0", 0) catch unreachable);
    }

    // Enable load balancing
    var backends = [_]prozy.Backend{
        prozy.Backend.init("backend1.example.com", 3003, 1),
        prozy.Backend.init("backend2.example.com", 3003, 2),  // Higher weight
        prozy.Backend.init("backend3.example.com", 3003, 1),
    };
    proxy.enableLoadBalancing(&backends, .weighted_round_robin);

    // Run proxy
    std.log.info("Prozy starting on port {}", .{proxy.proxy_port});
    try proxy.runWithIoOptions(io, .{});
}
```

### Environment Variables

Use environment variables for runtime configuration:

```zig
const listen_port = std.process.getEnvVarOwned(allocator, "PROZY_PORT")
    catch "8080";
const backend_host = std.process.getEnvVarOwned(allocator, "BACKEND_HOST")
    catch "localhost";
const backend_port = std.process.getEnvVarOwned(allocator, "BACKEND_PORT")
    catch "3003";
```

### Configuration Examples

See `examples/configs/` directory for:
- `simple_proxy.zig` - Basic TCP forwarding
- `caching_proxy.zig` - With HTTP response caching
- `load_balanced_proxy.zig` - Multi-backend load balancing
- `secure_proxy.zig` - Access control and rate limiting
- `production_proxy.zig` - Full enterprise feature set

Or run `zig build full_features` to see all features demonstrated.

## Deployment Patterns

### Systemd Service

Create `/etc/systemd/system/prozy.service`:

```ini
[Unit]
Description=Prozy TCP Proxy
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=prozy
Group=prozy
WorkingDirectory=/opt/prozy
ExecStart=/usr/local/bin/prozy
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

# Resource limits
LimitNOFILE=65536
MemoryMax=4G

# Environment
Environment="PROZY_PORT=8080"
Environment="BACKEND_HOST=backend.internal"
Environment="BACKEND_PORT=3003"

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable prozy
sudo systemctl start prozy
sudo systemctl status prozy
```

### Docker Container

Create `Dockerfile`:

```dockerfile
FROM alpine:3.18 AS builder

# Install Zig
RUN apk add --no-cache wget xz
RUN wget https://ziglang.org/download/0.16.0/zig-linux-x86_64-0.16.0.tar.xz
RUN tar -xf zig-linux-x86_64-0.16.0.tar.xz
RUN mv zig-linux-x86_64-0.16.0 /usr/local/zig
ENV PATH="/usr/local/zig:${PATH}"

# Build Prozy
WORKDIR /build
COPY . .
RUN zig build -Doptimize=ReleaseFast

# Runtime image
FROM alpine:3.18
RUN apk add --no-cache ca-certificates

COPY --from=builder /build/zig-out/bin/prozy /usr/local/bin/prozy

# Create non-root user
RUN addgroup -g 1000 prozy && \
    adduser -D -u 1000 -G prozy prozy

USER prozy
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/prozy"]
```

Build and run:

```bash
docker build -t prozy:1.0.0 .
docker run -p 8080:8080 \
  -e BACKEND_HOST=backend.internal \
  -e BACKEND_PORT=3003 \
  prozy:1.0.0
```

### Kubernetes Deployment

Create `prozy-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prozy
  labels:
    app: prozy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: prozy
  template:
    metadata:
      labels:
        app: prozy
    spec:
      containers:
      - name: prozy
        image: prozy:1.0.0
        ports:
        - containerPort: 8080
          name: proxy
        env:
        - name: BACKEND_HOST
          value: "backend-service"
        - name: BACKEND_PORT
          value: "3003"
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
        livenessProbe:
          tcpSocket:
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          tcpSocket:
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: prozy-service
spec:
  selector:
    app: prozy
  ports:
  - protocol: TCP
    port: 80
    targetPort: 8080
  type: LoadBalancer
```

Deploy:

```bash
kubectl apply -f prozy-deployment.yaml
kubectl get pods -l app=prozy
kubectl logs -f deployment/prozy
```

## Monitoring and Observability

### Logging

Prozy uses Zig's standard logging. Configure log level:

```bash
# Environment variable
export ZIG_LOG_LEVEL=info

# Systemd journal
journalctl -u prozy -f

# File output
systemctl edit prozy
# Add: StandardOutput=file:/var/log/prozy/output.log
```

Log levels:
- `err`: Errors only (production default)
- `warn`: Warnings and errors
- `info`: Informational messages
- `debug`: Detailed debugging (development only)

### Statistics API

Access real-time statistics programmatically:

```zig
// Get statistics snapshot
const stats = proxy.getStats();
std.log.info("Active connections: {}", .{stats.active_connections});
std.log.info("Total connections: {}", .{stats.total_connections});
std.log.info("Bytes transferred: {}", .{stats.total_bytes_client_to_backend});

// Get cache statistics
if (proxy.getCacheStats()) |cache_stats| {
    std.log.info("Cache hit rate: {d:.2}%", .{cache_stats.hitRate()});
}
```

### Metrics Export

Future versions will support Prometheus metrics export. For now, use logs:

```bash
# Parse statistics from logs
journalctl -u prozy | grep "Statistics" | tail -1
```

### Health Checks

Prozy responds on the listen port. Use TCP health checks:

```bash
# Simple health check
nc -zv localhost 8080

# With timeout
timeout 2 bash -c "</dev/tcp/localhost/8080" && echo "UP" || echo "DOWN"
```

## Security Hardening

### Network Security

1. **Bind to specific interface**:
   ```zig
   var proxy = prozy.Proxy.init(allocator, 8080, "0.0.0.0", 3003);
   // For internal only: use "127.0.0.1"
   ```

2. **Enable access control**:
   ```zig
   try proxy.enableAccessControl(.deny);  // Deny by default
   if (proxy.access_control) |*acl| {
       // Whitelist specific IPs
       try acl.addAllowedIp(trusted_ip);
   }
   ```

3. **Rate limiting**:
   ```zig
   // Prevent DoS attacks
   proxy.enableRateLimiting(100, 10000);
   ```

### System Security

1. **Run as non-root user**:
   ```bash
   sudo useradd -r -s /bin/false prozy
   sudo chown prozy:prozy /usr/local/bin/prozy
   ```

2. **Use port > 1024** or grant capability:
   ```bash
   # If binding to port 80/443
   sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/prozy
   ```

3. **Enable firewall**:
   ```bash
   # UFW example
   sudo ufw allow 8080/tcp
   sudo ufw enable
   ```

### TLS Termination

Prozy doesn't include TLS termination. Use a TLS-terminating reverse proxy:

```nginx
# Nginx as TLS terminator → Prozy
upstream prozy_backend {
    server 127.0.0.1:8080;
}

server {
    listen 443 ssl http2;
    server_name example.com;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location / {
        proxy_pass http://prozy_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## Performance Tuning

### Cache Configuration

Size cache based on working set:

```zig
// Small: 10 MB (low-traffic or small responses)
proxy.enableCaching(10 * 1024 * 1024);

// Medium: 100 MB (typical web content)
proxy.enableCaching(100 * 1024 * 1024);

// Large: 1 GB (high cache hit rate needed)
proxy.enableCaching(1024 * 1024 * 1024);
```

Cache efficiency monitoring:

```zig
const cache_stats = proxy.getCacheStats().?;
if (cache_stats.hitRate() < 50.0) {
    // Consider increasing cache size
    std.log.warn("Cache hit rate low: {d:.2}%", .{cache_stats.hitRate()});
}
```

### Load Balancer Tuning

Choose strategy based on workload:

- **Round Robin**: Even distribution, stateless workloads
- **Least Connections**: Uneven request durations
- **Weighted**: Heterogeneous backend capacity
- **IP Hash**: Session affinity required
- **Random**: Simple and effective for homogeneous backends

### System Tuning

**Linux kernel parameters** (`/etc/sysctl.conf`):

```bash
# Increase connection tracking
net.netfilter.nf_conntrack_max = 1048576

# TCP tuning
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192

# Increase receive/send buffers
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
```

Apply: `sudo sysctl -p`

## High Availability

### Active-Active Setup

Deploy multiple Prozy instances behind a load balancer:

```
              ┌─────────────┐
              │ Load        │
              │ Balancer    │
              │ (Nginx/HAProxy)
              └──────┬──────┘
                     │
          ┌──────────┼──────────┐
          │          │          │
     ┌────▼───┐ ┌───▼────┐ ┌───▼────┐
     │ Prozy  │ │ Prozy  │ │ Prozy  │
     │ Node 1 │ │ Node 2 │ │ Node 3 │
     └────┬───┘ └───┬────┘ └───┬────┘
          │         │          │
          └─────────┼──────────┘
                    │
              ┌─────▼─────┐
              │ Backend   │
              │ Services  │
              └───────────┘
```

**HAProxy configuration**:

```haproxy
frontend prozy_frontend
    bind *:80
    mode tcp
    default_backend prozy_backend

backend prozy_backend
    mode tcp
    balance roundrobin
    option tcp-check
    server prozy1 10.0.1.10:8080 check
    server prozy2 10.0.1.11:8080 check
    server prozy3 10.0.1.12:8080 check
```

### Cache Coherency

**Note**: HTTP cache is local to each Prozy instance. For distributed caching:

1. **Use external cache** (Redis, Memcached) - requires custom implementation
2. **Accept eventual consistency** - cache may differ between nodes
3. **Disable cache** if strong consistency required

### Graceful Shutdown

Prozy handles Ctrl+C gracefully. For systemd:

```ini
[Service]
KillMode=mixed
KillSignal=SIGINT
TimeoutStopSec=30
```

## Troubleshooting

### Common Issues

**Issue**: "Address already in use"
```bash
# Check what's using the port
sudo lsof -i :8080
sudo netstat -tulpn | grep 8080

# Kill existing process or use different port
```

**Issue**: "Too many open files"
```bash
# Increase file descriptor limit
ulimit -n 65536

# Make permanent in /etc/security/limits.conf
```

**Issue**: High memory usage
```bash
# Check cache size
# Reduce cache: proxy.enableCaching(10 * 1024 * 1024);

# Monitor memory
ps aux | grep prozy
top -p $(pgrep prozy)
```

**Issue**: Backend connection failures
```bash
# Check backend health
curl -v http://backend-host:backend-port

# Review logs
journalctl -u prozy | grep "Backend"

# Verify network connectivity
telnet backend-host backend-port
```

### Debug Mode

Build with debug symbols:

```bash
zig build -Doptimize=Debug
```

Enable debug logging:

```bash
export ZIG_LOG_LEVEL=debug
./zig-out/bin/prozy 2>&1 | tee prozy-debug.log
```

### Performance Profiling

Use Linux perf:

```bash
# Record performance profile
sudo perf record -F 99 -p $(pgrep prozy) -g -- sleep 30

# Generate flamegraph
sudo perf script | stackcollapse-perf.pl | flamegraph.pl > prozy-flamegraph.svg
```

### Getting Help

- **Documentation**: Check README.md and CLAUDE.md
- **Issues**: Search [GitHub issues](https://github.com/sammyjoyce/prozy/issues)
- **Discussions**: Post in [GitHub Discussions](https://github.com/sammyjoyce/prozy/discussions)
- **Security**: Email maintainers for security issues

## Production Checklist

Before going live:

- [ ] Built with `-Doptimize=ReleaseFast`
- [ ] Configured appropriate cache size
- [ ] Enabled rate limiting
- [ ] Configured access control (if needed)
- [ ] Set file descriptor limits
- [ ] Configured monitoring/logging
- [ ] Set up health checks
- [ ] Tested failover scenarios
- [ ] Documented configuration
- [ ] Planned backup strategy
- [ ] Tested rollback procedure
- [ ] Security review completed

---

**Production-ready?** Follow this guide and the [security hardening](SECURITY.md) recommendations for a robust Prozy deployment. 🚀
