const std = @import("std");
const gateway_client = @import("../../gateway/client.zig");
const gateway_json = @import("../../core/gateway/gateway_json.zig");
const provider_route = @import("../../core/gateway/provider_route.zig");
const responses_compaction_binding = @import("../../core/gateway/responses_compaction_binding.zig");
const responses_protocol = @import("../../core/gateway/responses_protocol.zig");
const stream_provider = @import("../../core/agent/stream_provider.zig");
const permission_auto_classifier = @import("../../core/permissions/auto_classifier.zig");
const session_usage = @import("../../core/session/session_usage.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const types = @import("../../core/shared/types.zig");
const openai_codex_models = @import("../../gateway/openai_codex_models.zig");

const Allocator = std.mem.Allocator;

const single_transport_attempt: usize = 1;
const guardian_prompt_cache_key_prefix = "guardian:";

const StreamFn = *const fn (
    *anyopaque,
    Allocator,
    []const u8,
    ?[]const u8,
    ?types.CredentialSource,
    ?[]const u8,
    ?[]const u8,
    []const u8,
    usize,
    []const u8,
    []const u8,
    std.Io.Clock.Timestamp,
    *gateway_client.DeliveryCertainty,
    *std.atomic.Value(bool),
) anyerror!gateway_client.StreamResult;

var default_stream_ctx: u8 = 0;

const GatewayConfig = struct {
    api_key: []const u8,
    team: ?[]const u8 = null,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    chat_url: []const u8,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
    stream_ctx: *anyopaque = @ptrCast(&default_stream_ctx),
    stream_fn: StreamFn = streamGatewayReviewer,
};

pub const provider = permission_auto_classifier.Provider{ .review_fn = reviewGateway };

fn reviewGateway(
    _: ?*anyopaque,
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
) anyerror!permission_auto_classifier.ParseOutcome {
    return reviewGatewayConfig(.{
        .api_key = input.credential,
        .team = input.tenant,
        .credential_source = input.credential_source,
        .account_id = input.account_id,
        .session_id = input.session_id,
        .chat_url = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .usage = input.usage,
        .usage_allocator = input.usage_allocator,
    }, alloc, request);
}

fn reviewGatewayConfig(
    config: GatewayConfig,
    alloc: Allocator,
    request: permission_auto_classifier.ReviewRequest,
) !permission_auto_classifier.ParseOutcome {
    var local = config;
    const reviewer_model = if (routeForSource(local.credential_source) == .codex_responses_oauth)
        openai_codex_models.reviewer_model
    else
        permission_auto_classifier.gateway_reviewer_model;
    return permission_auto_classifier.Reviewer.withTransportModel(
        .{
            .context = @ptrCast(&local),
            .build_fn = buildProviderReviewPayload,
            .send_fn = sendGatewayReview,
        },
        local.cancel_flag,
        permission_auto_classifier.Reviewer.default_timeout_ms,
        reviewer_model,
    ).review(alloc, request);
}

fn buildProviderReviewPayload(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    model: []const u8,
    tools_json: []const u8,
    messages: []const types.ChatMessage,
    target_call_id: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) ![]u8 {
    const config: *GatewayConfig = @ptrCast(@alignCast(raw_ctx));
    const route = routeForSource(config.credential_source);
    if (route == .vercel_gateway) {
        return gateway_json.buildGatewayPendingToolReviewRequestBodyWithMaxOutputTokens(
            alloc,
            tools_json,
            messages,
            target_call_id,
            .{},
            2048,
            deadline,
            cancel_flag,
        );
    }

    const expanded = try gateway_json.expandPendingToolReviewMessages(
        alloc,
        messages,
        target_call_id,
        deadline,
        cancel_flag,
    );
    defer alloc.free(expanded);

    const prompt_cache_key = if (config.session_id) |session_id|
        try std.fmt.allocPrint(
            alloc,
            guardian_prompt_cache_key_prefix ++ "{s}",
            .{session_id},
        )
    else
        null;
    defer if (prompt_cache_key) |key| alloc.free(key);

    return responses_protocol.buildRequest(alloc, .{
        .credential_source = config.credential_source,
        .model = provider_route.wireModel(route, model),
        .serialized_tools = tools_json,
        .messages = expanded,
        .tool_choice = .auto,
        .provider_options = .{ .parallel_tool_calls = false },
        .max_output_tokens = if (route.contract().supports_max_output_tokens) 2048 else null,
        .budget = stream_provider.BuildBudget{
            .deadline = deadline,
            .cancel_flag = cancel_flag,
        },
    }, .{
        .capabilities = .{
            .supports_max_output_tokens = route.contract().supports_max_output_tokens,
        },
        .prompt_cache_key = prompt_cache_key,
        .tool_choice_json = "\"required\"",
        .reasoning_summary = if (route == .codex_responses_oauth) "auto" else null,
        .function_tools_strict = false,
    });
}

fn routeForSource(source: ?types.CredentialSource) provider_route.ProviderRoute {
    return if (source) |value|
        provider_route.fromCredentialSource(value) orelse .vercel_gateway
    else
        .vercel_gateway;
}

const OwnedStream = struct {
    stream: gateway_client.StreamResult,
};

fn deinitOwnedStream(raw_ctx: *anyopaque, alloc: Allocator) void {
    const owned: *OwnedStream = @ptrCast(@alignCast(raw_ctx));
    owned.stream.deinit(alloc);
    alloc.destroy(owned);
}

fn sendGatewayReview(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    model: []const u8,
    payload: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) error{OutOfMemory}!permission_auto_classifier.TransportOutcome {
    const config: *GatewayConfig = @ptrCast(@alignCast(raw_ctx));
    const route = routeForSource(config.credential_source);
    const wire_model = provider_route.wireModel(route, model);
    debug_trace.logf(
        "permission",
        "event=auto_review_transport_start model={s} retry_count={d}",
        .{ model, single_transport_attempt },
    );
    if (cancel_flag.load(.seq_cst)) return .cancelled;
    if (config.api_key.len == 0 or config.chat_url.len == 0) {
        debug_trace.logf("permission", "event=auto_review_transport result=permanent_failure reason=missing_gateway_config", .{});
        return .permanent_failure;
    }

    const usage_observation = session_usage.GatewayObservation.begin(config.usage) catch |err| {
        debug_trace.logf(
            "permission",
            "event=auto_review_usage result=permanent_failure phase=begin reason={s}",
            .{@errorName(err)},
        );
        return .permanent_failure;
    };
    var delivery = gateway_client.DeliveryCertainty.init();
    var stream = config.stream_fn(
        config.stream_ctx,
        alloc,
        config.api_key,
        config.team,
        config.credential_source,
        config.account_id,
        config.session_id,
        wire_model,
        single_transport_attempt,
        config.chat_url,
        payload,
        deadline,
        &delivery,
        cancel_flag,
    ) catch |err| {
        usage_observation.fail(if (delivery.load() == .possibly_sent)
            .ambiguous_delivery
        else
            .unbilled) catch |usage_err| {
            debug_trace.logf(
                "permission",
                "event=auto_review_usage result=permanent_failure phase=transport_failure reason={s}",
                .{@errorName(usage_err)},
            );
            return .permanent_failure;
        };
        return mapTransportError(err, cancel_flag);
    };
    var stream_owned = true;
    defer if (stream_owned) stream.deinit(alloc);
    (if (route == .vercel_gateway)
        usage_observation.complete(
            config.usage_allocator,
            stream.status,
            stream.completion,
            gateway_client.generationBaseUrl(),
            config.team,
        )
    else
        usage_observation.completeDirect(
            config.usage_allocator,
            wire_model,
            stream.completion.usage,
            .{
                .http_ok = stream.status == .ok,
                .terminal_finish_reason = stream.completion.finish_reason,
            },
        )) catch |err| {
        debug_trace.logf(
            "permission",
            "event=auto_review_usage result=permanent_failure phase=completion reason={s}",
            .{@errorName(err)},
        );
        return .permanent_failure;
    };
    if (route == .vercel_gateway) {
        if (config.usage) |ledger| {
            ledger.startReconciliation(config.usage_allocator, config.api_key);
        }
    }

    if (cancel_flag.load(.seq_cst)) {
        return .cancelled;
    }
    if (stream.status != .ok) {
        const outcome = mapHttpStatus(stream.status);
        debug_trace.logf(
            "permission",
            "event=auto_review_transport result={s} http_status={d}",
            .{ @tagName(std.meta.activeTag(outcome)), @intFromEnum(stream.status) },
        );
        return outcome;
    }
    if (stream.completion.finish_reason) |reason| switch (reason) {
        .provider_error => {
            return .transient_failure;
        },
        .content_filter => {
            return .permanent_failure;
        },
        .stop, .length, .tool_calls, .other => {},
    };

    const owned = try alloc.create(OwnedStream);
    owned.* = .{ .stream = stream };
    stream_owned = false;
    return .{ .completion = .{
        .completion = owned.stream.completion,
        .context = @ptrCast(owned),
        .deinit_fn = deinitOwnedStream,
    } };
}

fn mapTransportError(
    err: anyerror,
    cancel_flag: *std.atomic.Value(bool),
) error{OutOfMemory}!permission_auto_classifier.TransportOutcome {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.Cancelled or cancel_flag.load(.seq_cst)) return .cancelled;
    if (err == error.Timeout) return .timed_out;
    if (gateway_client.isRetryableGatewayError(err)) return .transient_failure;
    debug_trace.logf(
        "permission",
        "event=auto_review_transport result=permanent_failure err={s}",
        .{@errorName(err)},
    );
    return .permanent_failure;
}

