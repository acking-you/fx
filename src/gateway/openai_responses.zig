const std = @import("std");

const stream_provider = @import("../core/agent/stream_provider.zig");
const provider_route = @import("../core/gateway/provider_route.zig");
const responses_compaction_binding = @import("../core/gateway/responses_compaction_binding.zig");
const responses_compaction_provider = @import("../core/gateway/responses_compaction_provider.zig");
const responses_compaction = @import("../core/gateway/responses_compaction.zig");
const responses_protocol = @import("../core/gateway/responses_protocol.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const compact_response_max_bytes: usize = 32 * 1024 * 1024;

pub const agent_stream_provider = stream_provider.Provider{
    .stream_fn = streamCompletion,
};

pub const compaction_provider = responses_compaction_provider.Provider{
    .fetch_fn = fetchCompaction,
};

fn fetchCompaction(
    _: ?*anyopaque,
    alloc: Allocator,
    input: responses_compaction_provider.Request,
) !responses_compaction_provider.Outcome {
    const source = input.build_request.credential_source orelse
        return error.UnsupportedCredentialSource;
    const route = provider_route.fromCredentialSource(source) orelse
        return error.UnsupportedCredentialSource;
    if (route.contract().remote_compaction == .unsupported) return .unsupported;
    try responses_compaction_binding.validate(source, input.provider_binding);
    if (!responses_compaction_binding.credentialMatches(
        source,
        input.credential,
        input.account_id,
        input.provider_binding,
    )) return error.ResponsesCompactionIdentityMismatch;

    var request = input.build_request;
    const wire_model = provider_route.wireModel(route, request.model);
    request.model = wire_model;
    request.responses_compaction_binding = input.provider_binding;
    const use_v2_trigger = route.contract().remote_compaction == .v2;
    request.responses_compaction_trigger = use_v2_trigger;
    request.tool_choice = .auto;
    request.responses_tool_choice_json = null;
    request.max_output_tokens = null;
    request.response_format = null;
    request.vision_mode = .unavailable;
    if (request.provider_options.parallel_tool_calls == null) {
        request.provider_options.parallel_tool_calls = true;
    }
    if (route == .openai_responses_byok) request.provider_options.fast = false;

    const request_options: responses_protocol.RequestOptions = .{
        .capabilities = .{
            .supports_max_output_tokens = route.contract().supports_max_output_tokens,
        },
        .store = false,
        .stream = use_v2_trigger,
        .include = if (use_v2_trigger) &.{"reasoning.encrypted_content"} else &.{},
        .prompt_cache_key = input.build_request.session_id,
        .reasoning_summary = if (route == .codex_responses_oauth or
            request.provider_options.reasoning != null)
            "auto"
        else
            null,
        .function_tools_strict = false,
    };
    const payload = if (use_v2_trigger)
        try responses_protocol.buildRequest(alloc, request, request_options)
    else
        try responses_protocol.buildCompactRequest(alloc, request, request_options);
    defer alloc.free(payload);

    const endpoint = if (use_v2_trigger)
        try alloc.dupe(u8, input.provider_binding.normalized_origin)
    else
        try provider_route.appendResponsesCompactEndpointAlloc(
            alloc,
            input.provider_binding.normalized_origin,
        );
    defer alloc.free(endpoint);

    if (route == .codex_responses_oauth) {
        var local_cancel = std.atomic.Value(bool).init(false);
        const cancel_flag = if (input.build_request.budget) |budget|
            budget.cancel_flag orelse &local_cancel
        else
            &local_cancel;
        var response = try gateway_client.streamResponsesCompactionBounded(
            alloc,
            .{
                .api_key = input.credential,
                .credential_source = source,
                .responses_compaction_binding = input.provider_binding,
                .model = wire_model,
                .retry_count = 1,
                .chat_url = endpoint,
                .payload = payload,
                .session_id = input.build_request.session_id,
                .codex_beta_features = responses_compaction.v2_beta_feature,
            },
            if (input.build_request.budget) |budget| budget.deadline else null,
            cancel_flag,
        );
        defer response.deinit(alloc);
        if (response.status.class() != .success) return .{ .rejected = response.status };

        const input_json = try responses_compaction.replayInputJsonFromOutputItemsAlloc(
            alloc,
            response.completion.responses_provider_output_items,
        );
        errdefer alloc.free(input_json);
        return .{ .compacted = .{
            .credential_source = source,
            .wire_model = try alloc.dupe(u8, wire_model),
            .input_json = input_json,
            .usage = response.completion.usage,
        } };
    }

    var response = try gateway_client.fetchOpenAIJsonBounded(alloc, .{
        .url = endpoint,
        .api_key = input.credential,
        .payload = payload,
        .organization = input.provider_binding.organization,
        .project = input.provider_binding.project,
        .cancel_flag = if (input.build_request.budget) |budget| budget.cancel_flag else null,
        .deadline = if (input.build_request.budget) |budget| budget.deadline else null,
        .max_response_bytes = compact_response_max_bytes,
    });
    defer response.deinit(alloc);
    if (response.status.class() != .success) return .{ .rejected = response.status };

    var decoded = responses_compaction.decodeResponse(alloc, response.body) catch |err| {
        debug_trace.logf("compaction", "invalid OpenAI compact response err={s}", .{@errorName(err)});
        return err;
    };
    defer decoded.deinit();
    const input_json = try decoded.replayInputJsonAlloc(alloc);
    errdefer alloc.free(input_json);
    return .{ .compacted = .{
        .credential_source = source,
        .wire_model = try alloc.dupe(u8, wire_model),
        .input_json = input_json,
        .usage = .{
            .input_tokens = decoded.usage.input_tokens,
            .output_tokens = decoded.usage.output_tokens,
            .cached_input_tokens = decoded.usage.cached_input_tokens,
            .cache_write_input_tokens = decoded.usage.cache_write_input_tokens,
            .reasoning_output_tokens = decoded.usage.reasoning_output_tokens,
            .total_tokens = decoded.usage.total_tokens,
            .codex_rollout_budget_units = decoded.usage.codex_rollout_budget_units,
        },
    } };
}

const PreparedRequest = struct {
    payload: []u8,
    binding: types.ResponsesCompactionProviderBinding,
    wire_model: []const u8,

    fn deinit(self: *PreparedRequest, alloc: Allocator) void {
        alloc.free(self.payload);
        types.freeResponsesCompactionProviderBinding(alloc, self.binding);
        self.* = undefined;
    }
};

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 1024) return error.InvalidOpenAIResponsesModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenAIResponsesModel;
    }
}

