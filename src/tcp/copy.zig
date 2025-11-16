//! TCP bidirectional copy operations for proxy data forwarding
//!
//! This module provides efficient bidirectional data copying between client and backend
//! connections with support for:
//! - Concurrent bidirectional copying using io.concurrent() and io.select()
//! - Statistics tracking and performance monitoring
//! - HTTP response caching with intelligent buffering
//! - 30-second timeout enforcement to prevent hung connections
//! - Graceful error handling and resource cleanup

const std = @import("std");
const builtin = @import("builtin");

// Core imports
const ProxyStats = @import("../core/stats.zig").ProxyStats;
const HTTPInspector = @import("../http/inspector.zig").HTTPInspector;
const HTTPCache = @import("../http/cache.zig").HTTPCache;

const proxy_core = @import("../app/proxy_core.zig");
const RunOptions = proxy_core.RunOptions;

const log = std.log;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Duration = Io.Duration;

/// Timeout configuration for bidirectional copy operations
///
/// After one direction of a connection completes, the proxy waits up to 30 seconds
/// for the other direction before timing out and canceling. This prevents hung
/// connections during HTTP keep-alive scenarios and network partitions.
pub const BIDIRECTIONAL_TIMEOUT_SECONDS: i64 = 30;

// ============= Copy Job Types =============

/// Simple pipe job for basic data copying
pub const PipeJob = struct {
    reader: *Reader,
    writer: *Writer,
};

/// Copy error union covering all possible read/write errors
pub const CopyError = Reader.Error || Writer.Error;

/// Pipe job with statistics tracking
pub const PipeJobWithStats = struct {
    reader: *Reader,
    writer: *Writer,
    stats: *ProxyStats,
    direction: Direction,
    http_inspector: *const HTTPInspector,
    enable_http_inspection: bool,

    pub const Direction = enum {
        client_to_backend,
        backend_to_client,
    };
};

/// Pipe job with HTTP response caching support
pub const PipeJobWithCaching = struct {
    reader: *Reader,
    writer: *Writer,
    stats: *ProxyStats,
    direction: Direction,
    http_inspector: *const HTTPInspector,
    enable_http_inspection: bool,
    http_cache: *HTTPCache,
    request_method: []const u8,
    request_host: []const u8,
    request_path: []const u8,
    allocator: std.mem.Allocator,

    pub const Direction = enum {
        client_to_backend,
        backend_to_client,
    };

    // Configuration constants for cache population
    pub const default_ttl_seconds: u32 = 300;
    pub const max_cacheable_size: usize = 1024 * 1024; // 1MB
};

// ============= Bidirectional Copy Functions =============

