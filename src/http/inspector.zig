//! HTTP request/response inspection and parsing utilities
//!
//! This module provides HTTP protocol analysis capabilities including:
//! - HTTP request line parsing (method, path, version)
//! - HTTP response status line parsing
//! - Header detection and extraction
//! - Complete response detection (Content-Length, chunked)

const std = @import("std");

pub const HTTPInspector = struct {
    add_forwarded_headers: bool = true,
    add_via_header: bool = true,
    proxy_name: []const u8 = "Prozy/1.0",

    pub fn init(add_forwarded: bool, add_via: bool, proxy_name: []const u8) HTTPInspector {
        return .{
            .add_forwarded_headers = add_forwarded,
            .add_via_header = add_via,
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
};
