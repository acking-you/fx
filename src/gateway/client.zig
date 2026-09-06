const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const chatgpt_oauth = @import("../core/auth/chatgpt_oauth.zig");
const oauth_transport = @import("../core/auth/oauth_transport.zig");
const secret = @import("../core/auth/secret.zig");
const agent_stream_provider = @import("../core/agent/stream_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const provider_route = @import("../core/gateway/provider_route.zig");
const responses_compaction_binding = @import("../core/gateway/responses_compaction_binding.zig");
const responses_protocol = @import("../core/gateway/responses_protocol.zig");
const responses_stream = @import("responses_stream.zig");

const max_provider_error_body_bytes: usize = 1024 * 1024;

pub fn isRetryableGatewayError(err: anyerror) bool {
    return err == error.HttpConnectionClosing or
        err == error.ConnectionResetByPeer or
        err == error.ConnectionTimedOut;
}

pub fn networkFailureEvidence(
    err: anyerror,
    delivery: DeliveryCertainty.State,
) ?agent_stream_provider.NetworkFailureEvidence {
    const cause: agent_stream_provider.NetworkFailureCause = if (err == error.SystemResumed)
        .system_resumed
    else if (isRetryableAgentNetworkError(err))
        .transport_interrupted
    else
        return null;
    return .{ .cause = cause, .delivery = delivery };
}

fn isRetryableAgentNetworkError(err: anyerror) bool {
    return err == error.TlsInitializationFailed or
        err == error.ConnectionSetupTimedOut or
        err == error.UnknownHostName or
        err == error.NameServerFailure or
        err == error.NoAddressReturned or
        err == error.DetectingNetworkConfigurationFailed or
        err == error.AddressUnavailable or
        err == error.ConnectionPending or
        err == error.ConnectionRefused or
        err == error.HostUnreachable or
        err == error.NetworkUnreachable or
        err == error.NetworkDown or
        err == error.Timeout or
        err == error.WouldBlock or
        err == error.WriteFailed or
        err == error.ReadFailed or
        err == error.ResponsesStreamEndedEarly or
        isRetryableGatewayError(err);
}

fn connectedIoFailure(
    cancelled: bool,
    system_resumed: bool,
    transport_error: anyerror,
) anyerror {
    if (cancelled) return error.Cancelled;
    if (system_resumed) return error.SystemResumed;
    return transport_error;
}

fn connectedIoFailureWithWatch(
    watch: ?*ConnectedRequestWatch,
    cancelled: bool,
    system_resumed: bool,
    transport_error: anyerror,
) anyerror {
    const mapped = connectedIoFailure(cancelled, system_resumed, transport_error);
    return if (watch) |state| state.finish_error(mapped) else mapped;
}

test "connected request failures prefer cancellation then wake evidence" {
    try std.testing.expectEqual(
        error.Cancelled,
        connectedIoFailure(true, true, error.WriteFailed),
    );
    try std.testing.expectEqual(
        error.SystemResumed,
        connectedIoFailure(false, true, error.WriteFailed),
    );
    try std.testing.expectEqual(
        error.WriteFailed,
        connectedIoFailure(false, false, error.WriteFailed),
    );
}

test "isRetryableGatewayError matches active retryable transport errors" {
    try std.testing.expect(isRetryableGatewayError(error.HttpConnectionClosing));
    try std.testing.expect(isRetryableGatewayError(error.ConnectionResetByPeer));
    try std.testing.expect(isRetryableGatewayError(error.ConnectionTimedOut));
    try std.testing.expect(!isRetryableGatewayError(error.AccessDenied));
}

test "native network failure evidence covers setup send read and resume failures" {
    const Cases = struct {
        err: anyerror,
        cause: agent_stream_provider.NetworkFailureCause = .transport_interrupted,
    };
    const cases = [_]Cases{
        .{ .err = error.TlsInitializationFailed },
        .{ .err = error.ConnectionSetupTimedOut },
        .{ .err = error.UnknownHostName },
        .{ .err = error.NameServerFailure },
        .{ .err = error.NoAddressReturned },
        .{ .err = error.DetectingNetworkConfigurationFailed },
        .{ .err = error.AddressUnavailable },
        .{ .err = error.ConnectionPending },
        .{ .err = error.ConnectionRefused },
        .{ .err = error.ConnectionResetByPeer },
        .{ .err = error.ConnectionTimedOut },
        .{ .err = error.HostUnreachable },
        .{ .err = error.NetworkUnreachable },
        .{ .err = error.NetworkDown },
        .{ .err = error.Timeout },
        .{ .err = error.WouldBlock },
        .{ .err = error.HttpConnectionClosing },
        .{ .err = error.WriteFailed },
        .{ .err = error.ReadFailed },
        .{ .err = error.ResponsesStreamEndedEarly },
        .{ .err = error.SystemResumed, .cause = .system_resumed },
    };

    for (cases) |case| {
        const evidence = networkFailureEvidence(
            case.err,
            .possibly_sent,
        ) orelse return error.TestExpectedNetworkFailureEvidence;
        try std.testing.expectEqual(case.cause, evidence.cause);
        try std.testing.expectEqual(
            DeliveryCertainty.State.possibly_sent,
            evidence.delivery,
        );
    }

    const pre_send = networkFailureEvidence(
        error.ConnectionRefused,
        .definitely_unsent,
    ).?;
    try std.testing.expectEqual(
        DeliveryCertainty.State.definitely_unsent,
        pre_send.delivery,
    );
}

test "native network failure evidence excludes opaque and configuration failures" {
    const excluded = [_]anyerror{
        error.JsHostStreamFailed,
        error.OutOfMemory,
        error.AccessDenied,
        error.UnsupportedUriScheme,
        error.ProtocolUnsupportedBySystem,
        error.ResolvConfParseFailed,
        error.InvalidDnsARecord,
    };

    for (excluded) |err| {
        try std.testing.expectEqual(
            @as(?agent_stream_provider.NetworkFailureEvidence, null),
            networkFailureEvidence(err, .definitely_unsent),
        );
    }
}

const HttpResult = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *HttpResult, alloc: std.mem.Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

pub const PostResult = HttpResult;
pub const GetResult = HttpResult;

pub const CodexJsonMethod = enum {
    get,
    post_json,
};

/// One bounded JSON request against the ChatGPT Codex account origin. The
/// access token and account id are checked against the same stored credential
/// before any bytes are sent; FedRAMP and originator headers are derived from
/// that exact identity inside the transport.
pub const CodexJsonRequest = struct {
    method: CodexJsonMethod,
    url: []const u8,
    access_token: []const u8,
    account_id: []const u8,
    payload: ?[]const u8 = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    deadline: ?std.Io.Clock.Timestamp = null,
    max_response_bytes: usize = 512 * 1024,
};

/// One bounded JSON POST against an OpenAI Responses endpoint. Organization
/// and project headers are derived inside the transport from the same route
/// policy used by streaming requests.
pub const OpenAIJsonRequest = struct {
    url: []const u8,
    api_key: []const u8,
    payload: []const u8,
    /// Exact identity snapshot paired with the request body. Explicit nulls
    /// mean no header; compact transport must not reread mutable environment
    /// state after its checkpoint binding was constructed.
    organization: ?[]const u8 = null,
    project: ?[]const u8 = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    deadline: ?std.Io.Clock.Timestamp = null,
    max_response_bytes: usize = 512 * 1024,
};

pub const GatewayJsonResult = union(enum) {
    /// Owned response body; the caller frees it with the request allocator.
    success: []u8,
    http_status: std.http.Status,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        switch (self.*) {
            .success => |body| alloc.free(body),
            .http_status => {},
        }
        self.* = undefined;
    }
};

pub const StreamCallback = agent_stream_provider.StreamCallback;
pub const ToolStartCallback = agent_stream_provider.ToolStartCallback;
pub const ProviderToolDoneCallback = agent_stream_provider.ProviderToolDoneCallback;
pub const ProviderToolStartCallback = agent_stream_provider.ProviderToolStartCallback;

const gateway_retry_base_delay_ns: u64 = 150 * std.time.ns_per_ms;
const gateway_connection_setup_timeout_ms: i64 = 30_000;
const gateway_retry_after_max_ns: u64 = 5 * std.time.ns_per_s;
const gateway_transfer_buffer_bytes: usize = 256 * 1024;
const provider_failure_detail_max_bytes: usize = 600;
const codex_json_request_timeout_ms: i64 = 15_000;
/// Identifies fx on provider requests; the zig std.http default is never sent.
pub const user_agent = "fx/" ++ build_options.app_version;
var test_cancel_watcher_spawn_error: ?anyerror = null;

pub const StreamResult = struct {
    status: std.http.Status,
    completion: types.ModelCompletion = .{},
    err_body: ?[]u8 = null,
    retry_after_seconds: ?u64 = null,

    /// Frees all owned response buffers allocated for this stream result.
    pub fn deinit(self: *StreamResult, alloc: std.mem.Allocator) void {
        if (self.err_body) |body| alloc.free(body);
        if (self.completion.content) |content| alloc.free(content);
        if (self.completion.reasoning) |reasoning| alloc.free(@constCast(reasoning));
        if (self.completion.reasoning_signature) |signature| alloc.free(@constCast(signature));
        if (self.completion.reasoning_item_id) |id| alloc.free(@constCast(id));
        if (self.completion.reasoning_encrypted_content) |content| alloc.free(@constCast(content));
        types.freeResponsesReasoningItems(alloc, self.completion.reasoning_items);
        types.freeResponsesProviderOutputItems(alloc, self.completion.responses_provider_output_items);
        types.freeResponsesUrlCitations(alloc, self.completion.url_citations);
        if (self.completion.generation_id) |id| alloc.free(id);
        if (self.completion.billing) |billing| alloc.free(@constCast(billing.model));
        for (self.completion.tool_calls) |call| {
            alloc.free(call.id);
            alloc.free(call.name);
            alloc.free(call.arguments_json);
            if (call.provisional_id) |provisional_id| alloc.free(provisional_id);
            if (call.provider_result) |provider_result| alloc.free(provider_result);
        }
        if (self.completion.tool_calls.len > 0) alloc.free(self.completion.tool_calls);
        if (self.completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
        const status = self.status;
        self.* = .{ .status = status };
    }
};

/// Possibly-sent model requests are retried by the agent so transport retries
/// cannot multiply the logical response budget. Other gateway consumers keep
/// their existing bounded transport retry behavior.
pub const ProviderAttemptOwner = enum {
    transport,
    agent,
};

pub fn fetchCodexJsonBounded(
    alloc: std.mem.Allocator,
    request: CodexJsonRequest,
) !GetResult {
    switch (request.method) {
        .get => if (request.payload != null) return error.UnexpectedCodexJsonPayload,
        .post_json => if (request.payload == null) return error.MissingCodexJsonPayload,
    }
    if (request.account_id.len == 0) return error.CodexCredentialChanged;

    var local_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = request.cancel_flag orelse &local_cancel;
    var operation = CodexJsonOperation{
        .alloc = alloc,
        .request = request,
        .cancel_flag = cancel_flag,
    };
    return runBoundedHttpOperation(
        GetResult,
        alloc,
        cancel_flag,
        request.deadline orelse std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(codex_json_request_timeout_ms),
        }),
        &operation,
    );
}

pub fn fetchOpenAIJsonBounded(
    alloc: std.mem.Allocator,
    request: OpenAIJsonRequest,
) !GetResult {
    if (request.api_key.len == 0) return error.MissingOpenAIApiKey;
    var local_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = request.cancel_flag orelse &local_cancel;
    var operation = OpenAIJsonOperation{
        .alloc = alloc,
        .request = request,
        .cancel_flag = cancel_flag,
    };
    return runBoundedHttpOperation(
        GetResult,
        alloc,
        cancel_flag,
        request.deadline orelse std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(codex_json_request_timeout_ms),
        }),
        &operation,
    );
}

const CodexJsonOperation = struct {
    alloc: std.mem.Allocator,
    request: CodexJsonRequest,
    cancel_flag: *std.atomic.Value(bool),

    fn run(self: *@This()) !GetResult {
        if (self.cancel_flag.load(.seq_cst)) return error.Cancelled;
        var identity = try loadCodexRequestIdentity(
            self.alloc,
            self.request.access_token,
            self.request.account_id,
        );
        defer identity.deinit(self.alloc);

        return executeProviderJsonBounded(self.alloc, .{
            .route = .codex_responses_oauth,
            .method = self.request.method,
            .url = self.request.url,
            .credential = self.request.access_token,
            .account_id = identity.account_id,
            .fedramp = false,
            .payload = self.request.payload,
            .cancel_flag = self.cancel_flag,
            .max_response_bytes = self.request.max_response_bytes,
            .response_too_large_error = error.CodexJsonResponseTooLarge,
        });
    }
};

const OpenAIJsonOperation = struct {
    alloc: std.mem.Allocator,
    request: OpenAIJsonRequest,
    cancel_flag: *std.atomic.Value(bool),

    fn run(self: *@This()) !GetResult {
        return executeProviderJsonBounded(self.alloc, .{
            .route = .openai_responses_byok,
            .method = .post_json,
            .url = self.request.url,
            .credential = self.request.api_key,
            .payload = self.request.payload,
            .openai_identity = .{
                .organization = self.request.organization,
                .project = self.request.project,
            },
            .cancel_flag = self.cancel_flag,
            .max_response_bytes = self.request.max_response_bytes,
            .response_too_large_error = error.OpenAIJsonResponseTooLarge,
        });
    }
};

const ProviderJsonOperationInput = struct {
    route: provider_route.ProviderRoute,
    method: CodexJsonMethod,
    url: []const u8,
    credential: []const u8,
    account_id: ?[]const u8 = null,
    fedramp: bool = false,
    openai_identity: ?OpenAIIdentityHeaders = null,
    payload: ?[]const u8 = null,
    cancel_flag: *std.atomic.Value(bool),
    max_response_bytes: usize,
    response_too_large_error: anyerror,
};

