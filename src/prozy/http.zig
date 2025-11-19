const std = @import("std");
const log = std.log;
const builtin = @import("builtin");
const Io = std.Io;
const Timeout = Io.Timeout;
const Writer = Io.Writer;
const Reader = Io.Reader;

/// HTTP protocol inspector for header manipulation
pub const HTTPInspector = struct {
    add_forwarded_headers: bool = true,
    add_via_header: bool = true,
    add_rfc7239_forwarded: bool = true, // RFC 7239 Forwarded header
    proxy_name: []const u8 = "Prozy/1.0",

    pub fn init(add_forwarded: bool, add_via: bool, proxy_name: []const u8) HTTPInspector {
        return .{
            .add_forwarded_headers = add_forwarded,
            .add_via_header = add_via,
            .add_rfc7239_forwarded = true,
            .proxy_name = proxy_name,
        };
    }

    /// Parse HTTP request line (GET /path HTTP/1.1)
    pub fn parseRequestLine(buffer: []const u8) ?HTTPRequest {
        var it = std.mem.splitSequence(u8, buffer, "\r\n");
        const first_line = it.next() orelse return null;

        var parts = std.mem.splitSequence(u8, first_line, " ");
        const method = parts.next() orelse return null;
        const path = parts.next() orelse return null;
        const version = parts.next() orelse return null;

        return .{
            .method = method,
            .path = path,
            .version = version,
        };
    }

    pub const HTTPRequest = struct {
        method: []const u8,
        path: []const u8,
        version: []const u8,
    };

    pub const HTTPResponse = struct {
        version: []const u8,
        status_code: u16,
        status_text: []const u8,
        headers_end: usize, // Offset where headers end (after \r\n\r\n)
    };

    /// Parse HTTP response status line (HTTP/1.1 200 OK)
    pub fn parseResponseLine(buffer: []const u8) ?HTTPResponse {
        // Find first line terminator
        var it = std.mem.splitSequence(u8, buffer, "\r\n");
        const first_line = it.next() orelse return null;

        // Parse "HTTP/1.1 200 OK" format
        var parts = std.mem.splitSequence(u8, first_line, " ");
        const version = parts.next() orelse return null;
        const status_code_str = parts.next() orelse return null;
        const status_text = parts.rest();

        // Validate HTTP version
        if (!std.mem.startsWith(u8, version, "HTTP/")) return null;

        // Parse status code as u16
        const status_code = std.fmt.parseInt(u16, status_code_str, 10) catch return null;

        // Validate status code range (100-599)
        if (status_code < 100 or status_code >= 600) return null;

        // Find headers end marker (\r\n\r\n)
        const headers_end = findHeadersEnd(buffer) orelse return null;

        return .{
            .version = version,
            .status_code = status_code,
            .status_text = status_text,
            .headers_end = headers_end,
        };
    }

    /// Find the end of HTTP headers (offset after \r\n\r\n)
    pub fn findHeadersEnd(buffer: []const u8) ?usize {
        const marker = "\r\n\r\n";
        if (std.mem.indexOf(u8, buffer, marker)) |idx| {
            return idx + marker.len;
        }
        return null;
    }

    pub const MessageBodyType = union(enum) {
        none,
        content_length: u64,
        chunked,
        until_close, // For HTTP/1.0 or ambiguous responses
    };

    /// Determine the body type and length from headers
    pub fn getBodyType(headers: []const u8) MessageBodyType {
        // Check for Transfer-Encoding: chunked (precedence over Content-Length)
        if (findHeader(headers, "Transfer-Encoding")) |transfer_encoding| {
            if (std.mem.indexOf(u8, transfer_encoding, "chunked") != null) {
                return .chunked;
            }
        }

        // Check for Content-Length header
        if (findHeader(headers, "Content-Length")) |content_length_str| {
            if (std.fmt.parseInt(u64, content_length_str, 10)) |len| {
                return .{ .content_length = len };
            } else |_| {}
        }

        // If neither, assume no body (or until close for legacy)
        // For strict HTTP/1.1 pipelining, we can't support "until_close" easily without closing connection.
        return .none;
    }

    /// Check if buffer contains a complete HTTP response
    pub fn isCompleteResponse(buffer: []const u8) bool {
        // First, check if we have complete headers
        const headers_end = findHeadersEnd(buffer) orelse return false;

        // Extract headers section
        const headers_section = buffer[0..headers_end];

        // Check for Content-Length header
        if (findHeader(headers_section, "Content-Length")) |content_length_str| {
            const content_length = std.fmt.parseInt(usize, content_length_str, 10) catch return false;
            const expected_total = headers_end + content_length;
            return buffer.len >= expected_total;
        }

        // Check for Transfer-Encoding: chunked
        if (findHeader(headers_section, "Transfer-Encoding")) |transfer_encoding| {
            if (std.mem.indexOf(u8, transfer_encoding, "chunked") != null) {
                // For chunked encoding, look for terminating chunk (0\r\n\r\n)
                const body_start = headers_end;
                if (body_start >= buffer.len) return false;
                const body = buffer[body_start..];
                return std.mem.endsWith(u8, body, "0\r\n\r\n");
            }
        }

        // If no Content-Length or Transfer-Encoding, assume complete after headers
        // (This handles HTTP/1.0 responses without Content-Length where connection closes)
        return true;
    }

    /// Find a header value in the headers section (case-insensitive)
    pub fn findHeader(headers: []const u8, name: []const u8) ?[]const u8 {
        var it = std.mem.splitSequence(u8, headers, "\r\n");
        _ = it.next(); // Skip status line

        while (it.next()) |line| {
            if (line.len == 0) break; // End of headers

            const colon_idx = std.mem.indexOf(u8, line, ":") orelse continue;
            const header_name = line[0..colon_idx];

            // Case-insensitive comparison
            if (std.ascii.eqlIgnoreCase(header_name, name)) {
                var value = line[colon_idx + 1 ..];
                // Trim leading whitespace
                while (value.len > 0 and (value[0] == ' ' or value[0] == '\t')) {
                    value = value[1..];
                }
                return value;
            }
        }
        return null;
    }

    /// Find Proxy-Authorization header value (case-insensitive)
    /// Used for RFC 7235 proxy authentication
    pub fn findProxyAuthorizationHeader(headers: []const u8) ?[]const u8 {
        return findHeader(headers, "Proxy-Authorization");
    }

    /// List of hop-by-hop headers that must be removed before forwarding (RFC 9110 Section 7.6.1)
    /// NOTE: Transfer-Encoding is NOT included because we don't decode/re-encode chunked bodies.
    /// As a simple forwarding proxy, we preserve Transfer-Encoding to maintain message integrity.
    const hop_by_hop_headers = [_][]const u8{
        "Connection",
        "Keep-Alive",
        "Proxy-Connection",
        "TE",
        "Trailer",
        "Upgrade",
        "Proxy-Authenticate",
        "Proxy-Authorization",
    };

    /// Check if a header is hop-by-hop and should be removed
    /// NOTE: Transfer-Encoding is preserved to maintain body framing for chunked messages
    fn isHopByHopHeader(header_name: []const u8) bool {
        for (hop_by_hop_headers) |hop_by_hop| {
            if (std.ascii.eqlIgnoreCase(header_name, hop_by_hop)) {
                return true;
            }
        }
        return false;
    }

    /// RFC 9111 Vary header support for content negotiation
    pub const VaryContext = struct {
        accept: ?[]const u8 = null,
        accept_encoding: ?[]const u8 = null,
        accept_language: ?[]const u8 = null,
        accept_charset: ?[]const u8 = null,
        user_agent: ?[]const u8 = null,

        /// Generate hash for vary context (for cache key)
        pub fn hash(self: VaryContext) u64 {
            var hasher = std.hash.Wyhash.init(0);
            if (self.accept) |v| hasher.update(v);
            if (self.accept_encoding) |v| hasher.update(v);
            if (self.accept_language) |v| hasher.update(v);
            if (self.accept_charset) |v| hasher.update(v);
            if (self.user_agent) |v| hasher.update(v);
            return hasher.final();
        }

        /// Check if two vary contexts are equal
        pub fn eql(self: VaryContext, other: VaryContext) bool {
            const accept_match = if (self.accept) |a|
                if (other.accept) |b| std.mem.eql(u8, a, b) else false
            else
                other.accept == null;

            const encoding_match = if (self.accept_encoding) |a|
                if (other.accept_encoding) |b| std.mem.eql(u8, a, b) else false
            else
                other.accept_encoding == null;

            const language_match = if (self.accept_language) |a|
                if (other.accept_language) |b| std.mem.eql(u8, a, b) else false
            else
                other.accept_language == null;

            const charset_match = if (self.accept_charset) |a|
                if (other.accept_charset) |b| std.mem.eql(u8, a, b) else false
            else
                other.accept_charset == null;

            const ua_match = if (self.user_agent) |a|
                if (other.user_agent) |b| std.mem.eql(u8, a, b) else false
            else
                other.user_agent == null;

            return accept_match and encoding_match and language_match and charset_match and ua_match;
        }
    };

    /// Parse Vary header to extract field names (RFC 9111 Section 4.1)
    /// Returns null if Vary: * (uncacheable)
    pub fn parseVaryHeader(allocator: std.mem.Allocator, headers: []const u8) !?[][]const u8 {
        const vary = findHeader(headers, "Vary") orelse return null;

        // Handle "Vary: *" - uncacheable (RFC 9111 Section 4.1)
        const trimmed = std.mem.trim(u8, vary, " \t");
        if (std.mem.eql(u8, trimmed, "*")) {
            return null; // Signal uncacheable
        }

        var result = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (result.items) |item| allocator.free(item);
            result.deinit();
        }

        var it = std.mem.splitSequence(u8, vary, ",");
        while (it.next()) |header_name| {
            const trimmed_name = std.mem.trim(u8, header_name, " \t");
            if (trimmed_name.len > 0) {
                try result.append(try allocator.dupe(u8, trimmed_name));
            }
        }

        return try result.toOwnedSlice();
    }

    /// Extract vary context from request headers based on Vary field names
    pub fn extractVaryContext(allocator: std.mem.Allocator, request_headers: []const u8, vary_headers: [][]const u8) !VaryContext {
        var context = VaryContext{};

        for (vary_headers) |header_name| {
            if (std.ascii.eqlIgnoreCase(header_name, "Accept")) {
                if (findHeader(request_headers, "Accept")) |value| {
                    context.accept = try allocator.dupe(u8, value);
                }
            } else if (std.ascii.eqlIgnoreCase(header_name, "Accept-Encoding")) {
                if (findHeader(request_headers, "Accept-Encoding")) |value| {
                    context.accept_encoding = try allocator.dupe(u8, value);
                }
            } else if (std.ascii.eqlIgnoreCase(header_name, "Accept-Language")) {
                if (findHeader(request_headers, "Accept-Language")) |value| {
                    context.accept_language = try allocator.dupe(u8, value);
                }
            } else if (std.ascii.eqlIgnoreCase(header_name, "Accept-Charset")) {
                if (findHeader(request_headers, "Accept-Charset")) |value| {
                    context.accept_charset = try allocator.dupe(u8, value);
                }
            } else if (std.ascii.eqlIgnoreCase(header_name, "User-Agent")) {
                if (findHeader(request_headers, "User-Agent")) |value| {
                    context.user_agent = try allocator.dupe(u8, value);
                }
            }
        }

        return context;
    }

    /// Free vary context allocated strings
    pub fn freeVaryContext(allocator: std.mem.Allocator, context: *VaryContext) void {
        if (context.accept) |v| allocator.free(v);
        if (context.accept_encoding) |v| allocator.free(v);
        if (context.accept_language) |v| allocator.free(v);
        if (context.accept_charset) |v| allocator.free(v);
        if (context.user_agent) |v| allocator.free(v);
        context.* = .{};
    }

    /// RFC 9111 Cache-Control directives
    pub const CacheControlDirectives = struct {
        max_age: ?u32 = null, // RFC 9111 Section 5.2.2.1
        s_maxage: ?u32 = null, // RFC 9111 Section 5.2.2.2 (shared caches)
        no_cache: bool = false, // RFC 9111 Section 5.2.2.4
        no_store: bool = false, // RFC 9111 Section 5.2.2.5
        must_revalidate: bool = false, // RFC 9111 Section 5.2.2.3
        proxy_revalidate: bool = false, // RFC 9111 Section 5.2.2.7
        private: bool = false, // RFC 9111 Section 5.2.2.6
        public: bool = false, // RFC 9111 Section 5.2.2.1
        no_transform: bool = false, // RFC 9111 Section 5.2.2.8
        immutable: bool = false, // RFC 8246 (extension)
        stale_while_revalidate: ?u32 = null, // RFC 5861 Section 3 (extension)

        /// Check if response is cacheable by proxy (shared cache)
        pub fn isCacheable(self: CacheControlDirectives) bool {
            // no-store: MUST NOT be cached (RFC 9111 Section 5.2.2.5)
            if (self.no_store) return false;

            // private: only cacheable by browser, not proxy (RFC 9111 Section 5.2.2.6)
            if (self.private) return false;

            return true;
        }

        /// Get TTL (Time To Live) in seconds for cache entry
        /// s-maxage takes precedence for shared caches (proxies)
        pub fn getTTL(self: CacheControlDirectives, default_ttl: u32) u32 {
            // s-maxage takes precedence for shared caches (RFC 9111 Section 5.2.2.2)
            if (self.s_maxage) |ttl| return ttl;

            // max-age fallback
            if (self.max_age) |ttl| return ttl;

            // Use default TTL if no explicit directive
            return default_ttl;
        }

        /// Check if response requires revalidation before serving from cache
        pub fn requiresRevalidation(self: CacheControlDirectives) bool {
            // no-cache: MUST revalidate before use (RFC 9111 Section 5.2.2.4)
            if (self.no_cache) return true;

            // must-revalidate: MUST revalidate when stale (RFC 9111 Section 5.2.2.3)
            if (self.must_revalidate) return true;

            // proxy-revalidate: proxies MUST revalidate when stale (RFC 9111 Section 5.2.2.7)
            if (self.proxy_revalidate) return true;

            return false;
        }
    };

    /// Parse Cache-Control header into structured directives (RFC 9111)
    pub fn parseCacheControl(headers: []const u8) CacheControlDirectives {
        var directives = CacheControlDirectives{};
        const cache_control = findHeader(headers, "Cache-Control") orelse return directives;

        // Cache-Control can have multiple directives separated by commas
        var it = std.mem.splitSequence(u8, cache_control, ",");
        while (it.next()) |directive_raw| {
            // Trim whitespace using std.mem.trim
            const directive = std.mem.trim(u8, directive_raw, " \t");

            // Skip empty directives
            if (directive.len == 0) continue;

            // Parse directive=value format
            if (std.mem.indexOf(u8, directive, "=")) |eq_idx| {
                const name = std.mem.trim(u8, directive[0..eq_idx], " \t");
                var value = std.mem.trim(u8, directive[eq_idx + 1 ..], " \t");

                // Proper quote handling: remove surrounding quotes if present
                if (value.len >= 2) {
                    if ((value[0] == '"' and value[value.len - 1] == '"') or
                        (value[0] == '\'' and value[value.len - 1] == '\''))
                    {
                        value = value[1 .. value.len - 1];
                    }
                }

                // SECURITY: Validate that boolean directives don't have values
                if (std.ascii.eqlIgnoreCase(name, "no-cache") or
                    std.ascii.eqlIgnoreCase(name, "no-store") or
                    std.ascii.eqlIgnoreCase(name, "must-revalidate") or
                    std.ascii.eqlIgnoreCase(name, "proxy-revalidate") or
                    std.ascii.eqlIgnoreCase(name, "private") or
                    std.ascii.eqlIgnoreCase(name, "public") or
                    std.ascii.eqlIgnoreCase(name, "no-transform") or
                    std.ascii.eqlIgnoreCase(name, "immutable"))
                {
                    // Boolean directives should not have values - ignore malformed input
                    continue;
                }

                // Parse directives with values and validate bounds
                if (std.ascii.eqlIgnoreCase(name, "max-age")) {
                    const parsed = std.fmt.parseInt(u32, value, 10) catch null;
                    // SECURITY: Validate max-age bounds (0 to 1 year in seconds)
                    if (parsed) |age| {
                        if (age <= 31536000) {
                            directives.max_age = age;
                        }
                    }
                } else if (std.ascii.eqlIgnoreCase(name, "s-maxage")) {
                    const parsed = std.fmt.parseInt(u32, value, 10) catch null;
                    // SECURITY: Validate s-maxage bounds (0 to 1 year in seconds)
                    if (parsed) |age| {
                        if (age <= 31536000) {
                            directives.s_maxage = age;
                        }
                    }
                } else if (std.ascii.eqlIgnoreCase(name, "stale-while-revalidate")) {
                    const parsed = std.fmt.parseInt(u32, value, 10) catch null;
                    // SECURITY: Validate stale-while-revalidate bounds (0 to 1 day in seconds)
                    if (parsed) |duration| {
                        if (duration <= 86400) {
                            directives.stale_while_revalidate = duration;
                        }
                    }
                }
            } else {
                // Boolean directives (no value) - case insensitive comparison
                if (std.ascii.eqlIgnoreCase(directive, "no-cache")) {
                    directives.no_cache = true;
                } else if (std.ascii.eqlIgnoreCase(directive, "no-store")) {
                    directives.no_store = true;
                } else if (std.ascii.eqlIgnoreCase(directive, "must-revalidate")) {
                    directives.must_revalidate = true;
                } else if (std.ascii.eqlIgnoreCase(directive, "proxy-revalidate")) {
                    directives.proxy_revalidate = true;
                } else if (std.ascii.eqlIgnoreCase(directive, "private")) {
                    directives.private = true;
                } else if (std.ascii.eqlIgnoreCase(directive, "public")) {
                    directives.public = true;
                } else if (std.ascii.eqlIgnoreCase(directive, "no-transform")) {
                    directives.no_transform = true;
                } else if (std.ascii.eqlIgnoreCase(directive, "immutable")) {
                    directives.immutable = true;
                }
            }
        }

        return directives;
    }

    /// Parse Cache-Control header to check for no-store directive (legacy function)
    /// Returns true if the response should NOT be cached
    /// NOTE: Use parseCacheControl() for full RFC 9111 compliance
    pub fn hasCacheControlNoStore(headers: []const u8) bool {
        const directives = parseCacheControl(headers);
        return directives.no_store;
    }

    /// Generate conditional request headers (If-None-Match, If-Modified-Since)
    /// Returns a new buffer with the modified headers if validators exist, otherwise returns copy of original
    pub fn addConditionalHeaders(
        allocator: std.mem.Allocator,
        original_headers: []const u8,
        metadata: HTTPCache.CacheMetadata,
    ) ![]u8 {
        if (metadata.etag == null and metadata.last_modified == null) {
            return allocator.dupe(u8, original_headers);
        }

        // Find where headers end
        const headers_end = findHeadersEnd(original_headers) orelse {
            return allocator.dupe(u8, original_headers);
        };

        var modified = std.ArrayListUnmanaged(u8){};
        errdefer modified.deinit(allocator);

        // Copy everything up to the end of headers (excluding the final \r\n that marks end of headers)
        // headers_end points after \r\n\r\n
        // So we want to slice up to headers_end - 2 (keep the first \r\n)
        try modified.appendSlice(allocator, original_headers[0 .. headers_end - 2]);

        if (metadata.etag) |etag| {
            // Check if etag is quoted, if not add quotes (some backends require it)
            // But we stored it raw. RFC says If-None-Match: "etag"
            try modified.appendSlice(allocator, "If-None-Match: ");
            try modified.appendSlice(allocator, etag);
            try modified.appendSlice(allocator, "\r\n");
        }

        if (metadata.last_modified) |lm| {
            try modified.appendSlice(allocator, "If-Modified-Since: ");
            try modified.appendSlice(allocator, lm);
            try modified.appendSlice(allocator, "\r\n");
        }

        try modified.appendSlice(allocator, "\r\n"); // End of headers

        // Copy body if any
        if (headers_end < original_headers.len) {
            try modified.appendSlice(allocator, original_headers[headers_end..]);
        }

        return modified.toOwnedSlice(allocator);
    }

    /// RFC 9111 Phase 4: ETag support
    pub const ETag = struct {
        value: []const u8,
        is_weak: bool,

        /// Parse ETag header value
        pub fn parse(etag_header: []const u8) ?ETag {
            const trimmed = std.mem.trim(u8, etag_header, " \t");

            if (std.mem.startsWith(u8, trimmed, "W/")) {
                // Weak ETag: W/"value"
                if (trimmed.len < 4) return null;
                const value_part = trimmed[2..];
                if (!std.mem.startsWith(u8, value_part, "\"") or
                    !std.mem.endsWith(u8, value_part, "\"")) return null;

                return ETag{
                    .value = value_part,
                    .is_weak = true,
                };
            } else if (std.mem.startsWith(u8, trimmed, "\"") and
                std.mem.endsWith(u8, trimmed, "\""))
            {
                // Strong ETag: "value"
                return ETag{
                    .value = trimmed,
                    .is_weak = false,
                };
            }

            return null;
        }

        /// Check if two ETags match (RFC 9110 Section 8.8.3.2)
        pub fn matches(self: ETag, other: ETag) bool {
            // Strong comparison: both must be strong and identical
            if (!self.is_weak and !other.is_weak) {
                return std.mem.eql(u8, self.value, other.value);
            }

            // Weak comparison: values must match (ignore W/ prefix)
            return std.mem.eql(u8, self.value, other.value);
        }
    };

    /// RFC 9111 Phase 5: Freshness calculation
    pub const FreshnessInfo = struct {
        date: ?i64 = null,
        age: ?u32 = null,
        expires: ?i64 = null,
        cache_control: CacheControlDirectives,
        response_time: i64,
        request_time: i64,

        /// Calculate freshness lifetime (RFC 9111 Section 4.2.1)
        pub fn calculateFreshnessLifetime(self: FreshnessInfo) u32 {
            // 1. s-maxage takes precedence for shared caches
            if (self.cache_control.s_maxage) |ttl| return ttl;

            // 2. max-age
            if (self.cache_control.max_age) |ttl| return ttl;

            // 3. Expires header
            if (self.expires) |exp_time| {
                if (self.date) |date_time| {
                    const lifetime = exp_time - date_time;
                    return if (lifetime > 0) @intCast(lifetime) else 0;
                }
            }

            // 4. Heuristic freshness (RFC 9111 Section 4.2.2)
            // For proxy, we use a conservative default instead of heuristics
            return 300; // 5 minutes default
        }

        /// Calculate current age (RFC 9111 Section 4.2.3)
        pub fn calculateCurrentAge(self: FreshnessInfo, now: i64) u32 {
            // apparent_age = max(0, response_time - date)
            const apparent_age = if (self.date) |date_time|
                @max(0, self.response_time - date_time)
            else
                0;

            // response_delay = response_time - request_time
            const response_delay = self.response_time - self.request_time;

            // corrected_age = age_value + response_delay
            const age_value: i64 = if (self.age) |a| @intCast(a) else 0;
            const corrected_age = age_value + response_delay;

            // corrected_initial_age = max(apparent_age, corrected_age)
            const corrected_initial_age = @max(apparent_age, corrected_age);

            // resident_time = now - response_time
            const resident_time = now - self.response_time;

            // current_age = corrected_initial_age + resident_time
            const current_age = corrected_initial_age + resident_time;

            return if (current_age > 0) @intCast(current_age) else 0;
        }

        /// Check if response is fresh (RFC 9111 Section 4.2)
        pub fn isFresh(self: FreshnessInfo, now: i64) bool {
            const freshness_lifetime = self.calculateFreshnessLifetime();
            const current_age = self.calculateCurrentAge(now);
            return current_age < freshness_lifetime;
        }

        /// Check if response is stale (requires revalidation)
        pub fn isStale(self: FreshnessInfo, now: i64) bool {
            return !self.isFresh(now);
        }
    };

    /// Parse HTTP date (RFC 9110 Section 5.6.7)
    /// Supports three formats:
    /// 1. IMF-fixdate (preferred): "Sun, 06 Nov 1994 08:49:37 GMT"
    /// 2. RFC 850 (obsolete): "Sunday, 06-Nov-94 08:49:37 GMT"
    /// 3. asctime: "Sun Nov  6 08:49:37 1994"
    /// Returns Unix timestamp or null if parsing fails
    pub fn parseHttpDate(date_str: []const u8) ?i64 {
        // Try IMF-fixdate first (most common)
        if (parseIMFFixdate(date_str)) |timestamp| return timestamp;

        // Try RFC 850 format
        if (parseRFC850(date_str)) |timestamp| return timestamp;

        // Try asctime format
        if (parseAsctime(date_str)) |timestamp| return timestamp;

        return null;
    }

    /// Parse IMF-fixdate format: "Sun, 06 Nov 1994 08:49:37 GMT"
    fn parseIMFFixdate(date_str: []const u8) ?i64 {
        // Format: day-name "," SP date1 SP time-of-day SP GMT
        // Example: Sun, 06 Nov 1994 08:49:37 GMT
        if (date_str.len < 29) return null; // Minimum valid length

        // Find comma after day name
        const comma_idx = std.mem.indexOfScalar(u8, date_str, ',') orelse return null;
        if (comma_idx > 9) return null; // Day name too long

        // Skip "day-name, "
        var idx: usize = comma_idx + 1;
        while (idx < date_str.len and date_str[idx] == ' ') : (idx += 1) {}
        if (idx + 20 > date_str.len) return null;

        // Parse day (2 digits)
        const day = std.fmt.parseInt(u8, date_str[idx .. idx + 2], 10) catch return null;
        if (day < 1 or day > 31) return null;
        idx += 3; // Skip day and space

        // Parse month (3 letters)
        if (idx + 3 > date_str.len) return null;
        const month = parseMonth(date_str[idx .. idx + 3]) orelse return null;
        idx += 4; // Skip month and space

        // Parse year (4 digits)
        if (idx + 4 > date_str.len) return null;
        const year = std.fmt.parseInt(u16, date_str[idx .. idx + 4], 10) catch return null;
        if (year < 1970 or year > 9999) return null;
        idx += 5; // Skip year and space

        // Parse time HH:MM:SS
        if (idx + 8 > date_str.len) return null;
        const time = parseTime(date_str[idx .. idx + 8]) orelse return null;

        // Convert to Unix timestamp
        return dateTimeToTimestamp(year, month, day, time.hour, time.minute, time.second);
    }

    /// Parse RFC 850 format: "Sunday, 06-Nov-94 08:49:37 GMT"
    fn parseRFC850(date_str: []const u8) ?i64 {
        // Format: day-name-l "," SP date2 SP time-of-day SP GMT
        // Example: Sunday, 06-Nov-94 08:49:37 GMT
        if (date_str.len < 30) return null;

        // Find comma after day name
        const comma_idx = std.mem.indexOfScalar(u8, date_str, ',') orelse return null;
        if (comma_idx > 9) return null;

        // Skip "day-name, "
        var idx: usize = comma_idx + 1;
        while (idx < date_str.len and date_str[idx] == ' ') : (idx += 1) {}
        if (idx + 18 > date_str.len) return null;

        // Parse day (2 digits)
        const day = std.fmt.parseInt(u8, date_str[idx .. idx + 2], 10) catch return null;
        if (day < 1 or day > 31) return null;
        idx += 3; // Skip day and "-"

        // Parse month (3 letters)
        if (idx + 3 > date_str.len) return null;
        const month = parseMonth(date_str[idx .. idx + 3]) orelse return null;
        idx += 4; // Skip month and "-"

        // Parse year (2 digits) - interpret as 1900+ or 2000+
        if (idx + 2 > date_str.len) return null;
        var year = std.fmt.parseInt(u16, date_str[idx .. idx + 2], 10) catch return null;
        // RFC 2616: 2-digit year >= 00 is 2000+, but we assume < 70 is 2000+, >= 70 is 1900+
        year = if (year >= 70) year + 1900 else year + 2000;
        idx += 3; // Skip year and space

        // Parse time HH:MM:SS
        if (idx + 8 > date_str.len) return null;
        const time = parseTime(date_str[idx .. idx + 8]) orelse return null;

        return dateTimeToTimestamp(year, month, day, time.hour, time.minute, time.second);
    }

    /// Parse asctime format: "Sun Nov  6 08:49:37 1994"
    fn parseAsctime(date_str: []const u8) ?i64 {
        // Format: day-name SP date3 SP time-of-day SP year
        // Example: Sun Nov  6 08:49:37 1994
        if (date_str.len < 24) return null;

        // Skip day name and space
        const first_space = std.mem.indexOfScalar(u8, date_str, ' ') orelse return null;
        if (first_space > 9) return null;
        var idx = first_space + 1;
        while (idx < date_str.len and date_str[idx] == ' ') : (idx += 1) {}

        // Parse month (3 letters)
        if (idx + 3 > date_str.len) return null;
        const month = parseMonth(date_str[idx .. idx + 3]) orelse return null;
        idx += 3;

        // Skip spaces before day
        while (idx < date_str.len and date_str[idx] == ' ') : (idx += 1) {}

        // Parse day (1 or 2 digits)
        const day_start = idx;
        while (idx < date_str.len and date_str[idx] >= '0' and date_str[idx] <= '9') : (idx += 1) {}
        if (idx == day_start) return null;
        const day = std.fmt.parseInt(u8, date_str[day_start..idx], 10) catch return null;
        if (day < 1 or day > 31) return null;

        // Skip space before time
        while (idx < date_str.len and date_str[idx] == ' ') : (idx += 1) {}

        // Parse time HH:MM:SS
        if (idx + 8 > date_str.len) return null;
        const time = parseTime(date_str[idx .. idx + 8]) orelse return null;
        idx += 8;

        // Skip space before year
        while (idx < date_str.len and date_str[idx] == ' ') : (idx += 1) {}

        // Parse year (4 digits)
        if (idx + 4 > date_str.len) return null;
        const year = std.fmt.parseInt(u16, date_str[idx .. idx + 4], 10) catch return null;
        if (year < 1970 or year > 9999) return null;

        return dateTimeToTimestamp(year, month, day, time.hour, time.minute, time.second);
    }

    /// Parse time in HH:MM:SS format
    /// Returns tuple of (hour, minute, second) or null if parsing fails
    fn parseTime(time_str: []const u8) ?struct { hour: u8, minute: u8, second: u8 } {
        if (time_str.len < 8) return null;

        const hour = std.fmt.parseInt(u8, time_str[0..2], 10) catch return null;
        if (hour > 23) return null;

        if (time_str[2] != ':') return null;

        const minute = std.fmt.parseInt(u8, time_str[3..5], 10) catch return null;
        if (minute > 59) return null;

        if (time_str[5] != ':') return null;

        const second = std.fmt.parseInt(u8, time_str[6..8], 10) catch return null;
        if (second > 60) return null; // Allow leap second

        return .{ .hour = hour, .minute = minute, .second = second };
    }

    /// Parse month name to month number (1-12)
    /// Uses StaticStringMap for efficient O(1) lookup with compiler optimization
    fn parseMonth(month_str: []const u8) ?u8 {
        if (month_str.len != 3) return null;

        // Compare case-insensitively
        var lower: [3]u8 = undefined;
        for (month_str, 0..) |c, i| {
            lower[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }

        // Use StaticStringMap for efficient jump table optimization
        const month_map = std.StaticStringMap(u8).initComptime(.{
            .{ "jan", 1 },
            .{ "feb", 2 },
            .{ "mar", 3 },
            .{ "apr", 4 },
            .{ "may", 5 },
            .{ "jun", 6 },
            .{ "jul", 7 },
            .{ "aug", 8 },
            .{ "sep", 9 },
            .{ "oct", 10 },
            .{ "nov", 11 },
            .{ "dec", 12 },
        });

        return month_map.get(&lower);
    }

    /// Convert date/time components to Unix timestamp
    /// Validates date components including day-of-month for each specific month
    fn dateTimeToTimestamp(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) ?i64 {
        if (year < 1970) return null;
        if (month < 1 or month > 12) return null;
        if (day < 1) return null;

        // Days in each month (non-leap year)
        const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

        // Validate day against actual days in the month
        var max_day = days_in_month[month - 1];
        if (month == 2 and isLeapYear(year)) {
            max_day = 29; // February in leap year
        }
        if (day > max_day) return null;

        // Calculate days since Unix epoch (Jan 1, 1970)
        var days: i64 = 0;

        // Add days for complete years
        var y: u16 = 1970;
        while (y < year) : (y += 1) {
            days += if (isLeapYear(y)) 365 + 1 else 365;
        }

        // Add days for complete months in current year
        var m: u8 = 1;
        while (m < month) : (m += 1) {
            days += days_in_month[m - 1];
            // Add extra day for February in leap year
            if (m == 2 and isLeapYear(year)) {
                days += 1;
            }
        }

        // Add remaining days
        days += day - 1;

        // Convert to seconds
        const timestamp = days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;

        return timestamp;
    }

    /// Check if year is a leap year
    fn isLeapYear(year: u16) bool {
        if (year % 400 == 0) return true;
        if (year % 100 == 0) return false;
        if (year % 4 == 0) return true;
        return false;
    }

    /// Generate Age header value (RFC 9111 Section 5.1)
    pub fn generateAgeHeader(allocator: std.mem.Allocator, freshness_info: FreshnessInfo, now: i64) ![]u8 {
        const current_age = freshness_info.calculateCurrentAge(now);
        var buffer: [64]u8 = undefined;
        const age_str = try std.fmt.bufPrint(&buffer, "Age: {}\r\n", .{current_age});
        return try allocator.dupe(u8, age_str);
    }

    /// Check if an IP address string is IPv6 (contains colons)
    fn isIPv6(ip: []const u8) bool {
        return std.mem.indexOf(u8, ip, ":") != null;
    }

    /// Format IP address for RFC 7239 Forwarded header
    /// IPv6: quoted with brackets: for="[2001:db8::1]"
    /// IPv4: unquoted: for=192.168.1.1
    fn formatForwardedFor(allocator: std.mem.Allocator, ip: []const u8) ![]const u8 {
        if (isIPv6(ip)) {
            // IPv6: for="[2001:db8::1]"
            var formatted: std.ArrayList(u8) = .{};
            defer formatted.deinit(allocator);

            try formatted.appendSlice(allocator, "\"[");
            try formatted.appendSlice(allocator, ip);
            try formatted.appendSlice(allocator, "]\"");

            return formatted.toOwnedSlice(allocator);
        } else {
            // IPv4: for=192.168.1.1 (no quotes, no brackets)
            return allocator.dupe(u8, ip);
        }
    }

    /// Validate protocol string against allowed values (RFC 7239 Section 5.4)
    /// Only http, https are allowed. Rejects arbitrary values like "ftp", "javascript:", etc.
    fn isValidProtocol(proto: []const u8) bool {
        return std.ascii.eqlIgnoreCase(proto, "http") or
            std.ascii.eqlIgnoreCase(proto, "https");
    }

    /// Manipulate HTTP request headers: add proxy headers, remove hop-by-hop headers
    /// Returns a new buffer with the modified request
    /// Caller must provide a buffer large enough (recommend original size + 512 bytes for added headers)
    pub fn manipulateRequestHeaders(
        self: *const HTTPInspector,
        allocator: std.mem.Allocator,
        original_request: []const u8,
        client_ip: []const u8,
        client_proto: []const u8,
        host_header: ?[]const u8,
    ) ![]u8 {
        // Find where headers end
        const headers_end = findHeadersEnd(original_request) orelse {
            // No headers end marker found, return original
            return try allocator.dupe(u8, original_request);
        };

        // Split request into request line + headers + body
        var lines = std.mem.splitSequence(u8, original_request[0..headers_end], "\r\n");
        const request_line = lines.next() orelse return error.InvalidRequest;

        // Build new request in a buffer
        var modified_request: std.ArrayList(u8) = .{};
        errdefer modified_request.deinit(allocator);

        // 1. Write request line
        try modified_request.appendSlice(allocator, request_line);
        try modified_request.appendSlice(allocator, "\r\n");

        // 2. Add/modify headers
        // First, copy existing headers (excluding hop-by-hop headers and Connection-listed headers)
        var connection_header_tokens: std.ArrayList([]const u8) = .{};
        defer connection_header_tokens.deinit(allocator);

        // First pass: find Connection header to identify additional hop-by-hop headers
        var temp_it = std.mem.splitSequence(u8, original_request[0..headers_end], "\r\n");
        _ = temp_it.next(); // Skip request line
        while (temp_it.next()) |line| {
            if (line.len == 0) break;

            const colon_idx = std.mem.indexOf(u8, line, ":") orelse continue;
            const header_name = line[0..colon_idx];

            if (std.ascii.eqlIgnoreCase(header_name, "Connection")) {
                var value = line[colon_idx + 1 ..];
                while (value.len > 0 and (value[0] == ' ' or value[0] == '\t')) {
                    value = value[1..];
                }

                // Parse comma-separated tokens
                var token_it = std.mem.splitSequence(u8, value, ",");
                while (token_it.next()) |token_raw| {
                    // Trim whitespace using std.mem.trim
                    const token = std.mem.trim(u8, token_raw, " \t");
                    if (token.len > 0) {
                        try connection_header_tokens.append(allocator, try allocator.dupe(u8, token));
                    }
                }
            }
        }

        // Second pass: copy headers, skipping hop-by-hop headers
        var header_it = std.mem.splitSequence(u8, original_request[0..headers_end], "\r\n");
        _ = header_it.next(); // Skip request line

        var saw_via = false;
        var saw_x_forwarded_for = false;
        var saw_x_forwarded_proto = false;
        var saw_x_forwarded_host = false;
        var saw_rfc7239_forwarded = false;

        // Detect upstream X-Forwarded-Proto to determine if we're behind a TLS terminator
        var upstream_proto: ?[]const u8 = null;

        while (header_it.next()) |line| {
            if (line.len == 0) break;

            const colon_idx = std.mem.indexOf(u8, line, ":") orelse continue;
            const header_name = line[0..colon_idx];

            // Skip hop-by-hop headers
            if (isHopByHopHeader(header_name)) {
                continue;
            }

            // Skip headers listed in Connection header
            var skip = false;
            for (connection_header_tokens.items) |token| {
                if (std.ascii.eqlIgnoreCase(header_name, token)) {
                    skip = true;
                    break;
                }
            }
            if (skip) continue;

            // Track which proxy headers already exist
            if (std.ascii.eqlIgnoreCase(header_name, "Via")) {
                saw_via = true;
            } else if (std.ascii.eqlIgnoreCase(header_name, "X-Forwarded-For")) {
                saw_x_forwarded_for = true;
            } else if (std.ascii.eqlIgnoreCase(header_name, "X-Forwarded-Proto")) {
                saw_x_forwarded_proto = true;
                // Extract the value to detect TLS terminator upstream
                var value = line[colon_idx + 1 ..];
                // Trim both leading and trailing whitespace
                value = std.mem.trim(u8, value, " \t");
                upstream_proto = value;
            } else if (std.ascii.eqlIgnoreCase(header_name, "X-Forwarded-Host")) {
                saw_x_forwarded_host = true;
            } else if (std.ascii.eqlIgnoreCase(header_name, "Forwarded")) {
                saw_rfc7239_forwarded = true;
            }

            // Copy header as-is
            try modified_request.appendSlice(allocator, line);
            try modified_request.appendSlice(allocator, "\r\n");
        }

        // Determine effective protocol: use upstream value if present, otherwise use provided client_proto
        // Validate upstream_proto to prevent injection attacks
        const validated_upstream = if (upstream_proto) |proto|
            if (isValidProtocol(proto)) proto else null
        else
            null;
        const effective_proto = validated_upstream orelse client_proto;

        // 3. Add X-Forwarded-* headers if enabled and not already present
        if (self.add_forwarded_headers) {
            if (!saw_x_forwarded_for) {
                try modified_request.appendSlice(allocator, "X-Forwarded-For: ");
                try modified_request.appendSlice(allocator, client_ip);
                try modified_request.appendSlice(allocator, "\r\n");
            }

            if (!saw_x_forwarded_proto) {
                try modified_request.appendSlice(allocator, "X-Forwarded-Proto: ");
                try modified_request.appendSlice(allocator, effective_proto);
                try modified_request.appendSlice(allocator, "\r\n");
            }

            if (!saw_x_forwarded_host and host_header != null) {
                try modified_request.appendSlice(allocator, "X-Forwarded-Host: ");
                try modified_request.appendSlice(allocator, host_header.?);
                try modified_request.appendSlice(allocator, "\r\n");
            }
        }

        // 4. Add RFC 7239 Forwarded header if enabled and not already present
        // Format: Forwarded: for=<client-ip>;host=<host>;proto=<protocol>
        if (self.add_rfc7239_forwarded and !saw_rfc7239_forwarded) {
            try modified_request.appendSlice(allocator, "Forwarded: for=");
            const formatted_for = try formatForwardedFor(allocator, client_ip);
            defer allocator.free(formatted_for);
            try modified_request.appendSlice(allocator, formatted_for);
            if (host_header != null) {
                try modified_request.appendSlice(allocator, ";host=\"");
                try modified_request.appendSlice(allocator, host_header.?);
                try modified_request.appendSlice(allocator, "\"");
            }
            try modified_request.appendSlice(allocator, ";proto=");
            try modified_request.appendSlice(allocator, effective_proto);
            try modified_request.appendSlice(allocator, "\r\n");
        }

        // 5. Add Via header if enabled
        if (self.add_via_header and !saw_via) {
            // Via: 1.1 prozy-name
            try modified_request.appendSlice(allocator, "Via: 1.1 ");
            try modified_request.appendSlice(allocator, self.proxy_name);
            try modified_request.appendSlice(allocator, "\r\n");
        }

        // 6. Add Connection: close header (since keep-alive is not supported)
        // Always add this to ensure the connection is closed after the response
        try modified_request.appendSlice(allocator, "Connection: close\r\n");

        // 7. End headers section
        try modified_request.appendSlice(allocator, "\r\n");

        // 8. Append body (if any)
        if (headers_end < original_request.len) {
            const body = original_request[headers_end..];
            try modified_request.appendSlice(allocator, body);
        }

        // Free Connection header tokens
        for (connection_header_tokens.items) |token| {
            allocator.free(token);
        }

        return try modified_request.toOwnedSlice(allocator);
    }

    /// Manipulate HTTP response headers: add Via header, remove hop-by-hop headers
    /// Returns a new buffer with the modified response
    /// Note: This only modifies headers, not the body
    pub fn manipulateResponseHeaders(
        self: *const HTTPInspector,
        allocator: std.mem.Allocator,
        original_response: []const u8,
    ) ![]u8 {
        // Find where headers end
        const headers_end = findHeadersEnd(original_response) orelse {
            // No headers end marker found, return original
            return try allocator.dupe(u8, original_response);
        };

        // Split response into status line + headers + body
        var lines = std.mem.splitSequence(u8, original_response[0..headers_end], "\r\n");
        const status_line = lines.next() orelse return error.InvalidResponse;

        // Build new response in a buffer
        var modified_response: std.ArrayList(u8) = .{};
        errdefer modified_response.deinit(allocator);

        // 1. Write status line
        try modified_response.appendSlice(allocator, status_line);
        try modified_response.appendSlice(allocator, "\r\n");

        // 2. First pass: find Connection header to identify additional hop-by-hop headers (RFC 9110 Section 7.6.1)
        var connection_header_tokens: std.ArrayList([]const u8) = .{};
        defer {
            for (connection_header_tokens.items) |token| {
                allocator.free(token);
            }
            connection_header_tokens.deinit(allocator);
        }

        var temp_it = std.mem.splitSequence(u8, original_response[0..headers_end], "\r\n");
        _ = temp_it.next(); // Skip status line
        while (temp_it.next()) |line| {
            if (line.len == 0) break;

            const colon_idx = std.mem.indexOf(u8, line, ":") orelse continue;
            const header_name = line[0..colon_idx];

            if (std.ascii.eqlIgnoreCase(header_name, "Connection")) {
                const value = line[colon_idx + 1 ..];

                // Parse comma-separated tokens
                var token_it = std.mem.splitSequence(u8, value, ",");
                while (token_it.next()) |token_raw| {
                    const token = std.mem.trim(u8, token_raw, " \t");
                    if (token.len > 0) {
                        try connection_header_tokens.append(allocator, try allocator.dupe(u8, token));
                    }
                }
            }
        }

        // 3. Second pass: copy headers (excluding hop-by-hop headers and Connection-nominated headers)
        var header_it = std.mem.splitSequence(u8, original_response[0..headers_end], "\r\n");
        _ = header_it.next(); // Skip status line

        var saw_via = false;

        while (header_it.next()) |line| {
            if (line.len == 0) break;

            const colon_idx = std.mem.indexOf(u8, line, ":") orelse continue;
            const header_name = line[0..colon_idx];

            // Skip hop-by-hop headers
            if (isHopByHopHeader(header_name)) {
                continue;
            }

            // Skip headers listed in Connection header
            var skip = false;
            for (connection_header_tokens.items) |token| {
                if (std.ascii.eqlIgnoreCase(header_name, token)) {
                    skip = true;
                    break;
                }
            }
            if (skip) continue;

            // Track if Via header exists
            if (std.ascii.eqlIgnoreCase(header_name, "Via")) {
                saw_via = true;
            }

            // Copy header as-is
            try modified_response.appendSlice(allocator, line);
            try modified_response.appendSlice(allocator, "\r\n");
        }

        // 3. Add Via header if enabled and not present
        if (self.add_via_header and !saw_via) {
            // Via: 1.1 prozy-name
            try modified_response.appendSlice(allocator, "Via: 1.1 ");
            try modified_response.appendSlice(allocator, self.proxy_name);
            try modified_response.appendSlice(allocator, "\r\n");
        }

        // 4. End headers section
        try modified_response.appendSlice(allocator, "\r\n");

        // 5. Append body (if any)
        if (headers_end < original_response.len) {
            const body = original_response[headers_end..];
            try modified_response.appendSlice(allocator, body);
        }

        return try modified_response.toOwnedSlice(allocator);
    }
};

