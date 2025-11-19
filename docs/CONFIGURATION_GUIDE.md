# Prozy Configuration Guide

Prozy supports configuration via JSON or ZON (Zig Object Notation) files. Configuration allows you to define proxy behavior, routing rules, load balancing clusters, and feature policies.

## Loading Configuration

You can load a configuration file using the `ConfigManager`:

```zig
const manager = try ConfigManager.init(allocator, "config.json");
defer manager.deinit();

// Start background watcher for hot reload (optional)
try manager.startWatcher(io);

// Get current config
var lease = manager.getConfig();
defer lease.release();
const config = lease.get();
```

## Configuration Format

### Basic Structure

```json
{
  "proxy": {
    "listen_host": "0.0.0.0",
    "listen_port": 8080
  },
  "mode": "reverse_proxy",
  "clusters": [...],
  "routes": [...]
}
```

### Proxy Settings

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `listen_host` | string | "127.0.0.1" | Interface to bind to |
| `listen_port` | integer | 8080 | TCP port to listen on |
| `max_connections` | integer | null | Max concurrent client connections (null = unlimited) |
| `reuse_address` | boolean | true | Allow reusing socket address |

### Routing

Prozy supports powerful routing based on Host header, path prefix, and HTTP method.

```json
"routes": [
  {
    "name": "api_route",
    "match": {
      "host": "api.example.com",
      "path_prefix": "/v1",
      "methods": ["GET", "POST"]
    },
    "cluster": "api_backend",
    "cache_policy": {
      "allow": true,
      "ttl_seconds": 60
    },
    "timeout_policy": {
      "connect_timeout_ms": 5000
    }
  }
]
```

### Clusters (Load Balancing)

Backends are grouped into clusters.

```json
"clusters": [
  {
    "name": "api_backend",
    "strategy": "weighted_round_robin",
    "max_concurrent": 1000,
    "backends": [
      { "host": "10.0.1.1", "port": 8080, "weight": 5 },
      { "host": "10.0.1.2", "port": 8080, "weight": 1 }
    ]
  }
]
```

Supported strategies:
- `round_robin`: Rotate sequentially
- `weighted_round_robin`: Respect weights
- `least_connections`: Pick backend with fewest active connections
- `ip_hash`: Consistent hashing based on client IP
- `random`: Pick randomly

### Features

#### Caching

```json
"cache": {
  "enabled": true,
  "max_size": 10485760
}
```

#### Rate Limiting

```json
"rate_limit": {
  "enabled": true,
  "max_per_ip": 100,
  "max_global": 10000
}
```

#### Access Control

```json
"access_control": {
  "enabled": true,
  "default_policy": "deny",
  "allow_list": ["127.0.0.1", "10.0.0.0/8"],
  "deny_list": ["192.168.1.5"]
}
```

## ZON Format Example

Prozy also supports ZON, which allows comments and trailing commas.

```zig
.{
    .proxy = .{
        .listen_port = 8080,
    },
    .clusters = .{
        .{
            .name = "backend",
            .backends = .{
                .{ .host = "localhost", .port = 3000 },
            },
        },
    },
    .routes = .{
        .{
            .name = "default",
            .match = .{},
            .cluster = "backend",
        },
    },
}
```

## Hot Reload

When using `ConfigManager` with the background watcher enabled, changes to the configuration file are automatically detected and applied without dropping active connections.

- **Active connections** continue to use the configuration snapshot that was active when they started.
- **New connections** pick up the new configuration immediately.
- Old configuration memory is safely reclaimed when all active connections using it have finished.