fn executeProviderJsonBounded(
    alloc: std.mem.Allocator,
    input: ProviderJsonOperationInput,
) !GetResult {
    if (input.cancel_flag.load(.seq_cst)) return error.Cancelled;

    try provider_route.validateBaseUrl(input.url);
    const uri = try std.Uri.parse(input.url);
    const auth_header = try std.fmt.allocPrint(
        alloc,
        "Bearer {s}",
        .{input.credential},
    );
    defer secret.zeroAndFree(alloc, auth_header);

    var client: std.http.Client = .{
        .allocator = alloc,
        .io = io_mod.getIo(),
    };
    defer client.deinit();

    var extra_headers_buf: [8]std.http.Header = undefined;
    const extra_headers = providerJsonExtraHeaders(
        &extra_headers_buf,
        input.route,
        input.account_id,
        input.fedramp,
        input.openai_identity,
    );
    var req = try client.request(switch (input.method) {
        .get => .GET,
        .post_json => .POST,
    }, uri, .{
        .headers = .{
            .authorization = .{ .override = auth_header },
            .content_type = switch (input.method) {
                .get => .default,
                .post_json => .{ .override = "application/json" },
            },
            .accept_encoding = .omit,
            .user_agent = .{ .override = user_agent },
        },
        .extra_headers = extra_headers,
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();
    if (input.cancel_flag.load(.seq_cst)) return error.Cancelled;

    switch (input.method) {
        .get => {
            try req.sendBodiless();
            if (req.connection) |conn| try conn.flush();
        },
        .post_json => try req.sendBodyComplete(@constCast(input.payload.?)),
    }
    if (input.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = try req.receiveHead(&.{});
    if (input.cancel_flag.load(.seq_cst)) return error.Cancelled;
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const body = response.reader(&transfer_buffer).allocRemaining(
        alloc,
        .limited(input.max_response_bytes),
    ) catch |err| switch (err) {
        error.StreamTooLong => return input.response_too_large_error,
        else => return err,
    };
    if (input.cancel_flag.load(.seq_cst)) {
        alloc.free(body);
        return error.Cancelled;
    }
    return .{ .status = response.head.status, .body = body };
}

pub fn fetchProviderJson(
    alloc: std.mem.Allocator,
    source: types.CredentialSource,
    api_key: []const u8,
    url: []const u8,
) !GatewayJsonResult {
    var cancel_flag = std.atomic.Value(bool).init(false);
    return fetchProviderJsonAtUrlCore(alloc, api_key, source, url, &cancel_flag);
}

pub fn fetchProviderJsonCancellable(
    alloc: std.mem.Allocator,
    source: types.CredentialSource,
    api_key: []const u8,
    url: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !GatewayJsonResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    var operation = GatewayJsonFetchOperation{
        .alloc = alloc,
        .api_key = api_key,
        .credential_source = source,
        .url = url,
        .cancel_flag = cancel_flag,
    };
    return runCancellableGatewayJsonFetch(alloc, cancel_flag, &operation);
}

const GatewayJsonFetchOperation = struct {
    alloc: std.mem.Allocator,
    api_key: []const u8,
    credential_source: types.CredentialSource,
    url: []const u8,
    cancel_flag: *std.atomic.Value(bool),

    fn run(self: *@This()) !GatewayJsonResult {
        return fetchProviderJsonAtUrlCore(
            self.alloc,
            self.api_key,
            self.credential_source,
            self.url,
            self.cancel_flag,
        );
    }
};

fn runCancellableGatewayJsonFetch(
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    operation: *GatewayJsonFetchOperation,
) !GatewayJsonResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    const Event = union(enum) {
        request: anyerror!GatewayJsonResult,
        cancelled: anyerror!void,
    };
    const Runner = struct {
        fn run(value: *GatewayJsonFetchOperation) anyerror!GatewayJsonResult {
            return value.run();
        }
    };
    const Cleanup = struct {
        fn drain(result_alloc: std.mem.Allocator, select: *std.Io.Select(Event)) void {
            while (select.cancel()) |item| switch (item) {
                .request => |request_result| {
                    var late_result = request_result catch continue;
                    late_result.deinit(result_alloc);
                },
                .cancelled => {},
            };
        }
    };

    var select_buffer: [2]Event = undefined;
    var select: std.Io.Select(Event) = .init(io_mod.getIo(), &select_buffer);
    select.concurrent(.cancelled, waitForBoundedCancellation, .{cancel_flag}) catch |err| return err;
    select.concurrent(.request, Runner.run, .{operation}) catch |err| {
        select.cancelDiscard();
        return err;
    };

    const event = select.await() catch |err| {
        Cleanup.drain(alloc, &select);
        return err;
    };
    switch (event) {
        .request => |request_result| {
            Cleanup.drain(alloc, &select);
            if (cancel_flag.load(.seq_cst)) {
                var result = request_result catch return error.Cancelled;
                result.deinit(alloc);
                return error.Cancelled;
            }
            return request_result;
        },
        .cancelled => |cancel_result| {
            cancel_result catch |err| {
                Cleanup.drain(alloc, &select);
                return err;
            };
            Cleanup.drain(alloc, &select);
            return error.Cancelled;
        },
    }
}

fn fetchProviderJsonAtUrlCore(
    alloc: std.mem.Allocator,
    api_key: []const u8,
    credential_source: types.CredentialSource,
    url: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !GatewayJsonResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    const route = provider_route.fromCredentialSource(credential_source) orelse
        return error.UnsupportedCredentialSource;
    var codex_identity: ?chatgpt_oauth.Access = null;
    defer if (codex_identity) |*identity| identity.deinit(alloc);
    if (route == .codex_responses_oauth) {
        codex_identity = try loadCodexRequestIdentity(
            alloc,
            api_key,
            null,
        );
    }

    var auth_header: ?[]u8 = null;
    defer if (auth_header) |value| secret.zeroAndFree(alloc, value);

    var headers: std.http.Client.Request.Headers = .{};
    headers.accept_encoding = .omit;
    headers.user_agent = .{ .override = user_agent };
    auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{api_key});
    headers.authorization = .{ .override = auth_header.? };
    var extra_headers_buf: [8]std.http.Header = undefined;
    const extra_headers = providerJsonExtraHeaders(
        &extra_headers_buf,
        route,
        if (codex_identity) |identity| identity.account_id else null,
        false,
        null,
    );

    var req = client.request(.GET, uri, .{
        .headers = headers,
        .extra_headers = extra_headers,
        .redirect_behavior = .unhandled,
    }) catch |err| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        return err;
    };
    defer req.deinit();
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const cancel_watcher = if (req.connection) |conn|
        try spawn_gateway_cancel_watcher(&cancel_watch_done, cancel_flag, null, null, null, conn.stream_writer.stream)
    else
        null;
    defer {
        cancel_watch_done.store(true, .seq_cst);
        if (cancel_watcher) |thread| thread.join();
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    req.sendBodiless() catch |err| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        return err;
    };
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (req.connection) |conn| {
        conn.flush() catch |err| {
            if (cancel_flag.load(.seq_cst)) return error.Cancelled;
            return err;
        };
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = req.receiveHead(&.{}) catch |err| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        return err;
    };
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (failedGatewayJsonStatus(response.head.status)) |status| return .{ .http_status = status };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var transfer_buffer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    _ = reader.streamRemaining(&out.writer) catch |err| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        return err;
    };
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    return .{ .success = try out.toOwnedSlice() };
}

fn loadCodexRequestIdentity(
    alloc: std.mem.Allocator,
    expected_access_token: []const u8,
    expected_account_id: ?[]const u8,
) !chatgpt_oauth.Access {
    var identity = (try chatgpt_oauth.loadAccess(alloc, oauth_transport.unavailable_provider, .stored)) orelse
        return error.CodexCredentialUnavailable;
    errdefer identity.deinit(alloc);
    if (!std.mem.eql(u8, identity.access_token, expected_access_token)) {
        return error.CodexCredentialChanged;
    }
    if (expected_account_id) |account_id| {
        if (account_id.len == 0 or !std.mem.eql(u8, identity.account_id, account_id)) {
            return error.CodexCredentialChanged;
        }
    }
    return identity;
}

fn failedGatewayJsonStatus(status: std.http.Status) ?std.http.Status {
    return if (status == .ok) null else status;
}

test "gateway JSON transport preserves non-success HTTP status" {
    try std.testing.expect(failedGatewayJsonStatus(.ok) == null);
    try std.testing.expectEqual(std.http.Status.unauthorized, failedGatewayJsonStatus(.unauthorized).?);
    try std.testing.expectEqual(std.http.Status.too_many_requests, failedGatewayJsonStatus(.too_many_requests).?);
    try std.testing.expectEqual(std.http.Status.service_unavailable, failedGatewayJsonStatus(.service_unavailable).?);
}

test "bounded Codex JSON transport validates method and payload before auth" {
    try std.testing.expectError(error.UnexpectedCodexJsonPayload, fetchCodexJsonBounded(
        std.testing.allocator,
        .{
            .method = .get,
            .url = "https://chatgpt.com/backend-api/wham/usage",
            .access_token = "access",
            .account_id = "account",
            .payload = "{}",
        },
    ));
    try std.testing.expectError(error.MissingCodexJsonPayload, fetchCodexJsonBounded(
        std.testing.allocator,
        .{
            .method = .post_json,
            .url = "https://chatgpt.com/backend-api/codex/responses/compact",
            .access_token = "access",
            .account_id = "account",
        },
    ));
}

/// Monotonic request-delivery evidence. It becomes possibly sent before the
/// first body write so any later transport failure is treated as potentially billed.
pub const DeliveryCertainty = agent_stream_provider.DeliveryCertainty;

const ConnectionSetupOutcome = union(enum) {
    request_succeeded,
    request_failed: anyerror,
};

const ConnectionSetupAction = union(enum) {
    succeed,
    retry,
    fail: anyerror,
    cancelled,
};

const ConnectionSetupSnapshot = struct {
    attempt: usize,
    attempt_limit: usize,
    now: std.Io.Clock.Timestamp,
    deadline: std.Io.Clock.Timestamp,
    cancelled: bool,
    delivery: DeliveryCertainty.State,
    outcome: ConnectionSetupOutcome,
};

const ConnectionSetupDecision = struct {
    action: ConnectionSetupAction,
};

fn decideConnectionSetup(snapshot: ConnectionSetupSnapshot) ConnectionSetupDecision {
    if (snapshot.cancelled) return .{ .action = .cancelled };
    if (!std.Io.Clock.Timestamp.compare(snapshot.now, .lt, snapshot.deadline)) {
        return .{ .action = .{ .fail = error.ConnectionSetupTimedOut } };
    }

    return switch (snapshot.outcome) {
        .request_succeeded => .{ .action = .succeed },
        .request_failed => |err| if (isRetryableConnectionSetupError(err) and
            snapshot.delivery == .definitely_unsent and
            snapshot.attempt < snapshot.attempt_limit)
            .{ .action = .retry }
        else
            .{ .action = .{ .fail = err } },
    };
}

fn isRetryableConnectionSetupError(err: anyerror) bool {
    return err == error.TlsInitializationFailed or isRetryableGatewayError(err);
}

const ConnectionSetupTiming = struct {
    timeout_ms: i64 = gateway_connection_setup_timeout_ms,
};

const ResponseHeadTiming = struct {
    timeout_ms: i64 = 30_000,
};

test "connection setup keeps the production timeout" {
    const timing = ConnectionSetupTiming{};

    try std.testing.expectEqual(@as(i64, 30_000), timing.timeout_ms);
}

test "response head wait keeps the production timeout" {
    const timing = ResponseHeadTiming{};

    try std.testing.expectEqual(@as(i64, 30_000), timing.timeout_ms);
}

const ConnectionSetupEpoch = struct {
    deadline: std.Io.Clock.Timestamp,

    fn init(timing: ConnectionSetupTiming) ConnectionSetupEpoch {
        const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        return .{
            .deadline = .{
                .clock = .awake,
                .raw = started.raw.addDuration(.fromMilliseconds(timing.timeout_ms)),
            },
        };
    }
};

const RequestOpenOverride = struct {
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        client: *std.http.Client,
        method: std.http.Method,
        uri: std.Uri,
        options: std.http.Client.RequestOptions,
    ) anyerror!std.http.Client.Request,
};

const StreamCoreOptions = struct {
    setup_timing: ConnectionSetupTiming = .{},
    response_head_timing: ResponseHeadTiming = .{},
    request_open_override: ?RequestOpenOverride = null,
};

const ConnectedRequestWatch = struct {
    const Phase = enum(u8) {
        sending,
        awaiting_head,
        streaming,
        completed,
        timed_out,
        cancelled,
        system_resumed,
    };

    phase: std.atomic.Value(Phase) = .init(.sending),
    response_head_deadline: std.Io.Clock.Timestamp = undefined,
    timing: ResponseHeadTiming,

    fn init(timing: ResponseHeadTiming) ConnectedRequestWatch {
        return .{ .timing = timing };
    }

    fn arm_response_head(self: *ConnectedRequestWatch) ?anyerror {
        self.response_head_deadline = std.Io.Clock.Timestamp.fromNow(
            io_mod.getIo(),
            .{
                .clock = .awake,
                .raw = .fromMilliseconds(self.timing.timeout_ms),
            },
        );
        if (self.phase.cmpxchgStrong(
            .sending,
            .awaiting_head,
            .seq_cst,
            .seq_cst,
        )) |winner| return phase_error(winner);
        return null;
    }

    fn commit_response_head(self: *ConnectedRequestWatch) ?anyerror {
        if (self.phase.cmpxchgStrong(
            .awaiting_head,
            .streaming,
            .seq_cst,
            .seq_cst,
        )) |winner| return phase_error(winner);
        return null;
    }

    fn finish(self: *ConnectedRequestWatch) ?anyerror {
        var current = self.phase.load(.seq_cst);
        while (is_active(current)) {
            if (self.phase.cmpxchgWeak(
                current,
                .completed,
                .seq_cst,
                .seq_cst,
            )) |observed| {
                current = observed;
                continue;
            }
            return null;
        }
        return phase_error(current);
    }

    fn finish_error(
        self: *ConnectedRequestWatch,
        transport_error: anyerror,
    ) anyerror {
        return self.finish() orelse transport_error;
    }

    fn win(self: *ConnectedRequestWatch, winner: Phase) bool {
        std.debug.assert(!is_active(winner));
        std.debug.assert(winner != .completed);
        var current = self.phase.load(.seq_cst);
        while (is_active(current)) {
            if (self.phase.cmpxchgWeak(
                current,
                winner,
                .seq_cst,
                .seq_cst,
            )) |observed| {
                current = observed;
                continue;
            }
            return true;
        }
        return false;
    }

    fn win_response_head_timeout(self: *ConnectedRequestWatch) bool {
        return self.phase.cmpxchgStrong(
            .awaiting_head,
            .timed_out,
            .seq_cst,
            .seq_cst,
        ) == null;
    }

    fn response_head_expired(
        self: *const ConnectedRequestWatch,
        now: std.Io.Clock.Timestamp,
    ) bool {
        if (self.phase.load(.seq_cst) != .awaiting_head) return false;
        return !std.Io.Clock.Timestamp.compare(
            now,
            .lt,
            self.response_head_deadline,
        );
    }

    fn is_active(phase: Phase) bool {
        return switch (phase) {
            .sending, .awaiting_head, .streaming => true,
            .completed, .timed_out, .cancelled, .system_resumed => false,
        };
    }

    fn phase_error(phase: Phase) ?anyerror {
        return switch (phase) {
            .timed_out => error.Timeout,
            .cancelled => error.Cancelled,
            .system_resumed => error.SystemResumed,
            .sending, .awaiting_head, .streaming, .completed => null,
        };
    }
};

const RequestOpenOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    options: std.http.Client.RequestOptions,
    request_open_override: ?RequestOpenOverride,

    fn run(self: *@This()) anyerror!std.http.Client.Request {
        if (self.request_open_override) |request_open| {
            return request_open.run(
                request_open.ctx,
                self.client,
                .POST,
                self.uri,
                self.options,
            );
        }
        return self.client.request(.POST, self.uri, self.options);
    }
};

fn openGatewayRequestBounded(
    client: *std.http.Client,
    uri: std.Uri,
    options: std.http.Client.RequestOptions,
    request_open_override: ?RequestOpenOverride,
    epoch: *ConnectionSetupEpoch,
    cancel_flag: *std.atomic.Value(bool),
) anyerror!std.http.Client.Request {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    if (!std.Io.Clock.Timestamp.compare(now, .lt, epoch.deadline)) {
        return error.ConnectionSetupTimedOut;
    }

    const Event = union(enum) {
        request: anyerror!std.http.Client.Request,
        cancelled: anyerror!void,
        deadline: anyerror!void,
    };
    const Cleanup = struct {
        fn drain(select: *std.Io.Select(Event)) void {
            while (select.cancel()) |item| switch (item) {
                .request => |request_result| {
                    var late_request = request_result catch continue;
                    late_request.deinit();
                },
                .cancelled, .deadline => {},
            };
        }
    };

    var operation = RequestOpenOperation{
        .client = client,
        .uri = uri,
        .options = options,
        .request_open_override = request_open_override,
    };
    var select_buffer: [3]Event = undefined;
    var select: std.Io.Select(Event) = .init(io_mod.getIo(), &select_buffer);
    select.concurrent(.cancelled, waitForBoundedCancellation, .{cancel_flag}) catch |err| return err;
    select.concurrent(.deadline, waitForBoundedDeadline, .{epoch.deadline}) catch |err| {
        select.cancelDiscard();
        return err;
    };
    select.concurrent(.request, RequestOpenOperation.run, .{&operation}) catch |err| {
        select.cancelDiscard();
        return err;
    };

    while (true) {
        const event = select.await() catch |err| {
            Cleanup.drain(&select);
            return err;
        };
        switch (event) {
            .request => |request_result| {
                Cleanup.drain(&select);
                if (cancel_flag.load(.seq_cst)) {
                    var cancelled_request = request_result catch return error.Cancelled;
                    cancelled_request.deinit();
                    return error.Cancelled;
                }

                var owned_request = request_result catch |request_err| return request_err;
                const result_now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
                if (!std.Io.Clock.Timestamp.compare(result_now, .lt, epoch.deadline)) {
                    owned_request.deinit();
                    return error.ConnectionSetupTimedOut;
                }
                return owned_request;
            },
            .cancelled => |cancelled_result| {
                cancelled_result catch |err| {
                    Cleanup.drain(&select);
                    return err;
                };
                Cleanup.drain(&select);
                return error.Cancelled;
            },
            .deadline => |deadline_result| {
                deadline_result catch |err| {
                    Cleanup.drain(&select);
                    return err;
                };
                Cleanup.drain(&select);
                if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                return error.ConnectionSetupTimedOut;
            },
        }
    }
}

