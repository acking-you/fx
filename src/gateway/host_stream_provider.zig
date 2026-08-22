const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const provider_route = @import("../core/gateway/provider_route.zig");
const secret = @import("../core/auth/secret.zig");
const io_mod = @import("../core/shared/io.zig");
const gateway_client = @import("client.zig");
const responses_stream = @import("responses_stream.zig");

const Allocator = std.mem.Allocator;
const max_error_body_bytes = 1024 * 1024;
const cooperative_pulse_interval_ms = 50;

pub const Transport = struct {
    context: ?*anyopaque,
    open_fn: *const fn (?*anyopaque, []const u8, []const u8, []const u8, []const u8) anyerror!i32,
    status_fn: *const fn (?*anyopaque, i32, *u16) i32,
    next_fn: *const fn (?*anyopaque, i32, []u8) i32,
    close_fn: *const fn (?*anyopaque, i32) void,

    pub fn open(self: Transport, method: []const u8, url: []const u8, headers: []const u8, body: []const u8) !i32 {
        return self.open_fn(self.context, method, url, headers, body);
    }

    pub fn status(self: Transport, handle: i32, status_out: *u16) i32 {
        return self.status_fn(self.context, handle, status_out);
    }

    pub fn next(self: Transport, handle: i32, out: []u8) i32 {
        return self.next_fn(self.context, handle, out);
    }

    pub fn close(self: Transport, handle: i32) void {
        self.close_fn(self.context, handle);
    }
};

pub const ProviderContext = struct {
    build_fn: stream_provider.BuildFn,
    transport: Transport,
    endpoint_overrides: ?provider_route.EndpointOverrides = null,
};

pub fn provider(context: *ProviderContext) stream_provider.Provider {
    return .{
        .context = context,
        .build_fn = build,
        .stream_fn = stream,
    };
}

pub fn initContext(build_fn: stream_provider.BuildFn, transport: Transport) ProviderContext {
    return .{ .build_fn = build_fn, .transport = transport };
}

