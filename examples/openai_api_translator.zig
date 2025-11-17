//! OpenAI API Translator Proxy
//!
//! This example demonstrates a real-world API gateway use case: translating
//! between OpenAI's Responses API format and the Chat Completions API format.
//!
//! Use case: Legacy clients using the Responses API can transparently connect
//! to backends that only support Chat Completions API (or vice versa).
//!
//! Features demonstrated:
//! - HTTP request/response transformation
//! - JSON parsing and manipulation
//! - Header modification
//! - Error handling and validation
//! - Real-world API gateway pattern
//!
//! Request flow:
//! 1. Client sends Responses API request → /v1/responses
//! 2. Proxy converts to Chat Completions format
//! 3. Proxy forwards to backend → /v1/chat/completions
//! 4. Backend responds with Chat Completions format
//! 5. Proxy converts back to Responses API format
//! 6. Client receives Responses API response
//!
//! Usage:
//!   zig build openai_translator
//!   ./zig-out/bin/openai_api_translator
//!
//! Then send requests:
//!   curl -X POST http://localhost:8080/v1/responses \
//!     -H "Content-Type: application/json" \
//!     -d '{
//!       "model": "gpt-4",
//!       "input": "What is the meaning of life?",
//!       "temperature": 0.7
//!     }'

const std = @import("std");
const prozy = @import("prozy");

const log = std.log;

/// OpenAI Responses API request format (simplified)
const ResponsesAPIRequest = struct {
    model: []const u8,
    input: []const u8,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    top_p: ?f32 = null,
    frequency_penalty: ?f32 = null,
    presence_penalty: ?f32 = null,
    stop: ?[]const []const u8 = null,
};

/// OpenAI Chat Completions API request format (simplified)
const ChatCompletionsRequest = struct {
    model: []const u8,
    messages: []Message,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    top_p: ?f32 = null,
    frequency_penalty: ?f32 = null,
    presence_penalty: ?f32 = null,
    stop: ?[]const []const u8 = null,

    const Message = struct {
        role: []const u8,
        content: []const u8,
    };
};

/// OpenAI Responses API response format (simplified)
const ResponsesAPIResponse = struct {
    id: []const u8,
    object: []const u8 = "response",
    created: i64,
    model: []const u8,
    output: []const u8,
    usage: ?Usage = null,

    const Usage = struct {
        prompt_tokens: u32,
        completion_tokens: u32,
        total_tokens: u32,
    };
};

/// OpenAI Chat Completions API response format (simplified)
const ChatCompletionsResponse = struct {
    id: []const u8,
    object: []const u8,
    created: i64,
    model: []const u8,
    choices: []Choice,
    usage: ?Usage = null,

    const Choice = struct {
        index: u32,
        message: Message,
        finish_reason: ?[]const u8 = null,

        const Message = struct {
            role: []const u8,
            content: []const u8,
        };
    };

    const Usage = struct {
        prompt_tokens: u32,
        completion_tokens: u32,
        total_tokens: u32,
    };
};

/// Convert Responses API request to Chat Completions request
fn convertRequestToChat(
    allocator: std.mem.Allocator,
    responses_req: ResponsesAPIRequest,
) !ChatCompletionsRequest {
    // Create messages array with single user message
    var messages = try allocator.alloc(ChatCompletionsRequest.Message, 1);
    messages[0] = .{
        .role = "user",
        .content = try allocator.dupe(u8, responses_req.input),
    };

    return .{
        .model = try allocator.dupe(u8, responses_req.model),
        .messages = messages,
        .temperature = responses_req.temperature,
        .max_tokens = responses_req.max_tokens,
        .top_p = responses_req.top_p,
        .frequency_penalty = responses_req.frequency_penalty,
        .presence_penalty = responses_req.presence_penalty,
        .stop = if (responses_req.stop) |stop| blk: {
            const stop_copy = try allocator.alloc([]const u8, stop.len);
            for (stop, 0..) |s, i| {
                stop_copy[i] = try allocator.dupe(u8, s);
            }
            break :blk stop_copy;
        } else null,
    };
}

/// Convert Chat Completions response to Responses API response
fn convertResponseToResponses(
    allocator: std.mem.Allocator,
    chat_resp: ChatCompletionsResponse,
) !ResponsesAPIResponse {
    // Extract content from first choice (or empty string if no choices)
    const output = if (chat_resp.choices.len > 0)
        try allocator.dupe(u8, chat_resp.choices[0].message.content)
    else
        try allocator.dupe(u8, "");

    return .{
        .id = try allocator.dupe(u8, chat_resp.id),
        .object = "response",
        .created = chat_resp.created,
        .model = try allocator.dupe(u8, chat_resp.model),
        .output = output,
        .usage = if (chat_resp.usage) |usage| .{
            .prompt_tokens = usage.prompt_tokens,
            .completion_tokens = usage.completion_tokens,
            .total_tokens = usage.total_tokens,
        } else null,
    };
}