fn sleepGatewaySetupRetry(
    delay_ns: u64,
    epoch: *ConnectionSetupEpoch,
    cancel_flag: *std.atomic.Value(bool),
) anyerror!void {
    const retry_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromNanoseconds(@intCast(delay_ns)),
    });

    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        if (!std.Io.Clock.Timestamp.compare(now, .lt, epoch.deadline)) {
            return error.ConnectionSetupTimedOut;
        }
        if (!std.Io.Clock.Timestamp.compare(now, .lt, retry_deadline)) return;

        var sleep_ns: i96 = 10 * std.time.ns_per_ms;
        sleep_ns = @min(sleep_ns, now.raw.durationTo(retry_deadline.raw).toNanoseconds());
        sleep_ns = @min(sleep_ns, now.raw.durationTo(epoch.deadline.raw).toNanoseconds());
        if (sleep_ns <= 0) continue;
        try io_mod.getIo().sleep(.fromNanoseconds(sleep_ns), .awake);
    }
}

fn testAwakeTimestamp(milliseconds: i64) std.Io.Clock.Timestamp {
    return .{
        .clock = .awake,
        .raw = .fromNanoseconds(@as(i96, milliseconds) * std.time.ns_per_ms),
    };
}

fn expectConnectionSetupActionTag(
    expected: std.meta.Tag(ConnectionSetupAction),
    action: ConnectionSetupAction,
) !void {
    try std.testing.expectEqual(expected, std.meta.activeTag(action));
}

test "connection setup policy makes cancellation absorbing" {
    const outcomes = [_]ConnectionSetupOutcome{
        .request_succeeded,
        .{ .request_failed = error.TlsInitializationFailed },
    };
    for (outcomes) |outcome| {
        const decision = decideConnectionSetup(.{
            .attempt = 1,
            .attempt_limit = 3,
            .now = testAwakeTimestamp(10),
            .deadline = testAwakeTimestamp(30_000),
            .cancelled = true,
            .delivery = .definitely_unsent,
            .outcome = outcome,
        });
        try expectConnectionSetupActionTag(.cancelled, decision.action);
    }
}

test "connection setup policy bounds retry by deadline attempts and delivery" {
    const retry = decideConnectionSetup(.{
        .attempt = 1,
        .attempt_limit = 3,
        .now = testAwakeTimestamp(10),
        .deadline = testAwakeTimestamp(30_000),
        .cancelled = false,
        .delivery = .definitely_unsent,
        .outcome = .{ .request_failed = error.TlsInitializationFailed },
    });
    try expectConnectionSetupActionTag(.retry, retry.action);

    const exhausted = decideConnectionSetup(.{
        .attempt = 3,
        .attempt_limit = 3,
        .now = testAwakeTimestamp(10),
        .deadline = testAwakeTimestamp(30_000),
        .cancelled = false,
        .delivery = .definitely_unsent,
        .outcome = .{ .request_failed = error.TlsInitializationFailed },
    });
    try expectConnectionSetupActionTag(.fail, exhausted.action);

    const possibly_sent = decideConnectionSetup(.{
        .attempt = 1,
        .attempt_limit = 3,
        .now = testAwakeTimestamp(10),
        .deadline = testAwakeTimestamp(30_000),
        .cancelled = false,
        .delivery = .possibly_sent,
        .outcome = .{ .request_failed = error.TlsInitializationFailed },
    });
    try expectConnectionSetupActionTag(.fail, possibly_sent.action);

    const timed_out = decideConnectionSetup(.{
        .attempt = 1,
        .attempt_limit = 3,
        .now = testAwakeTimestamp(30_000),
        .deadline = testAwakeTimestamp(30_000),
        .cancelled = false,
        .delivery = .definitely_unsent,
        .outcome = .{ .request_failed = error.TlsInitializationFailed },
    });
    try expectConnectionSetupActionTag(.fail, timed_out.action);
    switch (timed_out.action) {
        .fail => |err| try std.testing.expectEqual(error.ConnectionSetupTimedOut, err),
        else => return error.TestExpectedConnectionTimeout,
    }
}

pub const StreamRequest = struct {
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    /// Exact non-secret provider identity paired with `payload`. When set,
    /// direct Responses transport must not reread endpoint or OpenAI identity
    /// headers from mutable environment state.
    responses_compaction_binding: ?types.ResponsesCompactionProviderBindingView = null,
    model: []const u8,
    retry_count: usize,
    chat_url: []const u8,
    payload: []const u8,
    /// Borrowed until `streamGatewayCompletion` returns.
    session_id: ?[]const u8 = null,
    /// Comma-separated Codex beta features advertised for this request.
    codex_beta_features: ?[]const u8 = null,
    trace_ctx: debug_trace.TraceContext = .{},
    content_capture_limit: ?usize = null,
    delivery: ?*DeliveryCertainty = null,
    admission: ?agent_stream_provider.Admission = null,
    on_reasoning_chunk: ?StreamCallback = null,
    on_tool_input_chunk: ?StreamCallback = null,
    on_provider_tool_done: ?ProviderToolDoneCallback = null,
    on_provider_tool_start: ?ProviderToolStartCallback = null,
    /// Receives exact raw JSON for Responses events that the semantic fx
    /// completion contract does not consume. Slices are borrowed for the
    /// duration of the callback.
    on_responses_unhandled_event: ?responses_stream.UnknownEventCallback = null,
    provider_attempt_owner: ProviderAttemptOwner = .transport,
};

pub fn streamGatewayCompletion(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    cancel_flag: *std.atomic.Value(bool),
) !StreamResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    return streamGatewayCompletionCore(
        alloc,
        request,
        callback_ctx,
        on_content_chunk,
        on_tool_start,
        cancel_flag,
        true,
    );
}

fn streamResponsesCompletionBounded(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) !StreamResult {
    return runBoundedCompletion(alloc, request, deadline, cancel_flag);
}

pub fn streamResponsesCompactionBounded(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    deadline: ?std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) !StreamResult {
    return runBoundedCompletion(
        alloc,
        request,
        deadline orelse std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(codex_json_request_timeout_ms),
        }),
        cancel_flag,
    );
}

fn runBoundedCompletion(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) !StreamResult {
    var operation = BoundedGatewayOperation{
        .alloc = alloc,
        .request = request,
        .cancel_flag = cancel_flag,
    };
    return runBoundedStreamOperation(alloc, cancel_flag, deadline, &operation);
}

const BoundedGatewayOperation = struct {
    alloc: std.mem.Allocator,
    request: StreamRequest,
    cancel_flag: *std.atomic.Value(bool),

    fn run(self: *@This()) !StreamResult {
        return streamGatewayCompletionCore(
            self.alloc,
            self.request,
            @ptrCast(&bounded_stream_discard_ctx),
            discardBoundedContent,
            null,
            self.cancel_flag,
            false,
        );
    }
};

var bounded_stream_discard_ctx: u8 = 0;

fn discardBoundedContent(_: *anyopaque, _: []const u8) void {}

fn streamGatewayCompletionCore(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    cancel_flag: *std.atomic.Value(bool),
    watch_connected_socket: bool,
) !StreamResult {
    return streamGatewayCompletionCoreWithOptions(
        alloc,
        request,
        callback_ctx,
        on_content_chunk,
        on_tool_start,
        cancel_flag,
        watch_connected_socket,
        .{},
    );
}