fn prepareRequest(alloc: Allocator, request: stream_provider.ModelRequest) !PreparedRequest {
    if (request.credential.source != .openai_api_key) {
        return error.OpenAIResponsesApiKeyRequired;
    }
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    const route: provider_route.ProviderRoute = .openai_responses_byok;
    const wire_model = provider_route.wireModel(route, request.model);
    try validateModel(wire_model);
    var binding = try responses_compaction_binding.buildFromEnvironmentAlloc(
        alloc,
        .openai_api_key,
        request.credential.secret,
        request.credential.account_id,
    );
    errdefer types.freeResponsesCompactionProviderBinding(alloc, binding);

    const payload = try buildPayload(
        alloc,
        request.data(),
        request.credential.secret,
        request.credential.account_id,
        request.session_id,
        binding.view(),
    );
    return .{
        .payload = payload,
        .binding = binding,
        .wire_model = wire_model,
    };
}

pub fn buildRequest(alloc: Allocator, request: stream_provider.RequestData) ![]u8 {
    return buildPayload(alloc, request, null, null, null, null);
}

fn buildPayload(
    alloc: Allocator,
    request: stream_provider.RequestData,
    credential: ?[]const u8,
    account_id: ?[]const u8,
    session_id: ?[]const u8,
    binding: ?types.ResponsesCompactionProviderBindingView,
) ![]u8 {
    const route: provider_route.ProviderRoute = .openai_responses_byok;
    const wire_model = provider_route.wireModel(route, request.model);
    try validateModel(wire_model);

    var tools = try responses_protocol.prepareTools(alloc, request.tools);
    defer tools.deinit(alloc);

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
    if (provider_options.parallel_tool_calls == null) {
        provider_options.parallel_tool_calls = true;
    }
    const payload = try responses_protocol.buildRequest(alloc, .{
        .credential_source = .openai_api_key,
        .provider_credential = credential,
        .account_id = account_id,
        .session_id = session_id,
        .model = wire_model,
        .tool_registry = request.tools.registry,
        .serialized_tools = tools.base_json,
        .selected_dynamic_tool_schemas = tools.dynamic_json,
        .messages = request.messages,
        .tool_choice = request.tool_choice,
        .vision_mode = request.vision_mode,
        .provider_options = provider_options,
        .max_output_tokens = request.max_output_tokens,
        .budget = request.budget,
        .verified_images = request.verified_images,
        .response_format = response_format,
        .responses_compaction_binding = binding,
    }, .{
        .capabilities = .{
            .supports_max_output_tokens = route.contract().supports_max_output_tokens,
        },
        .prompt_cache_key = session_id,
        .reasoning_summary = if (provider_options.reasoning != null) "auto" else null,
        .function_tools_strict = false,
    });
    return payload;
}