/// Copy data bidirectionally between client and backend (basic version)
///
/// Uses io.concurrent() to run both directions in parallel and io.select() to
/// coordinate completion. Implements 30-second timeout after first direction
/// completes to prevent hung connections.
pub fn copyBidirectional(
    io: Io,
    client_reader: *Reader,
    backend_writer: *Writer,
    backend_reader: *Reader,
    client_writer: *Writer,
) void {
    const job_c2b = PipeJob{ .reader = client_reader, .writer = backend_writer };
    const job_b2c = PipeJob{ .reader = backend_reader, .writer = client_writer };

    // Simple approach: use concurrency but wait for both to complete naturally
    var future_c2b = io.concurrent(copyPipe, .{job_c2b}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            sequentialCopy(job_c2b);
            sequentialCopy(job_b2c);
            return;
        },
    };

    var future_b2c = io.concurrent(copyPipe, .{job_b2c}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            future_c2b.cancel(io) catch {};
            sequentialCopy(job_c2b);
            sequentialCopy(job_b2c);
            return;
        },
    };

    // Use io.select to wait for first completion, then wait for second without canceling
    const first_completed = io.select(.{
        .client_to_backend = &future_c2b,
        .backend_to_client = &future_b2c,
    }) catch |err| {
        log.err("io.select failed: {s}", .{@errorName(err)});
        future_c2b.cancel(io) catch {};
        future_b2c.cancel(io) catch {};
        return;
    };

    // Wait for second completion with timeout and error handling
    switch (first_completed) {
        .client_to_backend => |completion_result| {
            // Check if first direction succeeded or failed
            if (completion_result) |_| {
                // Success: wait for backend->client with timeout
                handleCopyResult("client->backend", completion_result);

                // Launch timeout future
                var timeout_future = io.concurrent(sleepForTimeout, .{ io, BIDIRECTIONAL_TIMEOUT_SECONDS }) catch |err| switch (err) {
                    error.ConcurrencyUnavailable => {
                        // Fallback: wait without timeout
                        const second_completed = io.select(.{
                            .backend_to_client = &future_b2c,
                        }) catch |err2| {
                            log.err("second io.select failed: {s}, canceling backend->client", .{@errorName(err2)});
                            future_b2c.cancel(io) catch {};
                            return;
                        };
                        switch (second_completed) {
                            .backend_to_client => |result| handleCopyResult("backend->client", result),
                        }
                        return;
                    },
                };

                const second_completed = io.select(.{
                    .backend_to_client = &future_b2c,
                    .timeout = &timeout_future,
                }) catch |err| {
                    log.err("second io.select failed: {s}, canceling both futures", .{@errorName(err)});
                    future_b2c.cancel(io) catch {};
                    timeout_future.cancel(io);
                    return;
                };

                switch (second_completed) {
                    .backend_to_client => |result| {
                        timeout_future.cancel(io);
                        handleCopyResult("backend->client", result);
                    },
                    .timeout => {
                        log.warn("backend->client timeout after {d}s, canceling", .{BIDIRECTIONAL_TIMEOUT_SECONDS});
                        future_b2c.cancel(io) catch {};
                    },
                }
            } else |err| {
                // Error in client->backend: cancel backend->client immediately
                log.err("client->backend failed: {s}, canceling backend->client", .{@errorName(err)});
                handleCopyResult("client->backend", completion_result);
                future_b2c.cancel(io) catch {};
            }
        },
        .backend_to_client => |completion_result| {
            // Check if first direction succeeded or failed
            if (completion_result) |_| {
                // Success: wait for client->backend with timeout
                handleCopyResult("backend->client", completion_result);

                // Launch timeout future
                var timeout_future = io.concurrent(sleepForTimeout, .{ io, BIDIRECTIONAL_TIMEOUT_SECONDS }) catch |err| switch (err) {
                    error.ConcurrencyUnavailable => {
                        // Fallback: wait without timeout
                        const second_completed = io.select(.{
                            .client_to_backend = &future_c2b,
                        }) catch |err2| {
                            log.err("second io.select failed: {s}, canceling client->backend", .{@errorName(err2)});
                            future_c2b.cancel(io) catch {};
                            return;
                        };
                        switch (second_completed) {
                            .client_to_backend => |result| handleCopyResult("client->backend", result),
                        }
                        return;
                    },
                };

                const second_completed = io.select(.{
                    .client_to_backend = &future_c2b,
                    .timeout = &timeout_future,
                }) catch |err| {
                    log.err("second io.select failed: {s}, canceling both futures", .{@errorName(err)});
                    future_c2b.cancel(io) catch {};
                    timeout_future.cancel(io);
                    return;
                };

                switch (second_completed) {
                    .client_to_backend => |result| {
                        timeout_future.cancel(io);
                        handleCopyResult("client->backend", result);
                    },
                    .timeout => {
                        log.warn("client->backend timeout after {d}s, canceling", .{BIDIRECTIONAL_TIMEOUT_SECONDS});
                        future_c2b.cancel(io) catch {};
                    },
                }
            } else |err| {
                // Error in backend->client: cancel client->backend immediately
                log.err("backend->client failed: {s}, canceling client->backend", .{@errorName(err)});
                handleCopyResult("backend->client", completion_result);
                future_c2b.cancel(io) catch {};
            }
        },
    }
}

