const std = @import("std");
const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const io_mod = @import("../core/shared/io.zig");
const message_history = @import("../core/gateway/message_history.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const session_usage = @import("../core/session/session_usage.zig");

const Allocator = std.mem.Allocator;

pub const BuildFn = *const fn (Allocator, stream_provider.RequestData) anyerror![]u8;
pub const SendFn = *const fn (
    Allocator,
    stream_provider.ModelRequest,
    []const u8,
) anyerror!stream_provider.Result;
pub const ValidateFn = *const fn (
    Allocator,
    permission_auto_classifier.ProviderInput,
) anyerror!void;

pub const Adapter = struct {
    source: types.CredentialSource,
    model: []const u8,
    require_account: bool = false,
    validate_fn: ValidateFn,
    build_fn: BuildFn,
    send_fn: SendFn,
};

const Runtime = struct {
    input: permission_auto_classifier.ProviderInput,
    adapter: Adapter,
};

pub fn review(
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
    adapter: Adapter,
) !permission_auto_classifier.ParseOutcome {
    if (input.credential.len == 0) {
        debugUnavailable(adapter.source, "validate", .missing_credential);
        return .invalid;
    }
    if (adapter.require_account and input.account_id == null) {
        debugUnavailable(adapter.source, "validate", .missing_account);
        return .invalid;
    }
    adapter.validate_fn(alloc, input) catch |err| {
        debugUnavailable(adapter.source, "validate", switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.InvalidAccount => .invalid_account,
            error.OpenAIResponsesApiKeyRequired => .credential_source_mismatch,
            else => .invalid_credential,
        });
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .invalid;
    };
    var runtime = Runtime{ .input = input, .adapter = adapter };
    return permission_auto_classifier.Reviewer.withTransportModel(
        .{
            .context = &runtime,
            .build_fn = buildReviewPayload,
            .send_fn = sendReview,
        },
        input.cancel_flag,
        permission_auto_classifier.Reviewer.default_timeout_ms,
        adapter.model,
    ).review(alloc, request);
}

fn buildReviewPayload(
    raw: *anyopaque,
    alloc: Allocator,
    model: []const u8,
    messages: []const types.ChatMessage,
    target_call_id: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) ![]u8 {
    const runtime: *Runtime = @ptrCast(@alignCast(raw));
    const expanded = try message_history.expandPendingToolReviewMessages(
        alloc,
        messages,
        target_call_id,
        deadline,
        cancel_flag,
    );
    defer alloc.free(expanded);
    return runtime.adapter.build_fn(alloc, .{
        .model = model,
        .messages = expanded,
        .tools = .{ .additional_functions = &.{permission_auto_classifier.function_schema} },
        .tool_choice = .required,
        .provider_options = .{},
        .max_output_tokens = 2048,
        .budget = .{ .deadline = deadline, .cancel_flag = cancel_flag },
    });
}

pub fn buildPayloadForTest(
    alloc: Allocator,
    model: []const u8,
    messages: []const types.ChatMessage,
    target_call_id: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
    build_fn: BuildFn,
) ![]u8 {
    var runtime = Runtime{
        .input = .{},
        .adapter = .{
            .source = .openai_api_key,
            .model = model,
            .build_fn = build_fn,
            .validate_fn = validateUnavailable,
            .send_fn = undefined,
        },
    };
    return buildReviewPayload(
        &runtime,
        alloc,
        model,
        messages,
        target_call_id,
        deadline,
        cancel_flag,
    );
}

fn validateUnavailable(_: Allocator, _: permission_auto_classifier.ProviderInput) !void {}

const OwnedResult = struct {
    result: stream_provider.Result,
};

const ReviewAdmission = struct {
    usage: ?*session_usage.Usage,
    evidence: *stream_provider.AttemptEvidence,
    observation: ?session_usage.InvocationObservation = null,

    fn admit(raw: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.observation != null) return error.ProviderAdmissionRepeated;
        self.observation = try session_usage.InvocationObservation.begin(self.usage);
        self.evidence.provider_admitted = true;
    }
};