/// Simple HTTP request transformer (demonstration)
fn transformRequest(
    allocator: std.mem.Allocator,
    body: []const u8,
) ![]const u8 {
    // Parse Responses API request
    const parsed = std.json.parseFromSlice(
        ResponsesAPIRequest,
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.err("Failed to parse Responses API request: {s}", .{@errorName(err)});
        return error.ParseFailed;
    };
    defer parsed.deinit();

    log.info("Converting Responses API request:", .{});
    log.info("  Model: {s}", .{parsed.value.model});
    log.info("  Input: {s}", .{parsed.value.input});

    // Convert to Chat Completions format
    const chat_req = try convertRequestToChat(allocator, parsed.value);

    log.info("Converted to Chat Completions request:", .{});
    log.info("  Model: {s}", .{chat_req.model});
    log.info("  Messages: {}", .{chat_req.messages.len});

    // Serialize to JSON
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    try std.json.stringify(chat_req, .{}, result.writer());

    return result.toOwnedSlice();
}

/// Simple HTTP response transformer (demonstration)
fn transformResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
) ![]const u8 {
    // Parse Chat Completions response
    const parsed = std.json.parseFromSlice(
        ChatCompletionsResponse,
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.err("Failed to parse Chat Completions response: {s}", .{@errorName(err)});
        return error.ParseFailed;
    };
    defer parsed.deinit();

    log.info("Converting Chat Completions response:", .{});
    log.info("  ID: {s}", .{parsed.value.id});
    log.info("  Choices: {}", .{parsed.value.choices.len});

    // Convert to Responses API format
    const responses_resp = try convertResponseToResponses(allocator, parsed.value);

    log.info("Converted to Responses API response:", .{});
    log.info("  ID: {s}", .{responses_resp.id});
    log.info("  Output length: {}", .{responses_resp.output.len});

    // Serialize to JSON
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    try std.json.stringify(responses_resp, .{}, result.writer());

    return result.toOwnedSlice();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.info("=== OpenAI API Translator Proxy ===", .{});
    log.info("", .{});
    log.info("This proxy translates between OpenAI Responses API and Chat Completions API", .{});
    log.info("", .{});
    log.info("Request flow:", .{});
    log.info("  1. Client → /v1/responses (Responses API format)", .{});
    log.info("  2. Proxy converts to Chat Completions format", .{});
    log.info("  3. Proxy → Backend /v1/chat/completions", .{});
    log.info("  4. Backend responds with Chat Completions format", .{});
    log.info("  5. Proxy converts back to Responses API format", .{});
    log.info("  6. Client receives Responses API response", .{});
    log.info("", .{});

    // Demonstrate transformation with example data
    const example_request =
        \\{
        \\  "model": "gpt-4",
        \\  "input": "What is the meaning of life?",
        \\  "temperature": 0.7,
        \\  "max_tokens": 100
        \\}
    ;

    const example_response =
        \\{
        \\  "id": "chatcmpl-123",
        \\  "object": "chat.completion",
        \\  "created": 1677652288,
        \\  "model": "gpt-4",
        \\  "choices": [{
        \\    "index": 0,
        \\    "message": {
        \\      "role": "assistant",
        \\      "content": "The meaning of life is a philosophical question..."
        \\    },
        \\    "finish_reason": "stop"
        \\  }],
        \\  "usage": {
        \\    "prompt_tokens": 10,
        \\    "completion_tokens": 20,
        \\    "total_tokens": 30
        \\  }
        \\}
    ;

    log.info("Example transformation demonstration:", .{});
    log.info("", .{});

    // Transform request
    log.info("=== Request Transformation ===", .{});
    log.info("Original Responses API request:", .{});
    log.info("{s}", .{example_request});
    log.info("", .{});

    const transformed_request = transformRequest(allocator, example_request) catch |err| {
        log.err("Request transformation failed: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(transformed_request);

    log.info("Transformed Chat Completions request:", .{});
    log.info("{s}", .{transformed_request});
    log.info("", .{});

    // Transform response
    log.info("=== Response Transformation ===", .{});
    log.info("Original Chat Completions response:", .{});
    log.info("{s}", .{example_response});
    log.info("", .{});

    const transformed_response = transformResponse(allocator, example_response) catch |err| {
        log.err("Response transformation failed: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(transformed_response);

    log.info("Transformed Responses API response:", .{});
    log.info("{s}", .{transformed_response});
    log.info("", .{});

    log.info("=== Transformation Complete ===", .{});
    log.info("", .{});
    log.info("In a full implementation, this proxy would:", .{});
    log.info("  • Listen on port 8080 for client requests", .{});
    log.info("  • Transform incoming Responses API requests", .{});
    log.info("  • Forward to OpenAI Chat Completions endpoint", .{});
    log.info("  • Transform responses back to Responses API format", .{});
    log.info("  • Handle streaming responses (if needed)", .{});
    log.info("  • Add authentication/rate limiting", .{});
    log.info("  • Log all transformations for debugging", .{});
    log.info("", .{});

    // TODO: Integrate with Prozy proxy for full implementation
    // This would require:
    // 1. Setting up proxy with custom transformation hooks
    // 2. Implementing request/response buffering
    // 3. Handling streaming responses (Server-Sent Events)
    // 4. Adding proper error handling and validation
    // 5. Supporting all OpenAI API parameters

    log.info("To use this in production:", .{});
    log.info("  1. Configure Prozy with transformation policies", .{});
    log.info("  2. Set up route matching for /v1/responses", .{});
    log.info("  3. Add request transformation hook", .{});
    log.info("  4. Add response transformation hook", .{});
    log.info("  5. Configure backend to point to api.openai.com", .{});
    log.info("", .{});

    // Demonstrate how this would integrate with Prozy's routing system
    log.info("Example Prozy configuration (JSON):", .{});
    const example_config =
        \\{
        \\  "proxy": {
        \\    "listen_host": "0.0.0.0",
        \\    "listen_port": 8080
        \\  },
        \\  "clusters": [{
        \\    "name": "openai_backend",
        \\    "backends": [{
        \\      "host": "api.openai.com",
        \\      "port": 443,
        \\      "weight": 1
        \\    }],
        \\    "strategy": "round_robin"
        \\  }],
        \\  "routes": [{
        \\    "name": "responses_api_translation",
        \\    "match": {
        \\      "path_prefix": "/v1/responses"
        \\    },
        \\    "cluster": "openai_backend",
        \\    "cache_policy": {
        \\      "allow": false
        \\    },
        \\    "timeout_policy": {
        \\      "connect_timeout_ms": 10000,
        \\      "request_timeout_ms": 60000,
        \\      "response_timeout_ms": 120000
        \\    }
        \\  }]
        \\}
    ;
    log.info("{s}", .{example_config});
    log.info("", .{});

    log.info("Note: Full proxy implementation with transformation requires:", .{});
    log.info("  • Request buffering (to transform before forwarding)", .{});
    log.info("  • Response buffering (to transform before returning)", .{});
    log.info("  • Memory management (arena allocators for each request)", .{});
    log.info("  • Error recovery (fallback on transformation failure)", .{});
    log.info("  • Streaming support (for SSE responses)", .{});
    log.info("", .{});

    log.info("This example demonstrates the transformation logic.", .{});
    log.info("Integration with Prozy's proxy engine is a future enhancement.", .{});
}

test "Request transformation" {
    const allocator = std.testing.allocator;

    const request_json =
        \\{
        \\  "model": "gpt-4",
        \\  "input": "Hello, world!",
        \\  "temperature": 0.5
        \\}
    ;

    const transformed = try transformRequest(allocator, request_json);
    defer allocator.free(transformed);

    // Verify transformation produced valid JSON
    const parsed = try std.json.parseFromSlice(
        ChatCompletionsRequest,
        allocator,
        transformed,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("gpt-4", parsed.value.model);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.messages.len);
    try std.testing.expectEqualStrings("user", parsed.value.messages[0].role);
    try std.testing.expectEqualStrings("Hello, world!", parsed.value.messages[0].content);
    try std.testing.expectEqual(@as(f32, 0.5), parsed.value.temperature.?);
}

test "Response transformation" {
    const allocator = std.testing.allocator;

    const response_json =
        \\{
        \\  "id": "test-123",
        \\  "object": "chat.completion",
        \\  "created": 1234567890,
        \\  "model": "gpt-4",
        \\  "choices": [{
        \\    "index": 0,
        \\    "message": {
        \\      "role": "assistant",
        \\      "content": "Test response"
        \\    }
        \\  }]
        \\}
    ;

    const transformed = try transformResponse(allocator, response_json);
    defer allocator.free(transformed);

    // Verify transformation produced valid JSON
    const parsed = try std.json.parseFromSlice(
        ResponsesAPIResponse,
        allocator,
        transformed,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test-123", parsed.value.id);
    try std.testing.expectEqualStrings("response", parsed.value.object);
    try std.testing.expectEqual(@as(i64, 1234567890), parsed.value.created);
    try std.testing.expectEqualStrings("gpt-4", parsed.value.model);
    try std.testing.expectEqualStrings("Test response", parsed.value.output);
}

test "Empty choices handling" {
    const allocator = std.testing.allocator;

    const response_json =
        \\{
        \\  "id": "test-456",
        \\  "object": "chat.completion",
        \\  "created": 1234567890,
        \\  "model": "gpt-4",
        \\  "choices": []
        \\}
    ;

    const transformed = try transformResponse(allocator, response_json);
    defer allocator.free(transformed);

    const parsed = try std.json.parseFromSlice(
        ResponsesAPIResponse,
        allocator,
        transformed,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("", parsed.value.output);
}