/// Copy data bidirectionally with statistics tracking
///
/// CRITICAL FIXES:
/// 1. 30-second timeout: Uses io.concurrent(sleep, ...) + io.select() to enforce timeout
/// 2. Cancel opposite direction immediately when one side fails (resource cleanup)
/// 3. Proper error propagation with stats recording
///
/// Previous issues:
/// - No timeout: connections could hang forever waiting for EOF
/// - No cancellation: failed direction kept other side running indefinitely
/// - Resource leak: tasks continued consuming CPU/memory after connection died
pub fn copyBidirectionalWithStats(
    io: Io,
    client_reader: *Reader,
    backend_writer: *Writer,
    backend_reader: *Reader,
    client_writer: *Writer,
    stats: *ProxyStats,
    http_inspector: *const HTTPInspector,
    options: RunOptions,
) void {
    const job_c2b = PipeJobWithStats{
        .reader = client_reader,
        .writer = backend_writer,
        .stats = stats,
        .direction = .client_to_backend,
        .http_inspector = http_inspector,
        .enable_http_inspection = options.enable_http_inspection,
    };
    const job_b2c = PipeJobWithStats{
        .reader = backend_reader,
        .writer = client_writer,
        .stats = stats,
        .direction = .backend_to_client,
        .http_inspector = http_inspector,
        .enable_http_inspection = options.enable_http_inspection,
    };

    // Use concurrent copying with statistics
    var future_c2b = io.concurrent(copyPipeWithStats, .{job_c2b}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            sequentialCopyWithStats(job_c2b);
            sequentialCopyWithStats(job_b2c);
            return;
        },
    };

    var future_b2c = io.concurrent(copyPipeWithStats, .{job_b2c}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            future_c2b.cancel(io) catch {};
            sequentialCopyWithStats(job_c2b);
            sequentialCopyWithStats(job_b2c);
            return;
        },
    };

    // Wait for first completion
    const first_completed = io.select(.{
        .client_to_backend = &future_c2b,
        .backend_to_client = &future_b2c,
    }) catch |err| {
        log.err("io.select failed: {s}", .{@errorName(err)});
        if (options.enable_stats) {
            stats.recordError();
        }
        future_c2b.cancel(io) catch {};
        future_b2c.cancel(io) catch {};
        return;
    };

    // Wait for second completion with timeout and error handling
    //
    // CRITICAL FIXES:
    // 1. 30-second timeout: Uses io.concurrent(sleep, ...) + io.select() to enforce timeout
    // 2. Cancel opposite direction immediately when one side fails (resource cleanup)
    // 3. Proper error propagation with stats recording
    //
    // Previous issues:
    // - No timeout: connections could hang forever waiting for EOF
    // - No cancellation: failed direction kept other side running indefinitely
    // - Resource leak: tasks continued consuming CPU/memory after connection died
    //
    // Timeout implementation: Uses io.concurrent(sleepForTimeout, ...) combined with
    // io.select() to enforce 30-second timeout when waiting for second direction.
    switch (first_completed) {
        .client_to_backend => |result| {
            // Check if first direction succeeded or failed
            if (result) |_| {
                // Success: wait for backend->client with timeout
                handleCopyResult("client->backend", result);

                // Launch timeout future
                var timeout_future = io.concurrent(sleepForTimeout, .{ io, BIDIRECTIONAL_TIMEOUT_SECONDS }) catch |err| switch (err) {
                    error.ConcurrencyUnavailable => {
                        // Fallback: wait without timeout
                        const second = io.select(.{
                            .backend_to_client = &future_b2c,
                        }) catch |err2| {
                            log.err("second io.select failed: {s}, canceling backend->client", .{@errorName(err2)});
                            future_b2c.cancel(io) catch {};
                            if (options.enable_stats) {
                                stats.recordError();
                            }
                            return;
                        };
                        switch (second) {
                            .backend_to_client => |r| handleCopyResult("backend->client", r),
                        }
                        return;
                    },
                };

                const second = io.select(.{
                    .backend_to_client = &future_b2c,
                    .timeout = &timeout_future,
                }) catch |err| {
                    log.err("second io.select failed: {s}, canceling both futures", .{@errorName(err)});
                    future_b2c.cancel(io) catch {};
                    timeout_future.cancel(io);
                    if (options.enable_stats) {
                        stats.recordError();
                    }
                    return;
                };

                switch (second) {
                    .backend_to_client => |r| {
                        timeout_future.cancel(io);
                        handleCopyResult("backend->client", r);
                    },
                    .timeout => {
                        log.warn("backend->client timeout after {d}s, canceling", .{BIDIRECTIONAL_TIMEOUT_SECONDS});
                        future_b2c.cancel(io) catch {};
                        if (options.enable_stats) {
                            stats.recordError();
                        }
                    },
                }
            } else |err| {
                // Error in client->backend: cancel backend->client immediately
                log.err("client->backend failed: {s}, canceling backend->client", .{@errorName(err)});
                handleCopyResult("client->backend", result);
                future_b2c.cancel(io) catch {};
                if (options.enable_stats) {
                    stats.recordError();
                }
            }
        },
        .backend_to_client => |result| {
            // Check if first direction succeeded or failed
            if (result) |_| {
                // Success: wait for client->backend with timeout
                handleCopyResult("backend->client", result);

                // Launch timeout future
                var timeout_future = io.concurrent(sleepForTimeout, .{ io, BIDIRECTIONAL_TIMEOUT_SECONDS }) catch |err| switch (err) {
                    error.ConcurrencyUnavailable => {
                        // Fallback: wait without timeout
                        const second = io.select(.{
                            .client_to_backend = &future_c2b,
                        }) catch |err2| {
                            log.err("second io.select failed: {s}, canceling client->backend", .{@errorName(err2)});
                            future_c2b.cancel(io) catch {};
                            if (options.enable_stats) {
                                stats.recordError();
                            }
                            return;
                        };
                        switch (second) {
                            .client_to_backend => |r| handleCopyResult("client->backend", r),
                        }
                        return;
                    },
                };

                const second = io.select(.{
                    .client_to_backend = &future_c2b,
                    .timeout = &timeout_future,
                }) catch |err| {
                    log.err("second io.select failed: {s}, canceling both futures", .{@errorName(err)});
                    future_c2b.cancel(io) catch {};
                    timeout_future.cancel(io);
                    if (options.enable_stats) {
                        stats.recordError();
                    }
                    return;
                };

                switch (second) {
                    .client_to_backend => |r| {
                        timeout_future.cancel(io);
                        handleCopyResult("client->backend", r);
                    },
                    .timeout => {
                        log.warn("client->backend timeout after {d}s, canceling", .{BIDIRECTIONAL_TIMEOUT_SECONDS});
                        future_c2b.cancel(io) catch {};
                        if (options.enable_stats) {
                            stats.recordError();
                        }
                    },
                }
            } else |err| {
                // Error in backend->client: cancel client->backend immediately
                log.err("backend->client failed: {s}, canceling client->backend", .{@errorName(err)});
                handleCopyResult("backend->client", result);
                future_c2b.cancel(io) catch {};
                if (options.enable_stats) {
                    stats.recordError();
                }
            }
        },
    }
}

