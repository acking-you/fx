const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const responses_protocol = @import("responses_protocol.zig");
const responses_compaction_binding = @import("../core/gateway/responses_compaction_binding.zig");
const responses_compaction_provider = @import("../core/gateway/responses_compaction_provider.zig");
const responses_request_protocol = @import("../core/gateway/responses_protocol.zig");
const responses_search = @import("../core/gateway/responses_search.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const provider_route = @import("../core/gateway/provider_route.zig");

const Allocator = std.mem.Allocator;
const e2e_endpoint_env = "FX_E2E_OPENAI_CODEX_RESPONSES_URL";

pub const agent_stream_provider = stream_provider.Provider{
    .stream_fn = streamCompletion,
};

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 1024) return error.InvalidOpenAICodexModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenAICodexModel;
    }
}

pub fn buildRequest(
    alloc: Allocator,
    request: stream_provider.RequestData,
) ![]u8 {
    return buildRequestBound(alloc, request, null, null);
}

fn buildRequestBound(
    alloc: Allocator,
    request: stream_provider.RequestData,
    session_id: ?[]const u8,
    binding: ?types.ResponsesCompactionProviderBindingView,
) ![]u8 {
    const route: provider_route.ProviderRoute = .codex_responses_oauth;
    const wire_model = provider_route.wireModel(route, request.model);
    try validateModel(wire_model);

    var tools = try responses_request_protocol.prepareTools(alloc, request.tools);
    defer tools.deinit(alloc);
    const projected_tools = try responses_search.projectNamespaceToolAlloc(
        alloc,
        tools.base_json,
        .{ .include_web_search = containsAdvertisedTool(request.tools, "web_search") },
    );
    defer alloc.free(projected_tools);

    var schema_json: ?[]u8 = null;
    defer if (schema_json) |schema| alloc.free(schema);
    const response_format: ?responses_compaction_provider.StructuredResponseFormat = if (request.response_format) |format| blk: {
        var encoded: std.Io.Writer.Allocating = .init(alloc);
        errdefer encoded.deinit();
        try std.json.Stringify.value(format.schema, .{}, &encoded.writer);
        schema_json = try encoded.toOwnedSlice();
        break :blk .{
            .name = format.name,
            .description = format.description,
            .schema_json = schema_json.?,
        };
    } else null;

    var provider_options = request.provider_options;
    if (provider_options.reasoning) |effort| {
        if (std.mem.eql(u8, effort.label(), "minimal")) {
            provider_options.reasoning = types.ReasoningEffort.literal("low");
        }
    }
    if (provider_options.parallel_tool_calls == null) {
        provider_options.parallel_tool_calls = true;
    }
    return responses_request_protocol.buildRequest(alloc, .{
        .credential_source = .chatgpt_subscription,
        .session_id = session_id,
        .model = wire_model,
        .tool_registry = request.tools.registry,
        .serialized_tools = projected_tools,
        .selected_dynamic_tool_schemas = tools.dynamic_json,
        .messages = request.messages,
        .tool_choice = request.tool_choice,
        .vision_mode = request.vision_mode,
        .provider_options = provider_options,
        .budget = request.budget,
        .verified_images = request.verified_images,
        .response_format = response_format,
        .responses_text_options_json = "{\"verbosity\":\"low\"}",
        .responses_compaction_binding = binding,
    }, .{
        .capabilities = .{
            .supports_max_output_tokens = route.contract().supports_max_output_tokens,
        },
        .prompt_cache_key = session_id,
        .service_tier = if (provider_options.fast) "priority" else null,
        .reasoning_summary = "auto",
        .function_tools_strict = false,
    });
}

fn containsAdvertisedTool(tools: stream_provider.ToolSelection, name: []const u8) bool {
    for (tools.advertised_names) |advertised| {
        if (std.mem.eql(u8, advertised, name)) return true;
    }
    return false;
}

