const std = @import("std");
const Backend = @import("./backend.zig").Backend;
const IpKey = @import("./ip_key.zig").IpKey;

pub const LoadBalancer = struct {
    backends: []Backend,
    current_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    strategy: Strategy,
    mutex: std.Thread.Mutex = .{},
    rng: std.Random.DefaultPrng,

    pub const Strategy = enum {
        round_robin,
        weighted_round_robin,
        least_connections,
        random,
        ip_hash,
    };

    pub fn init(backends: []Backend, strategy: Strategy) LoadBalancer {
        const seed = blk: {
            const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch break :blk 0;
            break :blk @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
        };
        return .{
            .backends = backends,
            .strategy = strategy,
            .rng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn selectBackend(self: *LoadBalancer, client_ip: IpKey) ?*Backend {
        return switch (self.strategy) {
            .round_robin => self.roundRobin(),
            .weighted_round_robin => self.weightedRoundRobin(),
            .least_connections => self.leastConnections(),
            .random => self.randomBackend(),
            .ip_hash => self.ipHash(client_ip),
        };
    }

    /// Backend eligibility predicate function signature.
    /// Returns true if the backend is eligible for selection.
    const BackendEligibilityFn = *const fn (backend: *const Backend) bool;

    /// Context structure for strategy-specific selection logic.
    const SelectionContext = struct {
        load_balancer: *LoadBalancer,
        start_index: usize,
        client_ip: IpKey,
    };

    /// Backend selector function signature.
    /// Takes backends array, eligibility predicate, and context.
    /// Returns selected backend or null if no eligible backend found.
    const BackendSelectorFn = *const fn (
        backends: []Backend,
        is_eligible: BackendEligibilityFn,
        context: SelectionContext,
    ) ?*Backend;

    /// Two-pass backend selection with health-based retry logic.
    ///
    /// This helper implements the common pattern used across all load balancing strategies:
    /// - Pass 1: Try to select from healthy backends (isHealthy() == true)
    /// - Pass 2: Try backends eligible for retry (shouldRetry() == true)
    ///
    /// This pattern enables automatic failover and health recovery while keeping
    /// strategy-specific selection logic separate and reusable.
    ///
    /// Arguments:
    ///   selector: Strategy-specific function that implements backend selection logic
    ///   context: Context containing load balancer state and request parameters
    ///
    /// Returns:
    ///   Selected backend pointer or null if no eligible backend exists
    fn selectBackendWithRetry(
        selector: BackendSelectorFn,
        context: SelectionContext,
    ) ?*Backend {
        const is_healthy: BackendEligibilityFn = &Backend.isHealthy;
        const should_retry: BackendEligibilityFn = &Backend.shouldRetry;

        // First pass: try healthy backends for optimal performance.
        if (selector(context.load_balancer.backends, is_healthy, context)) |backend| {
            return backend;
        }

        // Second pass: try backends ready for retry to enable health recovery.
        if (selector(context.load_balancer.backends, should_retry, context)) |backend| {
            return backend;
        }

        return null;
    }

    /// Round robin selector: cycles through backends sequentially.
    fn roundRobinSelector(
        backends: []Backend,
        is_eligible: BackendEligibilityFn,
        context: SelectionContext,
    ) ?*Backend {
        for (0..backends.len) |i| {
            const index = (context.start_index + i) % backends.len;
            const backend = &backends[index];
            if (is_eligible(backend)) {
                return backend;
            }
        }
        return null;
    }

    fn roundRobin(self: *LoadBalancer) ?*Backend {
        const start_index = self.current_index.fetchAdd(1, .monotonic);
        const context = SelectionContext{
            .load_balancer = self,
            .start_index = start_index,
            .client_ip = .{ .ipv4 = 0 },
        };
        return selectBackendWithRetry(roundRobinSelector, context);
    }

    /// Weighted round robin selector: distributes traffic based on backend weights.
    fn weightedRoundRobinSelector(
        backends: []Backend,
        is_eligible: BackendEligibilityFn,
        context: SelectionContext,
    ) ?*Backend {
        // Calculate total weight of eligible backends.
        var total_weight: u32 = 0;
        for (backends) |backend| {
            if (is_eligible(&backend)) {
                total_weight += backend.weight;
            }
        }

        if (total_weight == 0) return null;

        // Select backend based on weighted distribution.
        // Note: Counter is NOT incremented here to prevent double-increment
        // in selectBackendWithRetry two-pass selection. The counter is
        // incremented once per public call in weightedRoundRobin() method.
        const index = context.start_index;
        const total_weight_usize = @as(usize, @intCast(total_weight));
        var target = @as(u32, @intCast(index % total_weight_usize));

        for (backends) |*backend| {
            if (!is_eligible(backend)) continue;
            if (target < backend.weight) {
                return backend;
            }
            target -= backend.weight;
        }

        return null;
    }

    fn weightedRoundRobin(self: *LoadBalancer) ?*Backend {
        // No mutex needed: fetchAdd is atomic, backends array is immutable,
        // and selectBackendWithRetry only reads backend state via atomics
        const start_index = self.current_index.fetchAdd(1, .monotonic);

        const context = SelectionContext{
            .load_balancer = self,
            .start_index = start_index,
            .client_ip = .{ .ipv4 = 0 },
        };
        return selectBackendWithRetry(weightedRoundRobinSelector, context);
    }

    /// Least connections selector: routes to backend with fewest active connections.
    fn leastConnectionsSelector(
        backends: []Backend,
        is_eligible: BackendEligibilityFn,
        context: SelectionContext,
    ) ?*Backend {
        _ = context;
        var min_connections: u32 = std.math.maxInt(u32);
        var selected: ?*Backend = null;

        for (backends) |*backend| {
            if (!is_eligible(backend)) continue;
            const connections = backend.getConnections();
            if (connections < min_connections) {
                min_connections = connections;
                selected = backend;
            }
        }

        return selected;
    }

    fn leastConnections(self: *LoadBalancer) ?*Backend {
        // No mutex needed: connection counts are read via atomics
        const context = SelectionContext{
            .load_balancer = self,
            .start_index = 0,
            .client_ip = .{ .ipv4 = 0 },
        };
        return selectBackendWithRetry(leastConnectionsSelector, context);
    }

    /// Random selector: randomly selects from eligible backends.
    fn randomBackendSelector(
        backends: []Backend,
        is_eligible: BackendEligibilityFn,
        context: SelectionContext,
    ) ?*Backend {
        // Count eligible backends.
        var eligible_count: usize = 0;
        for (backends) |backend| {
            if (is_eligible(&backend)) eligible_count += 1;
        }

        if (eligible_count == 0) return null;

        // Randomly select one of the eligible backends.
        const random = context.load_balancer.rng.random();
        const target = random.uintLessThan(usize, eligible_count);
        var count: usize = 0;

        for (backends) |*backend| {
            if (is_eligible(backend)) {
                if (count == target) return backend;
                count += 1;
            }
        }

        return null;
    }

    fn randomBackend(self: *LoadBalancer) ?*Backend {
        self.mutex.lock();
        defer self.mutex.unlock();

        const context = SelectionContext{
            .load_balancer = self,
            .start_index = 0,
            .client_ip = .{ .ipv4 = 0 },
        };
        return selectBackendWithRetry(randomBackendSelector, context);
    }

    /// IP hash selector: provides session affinity based on client IP.
    fn ipHashSelector(
        backends: []Backend,
        is_eligible: BackendEligibilityFn,
        context: SelectionContext,
    ) ?*Backend {
        const ip_hash = context.client_ip.hash();
        const index = @as(usize, @intCast(ip_hash % @as(u64, @intCast(backends.len))));

        for (0..backends.len) |i| {
            const backend_index = (index + i) % backends.len;
            const backend = &backends[backend_index];
            if (is_eligible(backend)) {
                return backend;
            }
        }

        return null;
    }

    fn ipHash(self: *LoadBalancer, client_ip: IpKey) ?*Backend {
        const context = SelectionContext{
            .load_balancer = self,
            .start_index = 0,
            .client_ip = client_ip,
        };
        return selectBackendWithRetry(ipHashSelector, context);
    }
};