// ============= Helper Functions =============

/// Sequential fallback for basic copy (used when concurrency unavailable)
fn sequentialCopy(job: PipeJob) void {
    copyPipe(job) catch |err| log.warn("sequential copy error: {s}", .{@errorName(err)});
}

/// Sequential fallback for copy with stats (used when concurrency unavailable)
fn sequentialCopyWithStats(job: PipeJobWithStats) void {
    copyPipeWithStats(job) catch |err| log.warn("sequential copy with stats error: {s}", .{@errorName(err)});
}

/// Handle copy result by logging errors or success
fn handleCopyResult(direction: []const u8, result: CopyError!void) void {
    result catch |err| log.warn("{s} stream closed with {s}", .{ direction, @errorName(err) });
}

/// Sleep for specified duration (used for timeout enforcement)
pub fn sleepForTimeout(io: Io, seconds: i64) void {
    const duration = Duration.fromSeconds(seconds);
    io.sleep(duration, .awake) catch |err| {
        log.warn("timeout sleep failed: {s}", .{@errorName(err)});
    };
}

// ============= Unidirectional Copy Functions =============

/// Copy data from reader to writer (basic version without statistics)
fn copyPipe(job: PipeJob) CopyError!void {
    var buffer: [8192]u8 = undefined;
    var total_bytes: usize = 0;

    if (!builtin.is_test) log.info("copyPipe: starting copy operation", .{});

    while (true) {
        var slices = [_][]u8{buffer[0..]};
        const n = job.reader.readVec(&slices) catch |err| switch (err) {
            error.EndOfStream => {
                if (!builtin.is_test) log.info("copyPipe: EOF after {} bytes", .{total_bytes});
                break;
            },
            error.ReadFailed => {
                if (!builtin.is_test) log.warn("copyPipe: read failed after {} bytes", .{total_bytes});
                return err;
            },
        };

        if (n == 0) continue;

        total_bytes += n;
        if (!builtin.is_test) log.info("copyPipe: read {} bytes (total: {})", .{ n, total_bytes });

        try Writer.writeAll(job.writer, buffer[0..n]);
        try Writer.flush(job.writer);
        if (!builtin.is_test) log.info("copyPipe: wrote {} bytes to destination", .{n});
    }

    if (!builtin.is_test) log.info("copyPipe: flushing {} total bytes", .{total_bytes});
    try Writer.flush(job.writer);
    if (!builtin.is_test) log.info("copyPipe: completed successfully", .{});
}