fn streamGatewayCompletionCoreWithOptions(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    cancel_flag: *std.atomic.Value(bool),
    watch_connected_socket: bool,
    core_options: StreamCoreOptions,
) !StreamResult {
    const payload = request.payload;
    const route = if (request.credential_source) |source|
        provider_route.fromCredentialSource(source) orelse return error.UnsupportedCredentialSource
    else
        provider_route.ProviderRoute.openai_responses_byok;
    const provider_binding = try validatedStreamProviderBinding(request, route);
    const retry_count = switch (request.provider_attempt_owner) {
        .agent => 1,
        .transport => request.retry_count,
    };
    const trace_ctx = request.trace_ctx;
    var owned_request_url: ?[]u8 = null;
    defer if (owned_request_url) |url| alloc.free(url);
    const request_url = if (provider_binding) |binding|
        binding.normalized_origin
    else if (isLoopbackUrl(request.chat_url))
        request.chat_url
    else blk: {
        owned_request_url = try provider_route.resolveEndpointFromEnvironmentAlloc(alloc, route);
        break :blk owned_request_url.?;
    };
    const uri = try std.Uri.parse(request_url);

    var codex_identity: ?chatgpt_oauth.Access = null;
    defer if (codex_identity) |*identity| identity.deinit(alloc);
    if (route == .codex_responses_oauth) {
        codex_identity = try loadCodexRequestIdentity(
            alloc,
            request.api_key,
            if (provider_binding) |binding| binding.account_id else null,
        );
    }

    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer secret.zeroAndFree(alloc, auth_header);

    var extra_headers_buf: [12]std.http.Header = undefined;
    const extra_headers = responsesExtraHeaders(
        &extra_headers_buf,
        route,
        if (codex_identity) |identity| identity.account_id else null,
        false,
        request.session_id,
        if (provider_binding) |binding| .{
            .organization = binding.organization,
            .project = binding.project,
        } else null,
        request.codex_beta_features,
    );

    if (request.admission) |admission| try admission.admit();
    var attempt: usize = 0;
    var delivery_ambiguous = false;
    var request_body_possibly_sent = false;
    var setup_epoch: ?ConnectionSetupEpoch = null;
    while (attempt < retry_count) : (attempt += 1) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
        defer client.deinit();

        if (setup_epoch == null) {
            setup_epoch = ConnectionSetupEpoch.init(core_options.setup_timing);
        }
        const epoch = &setup_epoch.?;
        const setup_delivery: DeliveryCertainty.State = if (request_body_possibly_sent)
            .possibly_sent
        else if (request.delivery) |delivery|
            delivery.load()
        else
            .definitely_unsent;

        debug_trace.eventf("gateway", "before_http_open_connect", trace_ctx, "attempt={d} attempt_limit={d} retries_used={d}", .{ attempt + 1, retry_count, attempt });
        debug_trace.eventf("gateway", "before_request_open", trace_ctx, "attempt={d} attempt_limit={d} retries_used={d} payload_bytes={d}", .{ attempt + 1, retry_count, attempt, payload.len });
        var req = openGatewayRequestBounded(&client, uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = user_agent },
            },
            .extra_headers = extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }, core_options.request_open_override, epoch, cancel_flag) catch |err| {
            debug_trace.eventf("gateway", "http_open_connect_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            const decision = decideConnectionSetup(.{
                .attempt = attempt + 1,
                .attempt_limit = retry_count,
                .now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
                .deadline = epoch.deadline,
                .cancelled = cancel_flag.load(.seq_cst),
                .delivery = setup_delivery,
                .outcome = .{ .request_failed = err },
            });
            switch (decision.action) {
                .retry => {
                    sleepGatewaySetupRetry(
                        (attempt + 1) * gateway_retry_base_delay_ns,
                        epoch,
                        cancel_flag,
                    ) catch |sleep_err| return @as(anyerror!StreamResult, sleep_err);
                    continue;
                },
                .fail => |terminal_err| return @as(anyerror!StreamResult, terminal_err),
                .cancelled => return error.Cancelled,
                .succeed => unreachable,
            }
        };
        const setup_success = decideConnectionSetup(.{
            .attempt = attempt + 1,
            .attempt_limit = retry_count,
            .now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
            .deadline = epoch.deadline,
            .cancelled = cancel_flag.load(.seq_cst),
            .delivery = setup_delivery,
            .outcome = .request_succeeded,
        });
        switch (setup_success.action) {
            .succeed => {},
            .fail => |terminal_err| {
                req.deinit();
                return @as(anyerror!StreamResult, terminal_err);
            },
            .cancelled => {
                req.deinit();
                return error.Cancelled;
            },
            .retry => unreachable,
        }
        setup_epoch = null;
        defer req.deinit();
        debug_trace.eventf("gateway", "after_http_open_connect", trace_ctx, "attempt={d}", .{attempt + 1});
        debug_trace.eventf("gateway", "after_request_open", trace_ctx, "attempt={d}", .{attempt + 1});

        var cancel_watch_done = std.atomic.Value(bool).init(false);
        var system_resumed = std.atomic.Value(bool).init(false);
        var connected_watch = ConnectedRequestWatch.init(core_options.response_head_timing);
        const cancel_watcher = if (watch_connected_socket)
            if (req.connection) |conn|
                spawn_gateway_cancel_watcher(&cancel_watch_done, cancel_flag, &system_resumed, null, &connected_watch, conn.stream_writer.stream) catch |err| {
                    debug_trace.eventf("gateway", "cancel_watcher_spawn_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
                    return @as(anyerror!StreamResult, err);
                }
            else
                null
        else
            null;
        const active_connected_watch: ?*ConnectedRequestWatch = if (cancel_watcher != null)
            &connected_watch
        else
            null;
        defer {
            cancel_watch_done.store(true, .seq_cst);
            if (cancel_watcher) |thread| thread.join();
        }
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        req.transfer_encoding = .{ .content_length = payload.len };
        var send_buf: [8192]u8 = undefined;
        debug_trace.eventf("gateway", "before_request_send", trace_ctx, "attempt={d} payload_bytes={d}", .{ attempt + 1, payload.len });
        request_body_possibly_sent = true;
        if (request.delivery) |delivery| delivery.markPossiblySent();
        var body_writer = req.sendBodyUnflushed(&send_buf) catch |err| {
            debug_trace.eventf("gateway", "request_send_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            return @as(anyerror!StreamResult, connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            ));
        };
        body_writer.writer.writeAll(payload) catch |err| {
            debug_trace.eventf("gateway", "request_send_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            return @as(anyerror!StreamResult, connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            ));
        };
        body_writer.end() catch |err| {
            debug_trace.eventf("gateway", "request_send_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            return @as(anyerror!StreamResult, connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            ));
        };
        req.connection.?.flush() catch |err| {
            debug_trace.eventf("gateway", "request_send_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            return @as(anyerror!StreamResult, connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            ));
        };
        debug_trace.eventf("gateway", "after_request_send", trace_ctx, "attempt={d} payload_bytes={d}", .{ attempt + 1, payload.len });
        debug_trace.eventf("gateway", "after_send", trace_ctx, "attempt={d} payload_bytes={d}", .{ attempt + 1, payload.len });

        if (active_connected_watch) |watch| {
            if (watch.arm_response_head()) |err| return @as(anyerror!StreamResult, err);
        }
        debug_trace.eventf("gateway", "before_receive_head", trace_ctx, "attempt={d}", .{attempt + 1});
        var response = req.receiveHead(&.{}) catch |err| {
            debug_trace.eventf("gateway", "receive_head_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            const mapped = connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            );
            if (mapped == error.Cancelled or mapped == error.SystemResumed) {
                return @as(anyerror!StreamResult, mapped);
            }
            if (request.provider_attempt_owner == .transport and
                isRetryableGatewayError(mapped) and attempt + 1 < retry_count)
            {
                delivery_ambiguous = true;
                try sleepGatewayRetry((attempt + 1) * 150 * std.time.ns_per_ms, cancel_flag);
                continue;
            }
            return @as(anyerror!StreamResult, mapped);
        };
        if (active_connected_watch) |watch| {
            if (watch.commit_response_head()) |err| return @as(anyerror!StreamResult, err);
        }
        debug_trace.eventf("gateway", "after_receive_head", trace_ctx, "attempt={d} status={d}", .{ attempt + 1, @intFromEnum(response.head.status) });
        if (response.head.status != .ok) {
            const status = response.head.status;
            if (@intFromEnum(status) >= 500) delivery_ambiguous = true;
            var retry_after_seconds = retryAfterSeconds(response.head);
            debug_trace.logf("stream", "http status={d} attempt={d}", .{ @intFromEnum(status), attempt + 1 });
            var err_buf: [4096]u8 = undefined;
            const err_reader = response.reader(&err_buf);
            const err_body = readProviderErrorBodyBounded(alloc, err_reader) catch null;
            if (cancel_flag.load(.seq_cst)) return error.Cancelled;

            var owns_err_body = true;
            defer if (owns_err_body) if (err_body) |body| alloc.free(body);
            if (retry_after_seconds == null) {
                if (err_body) |body| {
                    retry_after_seconds = responsesRetryAfterFromBody(
                        alloc,
                        @intCast(@intFromEnum(status)),
                        body,
                    ) catch null;
                }
            }

            const retry_delay_ns = if (request.provider_attempt_owner == .transport and
                isRetryableGatewayStatus(status) and attempt + 1 < retry_count)
                if (retry_after_seconds) |seconds|
                    retryAfterSecondsDelayNs(seconds)
                else
                    retryBackoffDelayNs(attempt)
            else
                null;
            if (retry_delay_ns) |delay_ns| {
                debug_trace.eventf("gateway", "http_status_retry", trace_ctx, "attempt={d} status={d} delay_ms={d}", .{
                    attempt + 1,
                    @intFromEnum(status),
                    delay_ns / std.time.ns_per_ms,
                });
                try sleepGatewayRetry(delay_ns, cancel_flag);
                continue;
            }
            owns_err_body = false;
            return .{
                .status = status,
                .err_body = err_body,
                .retry_after_seconds = retry_after_seconds,
                .completion = .{
                    .delivery_ambiguous = delivery_ambiguous,
                },
            };
        }

        var transfer_buf: [gateway_transfer_buffer_bytes]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        debug_trace.eventf("gateway", "before_sse_consume", trace_ctx, "attempt={d}", .{attempt + 1});
        var completion = responses_stream.consume(alloc, body_reader, .{
            .context = callback_ctx,
            .on_content_chunk = on_content_chunk,
            .on_tool_start = on_tool_start,
            .on_provider_tool_done = request.on_provider_tool_done,
            .on_provider_tool_start = request.on_provider_tool_start,
            .on_reasoning_chunk = request.on_reasoning_chunk,
            .on_tool_input_chunk = request.on_tool_input_chunk,
            .on_unknown_event = request.on_responses_unhandled_event,
            .content_capture_limit = request.content_capture_limit,
        }, cancel_flag) catch |err| {
            debug_trace.eventf("gateway", "sse_consume_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            return @as(anyerror!StreamResult, connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            ));
        };
        if (active_connected_watch) |watch| {
            if (watch.finish()) |err| {
                deinitResponsesCompletion(alloc, &completion);
                return @as(anyerror!StreamResult, err);
            }
        }
        if (cancel_flag.load(.seq_cst)) {
            deinitResponsesCompletion(alloc, &completion);
            return error.Cancelled;
        }
        if (system_resumed.load(.seq_cst)) {
            deinitResponsesCompletion(alloc, &completion);
            return error.SystemResumed;
        }
        completion.delivery_ambiguous = delivery_ambiguous;
        debug_trace.eventf("gateway", "after_sse_consume", trace_ctx, "attempt={d} finish_reason={s} content_bytes={d} tool_call_count={d}", .{
            attempt + 1,
            finishReasonLabel(completion.finish_reason),
            if (completion.content) |content| content.len else 0,
            completion.tool_calls.len,
        });
        debug_trace.logf(
            "stream",
            "completed attempt={d} finish_reason={s} content_bytes={d} tool_calls={d}",
            .{
                attempt + 1,
                finishReasonLabel(completion.finish_reason),
                if (completion.content) |content| content.len else 0,
                completion.tool_calls.len,
            },
        );
        debug_trace.eventf(
            "gateway",
            "stream_complete",
            trace_ctx,
            "attempt={d} finish_reason={s} content_bytes={d} tool_call_count={d} tool_calls={d}",
            .{
                attempt + 1,
                finishReasonLabel(completion.finish_reason),
                if (completion.content) |content| content.len else 0,
                completion.tool_calls.len,
                completion.tool_calls.len,
            },
        );

        return .{
            .status = .ok,
            .completion = completion,
        };
    }

    return error.HttpConnectionClosing;
}

fn deinitResponsesCompletion(alloc: std.mem.Allocator, completion: *types.ModelCompletion) void {
    var result: StreamResult = .{ .status = .ok, .completion = completion.* };
    result.deinit(alloc);
    completion.* = .{};
}

fn finishReasonLabel(reason: ?types.ProviderFinishReason) []const u8 {
    return if (reason) |value| @tagName(value) else "(none)";
}

fn readProviderErrorBodyBounded(alloc: std.mem.Allocator, reader: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    while (out.written().len <= max_provider_error_body_bytes) {
        const remaining = max_provider_error_body_bytes + 1 - out.written().len;
        const count = reader.stream(&out.writer, .limited(remaining)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => break,
        };
        if (count == 0) break;
    }
    if (out.written().len <= max_provider_error_body_bytes) {
        return out.toOwnedSlice();
    }

    const clipped = try alloc.dupe(u8, out.written()[0..max_provider_error_body_bytes]);
    out.deinit();
    debug_trace.logf(
        "responses",
        "provider error body truncated bytes={d}",
        .{max_provider_error_body_bytes},
    );
    return clipped;
}

fn responsesExtraHeaders(
    buf: []std.http.Header,
    route: provider_route.ProviderRoute,
    account_id: ?[]const u8,
    fedramp: bool,
    session_id: ?[]const u8,
    openai_identity: ?OpenAIIdentityHeaders,
    codex_beta_features: ?[]const u8,
) []const std.http.Header {
    std.debug.assert(buf.len >= 12);
    var len: usize = 0;
    buf[len] = .{ .name = "Accept", .value = "text/event-stream" };
    len += 1;
    len = appendDirectProviderIdentityHeaders(buf, len, route, account_id, fedramp, openai_identity);
    if (route == .codex_responses_oauth) {
        buf[len] = .{ .name = "OpenAI-Beta", .value = "responses=experimental" };
        len += 1;
        if (codex_beta_features) |features| {
            if (features.len > 0) {
                buf[len] = .{ .name = "x-codex-beta-features", .value = features };
                len += 1;
            }
        }
        if (session_id) |id| {
            if (id.len > 0) {
                buf[len] = .{ .name = "session-id", .value = id };
                len += 1;
                buf[len] = .{ .name = "thread-id", .value = id };
                len += 1;
                buf[len] = .{ .name = "x-client-request-id", .value = id };
                len += 1;
            }
        }
    }
    return buf[0..len];
}

fn providerJsonExtraHeaders(
    buf: []std.http.Header,
    route: provider_route.ProviderRoute,
    account_id: ?[]const u8,
    fedramp: bool,
    openai_identity: ?OpenAIIdentityHeaders,
) []const std.http.Header {
    std.debug.assert(buf.len >= 4);
    var len: usize = 0;
    buf[len] = .{ .name = "Accept", .value = "application/json" };
    len += 1;
    len = appendDirectProviderIdentityHeaders(
        buf,
        len,
        route,
        account_id,
        fedramp,
        openai_identity,
    );
    return buf[0..len];
}

const OpenAIIdentityHeaders = struct {
    organization: ?[]const u8 = null,
    project: ?[]const u8 = null,
};

fn appendDirectProviderIdentityHeaders(
    buf: []std.http.Header,
    start: usize,
    route: provider_route.ProviderRoute,
    account_id: ?[]const u8,
    fedramp: bool,
    openai_identity: ?OpenAIIdentityHeaders,
) usize {
    std.debug.assert(buf.len >= start + 3);
    var len = start;
    switch (route) {
        .openai_responses_byok => {
            const identity = openai_identity orelse OpenAIIdentityHeaders{
                .organization = io_mod.getenv("OPENAI_ORG_ID"),
                .project = io_mod.getenv("OPENAI_PROJECT_ID"),
            };
            if (identity.organization) |organization| {
                if (organization.len > 0) {
                    buf[len] = .{ .name = "OpenAI-Organization", .value = organization };
                    len += 1;
                }
            }
            if (identity.project) |project| {
                if (project.len > 0) {
                    buf[len] = .{ .name = "OpenAI-Project", .value = project };
                    len += 1;
                }
            }
        },
        .codex_responses_oauth => {
            if (account_id) |account| {
                if (account.len > 0) {
                    buf[len] = .{ .name = "ChatGPT-Account-ID", .value = account };
                    len += 1;
                }
            }
            if (fedramp) {
                buf[len] = .{ .name = "X-OpenAI-Fedramp", .value = "true" };
                len += 1;
            }
            buf[len] = .{ .name = "originator", .value = "fx" };
            len += 1;
        },
    }
    return len;
}

fn validatedStreamProviderBinding(
    request: StreamRequest,
    route: provider_route.ProviderRoute,
) !?types.ResponsesCompactionProviderBindingView {
    const binding = request.responses_compaction_binding orelse return null;
    if (route.contract().wire_api != .openai_responses) {
        return error.InvalidResponsesCompactionProviderBinding;
    }
    const source = request.credential_source orelse
        return error.InvalidResponsesCompactionProviderBinding;
    try responses_compaction_binding.validate(source, binding);
    if (!responses_compaction_binding.credentialMatches(
        source,
        request.api_key,
        binding.account_id,
        binding,
    )) return error.ResponsesCompactionProviderBindingMismatch;
    return binding;
}

test "direct Responses stream pins provider binding to request credential and endpoint" {
    const alloc = std.testing.allocator;
    const binding = try responses_compaction_binding.buildAlloc(
        alloc,
        .openai_api_key,
        "sk-snapshot",
        null,
        .{
            .endpoint_overrides = .{ .responses_base_url = "https://snapshot.example/v1" },
            .organization = "org-snapshot",
            .project = "project-snapshot",
        },
    );
    defer types.freeResponsesCompactionProviderBinding(alloc, binding);

    const request: StreamRequest = .{
        .api_key = "sk-snapshot",
        .credential_source = .openai_api_key,
        .responses_compaction_binding = binding.view(),
        .model = "gpt-5",
        .retry_count = 1,
        .chat_url = "unused",
        .payload = "{}",
    };
    const validated = (try validatedStreamProviderBinding(
        request,
        .openai_responses_byok,
    )).?;
    try std.testing.expectEqualStrings(
        "https://snapshot.example/v1/responses",
        validated.normalized_origin,
    );

    var changed_key = request;
    changed_key.api_key = "sk-changed";
    try std.testing.expectError(
        error.ResponsesCompactionProviderBindingMismatch,
        validatedStreamProviderBinding(changed_key, .openai_responses_byok),
    );

    var wrong_source = request;
    wrong_source.credential_source = .chatgpt_subscription;
    try std.testing.expectError(
        error.InvalidResponsesCompactionProviderBinding,
        validatedStreamProviderBinding(wrong_source, .codex_responses_oauth),
    );
}

test "Codex provider JSON headers pair account identity" {
    var buf: [8]std.http.Header = undefined;
    const headers = providerJsonExtraHeaders(
        &buf,
        .codex_responses_oauth,
        "account_123",
        true,
        null,
    );
    try std.testing.expectEqualStrings("application/json", headerValue(headers, "accept").?);
    try std.testing.expectEqualStrings("account_123", headerValue(headers, "ChatGPT-Account-ID").?);
    try std.testing.expectEqualStrings("true", headerValue(headers, "X-OpenAI-Fedramp").?);
    try std.testing.expectEqualStrings("fx", headerValue(headers, "originator").?);
}

test "OpenAI provider JSON headers preserve organization and project identity" {
    _ = try stableModelsTestEnviron();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("OPENAI_ORG_ID", "org_123");
    try environ.put("OPENAI_PROJECT_ID", "proj_123");
    io_mod.setEnvironMap(&environ);
    defer if (stable_models_test_environ) |map| io_mod.setEnvironMap(map);

    var buf: [8]std.http.Header = undefined;
    const headers = providerJsonExtraHeaders(
        &buf,
        .openai_responses_byok,
        "account_must_not_cross",
        true,
        null,
    );
    try std.testing.expectEqualStrings("application/json", headerValue(headers, "accept").?);
    try std.testing.expectEqualStrings("org_123", headerValue(headers, "OpenAI-Organization").?);
    try std.testing.expectEqualStrings("proj_123", headerValue(headers, "OpenAI-Project").?);
    try std.testing.expect(headerValue(headers, "ChatGPT-Account-ID") == null);
    try std.testing.expect(headerValue(headers, "X-OpenAI-Fedramp") == null);
    try std.testing.expect(headerValue(headers, "originator") == null);

    const snapshot_headers = providerJsonExtraHeaders(
        &buf,
        .openai_responses_byok,
        null,
        false,
        .{ .organization = "org-snapshot", .project = "project-snapshot" },
    );
    try std.testing.expectEqualStrings(
        "org-snapshot",
        headerValue(snapshot_headers, "OpenAI-Organization").?,
    );
    try std.testing.expectEqualStrings(
        "project-snapshot",
        headerValue(snapshot_headers, "OpenAI-Project").?,
    );
}

test "Codex streaming headers share the same account identity fields" {
    var buf: [12]std.http.Header = undefined;
    const headers = responsesExtraHeaders(
        &buf,
        .codex_responses_oauth,
        "account_123",
        true,
        "session_123",
        null,
        "remote_compaction_v2",
    );
    try std.testing.expectEqualStrings("text/event-stream", headerValue(headers, "accept").?);
    try std.testing.expectEqualStrings("account_123", headerValue(headers, "ChatGPT-Account-ID").?);
    try std.testing.expectEqualStrings("true", headerValue(headers, "X-OpenAI-Fedramp").?);
    try std.testing.expectEqualStrings("fx", headerValue(headers, "originator").?);
    try std.testing.expectEqualStrings(
        "responses=experimental",
        headerValue(headers, "OpenAI-Beta").?,
    );
    try std.testing.expectEqualStrings("session_123", headerValue(headers, "session-id").?);
    try std.testing.expectEqualStrings(
        "remote_compaction_v2",
        headerValue(headers, "x-codex-beta-features").?,
    );
}

test "OpenAI streaming headers use the bound organization and project snapshot" {
    var buf: [12]std.http.Header = undefined;
    const headers = responsesExtraHeaders(
        &buf,
        .openai_responses_byok,
        null,
        false,
        null,
        .{ .organization = "org-snapshot", .project = "project-snapshot" },
        null,
    );
    try std.testing.expectEqualStrings(
        "org-snapshot",
        headerValue(headers, "OpenAI-Organization").?,
    );
    try std.testing.expectEqualStrings(
        "project-snapshot",
        headerValue(headers, "OpenAI-Project").?,
    );
}

fn headerValue(headers: []const std.http.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn sleepGatewayRetry(delay_ns: u64, cancel_flag: *std.atomic.Value(bool)) (std.Io.Cancelable || error{Cancelled})!void {
    var remaining_ns = delay_ns;
    while (remaining_ns > 0) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        const sleep_ns = @min(remaining_ns, 10 * std.time.ns_per_ms);
        try io_mod.getIo().sleep(.fromNanoseconds(@intCast(sleep_ns)), .awake);
        remaining_ns -= sleep_ns;
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
}

fn runBoundedStreamOperation(
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    operation: anytype,
) !StreamResult {
    return runBoundedHttpOperation(
        StreamResult,
        alloc,
        cancel_flag,
        deadline,
        operation,
    );
}

pub fn runBoundedHttpOperation(
    comptime Result: type,
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    operation: anytype,
) !Result {
    if (cancel_flag.load(.seq_cst)) {
        debug_trace.logf("stream", "bounded termination cause=cancellation phase=admission", .{});
        return error.Cancelled;
    }
    std.debug.assert(deadline.clock == .awake);

    const zio = io_mod.getIo();
    const now = std.Io.Clock.Timestamp.now(zio, .awake);
    if (!std.Io.Clock.Timestamp.compare(now, .lt, deadline)) {
        debug_trace.logf("stream", "bounded termination cause=deadline phase=admission", .{});
        return error.Timeout;
    }

    // `std.Io.Select.cancel` interrupts test-I/O operations, but native sleep
    // implementations are not required to observe that select cancellation.
    // Give the cancellation watcher an explicit request-lifetime signal so a
    // successful request can always join its control branches promptly.
    var control_done: std.Io.Event = .unset;

    const Event = union(enum) {
        request: anyerror!Result,
        cancelled: anyerror!void,
        deadline: anyerror!void,
    };
    const Operation = @TypeOf(operation);
    const Runner = struct {
        fn run(value: Operation) anyerror!Result {
            return value.run();
        }
    };
    const Cleanup = struct {
        fn drain(result_alloc: std.mem.Allocator, select: *std.Io.Select(Event)) void {
            while (select.cancel()) |item| switch (item) {
                .request => |request_result| {
                    var late_result = request_result catch continue;
                    late_result.deinit(result_alloc);
                },
                .cancelled, .deadline => {},
            };
        }
    };

    var select_buffer: [3]Event = undefined;
    var select: std.Io.Select(Event) = .init(zio, &select_buffer);
    select.concurrent(.cancelled, waitForBoundedCancellationOrDone, .{ cancel_flag, &control_done }) catch |err| {
        return err;
    };
    select.concurrent(.deadline, waitForBoundedDeadlineOrDone, .{ deadline, &control_done }) catch |err| {
        control_done.set(zio);
        select.cancelDiscard();
        return err;
    };
    select.concurrent(.request, Runner.run, .{operation}) catch |err| {
        control_done.set(zio);
        select.cancelDiscard();
        return err;
    };

    const event = select.await() catch |err| {
        control_done.set(zio);
        Cleanup.drain(alloc, &select);
        return err;
    };
    control_done.set(zio);
    switch (event) {
        .request => |request_result| {
            Cleanup.drain(alloc, &select);
            if (cancel_flag.load(.seq_cst)) {
                debug_trace.logf("stream", "bounded termination cause=cancellation phase=request_result", .{});
                var owned_result = request_result catch return error.Cancelled;
                owned_result.deinit(alloc);
                return error.Cancelled;
            }
            return request_result;
        },
        .cancelled => |cancel_result| {
            cancel_result catch |err| {
                Cleanup.drain(alloc, &select);
                return err;
            };
            Cleanup.drain(alloc, &select);
            debug_trace.logf("stream", "bounded termination cause=cancellation phase=control", .{});
            return error.Cancelled;
        },
        .deadline => |deadline_result| {
            deadline_result catch |err| {
                Cleanup.drain(alloc, &select);
                return err;
            };
            Cleanup.drain(alloc, &select);
            if (cancel_flag.load(.seq_cst)) {
                debug_trace.logf("stream", "bounded termination cause=cancellation phase=deadline_cleanup", .{});
                return error.Cancelled;
            }
            debug_trace.logf("stream", "bounded termination cause=deadline phase=control", .{});
            return error.Timeout;
        },
    }
}

fn waitForBoundedCancellationOrDone(
    cancel_flag: *std.atomic.Value(bool),
    control_done: *std.Io.Event,
) anyerror!void {
    while (!cancel_flag.load(.seq_cst)) {
        control_done.waitTimeout(io_mod.getIo(), .{
            .duration = .{ .clock = .awake, .raw = .fromMilliseconds(5) },
        }) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        return;
    }
}

fn waitForBoundedDeadlineOrDone(
    deadline: std.Io.Clock.Timestamp,
    control_done: *std.Io.Event,
) anyerror!void {
    control_done.waitTimeout(io_mod.getIo(), .{ .deadline = deadline }) catch |err| switch (err) {
        error.Timeout => return,
        else => return err,
    };
}

fn waitForBoundedCancellation(cancel_flag: *std.atomic.Value(bool)) anyerror!void {
    while (!cancel_flag.load(.seq_cst)) {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
}

fn waitForBoundedDeadline(deadline: std.Io.Clock.Timestamp) anyerror!void {
    try deadline.wait(io_mod.getIo());
}

const GatewayCancelWatcher = struct {
    fn run(
        done: *std.atomic.Value(bool),
        cancel_flag: *std.atomic.Value(bool),
        system_resumed: ?*std.atomic.Value(bool),
        deadline: ?std.Io.Clock.Timestamp,
        connected_watch: ?*ConnectedRequestWatch,
        stream: std.Io.net.Stream,
    ) void {
        var previous = SuspendClockSample.now();
        while (!done.load(.seq_cst)) {
            if (cancel_flag.load(.seq_cst)) {
                if (connected_watch == null or connected_watch.?.win(.cancelled)) {
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                }
                return;
            }
            const current = SuspendClockSample.now();
            if (system_resumed != null and suspendGapDetected(previous, current)) {
                if (cancel_flag.load(.seq_cst)) {
                    if (connected_watch == null or connected_watch.?.win(.cancelled)) {
                        stream.shutdown(io_mod.getIo(), .both) catch {};
                    }
                    return;
                }
                if (connected_watch == null or connected_watch.?.win(.system_resumed)) {
                    system_resumed.?.store(true, .seq_cst);
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                }
                return;
            }
            if (deadline) |limit| {
                const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
                if (!std.Io.Clock.Timestamp.compare(now, .lt, limit)) {
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                    return;
                }
            }
            if (connected_watch) |watch| {
                const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
                if (watch.response_head_expired(now) and watch.win_response_head_timeout()) {
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                    return;
                }
                if (watch.phase.load(.seq_cst) == .completed) return;
            }
            previous = current;
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
    }
};

const suspend_gap_tolerance_ns: i128 = 100 * std.time.ns_per_ms;

const SuspendClockSample = struct {
    awake_ns: i128,
    boot_ns: i128,

    fn now() SuspendClockSample {
        const io = io_mod.getIo();
        return .{
            .awake_ns = @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds()),
            .boot_ns = @intCast(std.Io.Clock.Timestamp.now(io, .boot).raw.toNanoseconds()),
        };
    }
};

fn suspendGapDetected(previous: SuspendClockSample, current: SuspendClockSample) bool {
    const awake_elapsed = current.awake_ns - previous.awake_ns;
    const boot_elapsed = current.boot_ns - previous.boot_ns;
    if (awake_elapsed < 0 or boot_elapsed < 0) return false;
    return boot_elapsed - awake_elapsed > suspend_gap_tolerance_ns;
}

pub fn spawnHttpCancelWatcher(
    done: *std.atomic.Value(bool),
    cancel_flag: *std.atomic.Value(bool),
    stream: std.Io.net.Stream,
) !std.Thread {
    return spawn_gateway_cancel_watcher(done, cancel_flag, null, null, null, stream);
}

pub fn spawnHttpCancelWatcherBounded(
    done: *std.atomic.Value(bool),
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    stream: std.Io.net.Stream,
) !std.Thread {
    return spawn_gateway_cancel_watcher(done, cancel_flag, null, deadline, null, stream);
}

fn spawn_gateway_cancel_watcher(
    done: *std.atomic.Value(bool),
    cancel_flag: *std.atomic.Value(bool),
    system_resumed: ?*std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
    connected_watch: ?*ConnectedRequestWatch,
    stream: std.Io.net.Stream,
) !std.Thread {
    if (builtin.is_test) {
        if (test_cancel_watcher_spawn_error) |err| return err;
    }
    return io_mod.spawn(.{}, GatewayCancelWatcher.run, .{
        done,
        cancel_flag,
        system_resumed,
        deadline,
        connected_watch,
        stream,
    });
}

test "suspend gap classification compares boot and awake clocks" {
    const before = SuspendClockSample{ .awake_ns = 1_000, .boot_ns = 10_000 };
    try std.testing.expect(!suspendGapDetected(before, .{
        .awake_ns = before.awake_ns + 10 * std.time.ns_per_ms,
        .boot_ns = before.boot_ns + 10 * std.time.ns_per_ms,
    }));
    try std.testing.expect(!suspendGapDetected(before, .{
        .awake_ns = before.awake_ns + 10 * std.time.ns_per_ms,
        .boot_ns = before.boot_ns + 10 * std.time.ns_per_ms + suspend_gap_tolerance_ns,
    }));
    try std.testing.expect(suspendGapDetected(before, .{
        .awake_ns = before.awake_ns + 10 * std.time.ns_per_ms,
        .boot_ns = before.boot_ns + 10 * std.time.ns_per_ms + suspend_gap_tolerance_ns + 1,
    }));
}

test "connected request watch keeps the first terminal winner" {
    var cancelled = ConnectedRequestWatch.init(.{});
    try std.testing.expect(cancelled.win(.cancelled));
    try std.testing.expect(!cancelled.win_response_head_timeout());
    try std.testing.expectEqual(error.Cancelled, cancelled.finish().?);

    var resumed = ConnectedRequestWatch.init(.{});
    try std.testing.expect(resumed.win(.system_resumed));
    try std.testing.expect(!resumed.win(.cancelled));
    try std.testing.expectEqual(error.SystemResumed, resumed.finish().?);

    var ordinary = ConnectedRequestWatch.init(.{});
    try std.testing.expect(ordinary.finish() == null);
    try std.testing.expect(!ordinary.win(.cancelled));
}

test "connected request watch disarms timeout at response head" {
    var watch = ConnectedRequestWatch.init(.{ .timeout_ms = 1 });
    try std.testing.expect(watch.arm_response_head() == null);
    try std.testing.expect(watch.commit_response_head() == null);
    try std.testing.expect(!watch.win_response_head_timeout());
    try std.testing.expect(watch.finish() == null);
}

fn resolveE2eGatewayUrl(env_name: []const u8, default_url: []const u8) ![]const u8 {
    return selectE2eGatewayUrl(io_mod.getenv(env_name), default_url);
}

fn selectE2eGatewayUrl(override_url: ?[]const u8, default_url: []const u8) ![]const u8 {
    const override = override_url orelse return default_url;
    if (!isLoopbackHttpUrl(override)) return error.InvalidE2EGatewayUrl;
    return override;
}

pub fn isLoopbackHttpUrl(url: []const u8) bool {
    return isLoopbackUrlWithHttps(url, false);
}

pub fn isLoopbackUrl(url: []const u8) bool {
    return isLoopbackUrlWithHttps(url, true);
}

fn isLoopbackUrlWithHttps(url: []const u8, allow_https: bool) bool {
    const uri = std.Uri.parse(url) catch return false;
    const supported_scheme = std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        (allow_https and std.ascii.eqlIgnoreCase(uri.scheme, "https"));
    if (!supported_scheme or
        uri.user != null or
        uri.password != null or
        uri.port == null)
    {
        return false;
    }

    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]");
}

const HeaderMatch = struct {
    name: []const u8,
    value: []const u8,
};

fn isRetryableGatewayStatus(status: std.http.Status) bool {
    return switch (status) {
        .too_many_requests,
        .internal_server_error,
        .bad_gateway,
        .service_unavailable,
        .gateway_timeout,
        => true,
        else => false,
    };
}

fn retryDelayNsForResponse(head: std.http.Client.Response.Head, attempt: usize) u64 {
    if (retryAfterDelayNs(head)) |delay_ns| return delay_ns;
    return retryBackoffDelayNs(attempt);
}

fn retryBackoffDelayNs(attempt: usize) u64 {
    const multiplier: u64 = @intCast(attempt + 1);
    return multiplier * gateway_retry_base_delay_ns;
}

fn retryAfterDelayNs(head: std.http.Client.Response.Head) ?u64 {
    const seconds = retryAfterSeconds(head) orelse return null;
    return retryAfterSecondsDelayNs(seconds);
}

fn retryAfterSecondsDelayNs(seconds: u64) u64 {
    const delay = std.math.mul(u64, seconds, std.time.ns_per_s) catch gateway_retry_after_max_ns;
    return @min(delay, gateway_retry_after_max_ns);
}

fn retryAfterSeconds(head: std.http.Client.Response.Head) ?u64 {
    const raw = findHeaderValue(head, "retry-after") orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u64, trimmed, 10) catch |err| switch (err) {
        error.Overflow => std.math.maxInt(u64),
        error.InvalidCharacter => null,
    };
}

pub fn responsesRetryAfterFromBody(
    alloc: std.mem.Allocator,
    status_code: u16,
    body: []const u8,
) std.mem.Allocator.Error!?u64 {
    var decoded = try responses_protocol.decodeErrorResponse(alloc, status_code, body);
    defer decoded.deinit();
    const seconds = decoded.info.retry_after_seconds orelse return null;
    if (!std.math.isFinite(seconds) or seconds < 0) return null;
    const rounded = @ceil(seconds);
    const max_as_float: f64 = @floatFromInt(std.math.maxInt(u64));
    if (rounded >= max_as_float) return std.math.maxInt(u64);
    return @intFromFloat(rounded);
}

fn findHeaderValue(head: std.http.Client.Response.Head, name: []const u8) ?[]const u8 {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

const BoundedProbeStage = enum {
    request_open,
    dns,
    connect,
    tls,
    send,
    response_head,
    response_body,
    retry_sleep,
};

const BoundedProbeMode = enum {
    success,
    wait,
    success_and_cancel,
    wait_and_mark_cancel_when_task_is_cancelled,
};

const BoundedProbe = struct {
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    mode: BoundedProbeMode,
    stage: BoundedProbeStage = .request_open,
    request_starts: usize = 0,
    active_tasks: usize = 0,
    network_opens: usize = 0,
    reached_stage: ?BoundedProbeStage = null,

    fn run(self: *@This()) anyerror!StreamResult {
        self.request_starts += 1;
        self.active_tasks += 1;
        defer self.active_tasks -= 1;
        self.network_opens += 1;
        self.reached_stage = self.stage;

        switch (self.mode) {
            .success => return self.successResult(),
            .wait => {
                try io_mod.getIo().sleep(.fromSeconds(5), .awake);
                return error.TestRequestDidNotBlock;
            },
            .success_and_cancel => {
                self.cancel_flag.store(true, .seq_cst);
                return self.successResult();
            },
            .wait_and_mark_cancel_when_task_is_cancelled => {
                io_mod.getIo().sleep(.fromSeconds(5), .awake) catch |err| {
                    if (err == error.Canceled) self.cancel_flag.store(true, .seq_cst);
                    return err;
                };
                return error.TestRequestDidNotBlock;
            },
        }
    }

    fn successResult(self: *@This()) !StreamResult {
        return .{
            .status = .ok,
            .completion = .{
                .content = try self.alloc.dupe(u8, "ok"),
                .finish_reason = .stop,
            },
        };
    }
};

fn testAwakeDeadlineAfter(milliseconds: i64) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(milliseconds),
    });
}

fn readTraceFileForTest(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 8192);
}

const LoopbackGatewayMode = enum {
    reset_on_accept,
    tls_handshake_stall,
    request_send_stall,
    response_head_stall,
    response_body_stall,
    response_body_delayed_success,
    response_body_progress,
    retry_once,
    retry_once_then_success,
    success,
    success_capture,
    model_catalog_success,
};

const LoopbackGatewayFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    mode: LoopbackGatewayMode,
    hold_ms: u64,
    thread: ?std.Thread = null,
    server_open: bool = true,
    accept_started: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    accepted: std.atomic.Value(bool) = .init(false),
    reached_stage: std.atomic.Value(bool) = .init(false),
    request_headers: [16 * 1024]u8 = undefined,
    request_headers_len: std.atomic.Value(usize) = .init(0),
    failure: ?anyerror = null,

    fn init(mode: LoopbackGatewayMode, hold_ms: u64) !@This() {
        var fixture: @This() = .{
            .server = undefined,
            .mode = mode,
            .hold_ms = hold_ms,
        };
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        fixture.server = try address.listen(fixture.io(), .{ .reuse_address = true });
        return fixture;
    }

    fn start(self: *@This()) !void {
        std.debug.assert(self.thread == null);
        self.thread = try io_mod.spawn(.{}, run, .{self});
    }

    fn deinit(self: *@This()) void {
        if (!self.server_open) return;

        const zio = self.io();
        self.stopping.store(true, .seq_cst);
        if (self.thread) |thread| {
            const listener = std.Io.net.Stream{ .socket = self.server.socket };
            listener.shutdown(zio, .both) catch {};
            self.wakeAccept();
            thread.join();
            self.thread = null;
        }
        self.server.deinit(zio);
        self.server_open = false;
    }

    fn port(self: *@This()) u16 {
        return self.server.socket.address.getPort();
    }

    fn io(self: *@This()) std.Io {
        return self.io_backend.io();
    }

    fn waitForAcceptStart(self: *@This(), timeout_ms: u64) bool {
        return self.waitForSignal(&self.accept_started, timeout_ms);
    }

    fn waitForStageOrDone(self: *@This(), request_done: *std.atomic.Value(bool)) bool {
        while (!self.reached_stage.load(.seq_cst)) {
            if (request_done.load(.seq_cst) or self.stopping.load(.seq_cst)) return false;
            sleepBlocking(1);
        }
        return true;
    }

    fn waitForSignal(self: *@This(), signal: *std.atomic.Value(bool), timeout_ms: u64) bool {
        var remaining_ms = timeout_ms;
        while (remaining_ms > 0) : (remaining_ms -= 1) {
            if (signal.load(.seq_cst)) return true;
            if (self.stopping.load(.seq_cst)) return false;
            sleepBlocking(1);
        }
        return signal.load(.seq_cst);
    }

    fn wakeAccept(self: *@This()) void {
        var wake_io_backend: std.Io.Threaded = .init_single_threaded;
        const zio = wake_io_backend.io();
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.port()) };
        var stream = address.connect(zio, .{
            .mode = .stream,
        }) catch return;
        stream.close(zio);
    }

    fn sleepBlocking(milliseconds: u64) void {
        var sleep_io_backend: std.Io.Threaded = .init_single_threaded;
        sleep_io_backend.io().sleep(.fromMilliseconds(@intCast(milliseconds)), .real) catch {};
    }

    fn hold(self: *@This()) void {
        var remaining_ms = self.hold_ms;
        while (remaining_ms > 0 and !self.stopping.load(.seq_cst)) {
            const sleep_ms: u64 = @min(remaining_ms, 10);
            sleepBlocking(sleep_ms);
            remaining_ms -= sleep_ms;
        }
    }

    fn markStage(self: *@This()) void {
        self.reached_stage.store(true, .seq_cst);
    }

    fn captureRequestHeaders(self: *@This(), headers: []const u8) void {
        const len = @min(headers.len, self.request_headers.len);
        @memcpy(self.request_headers[0..len], headers[0..len]);
        self.request_headers_len.store(len, .seq_cst);
    }

    fn capturedHeaderValue(self: *@This(), name: []const u8) ?[]const u8 {
        const len = self.request_headers_len.load(.seq_cst);
        if (len == 0) return null;
        return rawHeaderValue(self.request_headers[0..len], name);
    }

    fn run(self: *@This()) void {
        self.runFallible() catch |err| {
            if (self.stopping.load(.seq_cst) and err == error.SocketNotListening) return;
            self.failure = err;
        };
    }

    fn runFallible(self: *@This()) !void {
        const zio = self.io();
        self.accept_started.store(true, .seq_cst);
        var stream = try self.server.accept(zio);
        defer stream.close(zio);
        if (self.stopping.load(.seq_cst)) return;
        self.accepted.store(true, .seq_cst);

        switch (self.mode) {
            .reset_on_accept => {
                const reset_on_close: std.posix.linger = .{
                    .onoff = 1,
                    .linger = 0,
                };
                try std.posix.setsockopt(
                    stream.socket.handle,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.LINGER,
                    std.mem.asBytes(&reset_on_close),
                );
                self.markStage();
            },
            .tls_handshake_stall => {
                self.markStage();
                self.hold();
            },
            .request_send_stall => {
                const receive_buffer: c_int = 1024;
                std.posix.setsockopt(
                    stream.socket.handle,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.RCVBUF,
                    std.mem.asBytes(&receive_buffer),
                ) catch {};
                self.markStage();
                self.hold();
            },
            .response_head_stall => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                self.hold();
            },
            .response_body_stall => {
                try readLoopbackGatewayRequest(zio, stream, self);
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"partial\"}\n\n",
                );
                self.markStage();
                self.hold();
            },
            .response_body_delayed_success => {
                try readLoopbackGatewayRequest(zio, stream, self);
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n",
                );
                self.markStage();
                self.hold();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"ok\"}\n\n" ++
                        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n",
                );
            },
            .response_body_progress => {
                try readLoopbackGatewayRequest(zio, stream, self);
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n",
                );
                self.markStage();
                for (0..30) |_| {
                    if (self.stopping.load(.seq_cst)) return;
                    writeLoopbackGatewayBytes(zio, stream, ": progress\n\n") catch return;
                    sleepBlocking(20);
                }
                self.hold();
            },
            .retry_once => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 503 Service Unavailable\r\n" ++
                        "Content-Length: 0\r\n" ++
                        "Connection: close\r\n\r\n",
                );
            },
            .retry_once_then_success => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 503 Service Unavailable\r\n" ++
                        "Content-Length: 0\r\n" ++
                        "Connection: close\r\n\r\n",
                );

                var recovered_stream = try self.server.accept(zio);
                defer recovered_stream.close(zio);
                try readLoopbackGatewayRequest(zio, recovered_stream, self);
                try writeLoopbackGatewayBytes(
                    zio,
                    recovered_stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"ok\"}\n\n" ++
                        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n",
                );
            },
            .success => {
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"ok\"}\n\n" ++
                        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n",
                );
                self.hold();
            },
            .success_capture => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"ok\"}\n\n" ++
                        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n",
                );
            },
            .model_catalog_success => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: application/json\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        loopback_model_catalog_json,
                );
            },
        }
    }
};

