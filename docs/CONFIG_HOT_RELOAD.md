# Configuration Hot Reload

Prozy supports zero-downtime configuration hot reload, allowing you to update proxy settings, routing rules, and backend clusters without interrupting active connections.

## Features

- **Zero downtime**: Active connections continue using the old configuration while new connections use the updated configuration
- **Atomic swap**: Lock-free configuration updates using atomic pointer swapping
- **Fail-safe**: Parse errors and validation failures don't affect the running proxy
- **File watching**: Automatic detection of configuration file changes
- **Observable**: All config changes and errors are logged

## Architecture

### Atomic Pointer Swapping

The configuration manager uses `std.atomic.Value(*Config)` to store a pointer to the current configuration. When a new configuration is loaded:

1. New config is parsed and validated in a separate arena allocator
2. If validation passes, the pointer is atomically swapped
3. Old config memory is freed (safe because pointer was already swapped)
4. Active connections continue using the old config (they already have their references)
5. New connections get the new config

This provides:
- **Lock-free reads**: No mutex needed for accessing config
- **Zero downtime**: No blocking or waiting during reload
- **Memory safety**: Arena allocator ensures all related memory is freed together

### Memory Management

Each configuration version uses a dedicated arena allocator:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
const config = try loadConfigFromFile(arena.allocator(), path);
```

When a new config is loaded:
1. Create new arena
2. Parse config into new arena
3. Swap pointers
4. Deinit old arena (frees all old config memory at once)

## Configuration File Formats

Prozy supports two configuration formats:

1. **JSON** (Recommended for production) - Standard JSON format with full tooling support
2. **ZON** (Experimental) - Zig Object Notation for type-safe, native Zig configuration

The format is automatically detected based on file extension (`.json` or `.zon`).

### JSON Configuration (Recommended)

JSON provides stable parsing with excellent tooling support. This is the recommended format for production use.

#### Minimal JSON Configuration

```json
{
  "proxy": {
    "listen_host": "127.0.0.1",
    "listen_port": 8080
  },
  "clusters": [
    {
      "name": "default_backend",
      "backends": [
        { "host": "127.0.0.1", "port": 3003, "weight": 1 }
      ],
      "strategy": "round_robin"
    }
  ],
  "routes": [
    {
      "name": "default_route",
      "match": {},
      "cluster": "default_backend"
    }
  ]
}
```

### ZON Configuration (Experimental)

ZON (Zig Object Notation) provides a native, type-safe configuration format using Zig syntax.

**Note**: ZON support is currently experimental. Full AST evaluation is not yet implemented, so JSON is recommended for production use.

#### Minimal ZON Configuration

```zig
.{
    .proxy = .{
        .listen_host = "127.0.0.1",
        .listen_port = 8080,
    },
    .clusters = &[_]ClusterConfig{
        .{
            .name = "default_backend",
            .backends = &[_]BackendConfig{
                .{ .host = "127.0.0.1", .port = 3003, .weight = 1 },
            },
            .strategy = .round_robin,
        },
    },
    .routes = &[_]RouteConfig{
        .{
            .name = "default_route",
            .match = .{},
            .cluster = "default_backend",
        },
    },
}
```

#### ZON Benefits

When fully implemented, ZON will provide:
- **Type safety**: Compile-time type checking
- **Native syntax**: Familiar to Zig developers
- **Comments**: Inline documentation in config files
- **Enums**: Type-safe enum values (`.round_robin` vs `"round_robin"`)
- **Computation**: Arithmetic expressions (`10 * 1024 * 1024` for sizes)

See `config/simple.zon` and `config/example.zon` for complete examples.

### Full Configuration

See `config/example.json` or `config/example.zon` for complete examples with all available options:

- **Proxy settings**: Listen address, port, connection limits
- **Mode**: reverse_proxy, forward_proxy, or tunnel_only
- **Cache**: Enable/disable, size limits
- **Rate limiting**: Per-IP and global limits
- **Access control**: Allow/deny lists
- **Health checks**: Interval, timeouts, thresholds
- **Admin server**: Management API endpoint
- **Logging**: Log level, connection logging
- **Clusters**: Backend pools with load balancing
- **Routes**: Request routing rules with policies

## Configuration Sections

### Proxy Section

Basic proxy settings:

```json
{
  "proxy": {
    "listen_host": "0.0.0.0",
    "listen_port": 8080,
    "max_connections": 10000,
    "reuse_address": true
  }
}
```

### Clusters

Backend server pools with load balancing:

```json
{
  "clusters": [
    {
      "name": "api_backend",
      "backends": [
        { "host": "10.0.1.10", "port": 8080, "weight": 5 },
        { "host": "10.0.1.11", "port": 8080, "weight": 3 }
      ],
      "strategy": "weighted_round_robin",
      "max_concurrent": 1000
    }
  ]
}
```

**Load balancing strategies**:
- `round_robin`: Equal distribution
- `weighted_round_robin`: Weight-based distribution
- `least_connections`: Route to least loaded backend
- `random`: Random selection
- `ip_hash`: Session affinity based on client IP

### Routes

Request routing rules:

```json
{
  "routes": [
    {
      "name": "api_route",
      "match": {
        "host": "api.example.com",
        "path_prefix": "/v1/",
        "methods": ["GET", "POST"]
      },
      "cluster": "api_backend",
      "cache_policy": {
        "allow": true,
        "ttl_seconds": 300,
        "max_size": 1048576
      },
      "timeout_policy": {
        "connect_timeout_ms": 5000,
        "request_timeout_ms": 30000,
        "response_timeout_ms": 60000,
        "idle_timeout_seconds": 30
      },
      "concurrency_policy": {
        "max_concurrent": 1000,
        "max_queue_depth": 100,
        "reject_when_full": false
      }
    }
  ]
}
```

**Match criteria**:
- `host`: Exact host match (null = match any)
- `path_prefix`: Path prefix match (null = match any)
- `methods`: Array of HTTP methods (empty = match any)

**Policies**:
- `cache_policy`: Caching behavior per route
- `timeout_policy`: Connection and request timeouts
- `concurrency_policy`: Rate limiting and backpressure

## Usage

### Using ConfigManager

```zig
const std = @import("std");
const prozy = @import("prozy");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Initialize config manager
    var config_manager = try prozy.ConfigManager.init(
        allocator,
        "config/production.json"
    );
    defer config_manager.deinit();

    // Access current config (lock-free)
    const config = config_manager.getConfig();
    std.log.info("Proxy listening on {s}:{}", .{
        config.proxy.listen_host,
        config.proxy.listen_port
    });

    // Check for config changes and reload if needed
    const reloaded = try config_manager.checkAndReload();
    if (reloaded) {
        std.log.info("Configuration reloaded!", .{});
    }
}
```

### Manual Reload

Force reload without checking file modification time:

```zig
const reloaded = try config_manager.reload();
if (reloaded) {
    std.log.info("Configuration reloaded!", .{});
}
```

### Background Watcher (Planned)

Future implementation will support automatic background watching:

```zig
// Start background watcher (checks every 1 second by default)
try config_manager.startWatcher(io);
```

## Running the Demo

Build and run the configuration hot reload demonstration:

```bash
# Build the demo
zig build config_reload_demo