fn build(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.BuildRequest) anyerror![]u8 {
    const context: *ProviderContext = @ptrCast(@alignCast(raw.?));
    return context.build_fn(null, alloc, request);
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.Request) anyerror!stream_provider.Result {
    const context: *ProviderContext = @ptrCast(@alignCast(raw.?));
    const transport = context.transport;
    const route = if (request.credential_source) |source|
        provider_route.fromCredentialSource(source) orelse return error.UnsupportedCredentialSource
    else
        provider_route.ProviderRoute.vercel_gateway;
    // Codex OAuth credentials are paired with account identity in the native
    // auth store. The JavaScript host has no such store, so it must reject the
    // route before serializing the bearer token or opening a network request.
    if (route == .codex_responses_oauth) return error.CodexCredentialUnavailable;

    var owned_url: ?[]u8 = null;
    defer if (owned_url) |url| alloc.free(url);
    const request_url = if (route.contract().wire_api == .openai_responses) blk: {
        owned_url = try provider_route.resolveEndpointAlloc(
            alloc,
            route,
            context.endpoint_overrides orelse provider_route.EndpointOverrides.fromEnvironment(),
        );
        break :blk owned_url.?;
    } else request.chat_url;

    const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer secret.zeroAndFree(alloc, auth);

    const Header = struct { name: []const u8, value: []const u8 };
    var headers: std.ArrayList(Header) = .empty;
    defer headers.deinit(alloc);
    try headers.appendSlice(alloc, &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "authorization", .value = auth },
    });
    switch (route) {
        .vercel_gateway => {
            try headers.appendSlice(alloc, &.{
                .{ .name = "HTTP-Referer", .value = "https://github.com/vercel-labs/fx" },
                .{ .name = "X-Title", .value = "fx" },
                .{ .name = "ai-gateway-protocol-version", .value = "0.0.1" },
                .{ .name = "ai-language-model-specification-version", .value = "4" },
                .{ .name = "ai-language-model-id", .value = request.model },
                .{ .name = "ai-language-model-streaming", .value = "true" },
            });
            if (request.team) |team| if (team.len > 0) try headers.append(alloc, .{ .name = "x-vercel-ai-gateway-team", .value = team });
            if (request.session_id) |session_id| if (session_id.len > 0) try headers.appendSlice(alloc, &.{
                .{ .name = "x-session-id", .value = session_id },
                .{ .name = "x-session-affinity", .value = session_id },
            });
        },
        .openai_responses_byok => {
            try headers.append(alloc, .{ .name = "accept", .value = "text/event-stream" });
            if (io_mod.getenv("OPENAI_ORG_ID")) |organization| {
                if (organization.len > 0) try headers.append(alloc, .{ .name = "OpenAI-Organization", .value = organization });
            }
            if (io_mod.getenv("OPENAI_PROJECT_ID")) |project| {
                if (project.len > 0) try headers.append(alloc, .{ .name = "OpenAI-Project", .value = project });
            }
        },
        .codex_responses_oauth => unreachable,
    }

    var headers_json: std.Io.Writer.Allocating = .init(alloc);
    defer headers_json.deinit();
    try std.json.Stringify.value(headers.items, .{}, &headers_json.writer);

    request.delivery.markPossiblySent();
    const handle = try transport.open("POST", request_url, headers_json.writer.buffered(), request.payload);
    if (handle < 0) return error.HostStreamFailed;
    defer transport.close(handle);

    var status_code: u16 = 0;
    while (true) {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        const status_result = transport.status(handle, &status_code);
        if (status_result == 1) break;
        if (status_result == -2) return error.Cancelled;
        if (status_result < 0) return error.HostStreamFailed;
        try pulse(request.cooperative_pulse);
    }

    const status: std.http.Status = @enumFromInt(status_code);
    if (status != .ok) {
        const err_body = try readBody(alloc, transport, handle, request.cancel_flag, request.cooperative_pulse);
        errdefer alloc.free(err_body);
        const retry_after_seconds = if (route.contract().wire_api == .openai_responses)
            try gateway_client.responsesRetryAfterFromBody(alloc, status_code, err_body)
        else
            null;
        return .{
            .status = status,
            .err_body = err_body,
            .accounting = if (route.contract().usage == .response_body) .direct_usage else .gateway_generation,
            .retry_after_seconds = retry_after_seconds,
            .ownership = .owned,
        };
    }

    var reader: HostStreamReader = undefined;
    reader.init(transport, handle, request.cancel_flag, request.cooperative_pulse);
    const completion = (switch (route.contract().wire_api) {
        .vercel_ai_gateway => gateway_client.consumeGatewaySseStream(
            alloc,
            &reader.interface,
            request.callback_ctx,
            request.on_content_chunk,
            request.on_tool_start,
            request.on_reasoning_chunk,
            request.cancel_flag,
            request.content_capture_limit,
        ),
        .openai_responses => responses_stream.consume(alloc, &reader.interface, .{
            .context = request.callback_ctx,
            .on_content_chunk = request.on_content_chunk,
            .on_tool_start = request.on_tool_start,
            .on_reasoning_chunk = request.on_reasoning_chunk,
            .on_tool_input_chunk = request.on_tool_input_chunk,
            .on_unknown_event = request.on_unhandled_provider_event,
            .content_capture_limit = request.content_capture_limit,
        }, request.cancel_flag),
    }) catch |err| switch (err) {
        error.ReadFailed => return if (request.cancel_flag.load(.seq_cst) or reader.aborted) error.Cancelled else error.HostStreamFailed,
        else => return err,
    };
    return .{
        .status = .ok,
        .completion = completion,
        .accounting = if (route.contract().usage == .response_body) .direct_usage else .gateway_generation,
        .ownership = .owned,
    };
}

fn pulse(value: ?stream_provider.CooperativePulse) !void {
    if (value) |callback| try callback.pulse();
}

fn readBody(alloc: Allocator, transport: Transport, handle: i32, cancel_flag: *std.atomic.Value(bool), cooperative_pulse: ?stream_provider.CooperativePulse) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        const count = transport.next(handle, &chunk);
        if (count == -3) {
            try pulse(cooperative_pulse);
            continue;
        }
        if (count == -2) return error.Cancelled;
        if (count < 0) return error.HostStreamFailed;
        if (count == 0) break;
        const len: usize = @intCast(count);
        if (len > max_error_body_bytes - out.items.len) return error.HostStreamFailed;
        try out.appendSlice(alloc, chunk[0..len]);
    }
    return out.toOwnedSlice(alloc);
}