fn mapHttpStatus(status: std.http.Status) permission_auto_classifier.TransportOutcome {
    const code: u16 = @intFromEnum(status);
    if (code == 408 or code == 425 or code == 429 or code >= 500) {
        return .transient_failure;
    }
    return .permanent_failure;
}

fn streamGatewayReviewer(
    _: *anyopaque,
    alloc: Allocator,
    api_key: []const u8,
    team: ?[]const u8,
    credential_source: ?types.CredentialSource,
    account_id: ?[]const u8,
    session_id: ?[]const u8,
    model: []const u8,
    retry_count: usize,
    chat_url: []const u8,
    payload: []const u8,
    deadline: std.Io.Clock.Timestamp,
    delivery: *gateway_client.DeliveryCertainty,
    cancel_flag: *std.atomic.Value(bool),
) !gateway_client.StreamResult {
    const binding: ?types.ResponsesCompactionProviderBinding = if (credential_source) |source|
        if (provider_route.fromCredentialSource(source)) |route|
            if (route.contract().wire_api == .openai_responses)
                try responses_compaction_binding.buildFromEnvironmentAlloc(
                    alloc,
                    source,
                    api_key,
                    account_id,
                )
            else
                null
        else
            null
    else
        null;
    defer if (binding) |owned| types.freeResponsesCompactionProviderBinding(alloc, owned);
    return gateway_client.streamGatewayRequiredToolCompletionBounded(
        alloc,
        .{
            .api_key = api_key,
            .team = team,
            .credential_source = credential_source,
            .responses_compaction_binding = if (binding) |owned| owned.view() else null,
            .session_id = session_id,
            .model = model,
            .retry_count = retry_count,
            .chat_url = chat_url,
            .payload = payload,
            .delivery = delivery,
        },
        deadline,
        cancel_flag,
    );
}