pub fn streamPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) !stream_provider.Result {
    if (request.credential.source != .openai_api_key) {
        return error.OpenAIResponsesApiKeyRequired;
    }
    var binding = try responses_compaction_binding.buildFromEnvironmentAlloc(
        alloc,
        .openai_api_key,
        request.credential.secret,
        request.credential.account_id,
    );
    defer types.freeResponsesCompactionProviderBinding(alloc, binding);
    return streamPreparedWithBinding(alloc, request, payload, binding.view(), request.model);
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    var prepared = try prepareRequest(alloc, request);
    defer prepared.deinit(alloc);

    return streamPreparedWithBinding(
        alloc,
        request,
        prepared.payload,
        prepared.binding.view(),
        prepared.wire_model,
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
    var result = gateway_client.streamGatewayCompletion(
        alloc,
        .{
            .api_key = request.credential.secret,
            .credential_source = .openai_api_key,
            .responses_compaction_binding = binding,
            .session_id = request.session_id,
            .model = wire_model,
            .retry_count = request.retry_count,
            .chat_url = binding.normalized_origin,
            .payload = payload,
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
    ) catch |err| {
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(
            err,
            request.delivery.load(),
        );
        return err;
    };
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

    const completion = result.completion;
    result.completion = .{};
    return .{ .completed = .{
        .completion = completion,
        .usage = .{ .immediate = null },
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

test "OpenAI Responses request uses the direct wire model and typed tools" {
    const alloc = std.testing.allocator;
    const tool_names = [_][]const u8{"read_file"};
    const tool_schema = model_tool_schema.FunctionSchema{
        .name = "read_file",
        .description = "Read a file.",
        .input_schema = .{
            .properties = &.{.{ .name = "path", .json_type = .string }},
            .required = &.{"path"},
        },
    };
    const tool_schemas = [_]model_tool_schema.FunctionSchema{tool_schema};
    var delivery = stream_provider.DeliveryCertainty.init();
    var attempt_evidence: stream_provider.AttemptEvidence = .{};
    var cancel = std.atomic.Value(bool).init(false);
    var prepared = try prepareRequest(alloc, .{
        .credential = .{ .secret = "sk-test", .source = .openai_api_key },
        .session_id = "session-test",
        .model = "openai/gpt-5.4",
        .retry_count = 1,
        .messages = &.{.{ .role = .user, .content = "hello" }},
        .tools = .{
            .advertised_names = &tool_names,
            .advertised_functions = &tool_schemas,
        },
        .tool_choice = .auto,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &attempt_evidence,
        .events = undefined,
        .cancel_flag = &cancel,
    });
    defer prepared.deinit(alloc);

    try std.testing.expectEqualStrings("gpt-5.4", prepared.wire_model);
    try std.testing.expect(std.mem.find(u8, prepared.payload, "\"model\":\"gpt-5.4\"") != null);
    try std.testing.expect(std.mem.find(u8, prepared.payload, "\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, prepared.payload, "\"prompt_cache_key\":\"session-test\"") != null);
    try std.testing.expect(std.mem.find(u8, prepared.payload, "\"prompt\"") == null);
}