const loopback_model_catalog_json =
    "{\"object\":\"list\",\"data\":[{\"id\":\"gpt-5.6-sol\",\"object\":\"model\",\"created\":4},{\"id\":\"gpt-5.4\",\"object\":\"model\",\"created\":3},{\"id\":\"o4-mini\",\"object\":\"model\",\"created\":2},{\"id\":\"company-model\",\"object\":\"model\",\"created\":1}]}";

pub const TestModelCatalogFixture = struct {
    fixture: LoopbackGatewayFixture,

    pub fn init() !@This() {
        return .{ .fixture = try LoopbackGatewayFixture.init(.model_catalog_success, 0) };
    }

    pub fn start(self: *@This()) !void {
        try self.fixture.start();
    }

    pub fn deinit(self: *@This()) void {
        self.fixture.deinit();
    }

    pub fn port(self: *@This()) u16 {
        return self.fixture.port();
    }

    pub fn waitForAcceptStart(self: *@This(), timeout_ms: u64) bool {
        return self.fixture.waitForAcceptStart(timeout_ms);
    }

    pub fn failure(self: *@This()) ?anyerror {
        return self.fixture.failure;
    }

    pub fn capturedHeaderValue(self: *@This(), name: []const u8) ?[]const u8 {
        return self.fixture.capturedHeaderValue(name);
    }
};