const HostStreamReader = struct {
    transport: Transport = undefined,
    handle: i32 = -1,
    cancel_flag: *std.atomic.Value(bool) = undefined,
    cooperative_pulse: ?stream_provider.CooperativePulse = null,
    last_cooperative_pulse: ?std.Io.Clock.Timestamp = null,
    aborted: bool = false,
    buffer: [16 * 1024]u8 = undefined,
    interface: std.Io.Reader = undefined,

    fn init(self: *@This(), transport: Transport, handle: i32, cancel_flag: *std.atomic.Value(bool), cooperative_pulse: ?stream_provider.CooperativePulse) void {
        self.* = .{
            .transport = transport,
            .handle = handle,
            .cancel_flag = cancel_flag,
            .cooperative_pulse = cooperative_pulse,
            .last_cooperative_pulse = if (cooperative_pulse != null)
                std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)
            else
                null,
        };
        self.interface = .{ .vtable = &.{ .stream = streamReader, .readVec = readVec }, .buffer = &self.buffer, .seek = 0, .end = 0 };
    }

    fn readVec(reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *@This() = @alignCast(@fieldParentPtr("interface", reader));
        if (self.cancel_flag.load(.seq_cst)) return self.abortRead();
        for (data) |dest| if (dest.len > 0) return self.readHost(dest);
        const dest = reader.buffer[reader.end..];
        if (dest.len == 0) return 0;
        const count = try self.readHost(dest);
        reader.end += count;
        return 0;
    }

    fn abortRead(self: *@This()) std.Io.Reader.Error {
        self.aborted = true;
        return error.ReadFailed;
    }

    fn pulseAt(self: *@This(), now: std.Io.Clock.Timestamp) !void {
        if (self.cooperative_pulse == null) return;
        self.last_cooperative_pulse = now;
        try pulse(self.cooperative_pulse);
    }

    fn pulseIfDueAt(self: *@This(), now: std.Io.Clock.Timestamp) !void {
        if (self.cooperative_pulse == null) return;
        const last_pulse = self.last_cooperative_pulse orelse return;
        const elapsed_ms = last_pulse.durationTo(now).raw.toMilliseconds();
        if (elapsed_ms < cooperative_pulse_interval_ms) return;
        try self.pulseAt(now);
    }

    fn readHost(self: *@This(), dest: []u8) std.Io.Reader.Error!usize {
        while (true) {
            if (self.cancel_flag.load(.seq_cst)) return self.abortRead();
            if (self.cooperative_pulse != null) {
                self.pulseIfDueAt(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)) catch return error.ReadFailed;
            }
            if (self.cancel_flag.load(.seq_cst)) return self.abortRead();
            const count = self.transport.next(self.handle, dest);
            if (count == -3) {
                if (self.cooperative_pulse != null) {
                    self.pulseAt(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)) catch return error.ReadFailed;
                }
                continue;
            }
            if (count == -2) return self.abortRead();
            if (count < 0) return error.ReadFailed;
            if (count == 0) return error.EndOfStream;
            return @intCast(count);
        }
    }

    fn streamReader(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try writer.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const count = readVec(reader, &data) catch |err| return err;
        writer.advance(count);
        return count;
    }
};

test "error response bodies are bounded" {
    const FakeTransport = struct {
        body: []const u8,
        offset: usize = 0,

        fn open(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8, _: []const u8) anyerror!i32 {
            return 1;
        }

        fn status(_: ?*anyopaque, _: i32, status_out: *u16) i32 {
            status_out.* = 500;
            return 1;
        }

        fn next(raw: ?*anyopaque, _: i32, out: []u8) i32 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const len = @min(out.len, self.body.len - self.offset);
            if (len == 0) return 0;
            @memcpy(out[0..len], self.body[self.offset..][0..len]);
            self.offset += len;
            return @intCast(len);
        }

        fn close(_: ?*anyopaque, _: i32) void {}
    };

    const body = try std.testing.allocator.alloc(u8, max_error_body_bytes + 1);
    defer std.testing.allocator.free(body);
    @memset(body, 'x');
    var fake = FakeTransport{ .body = body };
    const transport = Transport{
        .context = &fake,
        .open_fn = FakeTransport.open,
        .status_fn = FakeTransport.status,
        .next_fn = FakeTransport.next,
        .close_fn = FakeTransport.close,
    };
    var cancel_flag = std.atomic.Value(bool).init(false);

    try std.testing.expectError(
        error.HostStreamFailed,
        readBody(std.testing.allocator, transport, 1, &cancel_flag, null),
    );
}

