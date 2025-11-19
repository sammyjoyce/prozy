const std = @import("std");
const config = @import("config.zig");
const json = std.json;
const http = std.http;

// --- Canonical Data Structures ---
pub const Message = struct { role: []const u8, content: []const u8 };
pub const CanonicalRequest = struct {
    model: []const u8,
    messages: []Message,
    stream: bool = false,
    pub fn deinit(self: CanonicalRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.model);
        for (self.messages) |msg| { allocator.free(msg.role); allocator.free(msg.content); }
        allocator.free(@ptrCast([*]Message, self.messages.ptr)[0..self.messages.len]);
    }
};
pub const CanonicalStreamChunk = struct { delta: []const u8 };

// --- API Schema & Translation Framework ---
pub const ApiSchema = enum { OpenAI, Anthropic, Unknown };
pub const Decoder = struct {
    vtable: *const VTable, context: anyopaque,
    pub const VTable = struct {
        decode: *const fn(c: anyopaque, a: std.mem.Allocator, b: []const u8) !CanonicalRequest,
        deinit: *const fn(c: anyopaque, a: std.mem.Allocator) void,
    };
    pub fn decode(self: Self, a: std.mem.Allocator, b: []const u8) !CanonicalRequest { return self.vtable.decode(self.context, a, b); }
    pub fn deinit(self: Self, a: std.mem.Allocator) void { self.vtable.deinit(self.context, a); }
};
pub const Encoder = struct {
    vtable: *const VTable, context: anyopaque,
    pub const VTable = struct {
        encode_request: *const fn(c: anyopaque, a: std.mem.Allocator, r: CanonicalRequest) ![]const u8,
        encode_chunk: *const fn(c: anyopaque, a: std.mem.Allocator, chunk: CanonicalStreamChunk) ![]const u8,
        deinit: *const fn(c: anyopaque, a: std.mem.Allocator) void,
    };
    pub fn encode_request(self: Self, a: std.mem.Allocator, r: CanonicalRequest) ![]const u8 { return self.vtable.encode_request(self.context, a, r); }
    pub fn encode_chunk(self: Self, a: std.mem.Allocator, c: CanonicalStreamChunk) ![]const u8 { return self.vtable.encode_chunk(self.context, a, c); }
    pub fn deinit(self: Self, a: std.mem.Allocator) void { self.vtable.deinit(self.context, a); }
};

// --- Translation Engine ---
pub const TranslationEngine = struct {
    allocator: std.mem.Allocator,
    config: *const config.Config,
    openai_decoder: Decoder,
    anthropic_decoder: Decoder,
    openai_encoder: Encoder,
    anthropic_encoder: Encoder,
    http_client: http.Client,

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config) !TranslationEngine {
        return .{
            .allocator = allocator, .config = cfg,
            .openai_decoder = try OpenAiDecoder.init(allocator),
            .anthropic_decoder = try AnthropicDecoder.init(allocator),
            .openai_encoder = try OpenAiEncoder.init(allocator),
            .anthropic_encoder = try AnthropicEncoder.init(allocator),
            .http_client = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *TranslationEngine) void {
        self.openai_decoder.deinit(self.allocator);
        self.anthropic_decoder.deinit(self.allocator);
        self.openai_encoder.deinit(self.allocator);
        self.anthropic_encoder.deinit(self.allocator);
        self.http_client.deinit();
    }

    pub fn translate_stream(self: *TranslationEngine, body: []const u8, writer: anytype) !void {
        const inbound_schema = self.fingerprint(body);
        var request = self.decodeRequest(inbound_schema, body) catch |err| {
            std.log.err("Failed to decode request: {any}", .{err});
            return err;
        };
        defer request.deinit(self.allocator);

        const backend = self.resolveBackend(request.model) catch |err| {
            std.log.err("No backend for model '{s}': {any}", .{request.model, err});
            return err;
        };

        var translator = StreamingTranslator.init(self, inbound_schema, writer);
        try self.proxy_stream(backend, request, &translator);
    }

    fn decodeRequest(self: *TranslationEngine, schema: ApiSchema, body: []const u8) !CanonicalRequest {
        return switch (schema) {
            .OpenAI => self.openai_decoder.decode(self.allocator, body),
            .Anthropic => self.anthropic_decoder.decode(self.allocator, body),
            else => error.UnsupportedSchema,
        };
    }

    fn resolveBackend(self: *const TranslationEngine, model: []const u8) !config.BackendProvider {
        for (self.config.routing_table) |route| {
            if (std.mem.eql(u8, route.inbound_model, model)) {
                for (self.config.providers) |provider| {
                    if (std.mem.eql(u8, provider.name, route.backend_provider)) {
                        return provider;
                    }
                }
            }
        }
        return error.NoBackendFound;
    }

    fn proxy_stream(self: *TranslationEngine, backend: config.BackendProvider, request: CanonicalRequest, translator: *StreamingTranslator) !void {
        const uri = try std.Uri.parse(backend.api_url);
        var req = try self.http_client.open(.POST, uri, .{});
        defer req.deinit();

        try req.headers.append("Authorization", try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{backend.api_key}));
        try req.headers.append("Content-Type", "application/json");

        const backend_schema = self.fingerprint(backend.api_url);
        const encoder = switch (backend_schema) {
            .OpenAI => self.openai_encoder,
            .Anthropic => self.anthropic_encoder,
            else => return error.UnsupportedSchema,
        };

        const request_body = try encoder.encode_request(self.allocator, request);
        defer self.allocator.free(request_body);

        try req.write(request_body);
        try req.send(.{});
        try req.wait();

        var buffer: [1024]u8 = undefined;
        while (try req.read(&buffer)) |chunk| {
            try translator.translateAndWrite(chunk);
        }
    }

    fn fingerprint(self: *TranslationEngine, body: []const u8) ApiSchema {
        if (std.mem.indexOf(u8, body, "anthropic")) |_| return .Anthropic;
        if (std.mem.indexOf(u8, body, "openai")) |_| return .OpenAI;

        var stream = json.TokenStream.init(body);
        var has_messages, has_system = false, false;
        while (stream.next() catch null) |token| {
            if (token == .String) {
                if (std.mem.eql(u8, stream.slice, "messages")) has_messages = true;
                if (std.mem.eql(u8, stream.slice, "system")) has_system = true;
            }
        }
        if (has_system and has_messages) return .Anthropic;
        if (has_messages) return .OpenAI;
        return .Unknown;
    }
};