fn buildBoundProviderIdentity(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !types.ResponsesCompactionProviderBinding {
    var options = responses_compaction_binding.BuildOptions.fromEnvironment();
    if (io_mod.getenv(e2e_endpoint_env)) |override| {
        if (!gateway_client.isLoopbackUrl(override)) {
            return error.InvalidE2EOpenAICodexEndpoint;
        }
        options.endpoint_overrides.codex_base_url = override;
    }
    return responses_compaction_binding.buildAlloc(
        alloc,
        .chatgpt_subscription,
        request.credential.secret,
        request.credential.account_id,
        options,
    );
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential.source != .chatgpt_subscription) {
        return error.CodexSubscriptionCredentialRequired;
    }
    try validateModel(request.model);
    var binding = try buildBoundProviderIdentity(alloc, request);
    defer types.freeResponsesCompactionProviderBinding(alloc, binding);
    const payload = buildRequestBound(
        alloc,
        request.data(),
        request.session_id,
        binding.view(),
    ) catch |err| return err;
    defer alloc.free(payload);
    return streamPreparedWithBinding(
        alloc,
        request,
        payload,
        binding.view(),
        provider_route.wireModel(.codex_responses_oauth, request.model),
    ) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
}

pub fn streamPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) !stream_provider.Result {
    if (request.credential.source != .chatgpt_subscription) {
        return error.CodexSubscriptionCredentialRequired;
    }
    var binding = try buildBoundProviderIdentity(alloc, request);
    defer types.freeResponsesCompactionProviderBinding(alloc, binding);
    return streamPreparedWithBinding(
        alloc,
        request,
        payload,
        binding.view(),
        provider_route.wireModel(.codex_responses_oauth, request.model),
    );
}

fn streamPreparedWithBinding(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
    binding: types.ResponsesCompactionProviderBindingView,
    wire_model: []const u8,
) !stream_provider.Result {
    var events = request.events;
    var result = try gateway_client.streamGatewayCompletion(
        alloc,
        .{
            .api_key = request.credential.secret,
            .credential_source = .chatgpt_subscription,
            .responses_compaction_binding = binding,
            .model = wire_model,
            .retry_count = request.retry_count,
            .chat_url = binding.normalized_origin,
            .payload = payload,
            .session_id = request.session_id,
            .trace_ctx = request.trace_ctx,
            .content_capture_limit = request.content_capture_limit,
            .delivery = request.delivery,
            .admission = request.admission,
            .on_reasoning_chunk = EventBridge.reasoning,
            .on_tool_input_chunk = EventBridge.toolInput,
            .provider_attempt_owner = switch (request.provider_attempt_owner) {
                .transport => .transport,
                .agent => .agent,
            },
        },
        &events,
        EventBridge.content,
        EventBridge.toolStart,
        request.cancel_flag,
    );
    defer result.deinit(alloc);
    if (result.status != .ok) {
        const detail = result.err_body;
        result.err_body = null;
        return .{ .failed = .{
            .kind = failureKind(result.status),
            .detail = detail,
            .retry_after_seconds = result.retry_after_seconds,
            .ownership = .owned,
        } };
    }
    var completion = result.completion;
    result.completion = .{};
    errdefer {
        var owned = stream_provider.Result{ .completed = .{
            .completion = completion,
            .ownership = .owned,
        } };
        owned.deinit(alloc);
    }
    const usage_outcome: stream_provider.UsageOutcome = usage: {
        if (completion.generation_id == null) {
            break :usage .{ .unavailable = .possibly_billed };
        }
        completion.billing = try responses_protocol.buildSubscriptionBilling(
            alloc,
            .codex,
            request.model,
            @max(io_mod.milliTimestamp(), 0),
            completion.usage,
        ) orelse break :usage .{ .unavailable = .possibly_billed };
        break :usage .{ .exact = .codex };
    };
    return .{ .completed = .{
        .completion = completion,
        .usage = usage_outcome,
        .ownership = .owned,
    } };
}

const EventBridge = struct {
    fn sink(raw: *anyopaque) *stream_provider.EventSink {
        return @ptrCast(@alignCast(raw));
    }

    fn content(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .content_delta = chunk });
    }

    fn reasoning(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .reasoning_delta = chunk });
    }

    fn toolInput(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .tool_input_delta = chunk });
    }

    fn toolStart(raw: *anyopaque, id: []const u8, name: []const u8, label: ?[]const u8) void {
        sink(raw).emit(.{ .tool_started = .{ .id = id, .name = name, .label = label } });
    }
};