fn deinitOwnedResult(raw: *anyopaque, alloc: Allocator) void {
    const owned: *OwnedResult = @ptrCast(@alignCast(raw));
    owned.result.deinit(alloc);
    alloc.destroy(owned);
}

fn ignoreEvent(_: *anyopaque, _: stream_provider.Event) void {}

fn sendReview(
    raw: *anyopaque,
    alloc: Allocator,
    model: []const u8,
    payload: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) !permission_auto_classifier.TransportOutcome {
    const runtime: *Runtime = @ptrCast(@alignCast(raw));
    if (cancel_flag.load(.seq_cst)) {
        debugUnavailable(runtime.adapter.source, "transport", .cancelled);
        return .cancelled;
    }
    if (!std.Io.Clock.Timestamp.compare(
        std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
        .lt,
        deadline,
    )) {
        debugUnavailable(runtime.adapter.source, "transport", .timed_out);
        return .timed_out;
    }

    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var admission = ReviewAdmission{
        .usage = runtime.input.usage,
        .evidence = &evidence,
    };
    var callback_context: u8 = 0;
    var result = runtime.adapter.send_fn(alloc, .{
        .credential = .{
            .secret = runtime.input.credential,
            .source = runtime.adapter.source,
            .account_id = runtime.input.account_id,
        },
        .endpoint = if (runtime.input.endpoint.len > 0) runtime.input.endpoint else null,
        .model = model,
        .retry_count = 1,
        .messages = &.{},
        .tool_choice = .required,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = 16 * 1024,
        .deadline = deadline,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &callback_context, .emit_fn = ignoreEvent },
        .admission = .{ .context = &admission, .admit_fn = ReviewAdmission.admit },
        .cancel_flag = cancel_flag,
        .provider_attempt_owner = .transport,
    }, payload) catch |err| {
        debugUnavailable(runtime.adapter.source, "transport", switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.Cancelled => .cancelled,
            error.Timeout => .timed_out,
            else => .transport_error,
        });
        if (admission.observation) |observation| observation.fail(
            if (delivery.load() == .possibly_sent) .ambiguous_delivery else .unbilled,
        ) catch |usage_err| {
            debugUsageFailure("transport_failure", usage_err);
            return .permanent_failure;
        };
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled or cancel_flag.load(.seq_cst)) return .cancelled;
        if (err == error.Timeout) return .timed_out;
        return .transient_failure;
    };
    var result_owned = true;
    defer if (result_owned) result.deinit(alloc);
    const observation = admission.observation orelse {
        debugUsageFailure("completion", error.ProviderAdmissionMissing);
        return .permanent_failure;
    };
    (switch (result) {
        .failed => observation.fail(.unbilled),
        .completed => |completed| observation.complete(
            runtime.input.usage_allocator,
            model,
            completed.completion,
            completed.usage,
        ),
    }) catch |err| {
        debugUsageFailure("completion", err);
        return .permanent_failure;
    };
    if (cancel_flag.load(.seq_cst)) {
        debugUnavailable(runtime.adapter.source, "completion", .cancelled);
        return .cancelled;
    }
    if (std.meta.activeTag(result) == .failed) {
        debug_trace.logDurable(
            "permission",
            "event=auto_review_unavailable layer=provider source={s} phase=response reason={s}",
            .{ @tagName(runtime.adapter.source), @tagName(result.failed.kind) },
        );
        return switch (result.failed.kind) {
            .rate_limited, .server_error, .bad_gateway, .unavailable, .gateway_timeout => .transient_failure,
            else => .permanent_failure,
        };
    }
    if (result.completed.completion.finish_reason) |reason| switch (reason) {
        .provider_error => {
            debugUnavailable(runtime.adapter.source, "completion", .provider_error);
            return .transient_failure;
        },
        .content_filter => {
            debugUnavailable(runtime.adapter.source, "completion", .content_filter);
            return .permanent_failure;
        },
        .stop, .length, .tool_calls, .other => {},
    };
    const owned = try alloc.create(OwnedResult);
    owned.* = .{ .result = result };
    result_owned = false;
    return .{ .completion = .{
        .completion = owned.result.completed.completion,
        .context = owned,
        .deinit_fn = deinitOwnedResult,
    } };
}