/// Copy data from reader to writer with statistics tracking
fn copyPipeWithStats(job: PipeJobWithStats) CopyError!void {
    var buffer: [8192]u8 = undefined;
    var total_bytes: usize = 0;
    var first_packet = true;

    if (!builtin.is_test) log.info("copyPipeWithStats: starting copy operation", .{});

    while (true) {
        var slices = [_][]u8{buffer[0..]};
        const n = job.reader.readVec(&slices) catch |err| switch (err) {
            error.EndOfStream => {
                if (!builtin.is_test) log.info("copyPipeWithStats: EOF after {} bytes", .{total_bytes});
                break;
            },
            error.ReadFailed => {
                if (!builtin.is_test) log.warn("copyPipeWithStats: read failed after {} bytes", .{total_bytes});
                job.stats.recordError();
                return err;
            },
        };

        if (n == 0) continue;

        // HTTP inspection on first packet from client
        if (first_packet and job.direction == .client_to_backend and job.enable_http_inspection) {
            if (HTTPInspector.parseRequestLine(buffer[0..n])) |request| {
                if (!builtin.is_test) {
                    log.info("HTTP {s} {s}", .{ request.method, request.path });
                }
            }
            first_packet = false;
        }

        total_bytes += n;

        // Record bytes in statistics
        switch (job.direction) {
            .client_to_backend => job.stats.recordBytesClientToBackend(@intCast(n)),
            .backend_to_client => job.stats.recordBytesBackendToClient(@intCast(n)),
        }

        if (!builtin.is_test) log.info("copyPipeWithStats: read {} bytes (total: {})", .{ n, total_bytes });

        try Writer.writeAll(job.writer, buffer[0..n]);
        try Writer.flush(job.writer);
        if (!builtin.is_test) log.info("copyPipeWithStats: wrote {} bytes to destination", .{n});
    }

    if (!builtin.is_test) log.info("copyPipeWithStats: flushing {} total bytes", .{total_bytes});
    try Writer.flush(job.writer);
    if (!builtin.is_test) log.info("copyPipeWithStats: completed successfully", .{});
}