const RequestOpenProbe = struct {
    attempts: usize = 0,
    tls_failure_attempt: ?usize = null,
    delays_ms: [3]i64 = .{ 0, 0, 0 },

    fn requestOpenOverride(self: *@This()) RequestOpenOverride {
        return .{ .ctx = @ptrCast(self), .run = open };
    }

    fn open(
        raw_ctx: *anyopaque,
        client: *std.http.Client,
        method: std.http.Method,
        uri: std.Uri,
        options: std.http.Client.RequestOptions,
    ) anyerror!std.http.Client.Request {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        const attempt_index = self.attempts;
        self.attempts += 1;
        if (attempt_index < self.delays_ms.len) {
            const delay_ms = self.delays_ms[attempt_index];
            if (delay_ms > 0) {
                try io_mod.getIo().sleep(.fromMilliseconds(delay_ms), .awake);
            }
        }
        if (self.tls_failure_attempt == attempt_index) {
            return error.TlsInitializationFailed;
        }
        return client.request(method, uri, options);
    }
};

const ConnectionSetupHarness = struct {
    fixture: LoopbackGatewayFixture,
    url: []u8,

    fn init(mode: LoopbackGatewayMode, use_tls: bool) !ConnectionSetupHarness {
        var fixture = try LoopbackGatewayFixture.init(mode, 500);
        errdefer fixture.deinit();
        const url = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}://127.0.0.1:{d}/chat",
            .{ if (use_tls) "https" else "http", fixture.port() },
        );
        return .{ .fixture = fixture, .url = url };
    }

    fn start(self: *@This()) !void {
        try self.fixture.start();
        if (!self.fixture.waitForAcceptStart(5000)) return error.TestFixtureDidNotStart;
    }

    fn deinit(self: *@This()) void {
        self.fixture.deinit();
        std.testing.allocator.free(self.url);
    }
};

fn discardConnectionSetupTestChunk(_: *anyopaque, _: []const u8) void {}

test "direct gateway request-open cancellation interrupts real TLS setup" {
    var harness = try ConnectionSetupHarness.init(.tls_handshake_stall, true);
    defer harness.deinit();
    try harness.start();

    var cancel_flag = std.atomic.Value(bool).init(false);
    var request_done = std.atomic.Value(bool).init(false);
    const Cancel = struct {
        fn run(
            fixture: *LoopbackGatewayFixture,
            flag: *std.atomic.Value(bool),
            done: *std.atomic.Value(bool),
        ) void {
            if (!fixture.waitForStageOrDone(done)) return;
            LoopbackGatewayFixture.sleepBlocking(30);
            if (!done.load(.seq_cst)) flag.store(true, .seq_cst);
        }
    };
    const cancel_thread = try io_mod.spawn(.{}, Cancel.run, .{
        &harness.fixture,
        &cancel_flag,
        &request_done,
    });
    defer {
        request_done.store(true, .seq_cst);
        cancel_thread.join();
    }

    var callback_ctx: u8 = 0;
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const result = streamGatewayCompletionCoreWithOptions(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 1,
            .chat_url = harness.url,
            .payload = "{}",
        },
        @ptrCast(&callback_ctx),
        discardConnectionSetupTestChunk,
        null,
        &cancel_flag,
        false,
        .{ .setup_timing = .{ .timeout_ms = 1000 } },
    );
    const elapsed_ms = started.durationTo(
        std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
    ).raw.toMilliseconds();

    try std.testing.expectError(error.Cancelled, result);
    try std.testing.expect(elapsed_ms < 500);
    harness.fixture.deinit();
    if (harness.fixture.failure) |err| return err;
}

test "direct gateway request-open deadline interrupts real TLS setup" {
    var harness = try ConnectionSetupHarness.init(.tls_handshake_stall, true);
    defer harness.deinit();
    try harness.start();

    var delivery = DeliveryCertainty.init();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const result = streamGatewayCompletionCoreWithOptions(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 1,
            .chat_url = harness.url,
            .payload = "{}",
            .delivery = &delivery,
        },
        @ptrCast(&callback_ctx),
        discardConnectionSetupTestChunk,
        null,
        &cancel_flag,
        false,
        .{ .setup_timing = .{ .timeout_ms = 80 } },
    );
    const elapsed_ms = started.durationTo(
        std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
    ).raw.toMilliseconds();

    try std.testing.expectError(error.ConnectionSetupTimedOut, result);
    try std.testing.expect(elapsed_ms < 400);
    try std.testing.expectEqual(DeliveryCertainty.State.definitely_unsent, delivery.load());
    harness.fixture.deinit();
    if (harness.fixture.failure) |err| return err;
}

test "TLS retry sleep consumes the original connection setup deadline" {
    var probe = RequestOpenProbe{ .tls_failure_attempt = 0 };
    var cancel_flag = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;
    const result = streamGatewayCompletionCoreWithOptions(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 3,
            .chat_url = "http://127.0.0.1:1/chat",
            .payload = "{}",
        },
        @ptrCast(&callback_ctx),
        discardConnectionSetupTestChunk,
        null,
        &cancel_flag,
        false,
        .{
            .setup_timing = .{ .timeout_ms = 80 },
            .request_open_override = probe.requestOpenOverride(),
        },
    );

    try std.testing.expectError(error.ConnectionSetupTimedOut, result);
    try std.testing.expectEqual(@as(usize, 1), probe.attempts);
}

test "transport-owned TLS setup retries before send" {
    var harness = try ConnectionSetupHarness.init(.success, false);
    defer harness.deinit();
    try harness.start();

    var probe = RequestOpenProbe{ .tls_failure_attempt = 0 };
    var cancel_flag = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;
    var result = try streamGatewayCompletionCoreWithOptions(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 2,
            .chat_url = harness.url,
            .payload = "{}",
        },
        @ptrCast(&callback_ctx),
        discardConnectionSetupTestChunk,
        null,
        &cancel_flag,
        false,
        .{
            .setup_timing = .{ .timeout_ms = 1000 },
            .request_open_override = probe.requestOpenOverride(),
        },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), probe.attempts);
    try std.testing.expectEqualStrings("ok", result.completion.content.?);
    harness.fixture.deinit();
    if (harness.fixture.failure) |err| return err;
}

test "gateway setup trace distinguishes attempt limits from retries used" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "gateway-attempts.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "gateway");

    var harness = try ConnectionSetupHarness.init(.success, false);
    defer harness.deinit();
    try harness.start();

    var probe = RequestOpenProbe{ .tls_failure_attempt = 0 };
    var cancel_flag = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;
    var result = try streamGatewayCompletionCoreWithOptions(
        alloc,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 2,
            .chat_url = harness.url,
            .payload = "{}",
        },
        @ptrCast(&callback_ctx),
        discardConnectionSetupTestChunk,
        null,
        &cancel_flag,
        false,
        .{
            .setup_timing = .{ .timeout_ms = 1000 },
            .request_open_override = probe.requestOpenOverride(),
        },
    );
    defer result.deinit(alloc);
    debug_trace.shutdown();

    const trace = try readTraceFileForTest(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "attempt=1 attempt_limit=2 retries_used=0",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "attempt=2 attempt_limit=2 retries_used=1",
    ) != null);
    try std.testing.expect(std.mem.find(u8, trace, "retry_count=") == null);

    harness.fixture.deinit();
    if (harness.fixture.failure) |err| return err;
}

test "a fresh setup epoch succeeds normally" {
    var harness = try ConnectionSetupHarness.init(.success, false);
    defer harness.deinit();
    try harness.start();

    var cancel_flag = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;
    var result = try streamGatewayCompletionCoreWithOptions(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 1,
            .chat_url = harness.url,
            .payload = "{}",
        },
        @ptrCast(&callback_ctx),
        discardConnectionSetupTestChunk,
        null,
        &cancel_flag,
        false,
        .{ .setup_timing = .{ .timeout_ms = 1000 } },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ok", result.completion.content.?);
    harness.fixture.deinit();
    if (harness.fixture.failure) |err| return err;
}

test "transport-owned TLS retry succeeds after delayed open" {
    var harness = try ConnectionSetupHarness.init(.success, false);
    defer harness.deinit();
    try harness.start();

    var probe = RequestOpenProbe{
        .tls_failure_attempt = 0,
        .delays_ms = .{ 0, 100, 0 },
    };
    var cancel_flag = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;
    var result = try streamGatewayCompletionCoreWithOptions(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 3,
            .chat_url = harness.url,
            .payload = "{}",
        },
        @ptrCast(&callback_ctx),
        discardConnectionSetupTestChunk,
        null,
        &cancel_flag,
        false,
        .{
            .setup_timing = .{ .timeout_ms = 1000 },
            .request_open_override = probe.requestOpenOverride(),
        },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), probe.attempts);
    harness.fixture.deinit();
    if (harness.fixture.failure) |err| return err;
}

test "transport-owned TLS retry succeeds after delayed failure" {
    var harness = try ConnectionSetupHarness.init(.success, false);
    defer harness.deinit();
    try harness.start();

    var probe = RequestOpenProbe{
        .tls_failure_attempt = 0,
        .delays_ms = .{ 50, 0, 0 },
    };
    var cancel_flag = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;
    var result = try streamGatewayCompletionCoreWithOptions(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 3,
            .chat_url = harness.url,
            .payload = "{}",
        },
        @ptrCast(&callback_ctx),
        discardConnectionSetupTestChunk,
        null,
        &cancel_flag,
        false,
        .{
            .setup_timing = .{ .timeout_ms = 1000 },
            .request_open_override = probe.requestOpenOverride(),
        },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), probe.attempts);
    harness.fixture.deinit();
    if (harness.fixture.failure) |err| return err;
}

test "response retry starts a fresh setup epoch without resetting delivery" {
    var harness = try ConnectionSetupHarness.init(.retry_once_then_success, false);
    defer harness.deinit();
    try harness.start();

    var probe = RequestOpenProbe{ .delays_ms = .{ 500, 500, 0 } };
    var delivery = DeliveryCertainty.init();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;
    var result = try streamGatewayCompletionCoreWithOptions(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 2,
            .chat_url = harness.url,
            .payload = "{}",
            .delivery = &delivery,
        },
        @ptrCast(&callback_ctx),
        discardConnectionSetupTestChunk,
        null,
        &cancel_flag,
        false,
        .{
            .setup_timing = .{ .timeout_ms = 800 },
            .request_open_override = probe.requestOpenOverride(),
        },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), probe.attempts);
    try std.testing.expectEqual(DeliveryCertainty.State.possibly_sent, delivery.load());
    try std.testing.expectEqualStrings("ok", result.completion.content.?);
    harness.fixture.deinit();
    if (harness.fixture.failure) |err| return err;
}