const UnavailableReason = enum {
    missing_credential,
    missing_account,
    invalid_account,
    credential_source_mismatch,
    invalid_credential,
    out_of_memory,
    cancelled,
    timed_out,
    transport_error,
    provider_error,
    content_filter,
};

fn debugUnavailable(source: types.CredentialSource, comptime phase: []const u8, reason: UnavailableReason) void {
    debug_trace.logDurable(
        "permission",
        "event=auto_review_unavailable layer=provider source={s} phase={s} reason={s}",
        .{ @tagName(source), phase, @tagName(reason) },
    );
}

fn debugUsageFailure(phase: []const u8, err: anyerror) void {
    debug_trace.logf(
        "permission",
        "event=auto_review_usage result=permanent_failure phase={s} reason={s}",
        .{ phase, @errorName(err) },
    );
}

test "direct review unavailable diagnostics retain bounded reasons without credentials or provider payloads" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "review.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "permission");

    const Fake = struct {
        fn validate(_: Allocator, _: permission_auto_classifier.ProviderInput) !void {
            return error.InvalidAccount;
        }

        fn build(_: Allocator, _: stream_provider.RequestData) ![]u8 {
            return error.TestUnexpectedBuild;
        }

        fn send(_: Allocator, request: stream_provider.ModelRequest, payload: []const u8) !stream_provider.Result {
            try request.admission.admit();
            if (std.meta.stringToEnum(stream_provider.FailureKind, payload)) |kind| {
                return .{ .failed = .{
                    .kind = kind,
                    .detail = @constCast("private-provider-payload Bearer sk-private-credential\n" ** 256),
                } };
            }
            if (std.mem.eql(u8, payload, "timeout")) return error.Timeout;
            if (std.mem.eql(u8, payload, "cancelled")) return error.Cancelled;
            if (std.mem.eql(u8, payload, "unknown")) return error.@"private-provider-payload";
            return .{ .completed = .{ .completion = .{
                .content = "private-provider-payload" ** 256,
                .finish_reason = if (std.mem.eql(u8, payload, "filtered")) .content_filter else .provider_error,
            } } };
        }
    };
    const adapter = Adapter{
        .source = .openai_api_key,
        .model = "private-model",
        .require_account = true,
        .validate_fn = Fake.validate,
        .build_fn = Fake.build,
        .send_fn = Fake.send,
    };
    const request = permission_auto_classifier.ReviewRequest{
        .review_turn = .{
            .model = "test-model",
            .pending_assistant = .{ .role = .assistant },
            .target_call_id = "target",
            .origin = .root,
            .current_root_request = "Run this.",
        },
        .targets = &.{},
        .action = .{ .command = .{
            .command = "true",
            .resolved_cwd = "/tmp/workspace",
            .background = false,
            .target_os = .linux,
        } },
    };
    const inputs = [_]permission_auto_classifier.ProviderInput{
        .{},
        .{ .credential = "sk-private-credential" },
        .{ .credential = "sk-private-credential", .account_id = "private-account" },
    };
    for (inputs) |input| {
        try std.testing.expectEqual(.invalid, std.meta.activeTag(try review(alloc, input, request, adapter)));
    }

    var runtime = Runtime{
        .input = .{
            .credential = "sk-private-credential",
            .account_id = "private-account",
            .endpoint = "https://private-user:private-password@example.test/?key=private-query",
        },
        .adapter = adapter,
    };
    const cases = [_]struct {
        payload: []const u8,
        expected: std.meta.Tag(permission_auto_classifier.TransportOutcome),
    }{
        .{ .payload = "unauthorized", .expected = .permanent_failure },
        .{ .payload = "rate_limited", .expected = .transient_failure },
        .{ .payload = "timeout", .expected = .timed_out },
        .{ .payload = "cancelled", .expected = .cancelled },
        .{ .payload = "unknown", .expected = .transient_failure },
        .{ .payload = "filtered", .expected = .permanent_failure },
        .{ .payload = "completion_error", .expected = .transient_failure },
    };
    for (cases) |case| {
        var cancelled = std.atomic.Value(bool).init(false);
        const outcome = try sendReview(
            &runtime,
            alloc,
            adapter.model,
            case.payload,
            std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromSeconds(5) }),
            &cancelled,
        );
        try std.testing.expectEqual(case.expected, std.meta.activeTag(outcome));
    }

    debug_trace.shutdown();
    var trace_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), trace_path, .{});
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 8192);
    defer alloc.free(trace);
    for ([_][]const u8{
        "phase=validate reason=missing_credential",
        "phase=validate reason=missing_account",
        "phase=validate reason=invalid_account",
        "phase=response reason=unauthorized",
        "phase=response reason=rate_limited",
        "phase=transport reason=timed_out",
        "phase=transport reason=cancelled",
        "phase=transport reason=transport_error",
        "phase=completion reason=content_filter",
        "phase=completion reason=provider_error",
    }) |reason| {
        try std.testing.expect(std.mem.find(u8, trace, reason) != null);
    }
    try std.testing.expect(std.mem.find(u8, trace, "private-") == null);
    try std.testing.expect(std.mem.find(u8, trace, "Bearer") == null);
    var lines = std.mem.tokenizeScalar(u8, trace, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        try std.testing.expect(line.len < 256);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), count);
}