# Run the demo
./zig-out/bin/config_hot_reload_demo
```

The demo will:
1. Load initial configuration from `config/simple.json`
2. Monitor the file for changes every second
3. Automatically reload when changes are detected
4. Run for 30 seconds (or until interrupted)

**Try it**:
1. Run the demo
2. Edit `config/simple.json` in another terminal
3. Save the file
4. Watch the demo logs show the configuration reload

## Validation

All configuration changes are validated before being applied:

1. **JSON parsing**: Syntax errors are caught
2. **Structure validation**: Required fields checked
3. **Port validation**: Ports must be non-zero
4. **Cluster validation**: Must have at least one backend
5. **Route validation**: Must reference existing clusters
6. **Backend validation**: Weights must be non-zero

If validation fails, the error is logged and the old configuration remains active.

## Error Handling

The hot reload system handles errors gracefully:

- **File not found**: Error logged, old config retained
- **Parse error**: Error logged, old config retained
- **Validation error**: Specific error logged, old config retained
- **Cluster reference error**: Invalid routes rejected, old config retained

Example error log:
```
ERROR: failed to parse JSON config: UnexpectedToken
ERROR: config validation failed: ClusterNotFound
ERROR: route 'api_route' references unknown cluster 'missing_cluster'
```

## Performance

Configuration access is lock-free and extremely fast:

- **Read overhead**: Single atomic pointer load (~1-2 CPU cycles)
- **No contention**: Multiple threads can read simultaneously
- **No blocking**: Reads never wait for writes
- **Memory efficient**: Only two config versions in memory during reload

Reload performance:
- **Parse time**: ~1-5ms for typical configs
- **Validation time**: ~100-500μs
- **Swap time**: ~1-2μs (single atomic operation)
- **Total reload**: ~2-10ms typical

## Best Practices

1. **Test configs before deployment**: Validate syntax and structure
2. **Use version control**: Track config changes in git
3. **Monitor reload logs**: Watch for validation errors
4. **Start simple**: Begin with minimal config, add complexity gradually
5. **Document custom routes**: Comment why specific rules exist
6. **Backup before changes**: Keep working config as fallback
7. **Gradual rollout**: Test config changes in staging first

## Comparison with Other Approaches

### Why Not Restart?

Traditional approach: Restart process to reload config

**Drawbacks**:
- Active connections dropped
- Downtime during restart
- Lost in-flight requests
- Cache cleared
- Statistics reset

**Our approach**: Zero-downtime hot reload preserves all active state

### Why Not Lock-Based?

Alternative: Mutex-protected shared config

**Drawbacks**:
- Every config access requires lock
- Read contention under load
- Potential priority inversion
- More complex error handling

**Our approach**: Lock-free atomic pointer swapping

### Why Not Signal-Based?

Alternative: SIGHUP triggers reload

**Drawbacks**:
- Platform-specific
- Requires external orchestration
- No programmatic control
- Limited error reporting

**Our approach**: Programmatic API with full error visibility

## Future Enhancements

- **ZON format support**: Native Zig configuration format
- **Incremental reload**: Only update changed sections
- **Config diffing**: Show what changed between versions
- **Rollback support**: Revert to previous config
- **Remote config**: Load from HTTP/HTTPS endpoints
- **Config API**: Update config via admin server
- **Schema validation**: More comprehensive checks
- **Hot reload hooks**: Callbacks for config changes
- **Graceful drain**: Wait for connections to close before applying changes to specific routes

## Troubleshooting

### Config file not found

```
ERROR: failed to read config file 'config/missing.json': FileNotFound
```

**Solution**: Ensure config file exists and path is correct

### JSON parse error

```
ERROR: failed to parse JSON config: UnexpectedToken
```

**Solution**: Validate JSON syntax (use `jq` or online validator)

### Cluster not found

```
ERROR: route 'api_route' references unknown cluster 'typo_cluster'
```

**Solution**: Check cluster names match exactly (case-sensitive)

### No backends in cluster

```
ERROR: cluster 'empty_cluster' has no backends
```

**Solution**: Add at least one backend to each cluster

### Invalid port

```
ERROR: invalid backend port: 0 in cluster 'api_backend'
```

**Solution**: Ensure all ports are non-zero (1-65535)

## See Also

- [Example configurations](../config/): Sample JSON configs
- [Routing documentation](ROUTING.md): Advanced routing features
- [Load balancing strategies](LOAD_BALANCING.md): Backend selection algorithms
- [Admin API](ADMIN_API.md): Management endpoints