/// Copy data from reader to writer with HTTP response caching
///
/// For backend->client direction with GET requests:
/// - Buffers the complete HTTP response in memory
/// - Detects HTTP 200 status codes
/// - Stores cacheable responses in the HTTPCache
/// - Enforces max cacheable size limit (1MB)
/// - Uses fixed TTL (300 seconds)
pub fn copyPipeWithCaching(job: PipeJobWithCaching) CopyError!void {
    var buffer: [8192]u8 = undefined;
    var total_bytes: usize = 0;
    var first_packet = true;

    // Response buffer for caching (only for backend->client direction)
    var response_buffer: ?std.ArrayList(u8) = null;
    defer if (response_buffer) |*buf| buf.deinit();

    // HTTP response state tracking
    var is_cacheable = false;
    var is_http_200 = false;
    var headers_complete = false;

    // Only allocate buffer for backend->client with GET requests
    if (job.direction == .backend_to_client and std.mem.eql(u8, job.request_method, "GET")) {
        response_buffer = std.ArrayList(u8).init(job.allocator);
        is_cacheable = true;
    }

    if (!builtin.is_test) log.info("copyPipeWithCaching: starting copy operation (cacheable={})", .{is_cacheable});

    while (true) {
        var slices = [_][]u8{buffer[0..]};
        const n = job.reader.readVec(&slices) catch |err| switch (err) {
            error.EndOfStream => {
                if (!builtin.is_test) log.info("copyPipeWithCaching: EOF after {} bytes", .{total_bytes});
                break;
            },
            error.ReadFailed => {
                if (!builtin.is_test) log.warn("copyPipeWithCaching: read failed after {} bytes", .{total_bytes});
                job.stats.recordError();
                is_cacheable = false; // Don't cache on error
                return err;
            },
        };

        if (n == 0) continue;

        // HTTP inspection on first packet from client
        if (first_packet and job.direction == .client_to_backend and job.enable_http_inspection) {
            if (HTTPInspector.parseRequestLine(buffer[0..n])) |request| {
                if (!builtin.is_test) {
                    log.info("HTTP {s} {s}", .{ request.method, request.path });
                }
            }
            first_packet = false;
        }

        // HTTP response inspection on first packet from backend
        if (first_packet and job.direction == .backend_to_client and is_cacheable) {
            // Check for "HTTP/1.1 200 OK" or "HTTP/1.0 200 OK"
            if (n >= 12) {
                if (std.mem.startsWith(u8, buffer[0..n], "HTTP/1.1 200") or
                    std.mem.startsWith(u8, buffer[0..n], "HTTP/1.0 200"))
                {
                    is_http_200 = true;
                    if (!builtin.is_test) {
                        log.info("detected HTTP 200 response, will cache", .{});
                    }
                } else {
                    is_cacheable = false; // Not a 200 response
                    if (!builtin.is_test) {
                        log.info("non-200 response, will not cache", .{});
                    }
                }
            }
            first_packet = false;
        }

        total_bytes += n;

        // Buffer response data if cacheable and under size limit
        if (is_cacheable and is_http_200 and response_buffer != null) {
            if (total_bytes <= PipeJobWithCaching.max_cacheable_size) {
                response_buffer.?.appendSlice(buffer[0..n]) catch |err| {
                    if (!builtin.is_test) {
                        log.warn("failed to buffer response for caching: {s}", .{@errorName(err)});
                    }
                    is_cacheable = false;
                };

                // Check if headers are complete (look for \r\n\r\n)
                if (!headers_complete and response_buffer.?.items.len >= 4) {
                    const items = response_buffer.?.items;
                    for (0..items.len - 3) |i| {
                        if (items[i] == '\r' and items[i + 1] == '\n' and
                            items[i + 2] == '\r' and items[i + 3] == '\n')
                        {
                            headers_complete = true;
                            break;
                        }
                    }
                }
            } else {
                is_cacheable = false; // Response too large
                if (!builtin.is_test) {
                    log.info("response exceeds max cacheable size, will not cache", .{});
                }
            }
        }

        // Record bytes in statistics
        switch (job.direction) {
            .client_to_backend => job.stats.recordBytesClientToBackend(@intCast(n)),
            .backend_to_client => job.stats.recordBytesBackendToClient(@intCast(n)),
        }

        if (!builtin.is_test) log.info("copyPipeWithCaching: read {} bytes (total: {})", .{ n, total_bytes });

        try Writer.writeAll(job.writer, buffer[0..n]);
        try Writer.flush(job.writer);
        if (!builtin.is_test) log.info("copyPipeWithCaching: wrote {} bytes to destination", .{n});
    }

    if (!builtin.is_test) log.info("copyPipeWithCaching: flushing {} total bytes", .{total_bytes});
    try Writer.flush(job.writer);

    // Store in cache if all conditions met
    if (is_cacheable and is_http_200 and headers_complete and response_buffer != null) {
        const response_data = response_buffer.?.items;
        if (response_data.len > 0 and response_data.len <= PipeJobWithCaching.max_cacheable_size) {
            job.http_cache.put(
                job.request_method,
                job.request_host,
                job.request_path,
                response_data,
                PipeJobWithCaching.default_ttl_seconds,
            ) catch |err| {
                if (!builtin.is_test) {
                    log.warn("failed to cache response: {s}", .{@errorName(err)});
                }
            };

            if (!builtin.is_test) {
                log.info("cached response for {s} {s} ({} bytes, TTL={}s)", .{
                    job.request_method,
                    job.request_path,
                    response_data.len,
                    PipeJobWithCaching.default_ttl_seconds,
                });
            }
        }
    }

    if (!builtin.is_test) log.info("copyPipeWithCaching: completed successfully", .{});
}

/// Sequential fallback for copy with caching (used when concurrency unavailable)
pub fn sequentialCopyWithCaching(job: PipeJobWithCaching) void {
    copyPipeWithCaching(job) catch |err| log.warn("sequential copy with caching error: {s}", .{@errorName(err)});
}