test "agent-owned provider attempts return the first retryable response" {
    var harness = try ConnectionSetupHarness.init(.retry_once, false);
    defer harness.deinit();
    try harness.start();

    var probe = RequestOpenProbe{};
    var delivery = DeliveryCertainty.init();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;
    var result = try streamGatewayCompletionCoreWithOptions(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 3,
            .chat_url = harness.url,
            .payload = "{}",
            .delivery = &delivery,
            .provider_attempt_owner = .agent,
        },
        @ptrCast(&callback_ctx),
        discardConnectionSetupTestChunk,
        null,
        &cancel_flag,
        false,
        .{
            .setup_timing = .{ .timeout_ms = 1000 },
            .request_open_override = probe.requestOpenOverride(),
        },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.service_unavailable, result.status);
    try std.testing.expectEqual(@as(usize, 1), probe.attempts);
    try std.testing.expectEqual(DeliveryCertainty.State.possibly_sent, delivery.load());
    harness.fixture.deinit();
    if (harness.fixture.failure) |err| return err;
}

test "agent-owned provider attempts return the first TLS setup failure" {
    var harness = try ConnectionSetupHarness.init(.success, false);
    defer harness.deinit();
    try harness.start();

    var probe = RequestOpenProbe{ .tls_failure_attempt = 0 };
    var delivery = DeliveryCertainty.init();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;
    const result = streamGatewayCompletionCoreWithOptions(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 3,
            .chat_url = harness.url,
            .payload = "{}",
            .delivery = &delivery,
            .provider_attempt_owner = .agent,
        },
        @ptrCast(&callback_ctx),
        discardConnectionSetupTestChunk,
        null,
        &cancel_flag,
        false,
        .{
            .setup_timing = .{ .timeout_ms = 1000 },
            .request_open_override = probe.requestOpenOverride(),
        },
    );
    if (result) |success_value| {
        var success = success_value;
        success.deinit(std.testing.allocator);
        return error.TestExpectedTlsInitializationFailure;
    } else |err| {
        try std.testing.expectEqual(error.TlsInitializationFailed, err);
    }

    try std.testing.expectEqual(@as(usize, 1), probe.attempts);
    try std.testing.expectEqual(DeliveryCertainty.State.definitely_unsent, delivery.load());
    harness.fixture.deinit();
    if (harness.fixture.failure) |err| return err;
}

test "agent-owned provider attempts return immediate peer resets without transport retry" {
    var harness = try ConnectionSetupHarness.init(.reset_on_accept, false);
    defer harness.deinit();
    try harness.start();

    var probe = RequestOpenProbe{};
    var delivery = DeliveryCertainty.init();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;
    const result = streamGatewayCompletionCoreWithOptions(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 3,
            .chat_url = harness.url,
            .payload = "{}",
            .delivery = &delivery,
            .provider_attempt_owner = .agent,
        },
        @ptrCast(&callback_ctx),
        discardConnectionSetupTestChunk,
        null,
        &cancel_flag,
        false,
        .{
            .setup_timing = .{ .timeout_ms = 1000 },
            .request_open_override = probe.requestOpenOverride(),
        },
    );
    if (result) |success_value| {
        var success = success_value;
        success.deinit(std.testing.allocator);
        return error.TestExpectedPeerReset;
    } else |err| {
        const evidence = networkFailureEvidence(
            err,
            delivery.load(),
        ) orelse return error.TestExpectedNetworkFailureEvidence;
        try std.testing.expectEqual(
            agent_stream_provider.NetworkFailureCause.transport_interrupted,
            evidence.cause,
        );
        try std.testing.expectEqual(delivery.load(), evidence.delivery);
    }

    try std.testing.expectEqual(@as(usize, 1), probe.attempts);
    harness.fixture.deinit();
    if (harness.fixture.failure) |err| return err;
}

test "TLS setup does not retry after a response made delivery possible" {
    var harness = try ConnectionSetupHarness.init(.retry_once, false);
    defer harness.deinit();
    try harness.start();

    var probe = RequestOpenProbe{ .tls_failure_attempt = 1 };
    var delivery = DeliveryCertainty.init();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;
    const result = streamGatewayCompletionCoreWithOptions(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 3,
            .chat_url = harness.url,
            .payload = "{}",
            .delivery = &delivery,
        },
        @ptrCast(&callback_ctx),
        discardConnectionSetupTestChunk,
        null,
        &cancel_flag,
        false,
        .{
            .setup_timing = .{ .timeout_ms = 1000 },
            .request_open_override = probe.requestOpenOverride(),
        },
    );

    try std.testing.expectError(error.TlsInitializationFailed, result);
    try std.testing.expectEqual(@as(usize, 2), probe.attempts);
    try std.testing.expectEqual(DeliveryCertainty.State.possibly_sent, delivery.load());
    harness.fixture.deinit();
    if (harness.fixture.failure) |err| return err;
}

test "TLS setup does not retry after delivery when no certainty sink is provided" {
    var harness = try ConnectionSetupHarness.init(.retry_once, false);
    defer harness.deinit();
    try harness.start();

    var probe = RequestOpenProbe{ .tls_failure_attempt = 1 };
    var cancel_flag = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;
    const result = streamGatewayCompletionCoreWithOptions(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 3,
            .chat_url = harness.url,
            .payload = "{}",
        },
        @ptrCast(&callback_ctx),
        discardConnectionSetupTestChunk,
        null,
        &cancel_flag,
        false,
        .{
            .setup_timing = .{ .timeout_ms = 1000 },
            .request_open_override = probe.requestOpenOverride(),
        },
    );

    try std.testing.expectError(error.TlsInitializationFailed, result);
    try std.testing.expectEqual(@as(usize, 2), probe.attempts);
    harness.fixture.deinit();
    if (harness.fixture.failure) |err| return err;
}

test "direct gateway cancellation before admission opens no connection" {
    var fixture = try LoopbackGatewayFixture.init(.success, 0);
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const chat_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/v1/chat/completions",
        .{fixture.port()},
    );
    defer std.testing.allocator.free(chat_url);

    var cancel_flag = std.atomic.Value(bool).init(true);
    try std.testing.expectError(
        error.Cancelled,
        streamGatewayCompletion(
            std.testing.allocator,
            .{
                .api_key = "test-key",
                .model = "provider/test-model",
                .retry_count = 1,
                .chat_url = chat_url,
                .payload = "{}",
            },
            @ptrCast(&bounded_stream_discard_ctx),
            discardBoundedContent,
            null,
            &cancel_flag,
        ),
    );
    try std.testing.expect(!fixture.accepted.load(.seq_cst));
    if (fixture.failure) |err| return err;
}

var stable_models_test_environ: ?*std.process.Environ.Map = null;

fn stableModelsTestEnviron() !*const std.process.Environ.Map {
    if (stable_models_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_models_test_environ = map;
    return map;
}

fn expectCancellableGatewayJsonCancellation(
    mode: LoopbackGatewayMode,
    api_key: []const u8,
    use_tls: bool,
    cancel_after_stage_ms: u64,
    hold_ms: u64,
    max_elapsed_ms: i64,
) !void {
    const zio = io_mod.getIo();
    var fixture = try LoopbackGatewayFixture.init(mode, hold_ms);
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const models_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}://127.0.0.1:{d}/v1/models",
        .{ if (use_tls) "https" else "http", fixture.port() },
    );
    defer std.testing.allocator.free(models_url);

    var cancel_flag = std.atomic.Value(bool).init(false);
    var request_done = std.atomic.Value(bool).init(false);
    const Cancel = struct {
        fn run(
            server_fixture: *LoopbackGatewayFixture,
            flag: *std.atomic.Value(bool),
            done: *std.atomic.Value(bool),
            delay_ms: u64,
        ) void {
            if (!server_fixture.waitForStageOrDone(done)) return;
            LoopbackGatewayFixture.sleepBlocking(delay_ms);
            if (!done.load(.seq_cst)) flag.store(true, .seq_cst);
        }
    };
    const cancel_thread = try io_mod.spawn(.{}, Cancel.run, .{
        &fixture,
        &cancel_flag,
        &request_done,
        cancel_after_stage_ms,
    });
    defer {
        request_done.store(true, .seq_cst);
        cancel_thread.join();
    }

    const started = std.Io.Clock.Timestamp.now(zio, .awake);
    const result = fetchProviderJsonCancellable(
        std.testing.allocator,
        .openai_api_key,
        api_key,
        models_url,
        &cancel_flag,
    );
    const elapsed_ms = started.durationTo(std.Io.Clock.Timestamp.now(zio, .awake)).raw.toMilliseconds();

    try std.testing.expectError(error.Cancelled, result);
    if (fixture.failure) |err| return err;
    try std.testing.expect(fixture.reached_stage.load(.seq_cst));
    try std.testing.expect(elapsed_ms < max_elapsed_ms);
}

test "cancellable gateway JSON request closes a held response head" {
    try expectCancellableGatewayJsonCancellation(.response_head_stall, "test-key", false, 20, 800, 500);
}

test "cancellable gateway JSON request closes a stalled request send" {
    const api_key = try std.testing.allocator.alloc(u8, 32 * 1024 * 1024);
    defer std.testing.allocator.free(api_key);
    @memset(api_key, 'x');

    try expectCancellableGatewayJsonCancellation(.request_send_stall, api_key, false, 100, 5000, 2000);
}

test "cancellable gateway JSON request interrupts a stalled TLS handshake" {
    try expectCancellableGatewayJsonCancellation(.tls_handshake_stall, "test-key", true, 20, 1200, 500);
}

fn readLoopbackGatewayRequest(zio: std.Io, stream: std.Io.net.Stream, fixture: *LoopbackGatewayFixture) !void {
    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(zio, &socket_buffer);
    var request: [16 * 1024]u8 = undefined;
    var header_len: usize = 0;

    while (header_len < request.len) {
        request[header_len] = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return error.TestRequestClosedEarly,
            else => return err,
        };
        header_len += 1;
        if (!std.mem.endsWith(u8, request[0..header_len], "\r\n\r\n")) continue;

        const headers = request[0 .. header_len - 4];
        fixture.captureRequestHeaders(headers);
        if (loopbackContentLength(headers)) |content_length| {
            reader.interface.discardAll(content_length) catch |err| switch (err) {
                error.EndOfStream => return error.TestRequestClosedEarly,
                else => return err,
            };
        }
        return;
    }

    return error.TestRequestTooLarge;
}

fn rawHeaderValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon_index = std.mem.findScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..colon_index], " \t");
        if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;
        return std.mem.trim(u8, line[colon_index + 1 ..], " \t");
    }
    return null;
}

fn loopbackContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const name = "content-length:";
        if (line.len < name.len or !std.ascii.eqlIgnoreCase(line[0..name.len], name)) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, line[name.len..], " \t"), 10) catch null;
    }
    return null;
}

fn writeLoopbackGatewayBytes(zio: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(zio, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

test "loopback gateway fixture cleanup joins without a client" {
    var fixture = try LoopbackGatewayFixture.init(.success, 0);
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(1000));

    fixture.deinit();

    try std.testing.expect(fixture.failure == null);
    try std.testing.expect(fixture.thread == null);
    try std.testing.expect(!fixture.server_open);
}

fn expectBoundedLoopbackTimeout(
    mode: LoopbackGatewayMode,
    payload: []const u8,
    retry_count: usize,
    deadline_ms: i64,
    hold_ms: u64,
    max_elapsed_ms: i64,
) !void {
    const zio = io_mod.getIo();
    var fixture = try LoopbackGatewayFixture.init(mode, hold_ms);
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/chat", .{fixture.port()});
    defer std.testing.allocator.free(url);

    var cancel_flag = std.atomic.Value(bool).init(false);
    const started = std.Io.Clock.Timestamp.now(zio, .awake);
    const request_result = streamResponsesCompletionBounded(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = retry_count,
            .chat_url = url,
            .payload = payload,
        },
        testAwakeDeadlineAfter(deadline_ms),
        &cancel_flag,
    );
    const elapsed_ms = started.durationTo(std.Io.Clock.Timestamp.now(zio, .awake)).raw.toMilliseconds();

    fixture.deinit();

    try std.testing.expectError(error.Timeout, request_result);
    if (fixture.failure) |err| return err;
    try std.testing.expect(fixture.accepted.load(.seq_cst));
    try std.testing.expect(fixture.reached_stage.load(.seq_cst));
    try std.testing.expect(elapsed_ms < max_elapsed_ms);
}

fn expectBoundedLoopbackCancellation(
    mode: LoopbackGatewayMode,
    payload: []const u8,
    use_tls: bool,
    cancel_after_stage_ms: u64,
    hold_ms: u64,
) !void {
    var fixture = try LoopbackGatewayFixture.init(mode, hold_ms);
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const scheme = if (use_tls) "https" else "http";
    const url = try std.fmt.allocPrint(std.testing.allocator, "{s}://127.0.0.1:{d}/chat", .{ scheme, fixture.port() });
    defer std.testing.allocator.free(url);

    var cancel_flag = std.atomic.Value(bool).init(false);
    var request_done = std.atomic.Value(bool).init(false);
    const Cancel = struct {
        fn run(
            server_fixture: *LoopbackGatewayFixture,
            flag: *std.atomic.Value(bool),
            done: *std.atomic.Value(bool),
            delay_ms: u64,
        ) void {
            if (!server_fixture.waitForStageOrDone(done)) return;
            LoopbackGatewayFixture.sleepBlocking(delay_ms);
            if (done.load(.seq_cst)) return;
            flag.store(true, .seq_cst);
        }
    };
    const cancel_thread = try io_mod.spawn(
        .{},
        Cancel.run,
        .{ &fixture, &cancel_flag, &request_done, cancel_after_stage_ms },
    );

    const request_result = streamResponsesCompletionBounded(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 1,
            .chat_url = url,
            .payload = payload,
        },
        testAwakeDeadlineAfter(5000),
        &cancel_flag,
    );

    request_done.store(true, .seq_cst);
    cancel_thread.join();
    fixture.deinit();

    try std.testing.expectError(error.Cancelled, request_result);
    if (fixture.failure) |err| return err;
    try std.testing.expect(fixture.accepted.load(.seq_cst));
    try std.testing.expect(fixture.reached_stage.load(.seq_cst));
}

test "bounded stream admission rejects cancellation before expiry without starting work" {
    var cancel_flag = std.atomic.Value(bool).init(true);
    var probe = BoundedProbe{
        .alloc = std.testing.allocator,
        .cancel_flag = &cancel_flag,
        .mode = .success,
    };

    try std.testing.expectError(
        error.Cancelled,
        runBoundedStreamOperation(std.testing.allocator, &cancel_flag, testAwakeDeadlineAfter(-1), &probe),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.request_starts);
    try std.testing.expectEqual(@as(usize, 0), probe.active_tasks);
    try std.testing.expectEqual(@as(usize, 0), probe.network_opens);
}

test "bounded stream admission rejects expiry without starting work" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    var probe = BoundedProbe{
        .alloc = std.testing.allocator,
        .cancel_flag = &cancel_flag,
        .mode = .success,
    };

    try std.testing.expectError(
        error.Timeout,
        runBoundedStreamOperation(std.testing.allocator, &cancel_flag, testAwakeDeadlineAfter(-1), &probe),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.request_starts);
    try std.testing.expectEqual(@as(usize, 0), probe.active_tasks);
    try std.testing.expectEqual(@as(usize, 0), probe.network_opens);
}

test "bounded stream returns a request result and joins control branches" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    var probe = BoundedProbe{
        .alloc = std.testing.allocator,
        .cancel_flag = &cancel_flag,
        .mode = .success,
    };

    var result = try runBoundedStreamOperation(std.testing.allocator, &cancel_flag, testAwakeDeadlineAfter(1000), &probe);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ok", result.completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.stop, result.completion.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 1), probe.request_starts);
    try std.testing.expectEqual(@as(usize, 0), probe.active_tasks);
}

test "bounded stream deadline cancels and joins every blocked request stage" {
    inline for (std.meta.tags(BoundedProbeStage)) |stage| {
        var cancel_flag = std.atomic.Value(bool).init(false);
        var probe = BoundedProbe{
            .alloc = std.testing.allocator,
            .cancel_flag = &cancel_flag,
            .mode = .wait,
            .stage = stage,
        };

        try std.testing.expectError(
            error.Timeout,
            runBoundedStreamOperation(std.testing.allocator, &cancel_flag, testAwakeDeadlineAfter(1), &probe),
        );
        try std.testing.expectEqual(stage, probe.reached_stage.?);
        try std.testing.expectEqual(@as(usize, 0), probe.active_tasks);
    }
}