test "direct review exact usage settles through the session ledger" {
    const Fake = struct {
        fn validate(_: Allocator, _: permission_auto_classifier.ProviderInput) !void {}

        fn build(_: Allocator, _: stream_provider.RequestData) ![]u8 {
            return error.TestUnexpectedBuild;
        }

        fn send(
            _: Allocator,
            request: stream_provider.ModelRequest,
            _: []const u8,
        ) !stream_provider.Result {
            try std.testing.expectEqualStrings(
                "https://review.example.test/v1/responses",
                request.endpoint orelse return error.MissingProviderEndpoint,
            );
            try request.admission.admit();
            request.delivery.markPossiblySent();
            return .{ .completed = .{
                .completion = .{
                    .content = "clear",
                    .generation_id = "response-review-1",
                    .billing = .{
                        .created_at_ms = 1,
                        .model = "codex/gpt-review",
                        .total_cost = 0,
                        .input_tokens = 11,
                        .output_tokens = 3,
                        .cache_read_tokens = 0,
                        .cache_write_tokens = 0,
                        .reasoning_tokens = null,
                        .billable_web_search_calls = 0,
                    },
                    .finish_reason = .stop,
                },
                .usage = .{ .exact = .codex },
            } };
        }
    };

    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var runtime = Runtime{
        .input = .{
            .endpoint = "https://review.example.test/v1/responses",
            .usage = &usage,
            .usage_allocator = alloc,
        },
        .adapter = .{
            .source = .chatgpt_subscription,
            .model = "gpt-review",
            .validate_fn = Fake.validate,
            .build_fn = Fake.build,
            .send_fn = Fake.send,
        },
    };
    var cancelled = std.atomic.Value(bool).init(false);
    var outcome = try sendReview(
        &runtime,
        alloc,
        "gpt-review",
        "{}",
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromSeconds(5),
        }),
        &cancelled,
    );
    defer if (outcome == .completion) outcome.completion.deinit(alloc);

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 11), snapshot.input_tokens);
    try std.testing.expectEqual(@as(u64, 3), snapshot.output_tokens);
    try std.testing.expectEqual(@as(?u64, 1), snapshot.request_count);
}