test "host stream reader omits pulse timing state without callback" {
    const FakeTransport = struct {
        fn open(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8, _: []const u8) anyerror!i32 {
            return 1;
        }

        fn status(_: ?*anyopaque, _: i32, _: *u16) i32 {
            return 1;
        }

        fn next(_: ?*anyopaque, _: i32, _: []u8) i32 {
            return 0;
        }

        fn close(_: ?*anyopaque, _: i32) void {}
    };

    var cancel_flag = std.atomic.Value(bool).init(false);
    var reader: HostStreamReader = undefined;
    reader.init(.{
        .context = null,
        .open_fn = FakeTransport.open,
        .status_fn = FakeTransport.status,
        .next_fn = FakeTransport.next,
        .close_fn = FakeTransport.close,
    }, 1, &cancel_flag, null);

    try std.testing.expect(reader.last_cooperative_pulse == null);
}

test "host stream reader throttles cooperative pulses" {
    const PulseTrace = struct {
        calls: usize = 0,

        fn run(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };
    const awake_timestamp = struct {
        fn at(milliseconds: i64) std.Io.Clock.Timestamp {
            return .{
                .clock = .awake,
                .raw = .fromNanoseconds(@as(i96, milliseconds) * std.time.ns_per_ms),
            };
        }
    }.at;

    var trace: PulseTrace = .{};
    var reader: HostStreamReader = .{
        .cooperative_pulse = .{ .ctx = &trace, .run = PulseTrace.run },
        .last_cooperative_pulse = awake_timestamp(100),
    };

    try reader.pulseIfDueAt(awake_timestamp(149));
    try std.testing.expectEqual(@as(usize, 0), trace.calls);
    try reader.pulseIfDueAt(awake_timestamp(150));
    try std.testing.expectEqual(@as(usize, 1), trace.calls);
    try reader.pulseIfDueAt(awake_timestamp(199));
    try std.testing.expectEqual(@as(usize, 1), trace.calls);
    try reader.pulseIfDueAt(awake_timestamp(200));
    try std.testing.expectEqual(@as(usize, 2), trace.calls);
}

const HostRouteFixture = struct {
    const responses_body =
        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"host direct\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":7,\"output_tokens\":3,\"total_tokens\":10}}}\n\n";

    open_calls: usize = 0,
    status_code: u16 = 200,
    body: []const u8 = responses_body,
    offset: usize = 0,
    url_buf: [1024]u8 = undefined,
    url_len: usize = 0,
    headers_buf: [4096]u8 = undefined,
    headers_len: usize = 0,

    fn transport(self: *@This()) Transport {
        return .{
            .context = self,
            .open_fn = open,
            .status_fn = status,
            .next_fn = next,
            .close_fn = close,
        };
    }

    fn open(raw: ?*anyopaque, _: []const u8, request_url: []const u8, request_headers: []const u8, _: []const u8) anyerror!i32 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.open_calls += 1;
        if (request_url.len > self.url_buf.len or request_headers.len > self.headers_buf.len) return error.TestCaptureTooSmall;
        @memcpy(self.url_buf[0..request_url.len], request_url);
        self.url_len = request_url.len;
        @memcpy(self.headers_buf[0..request_headers.len], request_headers);
        self.headers_len = request_headers.len;
        return 1;
    }

    fn status(raw: ?*anyopaque, _: i32, status_out: *u16) i32 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        status_out.* = self.status_code;
        return 1;
    }

    fn next(raw: ?*anyopaque, _: i32, out: []u8) i32 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const len = @min(out.len, self.body.len - self.offset);
        if (len == 0) return 0;
        @memcpy(out[0..len], self.body[self.offset..][0..len]);
        self.offset += len;
        return @intCast(len);
    }

    fn close(_: ?*anyopaque, _: i32) void {}

    fn url(self: *const @This()) []const u8 {
        return self.url_buf[0..self.url_len];
    }

    fn headers(self: *const @This()) []const u8 {
        return self.headers_buf[0..self.headers_len];
    }
};

fn noopChunk(_: *anyopaque, _: []const u8) void {}