const FakeOutcome = enum {
    valid,
    malformed,
    transient_error,
    permanent_error,
    ambiguous_error,
    timeout,
    cancelled,
    transient_http,
    permanent_http,
};

const FakeStream = struct {
    outcomes: []const FakeOutcome,
    calls: usize = 0,
    saw_single_attempt_only: bool = true,
    saw_expected_model_only: bool = true,
    saw_required_tool_payload: bool = true,
    saw_expected_source_only: bool = true,
    saw_responses_payload: bool = true,
    saw_expected_prompt_cache_key: bool = true,
    expected_model: []const u8 = "zai/glm-5.2",
    expected_source: ?types.CredentialSource = null,
    expected_prompt_cache_key: ?[]const u8 = null,
    expect_responses_payload: bool = false,
    deadlines: [2]?std.Io.Clock.Timestamp = .{ null, null },

    fn execute(
        raw_ctx: *anyopaque,
        alloc: Allocator,
        _: []const u8,
        _: ?[]const u8,
        source: ?types.CredentialSource,
        _: ?[]const u8,
        _: ?[]const u8,
        model: []const u8,
        retry_count: usize,
        _: []const u8,
        payload: []const u8,
        deadline: std.Io.Clock.Timestamp,
        delivery: *gateway_client.DeliveryCertainty,
        _: *std.atomic.Value(bool),
    ) anyerror!gateway_client.StreamResult {
        const self: *FakeStream = @ptrCast(@alignCast(raw_ctx));
        if (self.calls < self.deadlines.len) self.deadlines[self.calls] = deadline;
        self.saw_single_attempt_only = self.saw_single_attempt_only and retry_count == 1;
        self.saw_expected_model_only = self.saw_expected_model_only and std.mem.eql(u8, model, self.expected_model);
        self.saw_expected_source_only = self.saw_expected_source_only and source == self.expected_source;
        if (self.expect_responses_payload) {
            const expected_model = try std.fmt.allocPrint(alloc, "\"model\":\"{s}\"", .{self.expected_model});
            defer alloc.free(expected_model);
            self.saw_responses_payload = self.saw_responses_payload and
                std.mem.find(u8, payload, "\"input\":[") != null and
                std.mem.find(u8, payload, expected_model) != null and
                std.mem.find(u8, payload, "\"tool_choice\":\"required\"") != null;
        }
        if (self.expected_prompt_cache_key) |expected| {
            var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
            defer parsed.deinit();
            const actual = if (parsed.value == .object)
                parsed.value.object.get("prompt_cache_key")
            else
                null;
            self.saw_expected_prompt_cache_key = self.saw_expected_prompt_cache_key and
                actual != null and
                actual.? == .string and
                std.mem.eql(u8, actual.?.string, expected);
        }
        self.saw_required_tool_payload = self.saw_required_tool_payload and
            std.mem.find(u8, payload, "permission_decision") != null;
        const outcome = self.outcomes[@min(self.calls, self.outcomes.len - 1)];
        self.calls += 1;
        return switch (outcome) {
            .valid => validStream(alloc),
            .malformed => malformedStream(alloc),
            .transient_error => error.ConnectionResetByPeer,
            .permanent_error => error.AccessDenied,
            .ambiguous_error => {
                delivery.markPossiblySent();
                return error.ConnectionResetByPeer;
            },
            .timeout => error.Timeout,
            .cancelled => error.Cancelled,
            .transient_http => .{ .status = @enumFromInt(429) },
            .permanent_http => .{ .status = @enumFromInt(400) },
        };
    }
};