/// Get current Unix timestamp in seconds (public utility for HTTP and backend modules)
pub fn getTimestamp() i64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch |err| {
        log.warn("clock_gettime() failed: {s}, backend health recovery may be disabled", .{@errorName(err)});
        return 0;
    };
    return ts.sec;
}

/// HTTP response cache with LRU eviction for performance optimization
///
/// SECURITY: Cache keys include Host header for multi-tenant isolation.
/// Requests without Host headers MUST NOT be cached to prevent pollution
/// across different virtual hosts/APIs.
pub const HTTPCache = struct {
    /// Metadata for caching a response (RFC 9111 Phase 5)
    /// This is the non-owning version used for passing data
    pub const CacheMetadata = struct {
        date_header: ?i64 = null,
        age_header: ?u32 = null,
        expires_header: ?i64 = null,
        request_time: i64 = 0,
        response_time: i64 = 0,
        cache_control: HTTPInspector.CacheControlDirectives = .{},
        etag: ?[]const u8 = null,
        last_modified: ?[]const u8 = null,
        is_weak_etag: bool = false,
        // RFC 9111 Phase 3: Vary header support
        vary_headers: ?[][]const u8 = null,
        vary_context: ?HTTPInspector.VaryContext = null,
    };

    /// Internal storage for cache metadata with owned slices
    const CacheMetadataStorage = struct {
        date_header: ?i64 = null,
        age_header: ?u32 = null,
        expires_header: ?i64 = null,
        request_time: i64 = 0,
        response_time: i64 = 0,
        cache_control: HTTPInspector.CacheControlDirectives = .{},
        etag: ?[]u8 = null,
        last_modified: ?[]u8 = null,
        is_weak_etag: bool = false,
        vary_headers: ?[][]const u8 = null,
        vary_context: ?HTTPInspector.VaryContext = null,
    };

    const CacheNode = struct {
        key: u64,
        response: []u8,
        method: []u8,
        host: []u8,
        path: []u8,
        created_at: i64,
        ttl: u32,
        size: usize,
        access_count: u32,
        prev: ?*CacheNode,
        next: ?*CacheNode,

        // RFC 9111 metadata embedded (avoids field duplication)
        metadata: CacheMetadataStorage = .{},
    };

    allocator: std.mem.Allocator,
    cache: std.AutoHashMap(u64, *CacheNode),
    max_size: usize,
    current_size: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    hits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    misses: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rwlock: std.Thread.RwLock = .{},
    head: ?*CacheNode = null,
    tail: ?*CacheNode = null,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) HTTPCache {
        return .{
            .allocator = allocator,
            .cache = std.AutoHashMap(u64, *CacheNode).init(allocator),
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *HTTPCache) void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

        var it = self.cache.iterator();
        while (it.next()) |kv| {
            const node = kv.value_ptr.*;
            self.allocator.free(node.response);
            self.allocator.free(node.method);
            self.allocator.free(node.host);
            self.allocator.free(node.path);
            if (node.metadata.etag) |etag| self.allocator.free(etag);
            if (node.metadata.last_modified) |lm| self.allocator.free(lm);

            // RFC 9111 Phase 3: Free vary data
            if (node.metadata.vary_headers) |headers| {
                for (headers) |h| self.allocator.free(h);
                self.allocator.free(headers);
            }
            if (node.metadata.vary_context) |*ctx| {
                if (ctx.accept) |v| self.allocator.free(v);
                if (ctx.accept_encoding) |v| self.allocator.free(v);
                if (ctx.accept_language) |v| self.allocator.free(v);
                if (ctx.accept_charset) |v| self.allocator.free(v);
                if (ctx.user_agent) |v| self.allocator.free(v);
            }

            self.allocator.destroy(node);
        }
        self.cache.deinit();
    }

    /// Handle 304 Not Modified response from backend
    /// Returns the cached response (body + headers) to be served to the client
    /// Updates cached entry's metadata with new values from the 304 response
    pub fn handle304(self: *HTTPCache, cached_response: []const u8, new_304_headers: []const u8) []const u8 {
        _ = self;
        _ = new_304_headers;
        // TODO: Update cached metadata with new headers from 304 response
        // For now, just serve the stale cached response (200 OK)
        return cached_response;
    }

    /// Stale-while-revalidate context for background revalidation
    pub const RevalidationContext = struct {
        allocator: std.mem.Allocator,
        http_cache: *HTTPCache,
        method: []const u8,
        host: []const u8,
        path: []const u8,
        metadata: CacheMetadata,
        backend_host: []const u8,
        backend_port: u16,
        connect_timeout: Timeout,

        pub fn init(
            allocator: std.mem.Allocator,
            http_cache: *HTTPCache,
            method: []const u8,
            host: []const u8,
            path: []const u8,
            metadata: CacheMetadata,
            backend_host: []const u8,
            backend_port: u16,
            connect_timeout: std.Io.Timeout,
        ) !RevalidationContext {
            // Deep copy metadata strings to ensure safety if cache entry is evicted
            var safe_metadata = metadata;

            if (metadata.etag) |e| safe_metadata.etag = try allocator.dupe(u8, e);
            if (metadata.last_modified) |l| safe_metadata.last_modified = try allocator.dupe(u8, l);

            // Deep copy vary context if present
            if (metadata.vary_context) |ctx| {
                safe_metadata.vary_context = .{
                    .accept = if (ctx.accept) |v| try allocator.dupe(u8, v) else null,
                    .accept_encoding = if (ctx.accept_encoding) |v| try allocator.dupe(u8, v) else null,
                    .accept_language = if (ctx.accept_language) |v| try allocator.dupe(u8, v) else null,
                    .accept_charset = if (ctx.accept_charset) |v| try allocator.dupe(u8, v) else null,
                    .user_agent = if (ctx.user_agent) |v| try allocator.dupe(u8, v) else null,
                };
            }

            return RevalidationContext{
                .allocator = allocator,
                .http_cache = http_cache,
                .method = try allocator.dupe(u8, method),
                .host = try allocator.dupe(u8, host),
                .path = try allocator.dupe(u8, path),
                .metadata = safe_metadata,
                .backend_host = try allocator.dupe(u8, backend_host),
                .backend_port = backend_port,
                .connect_timeout = connect_timeout,
            };
        }

        pub fn deinit(self: *RevalidationContext) void {
            self.allocator.free(self.method);
            self.allocator.free(self.host);
            self.allocator.free(self.path);
            self.allocator.free(self.backend_host);

            // Free metadata strings
            if (self.metadata.etag) |e| self.allocator.free(e);
            if (self.metadata.last_modified) |l| self.allocator.free(l);

            // Free vary context
            if (self.metadata.vary_context) |*ctx| {
                if (ctx.accept) |v| self.allocator.free(v);
                if (ctx.accept_encoding) |v| self.allocator.free(v);
                if (ctx.accept_language) |v| self.allocator.free(v);
                if (ctx.accept_charset) |v| self.allocator.free(v);
                if (ctx.user_agent) |v| self.allocator.free(v);
            }
        }
    };

    /// Background revalidation task for stale-while-revalidate
    /// This runs as a detached async task to refresh stale cache entries
    pub fn revalidateStaleEntry(io: std.Io, context: RevalidationContext) void {
        var ctx = context;
        defer ctx.deinit();

        if (!builtin.is_test) {
            log.info("background revalidation started for {s} {s}://{s}:{d}{s}", .{ ctx.method, "http", ctx.backend_host, ctx.backend_port, ctx.path });
        }

        // Connect to backend
        const connectToBackend = @import("transport.zig").connectToBackend;
        const backend_stream = connectToBackend(io, ctx.backend_host, ctx.backend_port, ctx.connect_timeout) catch |err| {
            log.warn("background revalidation failed: cannot connect to backend: {s}", .{@errorName(err)});
            return;
        };
        defer backend_stream.close(io);

        // Build conditional request
        var request_buffer: [8192]u8 = undefined;
        const request = std.fmt.bufPrint(&request_buffer,
            \\{s} {s} HTTP/1.1\r\n
            \\Host: {s}\r\n
            \\User-Agent: Prozy-Revalidator/1.0\r\n
            \\Connection: close\r\n
        , .{ ctx.method, ctx.path, ctx.host }) catch |err| {
            log.warn("background revalidation failed: request formatting error: {s}", .{@errorName(err)});
            return;
        };

        // Add conditional headers
        const conditional_request = HTTPInspector.addConditionalHeaders(ctx.allocator, request, ctx.metadata) catch |err| {
            log.warn("background revalidation failed: conditional header error: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.allocator.free(conditional_request);

        // Send request
        var backend_write_buf: [4096]u8 = undefined;
        var backend_writer = backend_stream.writer(io, &backend_write_buf);

        Writer.writeAll(&backend_writer.interface, conditional_request) catch |err| {
            log.warn("background revalidation failed: request send error: {s}", .{@errorName(err)});
            return;
        };
        Writer.flush(&backend_writer.interface) catch |err| {
            log.warn("background revalidation failed: request flush error: {s}", .{@errorName(err)});
            return;
        };

        // Read response
        var backend_read_buf: [4096]u8 = undefined;
        var backend_reader = backend_stream.reader(io, &backend_read_buf);

        var response_buffer = std.ArrayList(u8){};
        defer response_buffer.deinit(context.allocator);

        var temp_buffer: [4096]u8 = undefined;
        while (true) {
            var slices = [_][]u8{temp_buffer[0..]};
            const n = backend_reader.interface.readVec(&slices) catch |err| {
                log.warn("background revalidation failed: response read error: {s}", .{@errorName(err)});
                return;
            };
            if (n == 0) break;
            response_buffer.appendSlice(context.allocator, temp_buffer[0..n]) catch |err| {
                log.warn("background revalidation failed: response buffer error: {s}", .{@errorName(err)});
                return;
            };
        }

        const response = response_buffer.toOwnedSlice(context.allocator) catch |err| {
            log.warn("background revalidation failed: response ownership error: {s}", .{@errorName(err)});
            return;
        };
        defer context.allocator.free(response);

        // Parse response to check if it's 304 or new content
        if (HTTPInspector.parseResponseLine(response)) |parsed_response| {
            if (parsed_response.status_code == 304) {
                // 304 Not Modified - cached content is still valid
                if (!builtin.is_test) {
                    log.info("background revalidation successful: 304 Not Modified for {s} {s}", .{ context.method, context.path });
                }

                // Update metadata from 304 response headers
                const cache_control = HTTPInspector.parseCacheControl(response);

                var etag: ?[]const u8 = null;
                if (HTTPInspector.findHeader(response, "ETag")) |e| etag = e;
                var last_modified: ?[]const u8 = null;
                if (HTTPInspector.findHeader(response, "Last-Modified")) |l| last_modified = l;

                // Parse other freshness headers
                const date_header = if (HTTPInspector.findHeader(response, "Date")) |d| HTTPInspector.parseHttpDate(d) else null;
                const expires_header = if (HTTPInspector.findHeader(response, "Expires")) |e| HTTPInspector.parseHttpDate(e) else null;

                // Calculate Age if present
                const age_header = if (HTTPInspector.findHeader(response, "Age")) |a| std.fmt.parseInt(u32, a, 10) catch null else null;

                const new_metadata = CacheMetadata{
                    .cache_control = cache_control,
                    .response_time = getTimestamp(),
                    .request_time = getTimestamp(), // Approximation for background revalidation
                    .etag = etag,
                    .last_modified = last_modified,
                    .date_header = date_header,
                    .expires_header = expires_header,
                    .age_header = age_header,
                    // Preserve vary context from original request
                    .vary_context = context.metadata.vary_context,
                };

                context.http_cache.updateMetadata(context.method, context.host, context.path, context.metadata.vary_context, new_metadata) catch |err| {
                    log.warn("background revalidation failed: metadata update error: {s}", .{@errorName(err)});
                };
            } else if (parsed_response.status_code == 200) {
                // New content available - update cache
                const cache_control = HTTPInspector.parseCacheControl(response);
                if (cache_control.isCacheable()) {
                    const ttl = cache_control.getTTL(300);

                    // Extract validators from response
                    var etag: ?[]const u8 = null;
                    if (HTTPInspector.findHeader(response, "ETag")) |e| etag = e;
                    var last_modified: ?[]const u8 = null;
                    if (HTTPInspector.findHeader(response, "Last-Modified")) |l| last_modified = l;

                    const updated_metadata = CacheMetadata{
                        .cache_control = cache_control,
                        .response_time = getTimestamp(),
                        .request_time = context.metadata.request_time,
                        .etag = etag,
                        .last_modified = last_modified,
                    };

                    context.http_cache.put(context.method, context.host, context.path, response, ttl, updated_metadata, null) catch |err| {
                        log.warn("background revalidation failed: cache update error: {s}", .{@errorName(err)});
                        return;
                    };

                    if (!builtin.is_test) {
                        log.info("background revalidation successful: updated cache entry for {s} {s}", .{ context.method, context.path });
                    }
                } else {
                    if (!builtin.is_test) {
                        log.info("background revalidation: new response is not cacheable, keeping stale entry", .{});
                    }
                }
            } else {
                if (!builtin.is_test) {
                    log.warn("background revalidation: unexpected response status {d} for {s} {s}", .{ parsed_response.status_code, context.method, context.path });
                }
            }
        } else {
            log.warn("background revalidation failed: invalid response from backend", .{});
        }
    }

    pub const GetResult = struct {
        response: []u8,
        metadata: CacheMetadata,
        is_stale: bool,
    };

    /// Get cached response (returns owned copy that caller must free)
    /// allow_stale: if true, returns stale entries (marked as is_stale=true) for revalidation
    pub fn get(
        self: *HTTPCache,
        method: []const u8,
        host: []const u8,
        path: []const u8,
        vary_context: ?HTTPInspector.VaryContext,
        allow_stale: bool,
    ) ?GetResult {
        const key = hashKey(method, host, path, vary_context);

        // Use shared (read) lock for concurrent reads
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();

        if (self.cache.get(key)) |node| {
            const now = getTimestamp();

            // Check expiration
            const is_stale = blk: {
                if (node.metadata.date_header != null or node.metadata.cache_control.max_age != null) {
                    const freshness_info = HTTPInspector.FreshnessInfo{
                        .date = node.metadata.date_header,
                        .age = node.metadata.age_header,
                        .expires = node.metadata.expires_header,
                        .cache_control = node.metadata.cache_control,
                        .response_time = node.metadata.response_time,
                        .request_time = node.metadata.request_time,
                    };
                    break :blk freshness_info.isStale(now);
                } else {
                    const elapsed = now - node.created_at;
                    break :blk elapsed >= 0 and elapsed > @as(i64, node.ttl);
                }
            };

            if (is_stale and !allow_stale) {
                _ = self.misses.fetchAdd(1, .monotonic);
                return null;
            }

            // Update stats
            if (!is_stale) {
                _ = self.hits.fetchAdd(1, .monotonic);
            } else {
                _ = self.misses.fetchAdd(1, .monotonic); // Stale is technically a miss for "fresh" content
            }

            const response_copy = self.allocator.alloc(u8, node.response.len) catch {
                return null;
            };
            @memcpy(response_copy, node.response);

            // Copy metadata
            var etag_copy: ?[]const u8 = null;
            if (node.metadata.etag) |e| etag_copy = self.allocator.dupe(u8, e) catch null;

            var last_modified_copy: ?[]const u8 = null;
            if (node.metadata.last_modified) |l| last_modified_copy = self.allocator.dupe(u8, l) catch null;

            const metadata = CacheMetadata{
                .date_header = node.metadata.date_header,
                .age_header = node.metadata.age_header,
                .expires_header = node.metadata.expires_header,
                .request_time = node.metadata.request_time,
                .response_time = node.metadata.response_time,
                .cache_control = node.metadata.cache_control,
                .etag = etag_copy,
                .last_modified = last_modified_copy,
                .is_weak_etag = node.metadata.is_weak_etag,
                .vary_headers = null, // Deep copy TODO if needed
                .vary_context = null, // Deep copy TODO if needed
            };

            return GetResult{
                .response = response_copy,
                .metadata = metadata,
                .is_stale = is_stale,
            };
        }

        _ = self.misses.fetchAdd(1, .monotonic);
        return null;
    }

    /// Store response in cache with optional RFC 9111 metadata
    /// ttl: Time-to-live in seconds (backward compatibility fallback when metadata is null)
    /// metadata: RFC 9111 cache metadata (preferred for freshness calculations)
    /// vary_context: Request headers for Vary-aware caching
    pub fn put(
        self: *HTTPCache,
        method: []const u8,
        host: []const u8,
        path: []const u8,
        response: []const u8,
        ttl: u32,
        metadata: ?CacheMetadata,
        vary_context: ?HTTPInspector.VaryContext,
    ) !void {
        const key = hashKey(method, host, path, vary_context);

        // Don't cache if response is too large
        if (response.len > self.max_size / 2) {
            return;
        }

        self.rwlock.lock();
        defer self.rwlock.unlock();

        // Evict old entry if exists
        if (self.cache.get(key)) |existing_node| {
            self.evictNode(existing_node);
        }

        // Check if we need to evict to make space
        const total_new_size = response.len + method.len + host.len + path.len;
        while (self.current_size.load(.monotonic) + total_new_size > self.max_size and self.cache.count() > 0) {
            self.evictLRU();
        }

        // Allocate and copy data
        // Each errdefer only frees the allocation immediately preceding it to avoid double-free
        const response_copy = try self.allocator.alloc(u8, response.len);
        errdefer self.allocator.free(response_copy);
        @memcpy(response_copy, response);

        const method_copy = try self.allocator.alloc(u8, method.len);
        errdefer self.allocator.free(method_copy);
        @memcpy(method_copy, method);

        const host_copy = try self.allocator.alloc(u8, host.len);
        errdefer self.allocator.free(host_copy);
        @memcpy(host_copy, host);

        const path_copy = try self.allocator.alloc(u8, path.len);
        errdefer self.allocator.free(path_copy);
        @memcpy(path_copy, path);

        // Copy optional metadata strings (ETag, Last-Modified)
        var etag_copy: ?[]u8 = null;
        var last_modified_copy: ?[]u8 = null;

        if (metadata) |meta| {
            if (meta.etag) |etag_str| {
                etag_copy = try self.allocator.alloc(u8, etag_str.len);
                @memcpy(etag_copy.?, etag_str);
            }
            if (meta.last_modified) |lm_str| {
                last_modified_copy = try self.allocator.alloc(u8, lm_str.len);
                @memcpy(last_modified_copy.?, lm_str);
            }
        }

        // RFC 9111 Phase 3: Copy vary headers and context
        var vary_headers_copy: ?[][]const u8 = null;
        var vary_context_copy: ?HTTPInspector.VaryContext = null;

        if (metadata) |meta| {
            if (meta.vary_headers) |headers| {
                const temp_headers = try self.allocator.alloc([]const u8, headers.len);
                for (headers, 0..) |header, i| {
                    temp_headers[i] = try self.allocator.dupe(u8, header);
                }
                vary_headers_copy = temp_headers;
            }
            if (meta.vary_context) |ctx| {
                // Deep copy VaryContext strings
                vary_context_copy = .{
                    .accept = if (ctx.accept) |v| try self.allocator.dupe(u8, v) else null,
                    .accept_encoding = if (ctx.accept_encoding) |v| try self.allocator.dupe(u8, v) else null,
                    .accept_language = if (ctx.accept_language) |v| try self.allocator.dupe(u8, v) else null,
                    .accept_charset = if (ctx.accept_charset) |v| try self.allocator.dupe(u8, v) else null,
                    .user_agent = if (ctx.user_agent) |v| try self.allocator.dupe(u8, v) else null,
                };
            }
        }

        // Create new node
        const node = try self.allocator.create(CacheNode);
        errdefer {
            self.allocator.free(response_copy);
            self.allocator.free(method_copy);
            self.allocator.free(host_copy);
            self.allocator.free(path_copy);
            if (etag_copy) |etag| self.allocator.free(etag);
            if (last_modified_copy) |lm| self.allocator.free(lm);
            // Clean up vary data
            if (vary_headers_copy) |headers| {
                for (headers) |h| self.allocator.free(h);
                self.allocator.free(headers);
            }
            if (vary_context_copy) |*ctx| {
                if (ctx.accept) |v| self.allocator.free(v);
                if (ctx.accept_encoding) |v| self.allocator.free(v);
                if (ctx.accept_language) |v| self.allocator.free(v);
                if (ctx.accept_charset) |v| self.allocator.free(v);
                if (ctx.user_agent) |v| self.allocator.free(v);
            }
            self.allocator.destroy(node);
        }

        node.* = .{
            .key = key,
            .response = response_copy,
            .method = method_copy,
            .host = host_copy,
            .path = path_copy,
            .created_at = getTimestamp(),
            .ttl = ttl,
            .size = response.len + method.len + host.len + path.len,
            .access_count = 0,
            .prev = null,
            .next = null,
            // RFC 9111 metadata embedded in storage struct
            .metadata = .{
                .date_header = if (metadata) |m| m.date_header else null,
                .age_header = if (metadata) |m| m.age_header else null,
                .expires_header = if (metadata) |m| m.expires_header else null,
                .request_time = if (metadata) |m| m.request_time else 0,
                .response_time = if (metadata) |m| m.response_time else getTimestamp(),
                .cache_control = if (metadata) |m| m.cache_control else .{},
                .etag = etag_copy,
                .last_modified = last_modified_copy,
                .is_weak_etag = if (metadata) |m| m.is_weak_etag else false,
                .vary_headers = vary_headers_copy,
                .vary_context = vary_context_copy,
            },
        };

        // Add to cache map (errdefer above handles cleanup on failure)
        try self.cache.put(key, node);

        // Add to front of LRU list
        self.addToFront(node);
        _ = self.current_size.fetchAdd(node.size, .monotonic);
    }

    /// Generate cache key including method, host, path, and optional vary context
    /// RFC 9111 Phase 3: Vary support for content negotiation
    fn hashKey(method: []const u8, host: []const u8, path: []const u8, vary_context: ?HTTPInspector.VaryContext) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(method);
        hasher.update(host);
        hasher.update(path);

        // Include vary context in key to support multiple variants for same URL
        if (vary_context) |ctx| {
            const ctx_hash = ctx.hash();
            hasher.update(std.mem.asBytes(&ctx_hash));
        }

        return hasher.final();
    }

    /// Add node to front of LRU list (most recently used)
    fn addToFront(self: *HTTPCache, node: *CacheNode) void {
        node.next = self.head;
        node.prev = null;

        if (self.head) |head| {
            head.prev = node;
        }
        self.head = node;

        if (self.tail == null) {
            self.tail = node;
        }
    }

    /// Update metadata for an existing cache entry (e.g., on 304 Not Modified)
    pub fn updateMetadata(
        self: *HTTPCache,
        method: []const u8,
        host: []const u8,
        path: []const u8,
        vary_context: ?HTTPInspector.VaryContext,
        new_metadata: CacheMetadata,
    ) !void {
        const key = hashKey(method, host, path, vary_context);

        self.rwlock.lock();
        defer self.rwlock.unlock();

        if (self.cache.get(key)) |node| {
            // Free old metadata strings
            if (node.metadata.etag) |e| self.allocator.free(e);
            if (node.metadata.last_modified) |lm| self.allocator.free(lm);

            // Copy new strings
            var etag_copy: ?[]u8 = null;
            if (new_metadata.etag) |etag_str| {
                etag_copy = try self.allocator.alloc(u8, etag_str.len);
                @memcpy(etag_copy.?, etag_str);
            }

            var last_modified_copy: ?[]u8 = null;
            if (new_metadata.last_modified) |lm_str| {
                last_modified_copy = try self.allocator.alloc(u8, lm_str.len);
                @memcpy(last_modified_copy.?, lm_str);
            }

            // Update metadata fields
            node.metadata.date_header = new_metadata.date_header;
            node.metadata.age_header = new_metadata.age_header;
            node.metadata.expires_header = new_metadata.expires_header;
            node.metadata.request_time = new_metadata.request_time;
            node.metadata.response_time = new_metadata.response_time;
            node.metadata.cache_control = new_metadata.cache_control;
            node.metadata.etag = etag_copy;
            node.metadata.last_modified = last_modified_copy;
            node.metadata.is_weak_etag = new_metadata.is_weak_etag;

            // Move to front (MRU) as it was just validated/updated
            self.moveToFront(node);
        }
    }

    /// Remove node from LRU list
    fn removeFromList(self: *HTTPCache, node: *CacheNode) void {
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.head = node.next;
        }

        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.tail = node.prev;
        }

        node.prev = null;
        node.next = null;
    }

    /// Move node to front of LRU list (mark as most recently used)
    fn moveToFront(self: *HTTPCache, node: *CacheNode) void {
        if (self.head == node) return; // Already at front

        self.removeFromList(node);
        self.addToFront(node);
    }

    /// Evict LRU entry (from tail) - O(1) operation
    fn evictLRU(self: *HTTPCache) void {
        if (self.tail) |tail_node| {
            self.evictNode(tail_node);
        }
    }

    /// Evict specific node
    fn evictNode(self: *HTTPCache, node: *CacheNode) void {
        // Remove from linked list
        self.removeFromList(node);

        // Remove from hash map
        _ = self.cache.remove(node.key);

        // Update size
        _ = self.current_size.fetchSub(node.size, .monotonic);

        // Free memory
        self.allocator.free(node.response);
        self.allocator.free(node.method);
        self.allocator.free(node.host);
        self.allocator.free(node.path);
        if (node.metadata.etag) |etag| self.allocator.free(etag);
        if (node.metadata.last_modified) |lm| self.allocator.free(lm);

        // RFC 9111 Phase 3: Free vary data
        if (node.metadata.vary_headers) |headers| {
            for (headers) |h| self.allocator.free(h);
            self.allocator.free(headers);
        }
        if (node.metadata.vary_context) |*ctx| {
            if (ctx.accept) |v| self.allocator.free(v);
            if (ctx.accept_encoding) |v| self.allocator.free(v);
            if (ctx.accept_language) |v| self.allocator.free(v);
            if (ctx.accept_charset) |v| self.allocator.free(v);
            if (ctx.user_agent) |v| self.allocator.free(v);
        }

        self.allocator.destroy(node);
    }

    pub fn getStats(self: *const HTTPCache) CacheStats {
        return .{
            .hits = self.hits.load(.monotonic),
            .misses = self.misses.load(.monotonic),
            .current_size = self.current_size.load(.monotonic),
            .entry_count = self.cache.count(),
            .max_size = self.max_size,
        };
    }

    pub const CacheStats = struct {
        hits: u64,
        misses: u64,
        current_size: usize,
        entry_count: usize,
        max_size: usize,

        pub fn hitRate(self: CacheStats) f64 {
            const total = self.hits + self.misses;
            if (total == 0) return 0.0;
            return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total)) * 100.0;
        }
    };
};
