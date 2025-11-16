# Security Policy

## Reporting Security Vulnerabilities

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, please report them via email to the maintainers. You should receive a response within 48 hours. If for some reason you do not, please follow up to ensure we received your original message.

Please include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

## Security Hardening Guide

This guide provides security recommendations for deploying Prozy in production environments.

## Table of Contents

- [Threat Model](#threat-model)
- [Network Security](#network-security)
- [Access Control](#access-control)
- [Rate Limiting & DoS Protection](#rate-limiting--dos-protection)
- [Backend Security](#backend-security)
- [System Hardening](#system-hardening)
- [Monitoring & Incident Response](#monitoring--incident-response)
- [Security Checklist](#security-checklist)

## Threat Model

### In Scope

Prozy is designed to protect against:

- ✅ **Unauthorized access**: IP-based filtering
- ✅ **Resource exhaustion**: Rate limiting, connection limits
- ✅ **Backend overload**: Load balancing, health checks
- ✅ **Traffic inspection**: HTTP protocol analysis
- ✅ **Cache poisoning**: Host header validation

### Out of Scope

Prozy **does not** currently protect against:

- ❌ **TLS attacks**: No TLS termination (use Nginx/HAProxy)
- ❌ **Application-layer attacks**: No WAF, SQL injection, XSS filtering
- ❌ **DDoS attacks**: Limited DoS protection (use upstream DDoS mitigation)
- ❌ **Backend compromise**: Trusted backend assumption
- ❌ **Authentication/Authorization**: No built-in auth (add in fork)

### Trust Boundaries

```
Untrusted          Prozy              Trusted
─────────────────────────────────────────────────
Internet    →    [Access Control]    →  Backend
Clients     →    [Rate Limiting]     →  Services
            →    [Cache]             →
            →    [Load Balancer]     →
```

**Assumptions:**
- Backend services are trusted
- Network between Prozy and backends is secure
- Prozy configuration is correct

## Network Security

### Bind to Specific Interfaces

**Recommendation**: Bind to specific interfaces, not `0.0.0.0` unless necessary.

```zig
// ❌ Bad: Exposed to all interfaces
var proxy = prozy.Proxy.init(allocator, 8080, "0.0.0.0", 3003);

// ✅ Good: Internal only
var proxy = prozy.Proxy.init(allocator, 8080, "127.0.0.1", 3003);

// ✅ Good: Specific interface
var proxy = prozy.Proxy.init(allocator, 8080, "10.0.1.10", 3003);
```

### Firewall Configuration

**Always** use a firewall to restrict access:

```bash
# UFW (Ubuntu/Debian)
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 10.0.0.0/8 to any port 8080
sudo ufw enable

# iptables
sudo iptables -A INPUT -p tcp --dport 8080 -s 10.0.0.0/8 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 8080 -j DROP
```

### Network Segmentation

Deploy Prozy in a DMZ or proxy tier:

```
Internet → [Firewall] → [Proxy Tier] → [Internal Firewall] → [Backend Tier]
                          └─ Prozy                             └─ Services
```

### TLS Termination

Prozy does not handle TLS. Use a TLS-terminating reverse proxy:

**Nginx example:**

```nginx
upstream prozy {
    server 127.0.0.1:8080;
}

server {
    listen 443 ssl http2;
    server_name proxy.example.com;

    # TLS configuration
    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;

    location / {
        proxy_pass http://prozy;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## Access Control

### IP-Based Filtering

Enable access control with deny-by-default policy:

```zig
// Deny all, then whitelist
try proxy.enableAccessControl(.deny);

if (proxy.access_control) |*acl| {
    // Whitelist specific IPs
    const allowed_ip1 = try std.Io.net.IpAddress.parseIp4("10.0.1.100", 0);
    const allowed_ip2 = try std.Io.net.IpAddress.parseIp4("10.0.2.0", 0);  // Can add CIDR logic

    try acl.addAllowedIp(allowed_ip1);
    try acl.addAllowedIp(allowed_ip2);
}
```

### Access Control Strategies

**Public-facing proxy** (allow all, block bad actors):
```zig
try proxy.enableAccessControl(.allow);
if (proxy.access_control) |*acl| {
    // Block known malicious IPs
    try acl.addDeniedIp(malicious_ip);
}
```

**Internal proxy** (deny all, allow known):
```zig
try proxy.enableAccessControl(.deny);
if (proxy.access_control) |*acl| {
    // Whitelist internal networks
    // Note: Current implementation is per-IP, not CIDR
    // For CIDR support, extend AccessControl in fork
}
```

### X-Forwarded-For Considerations

**Security Risk**: Prozy does not currently parse `X-Forwarded-For` headers.

- ✅ **Good**: Direct client connections (IP is from TCP socket)
- ⚠️ **Risk**: Behind another proxy (all clients appear as proxy IP)

**Mitigation**: If behind a proxy, implement X-Forwarded-For parsing in your fork:

```zig
// Extract real client IP from X-Forwarded-For header
const xff_header = // parse from HTTP headers
const real_ip = // parse first IP from XFF
// Use real_ip for access control
```

## Rate Limiting & DoS Protection

### Connection Rate Limiting

Enable both per-IP and global limits:

```zig
// Max 100 connections per IP, 10,000 global
proxy.enableRateLimiting(100, 10000);
```

### Tuning Rate Limits

**Conservative** (public internet):
```zig
proxy.enableRateLimiting(10, 1000);  // 10 per IP, 1K global
```

**Moderate** (semi-trusted):
```zig
proxy.enableRateLimiting(100, 10000);  // 100 per IP, 10K global
```

**Aggressive** (trusted internal):
```zig
proxy.enableRateLimiting(1000, 100000);  // 1K per IP, 100K global
```

### Connection Timeout

**Current**: 30-second bidirectional timeout (hardcoded in `BIDIRECTIONAL_TIMEOUT_SECONDS`)

To customize, modify `src/root.zig`:
```zig
const BIDIRECTIONAL_TIMEOUT_SECONDS: i64 = 10;  // Shorter for public-facing
```

### Resource Limits

Set system resource limits:

```bash
# File descriptors (2 per connection)
ulimit -n 65536

# Memory limit (systemd)
[Service]
MemoryMax=4G
MemoryHigh=3G
```

### Slowloris Protection

**Risk**: Slow clients can hold connections open.

**Current Protection**:
- 30-second timeout after one direction completes
- Rate limiting prevents too many slow connections

**Additional Protection** (for fork):
- Add read timeout per request
- Limit request header size (currently 8KB buffer)

## Backend Security

### Backend Authentication

**Current**: No authentication to backends (assumed trusted).

**For production**: Use mTLS, VPN, or private networks:

```
Prozy → [mTLS/VPN] → Backend Services
```

**Future enhancement**: Add backend authentication in fork:
```zig
// Custom backend authentication
const backend = Backend.initWithAuth("backend.internal", 3003, 1, api_key);
```

### Backend Validation

**Risk**: Malicious backend could send crafted responses.

**Current Protection**:
- Response size limits (cache won't store >50% of max size)
- Basic HTTP parsing

**Recommendations**:
1. Trust your backends (network isolation)
2. Validate backend certificates (if using TLS to backends)
3. Implement response validation in fork if needed

### Health Check Security

**Current**: Passive health checks (connection success/failure).

**Considerations**:
- Failed backends are marked unhealthy
- Exponential backoff prevents thundering herd
- No credentials sent during health checks

## System Hardening

### Run as Non-Root

**Always** run as a dedicated user:

```bash
# Create user
sudo useradd -r -s /bin/false prozy

# If binding to privileged port (<1024), grant capability
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/prozy

# Start as prozy user
sudo -u prozy /usr/local/bin/prozy
```

### Systemd Hardening

Use systemd security features:

```ini
[Service]
User=prozy
Group=prozy

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true

# Resource limits
LimitNOFILE=65536
MemoryMax=4G
TasksMax=4096
```

### Filesystem Security

Restrict filesystem access:

```bash
# Binary permissions
chmod 755 /usr/local/bin/prozy
chown root:root /usr/local/bin/prozy

# Cache directory
mkdir -p /var/cache/prozy
chown prozy:prozy /var/cache/prozy
chmod 700 /var/cache/prozy
```

### SELinux / AppArmor

Use mandatory access control:

**AppArmor profile** (`/etc/apparmor.d/usr.local.bin.prozy`):

```
#include <tunables/global>

/usr/local/bin/prozy {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  /usr/local/bin/prozy mr,
  /var/cache/prozy/ rw,
  /var/cache/prozy/** rw,

  network inet stream,
  network inet6 stream,

  capability net_bind_service,
}
```

## Monitoring & Incident Response

### Logging

Enable comprehensive logging:

```bash
# Set log level
export ZIG_LOG_LEVEL=info

# Systemd journal
journalctl -u prozy -f

# File logging with rotation
StandardOutput=file:/var/log/prozy/access.log
```

### Security Monitoring

**Monitor these events:**

1. **Access control denials**:
   ```bash
   journalctl -u prozy | grep "denied"
   ```

2. **Rate limit violations**:
   ```bash
   journalctl -u prozy | grep "rate limit"
   ```

3. **Backend failures**:
   ```bash
   journalctl -u prozy | grep "Backend connection failed"
   ```

4. **Unusual traffic patterns**:
   - Sudden spike in connections
   - High error rates
   - Low cache hit rates (possible cache poisoning attempt)

### Alerts

Set up alerts for:
- Backend failure rate > 10%
- Connection rate > threshold
- Memory usage > 80%
- Cache hit rate < 50% (if expected higher)

### Incident Response

**If compromised:**

1. **Isolate**: Block incoming traffic
2. **Investigate**: Review logs for attack vector
3. **Patch**: Apply security updates
4. **Restore**: From known-good backup
5. **Monitor**: Watch for continued attack

**If DoS attack:**

1. **Enable stricter rate limiting**
2. **Block malicious IPs** via access control
3. **Scale horizontally** (add more Prozy instances)
4. **Use upstream DDoS mitigation** (Cloudflare, AWS Shield, etc.)

## Security Checklist

### Deployment Security

- [ ] Running as non-root user
- [ ] Bound to specific interface (not 0.0.0.0)
- [ ] Firewall configured
- [ ] TLS termination in place (Nginx/HAProxy)
- [ ] Access control enabled with appropriate policy
- [ ] Rate limiting enabled
- [ ] Resource limits configured (memory, file descriptors)
- [ ] Systemd hardening enabled
- [ ] Logging configured
- [ ] Monitoring/alerting set up

### Network Security

- [ ] Network segmentation (DMZ/proxy tier)
- [ ] Private network to backends
- [ ] Backend authentication (mTLS/VPN)
- [ ] Load balancer health checks configured
- [ ] Connection timeouts appropriate for use case

### Operational Security

- [ ] Regular security updates
- [ ] Log rotation configured
- [ ] Backup and restore tested
- [ ] Incident response plan documented
- [ ] Security monitoring active
- [ ] Access to proxy host restricted

### Code Security

- [ ] Built with `-Doptimize=ReleaseSafe` or `ReleaseFast`
- [ ] No custom patches without security review
- [ ] Dependencies audited (Zig toolchain only)
- [ ] Configuration reviewed for security implications

## Security Best Practices

1. **Defense in Depth**: Multiple security layers (firewall + access control + rate limiting)
2. **Least Privilege**: Run as dedicated user, minimal permissions
3. **Network Isolation**: Separate proxy tier from backends
4. **Monitoring**: Log everything, alert on anomalies
5. **Keep Updated**: Track Prozy updates and security advisories
6. **Test Security**: Regular penetration testing and security audits
7. **Document Configuration**: Clear documentation of security decisions

## Known Security Considerations

### Request Smuggling

**Risk**: HTTP request smuggling via Content-Length/Transfer-Encoding confusion.

**Status**: Prozy does basic HTTP parsing but is not vulnerable to classic request smuggling because:
- One request per connection (no pipelining)
- Request buffering (8KB) then direct forwarding
- No request/response manipulation

**For forks**: If adding keep-alive support, implement RFC 7230 compliant parsing.

### Cache Poisoning

**Risk**: Attacker caches malicious content.

**Mitigations**:
- Cache key includes Host header
- Requests without Host header bypass cache (logged)
- Only GET requests cached
- Cache size limits prevent fill attacks

**Recommendation**: Monitor cache hit rates and "missing Host header" warnings.

### Slowloris

**Risk**: Slow clients hold connections open indefinitely.

**Mitigations**:
- 30-second bidirectional timeout
- Rate limiting (connection limits)

**For high-risk environments**: Reduce timeout to 10 seconds.

### Memory Exhaustion

**Risk**: Large cache or many connections exhaust memory.

**Mitigations**:
- Cache size limit (configurable)
- LRU eviction
- Rate limiting (connection limits)
- Systemd memory limits

**Monitoring**: Track memory usage and set alerts.

## Compliance

### Data Protection

Prozy logs:
- Client IP addresses
- Connection statistics
- HTTP request lines (method, path)

**For GDPR/privacy compliance**:
- Review log retention policies
- Anonymize IPs if required (extend in fork)
- Document data processing

### Security Standards

Prozy can support:
- **PCI DSS**: Use with TLS termination, access control, logging
- **HIPAA**: Deploy in compliant infrastructure with encryption
- **SOC 2**: Enable comprehensive logging and monitoring

**Note**: Prozy alone is not sufficient for compliance. Use as part of a compliant architecture.

---

**Questions?** Open a [GitHub Discussion](https://github.com/sammyjoyce/prozy/discussions) or email maintainers for security issues.