test "direct review settles every post-admission outcome before projection" {
    const Fake = struct {
        fn validate(_: Allocator, _: permission_auto_classifier.ProviderInput) !void {}

        fn build(_: Allocator, _: stream_provider.RequestData) ![]u8 {
            return error.TestUnexpectedBuild;
        }

        fn exactCompletion() stream_provider.Result {
            return .{ .completed = .{
                .completion = .{
                    .generation_id = "response-review-outcome",
                    .billing = .{
                        .created_at_ms = 1,
                        .model = "codex/gpt-review",
                        .total_cost = 0,
                        .input_tokens = 11,
                        .output_tokens = 3,
                        .cache_read_tokens = 0,
                        .cache_write_tokens = 0,
                        .reasoning_tokens = null,
                        .billable_web_search_calls = 0,
                    },
                    .finish_reason = .stop,
                },
                .usage = .{ .exact = .codex },
            } };
        }

        fn send(
            _: Allocator,
            request: stream_provider.ModelRequest,
            payload: []const u8,
        ) !stream_provider.Result {
            try request.admission.admit();
            if (std.mem.eql(u8, payload, "cancelled")) {
                request.delivery.markPossiblySent();
                return error.Cancelled;
            }
            if (std.mem.eql(u8, payload, "timed_out")) {
                request.delivery.markPossiblySent();
                return error.Timeout;
            }
            if (std.mem.eql(u8, payload, "provider_failure")) {
                return .{ .failed = .{ .kind = .unauthorized } };
            }
            if (std.mem.eql(u8, payload, "malformed")) {
                return .{ .completed = .{
                    .completion = .{ .finish_reason = .stop },
                    .usage = .{ .unavailable = .possibly_billed },
                } };
            }
            if (std.mem.eql(u8, payload, "cancel_after_completion")) {
                request.cancel_flag.store(true, .seq_cst);
                return exactCompletion();
            }
            if (std.mem.eql(u8, payload, "provider_error")) {
                var result = exactCompletion();
                result.completed.completion.finish_reason = .provider_error;
                return result;
            }
            return error.TestUnexpectedPayload;
        }
    };

    const cases = [_]struct {
        payload: []const u8,
        outcome: std.meta.Tag(permission_auto_classifier.TransportOutcome),
        billing: session_usage.Availability,
        request_count: ?u64,
        publication_backlog: usize,
    }{
        .{ .payload = "cancelled", .outcome = .cancelled, .billing = .incomplete, .request_count = 0, .publication_backlog = 0 },
        .{ .payload = "timed_out", .outcome = .timed_out, .billing = .incomplete, .request_count = 0, .publication_backlog = 0 },
        .{ .payload = "provider_failure", .outcome = .permanent_failure, .billing = .complete, .request_count = 0, .publication_backlog = 0 },
        .{ .payload = "malformed", .outcome = .completion, .billing = .incomplete, .request_count = 0, .publication_backlog = 0 },
        .{ .payload = "cancel_after_completion", .outcome = .cancelled, .billing = .complete, .request_count = 1, .publication_backlog = 1 },
        .{ .payload = "provider_error", .outcome = .transient_failure, .billing = .complete, .request_count = 1, .publication_backlog = 1 },
    };

    for (cases) |case| {
        var usage = session_usage.Usage.initFresh();
        defer usage.deinit(std.testing.allocator);
        var runtime = Runtime{
            .input = .{ .usage = &usage, .usage_allocator = std.testing.allocator },
            .adapter = .{
                .source = .chatgpt_subscription,
                .model = "gpt-review",
                .validate_fn = Fake.validate,
                .build_fn = Fake.build,
                .send_fn = Fake.send,
            },
        };
        var cancelled = std.atomic.Value(bool).init(false);
        var outcome = try sendReview(
            &runtime,
            std.testing.allocator,
            "gpt-review",
            case.payload,
            std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
                .clock = .awake,
                .raw = .fromSeconds(5),
            }),
            &cancelled,
        );
        defer if (outcome == .completion) outcome.completion.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.outcome, std.meta.activeTag(outcome));

        var snapshot = try usage.snapshot(std.testing.allocator);
        defer snapshot.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.billing, snapshot.billing);
        try std.testing.expectEqual(case.request_count, snapshot.request_count);
        try std.testing.expectEqual(@as(u64, 2), snapshot.next_sequence);
        try std.testing.expectEqual(@as(u64, 1), snapshot.settled_through_sequence);
        try std.testing.expectEqual(
            case.publication_backlog,
            snapshot.publication_backlog.len,
        );
    }
}