// --- Streaming Translator & SSE Parser ---

const SseParser = struct {
    buffer: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator) SseParser {
        return .{ .buffer = std.ArrayList(u8).init(allocator) };
    }

    fn deinit(self: *SseParser) void {
        self.buffer.deinit();
    }

    fn parse(self: *SseParser, chunk: []const u8, events: *std.ArrayList([]const u8)) !void {
        try self.buffer.appendSlice(chunk);

        while (std.mem.indexOf(u8, self.buffer.items, "\n\n")) |idx| {
            const event = self.buffer.items[0..idx];
            try events.append(try self.buffer.allocator.dupe(u8, event));
            self.buffer.replaceRange(0, idx + 2, &.{});
        }
    }
};

const StreamingTranslator = struct {
    engine: *TranslationEngine,
    inbound_schema: ApiSchema,
    writer: anytype,
    sse_parser: SseParser,

    fn init(engine: *TranslationEngine, schema: ApiSchema, writer: anytype) StreamingTranslator {
        return .{
            .engine = engine, .inbound_schema = schema, .writer = writer,
            .sse_parser = SseParser.init(engine.allocator),
        };
    }

    fn deinit(self: *StreamingTranslator) void {
        self.sse_parser.deinit();
    }

    fn translateAndWrite(self: *StreamingTranslator, chunk: []const u8) !void {
        var events = std.ArrayList([]const u8).init(self.engine.allocator);
        defer {
            for (events.items) |e| self.engine.allocator.free(e);
            events.deinit();
        }

        try self.sse_parser.parse(chunk, &events);

        for (events.items) |event| {
            if (std.mem.indexOf(u8, event, "\"delta\":{\"content\":\"")) |idx| {
                const start = idx + 20;
                if (std.mem.indexOf(u8, event[start..], "\"")) |end_idx| {
                    const delta = event[start..][0..end_idx];
                    const canonical_chunk = CanonicalStreamChunk{ .delta = delta };

                    const encoder = switch (self.inbound_schema) {
                        .OpenAI => self.engine.openai_encoder,
                        .Anthropic => self.engine.anthropic_encoder,
                        else => continue,
                    };

                    const encoded_chunk = try encoder.encode_chunk(self.engine.allocator, canonical_chunk);
                    defer self.engine.allocator.free(encoded_chunk);

                    try self.writer.writeAll(encoded_chunk);
                }
            }
        }
    }
};