fn validStream(alloc: Allocator) !gateway_client.StreamResult {
    const generation_id = try alloc.dupe(u8, "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV");
    errdefer alloc.free(generation_id);
    const id = try alloc.dupe(u8, "review_1");
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, permission_auto_classifier.tool_name);
    errdefer alloc.free(name);
    const arguments = try alloc.dupe(
        u8,
        "{\"risk\":\"low\",\"authorization\":\"medium\",\"decision\":\"allow\",\"rationale\":\"Narrow authorized action.\"}",
    );
    errdefer alloc.free(arguments);
    const tool_calls = try alloc.alloc(types.ToolCall, 1);
    errdefer alloc.free(tool_calls);
    tool_calls[0] = .{
        .id = id,
        .name = name,
        .arguments_json = arguments,
    };
    return .{
        .status = .ok,
        .completion = .{
            .tool_calls = tool_calls,
            .finish_reason = .tool_calls,
            .generation_id = generation_id,
        },
    };
}

fn malformedStream(alloc: Allocator) !gateway_client.StreamResult {
    return .{
        .status = .ok,
        .completion = .{
            .content = try alloc.dupe(u8, "not a structured decision"),
            .finish_reason = .stop,
        },
    };
}

fn testRequest() permission_auto_classifier.ReviewRequest {
    const pending = types.ChatMessage{
        .role = .assistant,
        .tool_calls = &.{.{
            .id = "call_1",
            .name = "list_files",
            .arguments_json = "{\"path\":\".\"}",
        }},
    };
    return .{
        .workspace_root = "/tmp/workspace",
        .review_turn = .{
            .model = "openai/gpt-5",
            .pending_assistant = pending,
            .target_call_id = "call_1",
            .origin = .root,
            .current_root_request = "User asked to inspect the repository.",
        },
        .targets = &.{},
        .action = .{ .tool = .{
            .tool_name = "list_files",
            .arguments_json = "{\"path\":\".\"}",
        } },
        .escalation_reason = "No deterministic rule settled the call.",
    };
}