test "bounded stream deadline does not depend on async capacity" {
    const previous_async_limit = std.testing.io_instance.async_limit;
    std.testing.io_instance.setAsyncLimit(.nothing);
    defer std.testing.io_instance.setAsyncLimit(previous_async_limit);

    var cancel_flag = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);
    const Watchdog = struct {
        fn run(flag: *std.atomic.Value(bool), operation_done: *std.atomic.Value(bool)) void {
            var remaining_ms: u64 = 250;
            while (remaining_ms > 0) : (remaining_ms -= 1) {
                if (operation_done.load(.seq_cst)) return;
                LoopbackGatewayFixture.sleepBlocking(1);
            }
            flag.store(true, .seq_cst);
        }
    };
    const watchdog = try io_mod.spawn(.{}, Watchdog.run, .{ &cancel_flag, &done });
    defer {
        done.store(true, .seq_cst);
        watchdog.join();
    }

    var probe = BoundedProbe{
        .alloc = std.testing.allocator,
        .cancel_flag = &cancel_flag,
        .mode = .wait,
    };
    try std.testing.expectError(
        error.Timeout,
        runBoundedStreamOperation(std.testing.allocator, &cancel_flag, testAwakeDeadlineAfter(1), &probe),
    );
    done.store(true, .seq_cst);
    try std.testing.expectEqual(@as(usize, 0), probe.active_tasks);
}

test "bounded stream traces deadline termination" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "bounded-deadline.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "stream");

    var cancel_flag = std.atomic.Value(bool).init(false);
    var probe = BoundedProbe{
        .alloc = alloc,
        .cancel_flag = &cancel_flag,
        .mode = .wait,
    };
    try std.testing.expectError(
        error.Timeout,
        runBoundedStreamOperation(alloc, &cancel_flag, testAwakeDeadlineAfter(1), &probe),
    );

    debug_trace.shutdown();
    const trace = try readTraceFileForTest(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "bounded termination cause=deadline") != null);
}

test "bounded stream cancellation cancels and joins every blocked request stage" {
    const Flip = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(20 * std.time.ns_per_ms);
            flag.store(true, .seq_cst);
        }
    };

    inline for (std.meta.tags(BoundedProbeStage)) |stage| {
        var cancel_flag = std.atomic.Value(bool).init(false);
        const thread = try io_mod.spawn(.{}, Flip.run, .{&cancel_flag});

        var probe = BoundedProbe{
            .alloc = std.testing.allocator,
            .cancel_flag = &cancel_flag,
            .mode = .wait,
            .stage = stage,
        };
        const result = runBoundedStreamOperation(std.testing.allocator, &cancel_flag, testAwakeDeadlineAfter(1000), &probe);
        thread.join();

        try std.testing.expectError(error.Cancelled, result);
        try std.testing.expectEqual(stage, probe.reached_stage.?);
        try std.testing.expectEqual(@as(usize, 0), probe.active_tasks);
    }
}

test "bounded stream cancellation wins when observable while deadline cleanup completes" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    var probe = BoundedProbe{
        .alloc = std.testing.allocator,
        .cancel_flag = &cancel_flag,
        .mode = .wait_and_mark_cancel_when_task_is_cancelled,
    };

    try std.testing.expectError(
        error.Cancelled,
        runBoundedStreamOperation(std.testing.allocator, &cancel_flag, testAwakeDeadlineAfter(1), &probe),
    );
    try std.testing.expect(cancel_flag.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), probe.active_tasks);
}

test "bounded stream discards a successful result when cancellation wins before return" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    var probe = BoundedProbe{
        .alloc = std.testing.allocator,
        .cancel_flag = &cancel_flag,
        .mode = .success_and_cancel,
    };

    try std.testing.expectError(
        error.Cancelled,
        runBoundedStreamOperation(std.testing.allocator, &cancel_flag, testAwakeDeadlineAfter(1000), &probe),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.active_tasks);
}

test "bounded gateway cancellation joins a real TLS handshake stall" {
    try expectBoundedLoopbackCancellation(.tls_handshake_stall, "{}", true, 20, 1200);
}

test "bounded gateway cancellation joins a blocked real request send" {
    const payload = try std.testing.allocator.alloc(u8, 32 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');

    try expectBoundedLoopbackCancellation(.request_send_stall, payload, false, 100, 500);
}

test "bounded gateway cancellation joins a real response head stall" {
    try expectBoundedLoopbackCancellation(.response_head_stall, "{}", false, 20, 500);
}

test "bounded gateway cancellation joins a real response body stall" {
    try expectBoundedLoopbackCancellation(.response_body_stall, "{}", false, 20, 500);
}

test "bounded gateway progress does not extend the absolute deadline" {
    try expectBoundedLoopbackTimeout(.response_body_progress, "{}", 1, 250, 300, 1500);
}

test "delivery certainty stays definitely unsent when request setup fails" {
    var delivery = DeliveryCertainty.init();
    var cancel_flag = std.atomic.Value(bool).init(false);
    const result = streamGatewayCompletion(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 1,
            .chat_url = "http://127.0.0.1:0/responses",
            .payload = "{}",
            .delivery = &delivery,
        },
        @ptrCast(&bounded_stream_discard_ctx),
        discardBoundedContent,
        null,
        &cancel_flag,
    );
    if (result) |value| {
        var owned = value;
        owned.deinit(std.testing.allocator);
        return error.TestExpectedGatewayFailure;
    } else |_| {}
    try std.testing.expectEqual(
        DeliveryCertainty.State.definitely_unsent,
        delivery.load(),
    );
}

test "delivery certainty becomes possibly sent before response head" {
    var fixture = try LoopbackGatewayFixture.init(.response_head_stall, 500);
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));
    const url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/chat",
        .{fixture.port()},
    );
    defer std.testing.allocator.free(url);

    var delivery = DeliveryCertainty.init();
    var cancel_flag = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.Timeout,
        streamResponsesCompletionBounded(
            std.testing.allocator,
            .{
                .api_key = "test-key",
                .model = "test/model",
                .retry_count = 1,
                .chat_url = url,
                .payload = "{}",
                .delivery = &delivery,
            },
            testAwakeDeadlineAfter(20),
            &cancel_flag,
        ),
    );
    try std.testing.expectEqual(
        DeliveryCertainty.State.possibly_sent,
        delivery.load(),
    );
}

test "server error response preserves billing ambiguity" {
    var fixture = try LoopbackGatewayFixture.init(.retry_once, 0);
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));
    const url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/chat",
        .{fixture.port()},
    );
    defer std.testing.allocator.free(url);

    var delivery = DeliveryCertainty.init();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var result = try streamResponsesCompletionBounded(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 1,
            .chat_url = url,
            .payload = "{}",
            .delivery = &delivery,
        },
        testAwakeDeadlineAfter(1000),
        &cancel_flag,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.service_unavailable, result.status);
    try std.testing.expect(result.completion.delivery_ambiguous);
    try std.testing.expectEqual(
        DeliveryCertainty.State.possibly_sent,
        delivery.load(),
    );
}

test "bounded gateway retry sleep uses the original absolute deadline" {
    try expectBoundedLoopbackTimeout(.retry_once, "{}", 2, 250, 0, 1500);
}

test "gateway retry sleep rejects cancellation before waiting" {
    var cancel_flag = std.atomic.Value(bool).init(true);
    try std.testing.expectError(
        error.Cancelled,
        sleepGatewayRetry(std.time.ns_per_s, &cancel_flag),
    );
}

fn expectDirectLoopbackCancellation(
    mode: LoopbackGatewayMode,
    payload: []const u8,
    cancel_after_stage_ms: u64,
    hold_ms: u64,
    max_elapsed_ms: i64,
) !void {
    const zio = io_mod.getIo();
    var fixture = try LoopbackGatewayFixture.init(mode, hold_ms);
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/chat", .{fixture.port()});
    defer std.testing.allocator.free(url);

    var cancel_flag = std.atomic.Value(bool).init(false);
    var request_done = std.atomic.Value(bool).init(false);
    const Cancel = struct {
        fn run(
            server_fixture: *LoopbackGatewayFixture,
            flag: *std.atomic.Value(bool),
            done: *std.atomic.Value(bool),
            delay_ms: u64,
        ) void {
            if (!server_fixture.waitForStageOrDone(done)) return;
            LoopbackGatewayFixture.sleepBlocking(delay_ms);
            if (!done.load(.seq_cst)) flag.store(true, .seq_cst);
        }
    };
    const cancel_thread = try io_mod.spawn(.{}, Cancel.run, .{
        &fixture,
        &cancel_flag,
        &request_done,
        cancel_after_stage_ms,
    });

    const Noop = struct {
        fn onChunk(_: *anyopaque, _: []const u8) void {}
    };
    var callback_ctx: u8 = 0;
    const started = std.Io.Clock.Timestamp.now(zio, .awake);
    const result = streamGatewayCompletionCore(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 1,
            .chat_url = url,
            .payload = payload,
        },
        @ptrCast(&callback_ctx),
        Noop.onChunk,
        null,
        &cancel_flag,
        true,
    );
    const elapsed_ms = started.durationTo(std.Io.Clock.Timestamp.now(zio, .awake)).raw.toMilliseconds();

    request_done.store(true, .seq_cst);
    cancel_thread.join();
    fixture.deinit();

    if (result) |value| {
        var owned = value;
        owned.deinit(std.testing.allocator);
        return error.TestExpectedCancellation;
    } else |err| {
        try std.testing.expectEqual(error.Cancelled, err);
    }
    if (fixture.failure) |err| return err;
    try std.testing.expect(cancel_flag.load(.seq_cst));
    try std.testing.expect(elapsed_ms < max_elapsed_ms);
}

test "direct gateway cancellation closes a stalled response body promptly" {
    try expectDirectLoopbackCancellation(.response_body_stall, "{}", 20, 800, 500);
}

test "direct gateway times out only while awaiting the response head" {
    const zio = io_mod.getIo();
    var fixture = try LoopbackGatewayFixture.init(.response_head_stall, 500);
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/chat", .{fixture.port()});
    defer std.testing.allocator.free(url);
    const Noop = struct {
        fn onChunk(_: *anyopaque, _: []const u8) void {}
    };
    var callback_ctx: u8 = 0;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = DeliveryCertainty.init();
    const started = std.Io.Clock.Timestamp.now(zio, .awake);
    const result = streamGatewayCompletionCoreWithOptions(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 1,
            .chat_url = url,
            .payload = "{}",
            .delivery = &delivery,
        },
        @ptrCast(&callback_ctx),
        Noop.onChunk,
        null,
        &cancel_flag,
        true,
        .{ .response_head_timing = .{ .timeout_ms = 80 } },
    );
    const elapsed_ms = started.durationTo(std.Io.Clock.Timestamp.now(zio, .awake)).raw.toMilliseconds();

    fixture.deinit();
    try std.testing.expectError(error.Timeout, result);
    if (fixture.failure) |err| return err;
    try std.testing.expectEqual(DeliveryCertainty.State.possibly_sent, delivery.load());
    try std.testing.expect(elapsed_ms < 500);
}

test "direct gateway response head timeout does not limit a delayed SSE body" {
    const zio = io_mod.getIo();
    var fixture = try LoopbackGatewayFixture.init(.response_body_delayed_success, 150);
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/chat", .{fixture.port()});
    defer std.testing.allocator.free(url);
    const Noop = struct {
        fn onChunk(_: *anyopaque, _: []const u8) void {}
    };
    var callback_ctx: u8 = 0;
    var cancel_flag = std.atomic.Value(bool).init(false);
    const started = std.Io.Clock.Timestamp.now(zio, .awake);
    var result = try streamGatewayCompletionCoreWithOptions(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 1,
            .chat_url = url,
            .payload = "{}",
        },
        @ptrCast(&callback_ctx),
        Noop.onChunk,
        null,
        &cancel_flag,
        true,
        .{ .response_head_timing = .{ .timeout_ms = 40 } },
    );
    defer result.deinit(std.testing.allocator);
    const elapsed_ms = started.durationTo(std.Io.Clock.Timestamp.now(zio, .awake)).raw.toMilliseconds();

    fixture.deinit();
    if (fixture.failure) |err| return err;
    try std.testing.expectEqual(std.http.Status.ok, result.status);
    try std.testing.expectEqualStrings("ok", result.completion.content.?);
    try std.testing.expect(elapsed_ms >= 100);
}

test "direct gateway cancellation closes a stalled request send promptly" {
    const payload = try std.testing.allocator.alloc(u8, 32 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');

    try expectDirectLoopbackCancellation(.request_send_stall, payload, 100, 5000, 2000);
}

test "direct gateway fails fast when cancellation watcher cannot start" {
    var fixture = try LoopbackGatewayFixture.init(.request_send_stall, 1000);
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/chat", .{fixture.port()});
    defer std.testing.allocator.free(url);

    test_cancel_watcher_spawn_error = error.TestCancelWatcherSpawnFailed;
    defer test_cancel_watcher_spawn_error = null;

    const Noop = struct {
        fn onChunk(_: *anyopaque, _: []const u8) void {}
    };
    var callback_ctx: u8 = 0;
    var cancel_flag = std.atomic.Value(bool).init(false);
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const result = streamGatewayCompletionCore(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 1,
            .chat_url = url,
            .payload = "{}",
        },
        @ptrCast(&callback_ctx),
        Noop.onChunk,
        null,
        &cancel_flag,
        true,
    );
    const elapsed_ms = started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds();

    fixture.deinit();

    try std.testing.expectError(error.TestCancelWatcherSpawnFailed, result);
    if (fixture.failure) |err| return err;
    try std.testing.expect(elapsed_ms < 500);
}

test "direct gateway core callbacks stay on the invoking thread" {
    var fixture = try LoopbackGatewayFixture.init(.success, 100);
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/chat", .{fixture.port()});
    defer std.testing.allocator.free(url);

    const CallbackCapture = struct {
        expected_thread: std.Thread.Id,
        observed_thread: ?std.Thread.Id = null,
        chunk_count: usize = 0,

        fn onChunk(raw: *anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.observed_thread = std.Thread.getCurrentId();
            self.chunk_count += 1;
        }
    };
    var capture = CallbackCapture{ .expected_thread = std.Thread.getCurrentId() };
    var cancel_flag = std.atomic.Value(bool).init(false);
    var result = try streamGatewayCompletionCore(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 1,
            .chat_url = url,
            .payload = "{}",
        },
        @ptrCast(&capture),
        CallbackCapture.onChunk,
        null,
        &cancel_flag,
        false,
    );
    defer result.deinit(std.testing.allocator);
    fixture.deinit();

    if (fixture.failure) |err| return err;
    try std.testing.expectEqualStrings("ok", result.completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.stop, result.completion.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 1), capture.chunk_count);
    try std.testing.expectEqual(capture.expected_thread, capture.observed_thread.?);
}

test "Responses request sends fx user agent without vendor gateway headers" {
    var fixture = try LoopbackGatewayFixture.init(.success_capture, 0);
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/chat", .{fixture.port()});
    defer std.testing.allocator.free(url);

    const Noop = struct {
        fn onChunk(_: *anyopaque, _: []const u8) void {}
    };
    var callback_ctx: u8 = 0;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var result = try streamGatewayCompletionCore(
        std.testing.allocator,
        .{
            .api_key = "test-key",
            .model = "test/model",
            .retry_count = 1,
            .chat_url = url,
            .payload = "{}",
            .session_id = "session_wire_123",
        },
        @ptrCast(&callback_ctx),
        Noop.onChunk,
        null,
        &cancel_flag,
        false,
    );
    defer result.deinit(std.testing.allocator);
    fixture.deinit();

    if (fixture.failure) |err| return err;
    try std.testing.expectEqualStrings(user_agent, fixture.capturedHeaderValue("user-agent").?);
    try std.testing.expectEqualStrings("text/event-stream", fixture.capturedHeaderValue("accept").?);
    try std.testing.expect(fixture.capturedHeaderValue("http-referer") == null);
    try std.testing.expect(std.mem.find(u8, fixture.capturedHeaderValue("user-agent").?, "zig") == null);
}