// --- Encoders / Decoders (remain the same) ---
pub const OpenAiEncoder = struct {
    pub fn init(a: std.mem.Allocator) !Encoder { return .{ .vtable = &v, .context = try a.create(OpenAiEncoder) }; }
    const v = Encoder.VTable{ .encode_request = er, .encode_chunk = ec, .deinit = x };
    static fn er(c: anyopaque, a: std.mem.Allocator, r: CanonicalRequest) ![]const u8 {
        _ = c;
        var body = std.ArrayList(u8).init(a);
        var jw = json.Writer(std.io.Writer(body, .{}), .{});
        try jw.write(.{ .model = r.model, .messages = r.messages, .stream = r.stream });
        return body.toOwnedSlice();
    }
    static fn ec(c: anyopaque, a: std.mem.Allocator, chunk: CanonicalStreamChunk) ![]const u8 {
        _ = c;
        return std.fmt.allocPrint(a, "data: {{\"choices\":[{{\"delta\":{{\"content\":\"{s}\"}}}}],\"model\":\"prozy-translator\"}}\n\n", .{chunk.delta});
    }
    static fn x(c: anyopaque, a: std.mem.Allocator) void { a.destroy(@ptrCast(*OpenAiEncoder, @alignCast(@alignOf(OpenAiEncoder), c))); }
};

pub const AnthropicEncoder = struct {
    pub fn init(a: std.mem.Allocator) !Encoder { return .{ .vtable = &v, .context = try a.create(AnthropicEncoder) }; }
    const v = Encoder.VTable{ .encode_request = er, .encode_chunk = ec, .deinit = x };
    static fn er(c: anyopaque, a: std.mem.Allocator, r: CanonicalRequest) ![]const u8 {
        _ = c;
        var body = std.ArrayList(u8).init(a);
        var jw = json.Writer(std.io.Writer(body, .{}), .{});
        try jw.write(.{ .model = r.model, .messages = r.messages, .stream = r.stream });
        return body.toOwnedSlice();
    }
    static fn ec(c: anyopaque, a: std.mem.Allocator, chunk: CanonicalStreamChunk) ![]const u8 {
        _ = c;
        return std.fmt.allocPrint(a, "data: {{\"type\":\"content_block_delta\",\"delta\":{{\"type\":\"text_delta\",\"text\":\"{s}\"}}}}\n\n", .{chunk.delta});
    }
    static fn x(c: anyopaque, a: std.mem.Allocator) void { a.destroy(@ptrCast(*AnthropicEncoder, @alignCast(@alignOf(AnthropicEncoder), c))); }
};

const OpenAiChatRequest = struct { model: []const u8, messages: []Message, stream: bool = false };
pub const OpenAiDecoder = struct {
    pub fn init(a: std.mem.Allocator) !Decoder { return .{ .vtable = &v, .context = try a.create(OpenAiDecoder) }; }
    const v = Decoder.VTable{ .decode = d, .deinit = x };
    fn d(c: anyopaque, a: std.mem.Allocator, b: []const u8) !CanonicalRequest {
        _ = c;
        const p = try json.parseFromSlice(OpenAiChatRequest, a, b, .{});
        defer json.parseFree(OpenAiChatRequest, p, a);
        var m = try a.alloc(Message, p.messages.len);
        for (p.messages, 0..) |msg, i| m[i] = .{ .role = try a.dupe(u8, msg.role), .content = try a.dupe(u8, msg.content) };
        return .{ .model = try a.dupe(u8, p.model), .messages = m, .stream = p.stream };
    }
    fn x(c: anyopaque, a: std.mem.Allocator) void { a.destroy(@ptrCast(*OpenAiDecoder, @alignCast(@alignOf(OpenAiDecoder), c))); }
};

const AnthropicChatRequest = struct { model: []const u8, system: ?[]const u8 = null, messages: []Message, stream: bool = false };
pub const AnthropicDecoder = struct {
    pub fn init(a: std.mem.Allocator) !Decoder { return .{ .vtable = &v, .context = try a.create(AnthropicDecoder) }; }
    const v = Decoder.VTable{ .decode = d, .deinit = x };
    fn d(c: anyopaque, a: std.mem.Allocator, b: []const u8) !CanonicalRequest {
        _ = c;
        const p = try json.parseFromSlice(AnthropicChatRequest, a, b, .{});
        defer json.parseFree(AnthropicChatRequest, p, a);
        const h = p.system != null;
        var m = try a.alloc(Message, p.messages.len + @boolToInt(h));
        var i: usize = 0;
        if (p.system) |s| { m[0] = .{ .role = try a.dupe(u8, "system"), .content = try a.dupe(u8, s) }; i += 1; }
        for (p.messages) |msg| { m[i] = .{ .role = try a.dupe(u8, msg.role), .content = try a.dupe(u8, msg.content) }; i += 1; }
        return .{ .model = try a.dupe(u8, p.model), .messages = m, .stream = p.stream };
    }
    fn x(c: anyopaque, a: std.mem.Allocator) void { a.destroy(@ptrCast(*AnthropicDecoder, @alignCast(@alignOf(AnthropicDecoder), c))); }
};