fn testConfig(fake: *FakeStream, cancel_flag: ?*std.atomic.Value(bool)) GatewayConfig {
    return .{
        .api_key = "test-key",
        .chat_url = "https://example.test/chat",
        .cancel_flag = cancel_flag,
        .stream_ctx = @ptrCast(fake),
        .stream_fn = FakeStream.execute,
    };
}

test "gateway automatic reviewer transport is single-attempt" {
    var fake = FakeStream{ .outcomes = &.{.valid} };
    const config = testConfig(&fake, null);
    var outcome = try reviewGatewayConfig(config, std.testing.allocator, testRequest());
    defer outcome.deinit(std.testing.allocator);

    switch (outcome) {
        .valid => |result| try std.testing.expectEqual(permission_auto_classifier.Decision.allow, result.decision),
        .invalid => return error.TestExpectedEqual,
    }
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(fake.saw_single_attempt_only);
    try std.testing.expect(fake.saw_expected_model_only);
    try std.testing.expect(fake.saw_required_tool_payload);
}

test "direct automatic reviewer uses Responses route without Gateway reconciliation" {
    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var fake = FakeStream{
        .outcomes = &.{.valid},
        .expected_model = "gpt-5.4",
        .expected_source = .openai_api_key,
        .expected_prompt_cache_key = "guardian:parent-session-1",
        .expect_responses_payload = true,
    };
    const config = GatewayConfig{
        .api_key = "openai-test-key",
        .credential_source = .openai_api_key,
        .session_id = "parent-session-1",
        .chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model",
        .usage = &usage,
        .usage_allocator = alloc,
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    };

    var outcome = try reviewGatewayConfig(config, alloc, testRequest());
    defer outcome.deinit(alloc);
    try std.testing.expect(fake.saw_expected_source_only);
    try std.testing.expect(fake.saw_expected_model_only);
    try std.testing.expect(fake.saw_responses_payload);
    try std.testing.expect(fake.saw_expected_prompt_cache_key);

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), snapshot.pending.len);
    try std.testing.expectEqual(session_usage.Availability.incomplete, snapshot.billing);
    try std.testing.expectEqual(@as(usize, 1), snapshot.incidents.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.models.len);
}

test "Codex automatic reviewer uses the shared Responses route and reviewer model" {
    const alloc = std.testing.allocator;
    var fake = FakeStream{
        .outcomes = &.{.valid},
        .expected_model = openai_codex_models.reviewer_model,
        .expected_source = .chatgpt_subscription,
        .expected_prompt_cache_key = "guardian:codex-parent-session",
        .expect_responses_payload = true,
    };
    const config = GatewayConfig{
        .api_key = "codex-test-token",
        .credential_source = .chatgpt_subscription,
        .account_id = "codex-account",
        .session_id = "codex-parent-session",
        .chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model",
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    };

    var outcome = try reviewGatewayConfig(config, alloc, testRequest());
    defer outcome.deinit(alloc);
    try std.testing.expect(fake.saw_expected_source_only);
    try std.testing.expect(fake.saw_expected_model_only);
    try std.testing.expect(fake.saw_responses_payload);
    try std.testing.expect(fake.saw_expected_prompt_cache_key);
}