test "OpenAI host route uses scoped endpoint headers Responses decoder and direct usage" {
    var fixture: HostRouteFixture = .{};
    var context = ProviderContext{
        .build_fn = undefined,
        .transport = fixture.transport(),
        .endpoint_overrides = .{ .responses_base_url = "http://127.0.0.1:43123/v1" },
    };
    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var attempt_evidence: stream_provider.AttemptEvidence = .{};
    var callback_context: u8 = 0;
    var result = try stream(&context, std.testing.allocator, .{
        .api_key = "openai-secret",
        .team = "must-not-cross-provider",
        .credential_source = .openai_api_key,
        .session_id = "session-private",
        .model = "gpt-5.4",
        .retry_count = 1,
        .chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model",
        .payload = "{}",
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &attempt_evidence,
        .callback_ctx = &callback_context,
        .on_content_chunk = noopChunk,
        .on_tool_start = null,
        .on_reasoning_chunk = noopChunk,
        .cancel_flag = &cancel_flag,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), fixture.open_calls);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/v1/responses", fixture.url());
    try std.testing.expect(std.mem.find(u8, fixture.headers(), "Bearer openai-secret") != null);
    try std.testing.expect(std.mem.find(u8, fixture.headers(), "text/event-stream") != null);
    try std.testing.expect(std.mem.find(u8, fixture.headers(), "ai-gateway-protocol-version") == null);
    try std.testing.expect(std.mem.find(u8, fixture.headers(), "must-not-cross-provider") == null);
    try std.testing.expect(std.mem.find(u8, fixture.headers(), "session-private") == null);
    try std.testing.expectEqual(stream_provider.AccountingDisposition.direct_usage, result.accounting);
    try std.testing.expectEqualStrings("host direct", result.completion.content.?);
    try std.testing.expectEqual(@as(?u64, 7), result.completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 3), result.completion.usage.output_tokens);
}

test "Codex OAuth host route fails before serializing or sending its credential" {
    var fixture: HostRouteFixture = .{};
    var context = ProviderContext{
        .build_fn = undefined,
        .transport = fixture.transport(),
    };
    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var attempt_evidence: stream_provider.AttemptEvidence = .{};
    var callback_context: u8 = 0;
    try std.testing.expectError(error.CodexCredentialUnavailable, stream(&context, std.testing.allocator, .{
        .api_key = "codex-secret-must-not-leave",
        .team = null,
        .credential_source = .chatgpt_subscription,
        .model = "gpt-5.6-sol",
        .retry_count = 1,
        .chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model",
        .payload = "{}",
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &attempt_evidence,
        .callback_ctx = &callback_context,
        .on_content_chunk = noopChunk,
        .on_tool_start = null,
        .on_reasoning_chunk = noopChunk,
        .cancel_flag = &cancel_flag,
    }));
    try std.testing.expectEqual(@as(usize, 0), fixture.open_calls);
    try std.testing.expectEqual(stream_provider.DeliveryCertainty.State.definitely_unsent, delivery.load());
}

test "OpenAI host error keeps direct accounting and Responses retry metadata" {
    var fixture = HostRouteFixture{
        .status_code = 429,
        .body = "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\",\"retry_after_seconds\":1.25}}",
    };
    var context = ProviderContext{
        .build_fn = undefined,
        .transport = fixture.transport(),
        .endpoint_overrides = .{ .openai_base_url = "https://responses.example.test/v1" },
    };
    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var attempt_evidence: stream_provider.AttemptEvidence = .{};
    var callback_context: u8 = 0;
    var result = try stream(&context, std.testing.allocator, .{
        .api_key = "openai-secret",
        .team = null,
        .credential_source = .openai_api_key,
        .model = "gpt-5.4",
        .retry_count = 1,
        .chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model",
        .payload = "{}",
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &attempt_evidence,
        .callback_ctx = &callback_context,
        .on_content_chunk = noopChunk,
        .on_tool_start = null,
        .on_reasoning_chunk = noopChunk,
        .cancel_flag = &cancel_flag,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.too_many_requests, result.status);
    try std.testing.expectEqual(stream_provider.AccountingDisposition.direct_usage, result.accounting);
    try std.testing.expectEqual(@as(?u64, 2), result.retry_after_seconds);
    try std.testing.expectEqualStrings(fixture.body, result.err_body.?);
}
