# Changelog

All notable changes to Prozy will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-11-16

### Production Release

This is the first production-ready release of Prozy, suitable for forking and building purpose-specific proxies.

#### Core Features

- ✅ **True Async I/O**: Using Zig 0.16.x `std.Io.Threaded` runtime
- ✅ **Concurrent Connections**: `io.concurrent()` for parallel client handling
- ✅ **Bidirectional Proxying**: `io.select()` for duplex data flow with 30-second timeout
- ✅ **HTTP Response Caching**: O(1) LRU cache with RwLock concurrency and TTL
- ✅ **Load Balancing**: 5 strategies (round-robin, weighted, least-connections, random, IP hash)
- ✅ **Access Control**: IP-based allow/deny lists for IPv4 and IPv6
- ✅ **Rate Limiting**: Per-IP and global connection throttling
- ✅ **Backend Health Management**: Exponential backoff recovery (5s → 300s max)
- ✅ **Comprehensive Monitoring**: Real-time statistics and metrics

#### Architecture

- Request buffering (8KB) to prevent data loss during cache inspection
- Automatic backend failover with health tracking
- Thread-safe atomic operations for statistics
- Proper resource cleanup with defer statements
- Cross-platform support (Linux, macOS, Windows)

#### Testing

- 40+ comprehensive unit tests covering all features
- Integration tests with end-to-end HTTP proxying
- Load balancer strategy verification
- Cache effectiveness testing
- Backend health and recovery testing

#### Documentation

- Complete architecture documentation with GraphViz diagrams
- Prozy coding style guide (CLAUDE.md)
- Production deployment guide
- Security hardening recommendations
- Fork and contribution guidelines

#### Known Limitations

- One HTTP request per TCP connection (no keep-alive/pipelining)
- Cache serving only (no backend response caching yet)
- Reactive health checks only (no proactive polling)
- Fixed-size buffers (4KB + 8KB per connection)
- No TLS termination (can be added)

---

## Future Releases

### Planned for 1.1.0
- [ ] Cache population from backend responses
- [ ] Proactive backend health checks
- [ ] HTTP header manipulation (X-Forwarded-For, Via)
- [ ] Metrics export (Prometheus format)
- [ ] Configuration file support (TOML/JSON)

### Planned for 2.0.0
- [ ] TLS/SSL termination
- [ ] HTTP keep-alive and pipelining support
- [ ] Dynamic backend configuration
- [ ] WebSocket proxying
- [ ] HTTP/2 support

---

[1.0.0]: https://github.com/sammyjoyce/prozy/releases/tag/v1.0.0