test "gateway automatic reviewer records its generation in session usage" {
    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var fake = FakeStream{ .outcomes = &.{.valid} };
    const config = GatewayConfig{
        .api_key = "test-key",
        .chat_url = "https://example.test/chat",
        .usage = &usage,
        .usage_allocator = alloc,
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    };

    var outcome = try reviewGatewayConfig(config, alloc, testRequest());
    defer outcome.deinit(alloc);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(session_usage.Availability.pending, snapshot.billing);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pending.len);
    try std.testing.expectEqualStrings(
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        snapshot.pending[0].id,
    );
}

test "pre-send automatic reviewer failure stays unbilled" {
    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var fake = FakeStream{ .outcomes = &.{.permanent_error} };
    const config = GatewayConfig{
        .api_key = "test-key",
        .chat_url = "https://example.test/chat",
        .usage = &usage,
        .usage_allocator = alloc,
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    };

    var outcome = try reviewGatewayConfig(config, alloc, testRequest());
    defer outcome.deinit(alloc);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(session_usage.Availability.complete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
    try std.testing.expectEqual(@as(u64, 1), snapshot.settled_through_sequence);
}

test "possibly sent automatic reviewer failure marks billing incomplete" {
    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var fake = FakeStream{ .outcomes = &.{.ambiguous_error} };
    const config = GatewayConfig{
        .api_key = "test-key",
        .chat_url = "https://example.test/chat",
        .usage = &usage,
        .usage_allocator = alloc,
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    };

    var outcome = try reviewGatewayConfig(config, alloc, testRequest());
    defer outcome.deinit(alloc);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(session_usage.Availability.incomplete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
    try std.testing.expectEqual(@as(u64, 1), snapshot.settled_through_sequence);
}

test "terminal checkpoint failure releases automatic reviewer stream" {
    const Checkpoint = struct {
        calls: usize = 0,

        fn persist(raw_ctx: *anyopaque, _: session_usage.Snapshot) !void {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            self.calls += 1;
            if (self.calls == 2) return error.CheckpointRejected;
        }
    };

    const alloc = std.testing.allocator;
    var checkpoint = Checkpoint{};
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    usage.configureCheckpointSink(.{
        .context = &checkpoint,
        .allocator = alloc,
        .persist = Checkpoint.persist,
    });
    var fake = FakeStream{ .outcomes = &.{.valid} };
    const config = GatewayConfig{
        .api_key = "test-key",
        .chat_url = "https://example.test/chat",
        .usage = &usage,
        .usage_allocator = alloc,
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    };

    var outcome = try reviewGatewayConfig(config, alloc, testRequest());
    defer outcome.deinit(alloc);
    try std.testing.expectEqual(
        std.meta.Tag(permission_auto_classifier.ParseOutcome).valid,
        std.meta.activeTag(outcome),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(usize, 2), checkpoint.calls);
}

test "permission reviewer owns a single-send budget" {
    var fake = FakeStream{ .outcomes = &.{ .transient_error, .malformed } };
    const config = testConfig(&fake, null);
    const outcome = try reviewGatewayConfig(config, std.testing.allocator, testRequest());

    try std.testing.expectEqual(
        std.meta.Tag(permission_auto_classifier.ParseOutcome).invalid,
        std.meta.activeTag(outcome),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(fake.saw_single_attempt_only);
    try std.testing.expect(fake.deadlines[0] != null);
    try std.testing.expect(fake.deadlines[1] == null);
}

test "gateway automatic reviewer distinguishes transient and permanent HTTP failures" {
    var transient_fake = FakeStream{ .outcomes = &.{ .transient_http, .valid } };
    const transient_config = testConfig(&transient_fake, null);
    var transient = try reviewGatewayConfig(transient_config, std.testing.allocator, testRequest());
    defer transient.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        std.meta.Tag(permission_auto_classifier.ParseOutcome).invalid,
        std.meta.activeTag(transient),
    );
    try std.testing.expectEqual(@as(usize, 1), transient_fake.calls);

    var permanent_fake = FakeStream{ .outcomes = &.{ .permanent_http, .valid } };
    const permanent_config = testConfig(&permanent_fake, null);
    const permanent = try reviewGatewayConfig(permanent_config, std.testing.allocator, testRequest());
    try std.testing.expectEqual(
        std.meta.Tag(permission_auto_classifier.ParseOutcome).invalid,
        std.meta.activeTag(permanent),
    );
    try std.testing.expectEqual(@as(usize, 1), permanent_fake.calls);
}

test "gateway transport preserves cancellation timeout transient and permanent outcomes" {
    var fake = FakeStream{ .outcomes = &.{
        .cancelled,
        .timeout,
        .transient_error,
        .permanent_error,
    } };
    var config = GatewayConfig{
        .api_key = "test-key",
        .chat_url = "https://example.test/chat",
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    };
    var cancel_flag = std.atomic.Value(bool).init(false);
    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(100),
    });
    const expected = [_]std.meta.Tag(permission_auto_classifier.TransportOutcome){
        .cancelled,
        .timed_out,
        .transient_failure,
        .permanent_failure,
    };
    for (expected) |expected_tag| {
        const outcome = try sendGatewayReview(
            @ptrCast(&config),
            std.testing.allocator,
            "openai/gpt-5",
            "{}",
            deadline,
            &cancel_flag,
        );
        try std.testing.expectEqual(expected_tag, std.meta.activeTag(outcome));
    }
    try std.testing.expectEqual(expected.len, fake.calls);
}