fn failureKind(status: std.http.Status) stream_provider.FailureKind {
    return switch (status) {
        .bad_request => .invalid_request,
        .unauthorized => .unauthorized,
        .forbidden => .forbidden,
        .payload_too_large => .request_too_large,
        .too_many_requests => .rate_limited,
        .internal_server_error => .server_error,
        .bad_gateway => .bad_gateway,
        .service_unavailable => .unavailable,
        .gateway_timeout => .gateway_timeout,
        else => .provider_error,
    };
}

test "OpenAI Codex request uses Responses input and converts AI SDK tool schemas" {
    const read_file_schema = model_tool_schema.FunctionSchema{
        .name = "read_file",
        .description = "Read",
        .input_schema = .{},
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Be concise." },
        .{ .role = .user, .content = "Read it." },
        .{
            .role = .assistant,
            .tool_calls = &.{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }},
            .provider_state_json = "[{\"id\":\"rs_1\",\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}]",
        },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
    };
    const body = try buildRequest(std.testing.allocator, .{
        .model = "gpt-5.4",
        .messages = &messages,
        .tools = .{ .additional_functions = &.{read_file_schema} },
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high"), .fast = true },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"gpt-5.4\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"instructions\":\"Be concise.\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"encrypted_content\":\"opaque\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\":{\"type\":\"object\",\"properties\":{}}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning\":{\"effort\":\"high\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"service_tier\":\"priority\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_output_tokens\"") == null);
}

test "OpenAI Codex standard requests omit the priority service tier" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hello." }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "gpt-5.6-sol",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"service_tier\"") == null);
}

test "OpenAI Codex projects local web search to the reserved namespace" {
    const web_search_schema = model_tool_schema.FunctionSchema{
        .name = "web_search",
        .description = "Search",
        .input_schema = .{},
    };
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Search for Zig." }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "gpt-5.6-sol",
        .messages = &messages,
        .tools = .{ .additional_functions = &.{web_search_schema} },
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"namespace\",\"name\":\"web\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"web_search\"") == null);
}

test "OpenAI Codex appends the reserved namespace for provider-executed search projection" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Search for Zig." }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "gpt-5.6-sol",
        .messages = &messages,
        .tools = .{ .advertised_names = &.{"web_search"} },
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"namespace\",\"name\":\"web\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"web_search\"") == null);
}

test "OpenAI Codex serializes each verified image directly once" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Describe it." }};
    const images = [_]image_attachments.VerifiedSnapshot{.{
        .bytes = @constCast(&[_]u8{ 1, 2, 3, 4 }),
        .media_type = "image/png",
    }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "gpt-5.6-sol",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
        .verified_images = &images,
    });
    defer std.testing.allocator.free(body);

    const marker = "\"type\":\"input_image\"";
    const first = std.mem.find(u8, body, marker) orelse return error.TestExpectedImage;
    try std.testing.expect(std.mem.findPos(u8, body, first + marker.len, marker) == null);
    try std.testing.expect(std.mem.find(u8, body, "data:image/png;base64,AQIDBA==") != null);
}

test "OpenAI Codex rejects a wrong-origin credential before network I/O" {
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var callback_context: u8 = 0;
    try std.testing.expectError(
        error.CodexSubscriptionCredentialRequired,
        agent_stream_provider.stream(std.testing.allocator, .{
            .credential = .{ .secret = "gateway-key", .source = .openai_api_key },
            .model = "gpt-5.6-sol",
            .retry_count = 1,
            .messages = &.{},
            .tool_choice = .none,
            .provider_options = .{},
            .trace_ctx = .{},
            .content_capture_limit = null,
            .delivery = &delivery,
            .attempt_evidence = &evidence,
            .events = .{ .context = &callback_context, .emit_fn = struct {
                fn ignore(_: *anyopaque, _: stream_provider.Event) void {}
            }.ignore },
            .cancel_flag = &cancelled,
        }),
    );
    try std.testing.expectEqual(stream_provider.DeliveryCertainty.State.definitely_unsent, delivery.load());
}