test "gateway automatic reviewer distinguishes timeout permanent failure and cancellation" {
    var timeout_fake = FakeStream{ .outcomes = &.{.timeout} };
    const timeout_config = testConfig(&timeout_fake, null);
    const timed_out = try reviewGatewayConfig(timeout_config, std.testing.allocator, testRequest());
    try std.testing.expectEqual(
        std.meta.Tag(permission_auto_classifier.ParseOutcome).invalid,
        std.meta.activeTag(timed_out),
    );
    try std.testing.expectEqual(@as(usize, 1), timeout_fake.calls);

    var permanent_fake = FakeStream{ .outcomes = &.{ .permanent_error, .valid } };
    const permanent_config = testConfig(&permanent_fake, null);
    const permanent = try reviewGatewayConfig(permanent_config, std.testing.allocator, testRequest());
    try std.testing.expectEqual(
        std.meta.Tag(permission_auto_classifier.ParseOutcome).invalid,
        std.meta.activeTag(permanent),
    );
    try std.testing.expectEqual(@as(usize, 1), permanent_fake.calls);

    var cancelled_fake = FakeStream{ .outcomes = &.{.cancelled} };
    const cancelled_config = testConfig(&cancelled_fake, null);
    try std.testing.expectError(
        error.Cancelled,
        reviewGatewayConfig(cancelled_config, std.testing.allocator, testRequest()),
    );
    try std.testing.expectEqual(@as(usize, 1), cancelled_fake.calls);

    var cancel_flag = std.atomic.Value(bool).init(true);
    var pre_cancelled_fake = FakeStream{ .outcomes = &.{.valid} };
    const pre_cancelled_config = testConfig(&pre_cancelled_fake, &cancel_flag);
    try std.testing.expectError(
        error.Cancelled,
        reviewGatewayConfig(pre_cancelled_config, std.testing.allocator, testRequest()),
    );
    try std.testing.expectEqual(@as(usize, 0), pre_cancelled_fake.calls);
}
