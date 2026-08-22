const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const permission_reviewer = @import("gateway/permission_reviewer.zig");

const api_key_validator_contract = @import("../core/auth/api_key_validator.zig");
const agent_stream_provider_contract = @import("../core/agent/stream_provider.zig");
const chatgpt_oauth = @import("../core/auth/chatgpt_oauth.zig");
const credentials = @import("../core/auth/credentials.zig");
const oauth_transport = @import("../core/auth/oauth_transport.zig");
const secret = @import("../core/auth/secret.zig");
const collections = @import("../core/shared/collections.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const gateway_error_format = @import("../core/shared/gateway_error_format.zig");
const gateway_client = @import("../gateway/client.zig");
const gateway_failure_diagnostics = @import("../core/gateway/gateway_failure_diagnostics.zig");
const gateway_json = @import("../core/gateway/gateway_json.zig");
const codex_usage = @import("../core/gateway/codex_usage.zig");
const io_mod = @import("../core/shared/io.zig");
const gateway_generation_usage = @import("../gateway/generation_usage.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const provider_route = @import("../core/gateway/provider_route.zig");
const responses_compaction_binding = @import("../core/gateway/responses_compaction_binding.zig");
const responses_compaction = @import("../core/gateway/responses_compaction.zig");
const responses_compaction_provider = @import("../core/gateway/responses_compaction_provider.zig");
const responses_protocol = @import("../core/gateway/responses_protocol.zig");
const responses_search = @import("../core/gateway/responses_search.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const output_contracts = @import("../core/output/output_contracts.zig");
const shared_types = @import("../core/shared/types.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const session_usage = @import("../core/session/session_usage.zig");
const web_search_contract = @import("../core/tooling/web_search_contract.zig");
const web_search_policy = @import("../core/tooling/web_search_policy.zig");
const web_search_provider = @import("../core/tooling/web_search_provider.zig");
const gateway_schema = @import("../core/tooling/gateway_schema.zig");
const tool_advertisement = @import("../core/tooling/tool_advertisement.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const sort_utils = @import("../core/shared/sort_utils.zig");

const Allocator = std.mem.Allocator;
const FetchGatewayGetResultFn = *const fn (Allocator, ?[]const u8, []const u8) anyerror!gateway_client.GetResult;

const Request = web_search_contract.ProviderRequest;
const Response = web_search_contract.ProviderResponse;
const ProgressFn = web_search_contract.ProgressFn;

pub const default_model = "zai/glm-5.2";
pub const default_chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model";
pub const models_path = "/coding-agent/v1/models";
const credits_path = "/coding-agent/v1/credits";
pub const retry_count: usize = 3;
pub const chat_url_env = "FX_GATEWAY_CHAT_URL";
pub const default_model_catalog_base_url = "https://ai-gateway.vercel.sh";
const base_url_env = "FX_GATEWAY_BASE_URL";
const e2e_gateway_models_url_env = "FX_E2E_GATEWAY_MODELS_URL";
const oauth_request_timeout_ms: i64 = 15_000;
const oauth_response_max_bytes: usize = 64 * 1024;
const compact_response_max_bytes: usize = 32 * 1024 * 1024;

const web_search_system_prompt = "Research the user's query with the web_search tool and preserve sources for citation.";
const perplexity_search_backend_id = web_search_contract.SearchBackendId{ .value = "ai_gateway_perplexity_search" };
const parallel_search_backend_id = web_search_contract.SearchBackendId{ .value = "ai_gateway_parallel_search" };
const codex_search_backend_id = web_search_contract.SearchBackendId{ .value = "codex_standalone_search" };
const responses_default_include = [_][]const u8{"reasoning.encrypted_content"};
const responses_hosted_search_include = [_][]const u8{
    "reasoning.encrypted_content",
    "web_search_call.action.sources",
    "web_search_call.results",
};
const default_web_search_backend_order = [_]web_search_contract.SearchBackendId{
    perplexity_search_backend_id,
    parallel_search_backend_id,
};
const perplexity_search_backend = [_]web_search_contract.SearchBackendId{perplexity_search_backend_id};
const parallel_search_backend = [_]web_search_contract.SearchBackendId{parallel_search_backend_id};
const codex_search_backend = [_]web_search_contract.SearchBackendId{codex_search_backend_id};
const default_web_search_backend_policies = [_]web_search_policy.BackendPolicy{
    .{
        .id = perplexity_search_backend_id,
        .features = .{
            .max_uses = .best_effort,
            .allowed_domains = .pass_through,
            .blocked_domains = .pass_through,
            .ordered_sources = true,
            .usage = true,
            .terminal_incomplete = true,
            .timeout = true,
            .cancellation = true,
            .result_bounds = .post_filter,
        },
    },
    .{
        .id = parallel_search_backend_id,
        .features = .{
            .max_uses = .best_effort,
            .allowed_domains = .pass_through,
            .blocked_domains = .pass_through,
            .ordered_sources = true,
            .usage = true,
            .terminal_incomplete = true,
            .timeout = true,
            .cancellation = true,
            .result_bounds = .pass_through,
        },
    },
    .{
        .id = codex_search_backend_id,
        .features = .{
            .max_uses = .best_effort,
            .allowed_domains = .pass_through,
            .blocked_domains = .pass_through,
            .ordered_sources = true,
            .usage = true,
            .terminal_incomplete = true,
            .timeout = true,
            .cancellation = true,
            .result_bounds = .pass_through,
        },
    },
};

pub const default_web_search_policy = web_search_policy.WebSearchPolicy{
    .preferred_backends = &default_web_search_backend_order,
    .backend_policies = &default_web_search_backend_policies,
};

pub const default_web_search_provider = web_search_provider.Provider{
    .policy = default_web_search_policy,
    .input_overhead_bytes = web_search_system_prompt.len,
    .preferred_backends_fn = resolvePreferredWebSearchBackends,
    .execute_fn = executeWebSearchProvider,
};

pub const chat_url_provider = gateway_provider.ChatUrlProvider{
    .resolve_fn = resolveChatUrlForProvider,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

pub const credits_provider = gateway_provider.CreditsProvider{
    .fetch_fn = fetchCredits,
};

pub const account_usage_provider = gateway_provider.AccountUsageProvider{
    .fetch_fn = fetchAccountUsage,
};

pub const api_key_validator = api_key_validator_contract.Provider{
    .validate_fn = validateApiKey,
};

pub const oauth_transport_provider = oauth_transport.Provider{
    .execute_fn = executeOAuthRequest,
};

pub const generation_usage_provider = gateway_generation_usage.provider;

pub const agent_stream_provider = agent_stream_provider_contract.Provider{
    .build_fn = buildAgentRequest,
    .stream_fn = streamAgentCompletion,
};

pub const responses_compaction_provider_impl = responses_compaction_provider.Provider{
    .fetch_fn = fetchResponsesCompaction,
};

pub const provider = gateway_provider.Provider{
    .agent_stream = agent_stream_provider,
    .oauth_transport = oauth_transport_provider,
    .chat_url = chat_url_provider,
    .cli_model_catalog = cli_model_catalog_provider,
    .credits = credits_provider,
    .account_usage = account_usage_provider,
    .responses_compaction = responses_compaction_provider_impl,
    .generation_usage = generation_usage_provider,
    .web_search = default_web_search_provider,
    .model_catalog = model_catalog_provider,
};

fn fetchResponsesCompaction(
    _: ?*anyopaque,
    alloc: Allocator,
    input: responses_compaction_provider.Request,
) anyerror!responses_compaction_provider.Outcome {
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
    )) {
        return error.ResponsesCompactionIdentityMismatch;
    }

    const wire_model = provider_route.wireModel(route, input.build_request.model);
    const direct_tools = try projectDirectResponseTools(
        alloc,
        input.build_request.serialized_tools,
        route,
        wire_model,
    );
    defer alloc.free(direct_tools);
    try rejectSelectedDirectProviderTools(
        alloc,
        input.build_request.selected_dynamic_tool_schemas,
    );

    var request = input.build_request;
    request.model = wire_model;
    request.serialized_tools = direct_tools;
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
    // Latest Codex deliberately omits service tier for API-key compaction;
    // OAuth retains Fast through the Responses priority tier.
    if (route == .openai_responses_byok) request.provider_options.fast = false;

    const request_options: responses_protocol.RequestOptions = .{
        .capabilities = .{
            .supports_max_output_tokens = route.contract().supports_max_output_tokens,
        },
        .store = false,
        .stream = use_v2_trigger,
        .include = if (use_v2_trigger) &responses_default_include else &.{},
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
        const model_copy = try alloc.dupe(u8, wire_model);
        return .{ .compacted = .{
            .credential_source = source,
            .wire_model = model_copy,
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

    var decoded = try responses_protocol.compaction.decodeResponse(alloc, response.body);
    defer decoded.deinit();
    const input_json = try decoded.replayInputJsonAlloc(alloc);
    errdefer alloc.free(input_json);
    const model_copy = try alloc.dupe(u8, wire_model);
    return .{ .compacted = .{
        .credential_source = source,
        .wire_model = model_copy,
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

pub fn buildAgentRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider_contract.BuildRequest,
) anyerror![]u8 {
    const route = if (request.credential_source) |source|
        provider_route.fromCredentialSource(source) orelse return error.UnsupportedCredentialSource
    else
        provider_route.ProviderRoute.vercel_gateway;
    if (route.contract().wire_api == .openai_responses) {
        const wire_model = provider_route.wireModel(route, request.model);
        const direct_tools = try projectDirectResponseTools(
            alloc,
            request.serialized_tools,
            route,
            wire_model,
        );
        defer alloc.free(direct_tools);
        try rejectSelectedDirectProviderTools(alloc, request.selected_dynamic_tool_schemas);

        var routed_request = request;
        routed_request.model = wire_model;
        routed_request.serialized_tools = direct_tools;
        var owned_provider_binding: ?shared_types.ResponsesCompactionProviderBinding = null;
        defer if (owned_provider_binding) |binding| {
            shared_types.freeResponsesCompactionProviderBinding(alloc, binding);
        };
        if (request.responses_compaction_binding) |binding| {
            const source = request.credential_source orelse
                return error.InvalidResponsesCompactionProviderBinding;
            try responses_compaction_binding.validate(source, binding);
            if (request.provider_credential) |credential| {
                if (!responses_compaction_binding.credentialMatches(
                    source,
                    credential,
                    request.account_id,
                    binding,
                )) return error.ResponsesCompactionProviderBindingMismatch;
            }
            routed_request.responses_compaction_binding = binding;
        } else if (request.provider_credential) |credential| {
            owned_provider_binding = try responses_compaction_binding.buildFromEnvironmentAlloc(
                alloc,
                request.credential_source.?,
                credential,
                request.account_id,
            );
            routed_request.responses_compaction_binding = owned_provider_binding.?.view();
        } else {
            routed_request.responses_compaction_binding = null;
        }
        if (routed_request.provider_options.parallel_tool_calls == null) {
            routed_request.provider_options.parallel_tool_calls = true;
        }
        const summary: ?[]const u8 = if (route == .codex_responses_oauth or
            routed_request.provider_options.reasoning != null)
            "auto"
        else
            null;
        return responses_protocol.buildRequest(alloc, routed_request, .{
            .capabilities = .{
                .supports_max_output_tokens = route.contract().supports_max_output_tokens,
            },
            .prompt_cache_key = request.session_id,
            .reasoning_summary = summary,
            .include = try directResponsesInclude(alloc, route, direct_tools),
            .function_tools_strict = false,
            .responses_input_json = request.responses_input_json,
            .responses_text_options_json = request.responses_text_options_json,
            .responses_reasoning_options_json = request.responses_reasoning_options_json,
            .tool_choice_json = request.responses_tool_choice_json,
            .extra_fields_json = request.responses_extra_fields_json,
        });
    }

    const budget: ?gateway_json.BuildBudget = if (request.budget) |value|
        .{ .deadline = value.deadline, .cancel_flag = value.cancel_flag }
    else
        null;
    if (budget) |active| try active.check();

    if (request.verified_images) |images| {
        const response_format = request.response_format orelse
            return error.MissingStructuredResponseFormat;
        const body = try gateway_json.buildGatewayRequestBodyWithVerifiedImagesAndBudget(
            alloc,
            request.serialized_tools,
            request.messages,
            images,
            request.provider_options,
            request.tool_choice,
            .{
                .name = response_format.name,
                .description = response_format.description,
                .schema_json = response_format.schema_json,
            },
            budget orelse .{},
        );
        return finalizeAgentRequestBody(alloc, request.model, body);
    }
    if (request.response_format != null) return error.StructuredResponseRequiresVerifiedImages;

    if (request.vision_mode == .unavailable and request.selected_dynamic_tool_schemas.len == 0) {
        const body = if (budget) |active|
            gateway_json.buildGatewayRequestBodyWithOptionsAndBudget(
                alloc,
                request.serialized_tools,
                request.messages,
                request.provider_options,
                request.tool_choice,
                request.max_output_tokens,
                active,
            )
        else
            gateway_json.buildGatewayRequestBodyWithOptionsAndOutputLimit(
                alloc,
                request.serialized_tools,
                request.messages,
                request.provider_options,
                request.tool_choice,
                request.max_output_tokens,
            );
        return finalizeAgentRequestBody(alloc, request.model, try body);
    }

    const vision_schema = if (request.vision_mode != .unavailable)
        try writeVisionGatewaySchema(alloc, request.tool_registry)
    else
        null;
    defer if (vision_schema) |schema| alloc.free(schema);

    if (request.vision_mode == .required) {
        const tools_json = try std.fmt.allocPrint(alloc, "[{s}]", .{vision_schema.?});
        defer alloc.free(tools_json);
        const body = if (budget) |active|
            gateway_json.buildGatewayRequiredToolRequestBodyWithOptionsAndBudget(
                alloc,
                tools_json,
                request.messages,
                request.provider_options,
                request.max_output_tokens,
                active,
            )
        else
            gateway_json.buildGatewayRequiredToolRequestBodyWithOptionsAndOutputLimit(
                alloc,
                tools_json,
                request.messages,
                request.provider_options,
                request.max_output_tokens,
            );
        return finalizeAgentRequestBody(alloc, request.model, try body);
    }

    var schemas: std.ArrayList([]const u8) = .empty;
    defer schemas.deinit(alloc);
    try schemas.appendSlice(alloc, request.selected_dynamic_tool_schemas);
    if (vision_schema) |schema| try schemas.append(alloc, schema);
    const tools_json = try tool_advertisement.buildGatewayToolsJsonWithSelectedDynamicSchemas(
        alloc,
        request.serialized_tools,
        schemas.items,
    );
    defer alloc.free(tools_json);
    const body = if (budget) |active|
        gateway_json.buildGatewayRequestBodyWithOptionsAndBudget(
            alloc,
            tools_json,
            request.messages,
            request.provider_options,
            request.tool_choice,
            request.max_output_tokens,
            active,
        )
    else
        gateway_json.buildGatewayRequestBodyWithOptionsAndOutputLimit(
            alloc,
            tools_json,
            request.messages,
            request.provider_options,
            request.tool_choice,
            request.max_output_tokens,
        );
    return finalizeAgentRequestBody(alloc, request.model, try body);
}

fn finalizeAgentRequestBody(
    alloc: Allocator,
    model: []const u8,
    body: []u8,
) ![]u8 {
    if (!std.mem.eql(u8, model, "zai/glm-5.2")) return body;

    errdefer alloc.free(body);
    const identified = try gateway_json.withRequestUserAgent(
        alloc,
        body,
        gateway_client.user_agent,
    );
    alloc.free(body);
    return identified;
}

/// Vercel's `type:provider` tools are not part of the Responses wire contract.
/// The two built-in Gateway search backends have a direct Responses equivalent;
/// all other provider-owned tools are omitted so a direct credential can never
/// activate an Fx worker that sends it back to Vercel.
fn projectDirectResponseTools(
    alloc: Allocator,
    serialized_tools: []const u8,
    route: provider_route.ProviderRoute,
    wire_model: []const u8,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponsesTools,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidResponsesTools;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const codex_namespace = if (route == .codex_responses_oauth)
        try responses_search.buildNamespaceToolAlloc(alloc)
    else
        null;
    defer if (codex_namespace) |tool| alloc.free(tool);
    const supports_hosted_web_search = route == .openai_responses_byok and
        isOpenAiTextModel(wire_model);
    try out.writer.writeByte('[');
    var wrote = false;
    var wrote_native_web_search = false;
    for (parsed.value.array.items) |tool| {
        if (isProviderTool(tool)) {
            if ((codex_namespace != null or supports_hosted_web_search) and
                isGatewaySearchProviderTool(tool) and
                !wrote_native_web_search)
            {
                if (wrote) try out.writer.writeByte(',');
                if (codex_namespace) |namespace_tool| {
                    try out.writer.writeAll(namespace_tool);
                } else {
                    try out.writer.writeAll("{\"type\":\"web_search\"}");
                }
                wrote = true;
                wrote_native_web_search = true;
            } else if (!isGatewaySearchProviderTool(tool) or
                (codex_namespace == null and !supports_hosted_web_search))
            {
                debug_trace.logf("gateway", "omitting unsupported provider-owned tool from direct Responses request", .{});
            }
            continue;
        }
        if (wrote) try out.writer.writeByte(',');
        try std.json.Stringify.value(tool, .{}, &out.writer);
        wrote = true;
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn rejectSelectedDirectProviderTools(
    alloc: Allocator,
    selected_schemas: []const []const u8,
) !void {
    for (selected_schemas) |schema_json| {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, schema_json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResponsesTools,
        };
        defer parsed.deinit();
        switch (parsed.value) {
            .object => if (isProviderTool(parsed.value)) return error.DirectProviderToolUnsupported,
            .array => |tools| for (tools.items) |tool| {
                if (isProviderTool(tool)) return error.DirectProviderToolUnsupported;
            },
            else => return error.InvalidResponsesTools,
        }
    }
}

fn isProviderTool(tool: std.json.Value) bool {
    if (tool != .object) return false;
    const tool_type = tool.object.get("type") orelse return false;
    return tool_type == .string and std.mem.eql(u8, tool_type.string, "provider");
}

fn isGatewaySearchProviderTool(tool: std.json.Value) bool {
    if (!isProviderTool(tool)) return false;
    const id = tool.object.get("id") orelse return false;
    if (id != .string) return false;
    return std.mem.eql(u8, id.string, "gateway.perplexity_search") or
        std.mem.eql(u8, id.string, "gateway.parallel_search");
}

fn directResponsesInclude(
    alloc: Allocator,
    route: provider_route.ProviderRoute,
    serialized_tools: []const u8,
) ![]const []const u8 {
    if (route != .openai_responses_byok) return &responses_default_include;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponsesTools,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidResponsesTools;
    for (parsed.value.array.items) |tool| {
        if (tool != .object) continue;
        const tool_type = tool.object.get("type") orelse continue;
        if (tool_type == .string and std.mem.eql(u8, tool_type.string, "web_search")) {
            return &responses_hosted_search_include;
        }
    }
    return &responses_default_include;
}

fn writeVisionGatewaySchema(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
) ![]u8 {
    const vision_tool = registry.lookup("vision") orelse return error.VisionToolNotRegistered;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try gateway_schema.writeBuiltinFunctionSchema(alloc, &out.writer, vision_tool.gateway_schema);
    return out.toOwnedSlice();
}

test "agent request builder keeps default reasoning silent and emits output limit" {
    const messages = [_]shared_types.ChatMessage{.{ .role = .user, .content = "question" }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .model = "anthropic/claude-opus-4.8",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = model_capabilities.resolveProviderOptions(
            "anthropic/claude-opus-4.8",
            .auto,
            false,
        ),
        .max_output_tokens = 32_000,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"maxOutputTokens\":32000") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"providerOptions\"") == null);
}

test "agent request builder scopes the product user agent to GLM 5.2" {
    const alloc = std.testing.allocator;
    const messages = [_]shared_types.ChatMessage{.{ .role = .user, .content = "question" }};
    const cases = [_]struct {
        model: []const u8,
        include_user_agent: bool,
    }{
        .{ .model = "zai/glm-5.2", .include_user_agent = true },
        .{ .model = "poolside/laguna-s-2.1-free", .include_user_agent = false },
    };

    for (cases) |case| {
        const body = try agent_stream_provider.build(alloc, .{
            .model = case.model,
            .serialized_tools = "[]",
            .messages = &messages,
            .tool_choice = .auto,
            .provider_options = model_capabilities.resolveProviderOptions(case.model, .auto, false),
        });
        defer alloc.free(body);

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer parsed.deinit();

        const headers = parsed.value.object.get("headers");
        if (!case.include_user_agent) {
            try std.testing.expect(headers == null);
            continue;
        }
        const user_agent = headers.?.object.get("user-agent") orelse
            return error.TestExpectedGatewayUserAgent;
        try std.testing.expect(user_agent == .string);
        try std.testing.expectEqualStrings(gateway_client.user_agent, user_agent.string);
    }
}

test "agent request builder overlays selected dynamic schemas" {
    const messages = [_]shared_types.ChatMessage{.{ .role = .user, .content = "question" }};
    const selected_schema = "{\"type\":\"function\",\"name\":\"mcp_fs_read\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}";
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .model = "anthropic/claude",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .auto,
        .selected_dynamic_tool_schemas = &.{selected_schema},
        .provider_options = model_capabilities.resolveProviderOptions(
            "anthropic/claude",
            .auto,
            false,
        ),
        .max_output_tokens = 64_000,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"mcp_fs_read\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"maxOutputTokens\":64000") != null);
}

test "direct Responses request maps Gateway search and omits unknown provider tools" {
    const messages = [_]shared_types.ChatMessage{.{ .role = .system, .content = "instruction" }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .credential_source = .openai_api_key,
        .model = "openai/gpt-5.4",
        .serialized_tools = "[{\"type\":\"provider\",\"id\":\"gateway.perplexity_search\",\"name\":\"perplexity_search\",\"args\":{}},{\"type\":\"provider\",\"id\":\"gateway.future_tool\",\"name\":\"future_tool\",\"args\":{}},{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
        .responses_input_json = "[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_file\",\"file_id\":\"file_123\"}]}]",
        .responses_text_options_json = "{\"verbosity\":\"low\"}",
        .responses_reasoning_options_json = "{\"future_mode\":\"compact\"}",
        .responses_tool_choice_json = "{\"type\":\"function\",\"name\":\"read_file\"}",
        .responses_extra_fields_json = "{\"metadata\":{\"source\":\"fx-test\"},\"temperature\":0.2}",
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"gpt-5.4\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"web_search\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "gateway.perplexity_search") == null);
    try std.testing.expect(std.mem.find(u8, body, "gateway.future_tool") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":{\"type\":\"function\",\"name\":\"read_file\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"file_id\":\"file_123\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"verbosity\":\"low\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"future_mode\":\"compact\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"metadata\":{\"source\":\"fx-test\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"temperature\":2e-1") != null or
        std.mem.find(u8, body, "\"temperature\":0.2") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const include = parsed.value.object.get("include").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), include.len);
    try std.testing.expectEqualStrings("reasoning.encrypted_content", include[0].string);
    try std.testing.expectEqualStrings("web_search_call.action.sources", include[1].string);
    try std.testing.expectEqualStrings("web_search_call.results", include[2].string);
}

test "Codex Responses request advertises latest web namespace instead of hosted search" {
    const messages = [_]shared_types.ChatMessage{.{ .role = .user, .content = "research Zig" }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .credential_source = .chatgpt_subscription,
        .model = "gpt-5.6-sol",
        .serialized_tools = "[{\"type\":\"provider\",\"id\":\"gateway.perplexity_search\",\"name\":\"perplexity_search\",\"args\":{}}]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("namespace", tools[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("web", tools[0].object.get("name").?.string);
    try std.testing.expectEqualStrings(
        "run",
        tools[0].object.get("tools").?.array.items[0].object.get("name").?.string,
    );
    const include = parsed.value.object.get("include").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), include.len);
    try std.testing.expectEqualStrings("reasoning.encrypted_content", include[0].string);
    try std.testing.expect(parsed.value.object.get("parallel_tool_calls").?.bool);
}

test "direct Responses request rejects selected provider-owned schemas" {
    const messages = [_]shared_types.ChatMessage{.{ .role = .user, .content = "question" }};
    try std.testing.expectError(error.DirectProviderToolUnsupported, agent_stream_provider.build(std.testing.allocator, .{
        .credential_source = .chatgpt_subscription,
        .model = "gpt-5.6-sol",
        .serialized_tools = "[]",
        .selected_dynamic_tool_schemas = &.{"{\"type\":\"provider\",\"id\":\"gateway.future\"}"},
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    }));
}

test "direct compatible model without native search capability drops Gateway search" {
    const messages = [_]shared_types.ChatMessage{.{ .role = .user, .content = "question" }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .credential_source = .openai_api_key,
        .model = "acme/llama-agent",
        .serialized_tools = "[{\"type\":\"provider\",\"id\":\"gateway.parallel_search\",\"name\":\"parallel_search\",\"args\":{}}]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "gateway.parallel_search") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"web_search\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"tools\":[]") != null);
}

test "required vision request contains only the registered vision schema" {
    const Callbacks = struct {
        fn decode(_: tool_dispatch.DispatchContext, _: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
            return error.InvalidToolArguments;
        }

        fn call(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
            return error.InvalidToolArguments;
        }

        fn readsOnly(_: tool_dispatch.ToolInput) bool {
            return true;
        }

        fn isIrreversible(_: tool_dispatch.ToolInput) bool {
            return false;
        }
    };
    const messages = [_]shared_types.ChatMessage{.{ .role = .user, .content = "inspect image 7" }};
    const vision_tool = tool_dispatch.Tool{
        .name = "vision",
        .description = "registry-owned vision schema sentinel",
        .gateway_schema = .{
            .name = "vision",
            .description = "registry-owned vision schema sentinel",
        },
        .executor_kind = .vision,
        .decode = Callbacks.decode,
        .call = Callbacks.call,
        .reads_only_fn = Callbacks.readsOnly,
        .irreversible_fn = Callbacks.isIrreversible,
    };
    const registered_tools = [_]tool_dispatch.Tool{vision_tool};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .model = "zai/glm-5.2",
        .tool_registry = .{ .tools = registered_tools[0..] },
        .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]",
        .messages = &messages,
        .tool_choice = .none,
        .selected_dynamic_tool_schemas = &.{"{\"type\":\"function\",\"name\":\"mcp_fs_read\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}"},
        .vision_mode = .required,
        .provider_options = model_capabilities.resolveProviderOptions(
            "zai/glm-5.2",
            .auto,
            false,
        ),
        .max_output_tokens = 128_000,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"toolChoice\":{\"type\":\"required\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"vision\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "registry-owned vision schema sentinel") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"read_file\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"mcp_fs_read\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"maxOutputTokens\":128000") != null);
}

fn streamAgentCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider_contract.Request,
) anyerror!agent_stream_provider_contract.Result {
    if (request.credential_source == .chatgpt_subscription or request.credential_source == .grok_subscription) {
        return error.SubscriptionCredentialCannotAuthorizeGateway;
    }
    const result = gateway_client.streamGatewayCompletion(
        alloc,
        .{
            .api_key = request.api_key,
            .credential_source = request.credential_source,
            .responses_compaction_binding = request.responses_compaction_binding,
            .team = request.team,
            .session_id = request.session_id,
            .model = request.model,
            .retry_count = request.retry_count,
            .chat_url = request.chat_url,
            .payload = request.payload,
            .trace_ctx = request.trace_ctx,
            .content_capture_limit = request.content_capture_limit,
            .delivery = request.delivery,
            .on_reasoning_chunk = request.on_reasoning_chunk,
            .on_tool_input_chunk = request.on_tool_input_chunk,
            .on_responses_unhandled_event = request.on_unhandled_provider_event,
            .provider_attempt_owner = switch (request.provider_attempt_owner) {
                .transport => .transport,
                .agent => .agent,
            },
        },
        request.callback_ctx,
        request.on_content_chunk,
        request.on_tool_start,
        request.cancel_flag,
    ) catch |err| {
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(
            err,
            request.delivery.load(),
        );
        return err;
    };
    const diagnostics = if (result.status == .ok)
        gateway_failure_diagnostics.FailureDiagnostics{}
    else
        gateway_failure_diagnostics.collect(alloc, request.payload, result.err_body);
    const route = if (request.credential_source) |source|
        provider_route.fromCredentialSource(source) orelse return error.UnsupportedCredentialSource
    else
        provider_route.ProviderRoute.vercel_gateway;
    const direct_responses = route.contract().wire_api == .openai_responses;
    return .{
        .status = result.status,
        .completion = result.completion,
        .err_body = result.err_body,
        .generation_origin = if (direct_responses) "" else gateway_client.generationBaseUrl(),
        .reconcile_generation_usage = !direct_responses,
        .accounting = if (direct_responses) .direct_usage else .gateway_generation,
        .failure_schema = diagnostics.schema,
        .failure_request_shape = diagnostics.request_shape,
        .retry_after_seconds = result.retry_after_seconds,
        .ownership = .owned,
    };
}

fn fetchCredits(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CreditsLookupInput,
) output_contracts.CreditsSnapshot {
    if (input.credential_source) |source| {
        const route = provider_route.fromCredentialSource(source) orelse {
            return creditsErrorSnapshot(alloc, "credits are unavailable for this credential source");
        };
        if (!route.contract().supports_credits) {
            return creditsErrorSnapshot(alloc, "credits are available only for Vercel AI Gateway credentials");
        }
    }
    return fetchCreditsWithFetch(
        alloc,
        input.credential,
        input.tenant,
        gateway_client.fetchGatewayGetResult,
    );
}

fn fetchAccountUsage(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.AccountUsageLookupInput,
) output_contracts.CodexAccountUsageSnapshot {
    if (input.credential_source != .chatgpt_subscription) {
        return codexAccountUsageFailure(.unsupported_credential_source, null);
    }
    const access_token = input.credential orelse
        return codexAccountUsageFailure(.missing_credential, null);
    if (access_token.len == 0) return codexAccountUsageFailure(.missing_credential, null);
    const account_id = input.account_id orelse
        return codexAccountUsageFailure(.missing_account_id, null);
    if (account_id.len == 0) return codexAccountUsageFailure(.missing_account_id, null);

    var endpoints = codex_usage.resolveEndpointsAlloc(
        alloc,
        codex_usage.EndpointOverrides.fromEnvironment(),
    ) catch |err| {
        debug_trace.logf("codex_usage", "endpoint resolution failed err={s}", .{@errorName(err)});
        return codexAccountUsageFailure(codexUsageFailureKindForError(err), null);
    };
    defer endpoints.deinit(alloc);

    return fetchAccountUsageWithRetry(
        alloc,
        endpoints,
        access_token,
        account_id,
        input.cancel_flag,
        .{},
    );
}

const AccountUsageRetryDependencies = struct {
    context: ?*anyopaque = null,
    fetch_pair_fn: *const fn (
        ?*anyopaque,
        Allocator,
        codex_usage.Endpoints,
        []const u8,
        []const u8,
        ?*std.atomic.Value(bool),
    ) output_contracts.CodexAccountUsageSnapshot = fetchAccountUsagePairProvider,
    load_credential_fn: *const fn (
        ?*anyopaque,
        Allocator,
        AccountUsageCredentialRetryMode,
    ) anyerror!?chatgpt_oauth.Access = loadCodexAuthForUsageRetry,
};

const AccountUsageCredentialRetryMode = enum {
    reload,
    force_refresh,
};

fn fetchAccountUsageWithRetry(
    alloc: Allocator,
    endpoints: codex_usage.Endpoints,
    access_token: []const u8,
    account_id: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    dependencies: AccountUsageRetryDependencies,
) output_contracts.CodexAccountUsageSnapshot {
    var first = dependencies.fetch_pair_fn(
        dependencies.context,
        alloc,
        endpoints,
        access_token,
        account_id,
        cancel_flag,
    );
    const retry_mode: AccountUsageCredentialRetryMode = if (first.failure) |failure|
        switch (failure.kind) {
            .unauthorized => .force_refresh,
            .credential_changed => .reload,
            else => return first,
        }
    else
        return first;
    first.deinit(alloc);

    var refreshed = (dependencies.load_credential_fn(dependencies.context, alloc, retry_mode) catch |err| {
        debug_trace.logf("codex_usage", "credential retry failed mode={s} err={s}", .{ @tagName(retry_mode), @errorName(err) });
        return codexAccountUsageFailure(codexUsageFailureKindForError(err), null);
    }) orelse return codexAccountUsageFailure(.credential_unavailable, null);
    defer refreshed.deinit(alloc);
    if (!std.mem.eql(u8, refreshed.account_id, account_id)) {
        return codexAccountUsageFailure(.credential_changed, null);
    }
    return dependencies.fetch_pair_fn(
        dependencies.context,
        alloc,
        endpoints,
        refreshed.access_token,
        refreshed.account_id,
        cancel_flag,
    );
}

fn loadCodexAuthForUsageRetry(
    _: ?*anyopaque,
    alloc: Allocator,
    mode: AccountUsageCredentialRetryMode,
) !?chatgpt_oauth.Access {
    return switch (mode) {
        .reload => chatgpt_oauth.loadAccess(alloc, oauth_transport_provider, .stored),
        .force_refresh => chatgpt_oauth.loadAccess(alloc, oauth_transport_provider, .force),
    };
}

fn fetchAccountUsagePairProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    endpoints: codex_usage.Endpoints,
    access_token: []const u8,
    account_id: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
) output_contracts.CodexAccountUsageSnapshot {
    return fetchAccountUsagePair(
        alloc,
        endpoints,
        access_token,
        account_id,
        cancel_flag,
    );
}

fn fetchAccountUsagePair(
    alloc: Allocator,
    endpoints: codex_usage.Endpoints,
    access_token: []const u8,
    account_id: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
) output_contracts.CodexAccountUsageSnapshot {
    var usage_response = gateway_client.fetchCodexJsonBounded(alloc, .{
        .method = .get,
        .url = endpoints.usage,
        .access_token = access_token,
        .account_id = account_id,
        .cancel_flag = cancel_flag,
        .max_response_bytes = codex_usage.max_response_bytes,
    }) catch |err| {
        debug_trace.logf("codex_usage", "usage request failed err={s}", .{@errorName(err)});
        return codexAccountUsageFailure(codexUsageFailureKindForError(err), null);
    };
    defer usage_response.deinit(alloc);
    if (usage_response.status != .ok) {
        return codexAccountUsageFailureForStatus(usage_response.status);
    }

    // The second request is independently checked against the same access
    // token and account id. If the auth file changes between calls, the client
    // returns CodexCredentialChanged and this partial pair is discarded.
    var profile_response = gateway_client.fetchCodexJsonBounded(alloc, .{
        .method = .get,
        .url = endpoints.profile,
        .access_token = access_token,
        .account_id = account_id,
        .cancel_flag = cancel_flag,
        .max_response_bytes = codex_usage.max_response_bytes,
    }) catch |err| {
        debug_trace.logf("codex_usage", "profile request failed err={s}", .{@errorName(err)});
        return codexAccountUsageFailure(codexUsageFailureKindForError(err), null);
    };
    defer profile_response.deinit(alloc);
    if (profile_response.status != .ok) {
        return codexAccountUsageFailureForStatus(profile_response.status);
    }

    const data = codex_usage.parseSnapshot(
        alloc,
        usage_response.body,
        profile_response.body,
        io_mod.milliTimestamp(),
    ) catch |err| {
        debug_trace.logf("codex_usage", "response parse failed err={s}", .{@errorName(err)});
        return codexAccountUsageFailure(codexUsageFailureKindForError(err), null);
    };
    return .{ .data = data };
}

fn codexAccountUsageFailure(
    kind: codex_usage.FailureKind,
    status: ?std.http.Status,
) output_contracts.CodexAccountUsageSnapshot {
    return .{ .failure = .{ .kind = kind, .http_status = status } };
}

fn codexAccountUsageFailureForStatus(status: std.http.Status) output_contracts.CodexAccountUsageSnapshot {
    const kind: codex_usage.FailureKind = switch (status) {
        .unauthorized => .unauthorized,
        .forbidden => .forbidden,
        .too_many_requests => .rate_limited,
        else => .http_error,
    };
    return codexAccountUsageFailure(kind, status);
}

fn codexUsageFailureKindForError(err: anyerror) codex_usage.FailureKind {
    return switch (err) {
        error.OutOfMemory => .resource_exhausted,
        error.Cancelled => .cancelled,
        error.Timeout => .timeout,
        error.CodexAuthUnavailable,
        error.CodexCredentialUnavailable,
        => .credential_unavailable,
        error.CodexAccountChanged,
        error.CodexCredentialChanged,
        => .credential_changed,
        error.CodexJsonResponseTooLarge,
        error.CodexUsageResponseTooLarge,
        => .response_too_large,
        error.InvalidCodexUsageResponse,
        error.InvalidCodexTokenProfileResponse,
        error.TooManyCodexRateLimits,
        error.TooManyCodexDailyUsageBuckets,
        => .invalid_response,
        error.InvalidBaseUrl,
        error.BaseUrlContainsUserInfo,
        error.BaseUrlContainsQueryOrFragment,
        error.InsecureBaseUrl,
        error.InvalidUri,
        => .invalid_endpoint,
        else => .transport,
    };
}

test "account usage provider rejects unbound and non-Codex credentials before transport" {
    var wrong_source = fetchAccountUsage(null, std.testing.allocator, .{
        .credential = "key",
        .account_id = "account",
        .credential_source = .openai_api_key,
    });
    defer wrong_source.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        codex_usage.FailureKind.unsupported_credential_source,
        wrong_source.failure.?.kind,
    );

    var missing_account = fetchAccountUsage(null, std.testing.allocator, .{
        .credential = "access",
        .account_id = null,
        .credential_source = .chatgpt_subscription,
    });
    defer missing_account.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        codex_usage.FailureKind.missing_account_id,
        missing_account.failure.?.kind,
    );
}

test "account usage provider classifies provider HTTP failures without response detail" {
    var unauthorized = codexAccountUsageFailureForStatus(.unauthorized);
    defer unauthorized.deinit(std.testing.allocator);
    try std.testing.expectEqual(codex_usage.FailureKind.unauthorized, unauthorized.failure.?.kind);
    try std.testing.expectEqual(std.http.Status.unauthorized, unauthorized.failure.?.http_status.?);

    var throttled = codexAccountUsageFailureForStatus(.too_many_requests);
    defer throttled.deinit(std.testing.allocator);
    try std.testing.expectEqual(codex_usage.FailureKind.rate_limited, throttled.failure.?.kind);
}

test "account usage provider refreshes once and retries the complete pair for the same account" {
    const Fake = struct {
        pair_calls: usize = 0,
        refresh_calls: usize = 0,
        saw_initial_access: bool = false,
        saw_refreshed_access: bool = false,
        saw_force_refresh: bool = false,
        refresh_account: []const u8 = "account",

        fn fetchPair(
            raw: ?*anyopaque,
            _: Allocator,
            _: codex_usage.Endpoints,
            access_token: []const u8,
            account_id: []const u8,
            _: ?*std.atomic.Value(bool),
        ) output_contracts.CodexAccountUsageSnapshot {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.pair_calls += 1;
            self.saw_initial_access = self.saw_initial_access or
                (std.mem.eql(u8, access_token, "expired") and
                    std.mem.eql(u8, account_id, "account"));
            self.saw_refreshed_access = self.saw_refreshed_access or
                (std.mem.eql(u8, access_token, "fresh") and
                    std.mem.eql(u8, account_id, "account"));
            return if (self.pair_calls == 1)
                codexAccountUsageFailure(.unauthorized, .unauthorized)
            else
                codexAccountUsageFailure(.forbidden, .forbidden);
        }

        fn loadCredential(
            raw: ?*anyopaque,
            alloc: Allocator,
            mode: AccountUsageCredentialRetryMode,
        ) !?chatgpt_oauth.Access {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.refresh_calls += 1;
            self.saw_force_refresh = mode == .force_refresh;
            const access_token = try alloc.dupe(u8, "fresh");
            errdefer alloc.free(access_token);
            return .{
                .access_token = access_token,
                .account_id = try alloc.dupe(u8, self.refresh_account),
                .refresh_after_ms = 0,
            };
        }
    };

    const endpoints = codex_usage.Endpoints{
        .usage = @constCast("usage"),
        .profile = @constCast("profile"),
    };
    var fake: Fake = .{};
    var result = fetchAccountUsageWithRetry(
        std.testing.allocator,
        endpoints,
        "expired",
        "account",
        null,
        .{
            .context = &fake,
            .fetch_pair_fn = Fake.fetchPair,
            .load_credential_fn = Fake.loadCredential,
        },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), fake.pair_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.refresh_calls);
    try std.testing.expect(fake.saw_initial_access);
    try std.testing.expect(fake.saw_refreshed_access);
    try std.testing.expect(fake.saw_force_refresh);
    try std.testing.expectEqual(codex_usage.FailureKind.forbidden, result.failure.?.kind);
}

test "account usage provider rejects a cross-account refresh without retrying" {
    const Fake = struct {
        pair_calls: usize = 0,
        refresh_calls: usize = 0,

        fn fetchPair(
            raw: ?*anyopaque,
            _: Allocator,
            _: codex_usage.Endpoints,
            _: []const u8,
            _: []const u8,
            _: ?*std.atomic.Value(bool),
        ) output_contracts.CodexAccountUsageSnapshot {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.pair_calls += 1;
            return codexAccountUsageFailure(.unauthorized, .unauthorized);
        }

        fn loadCredential(
            raw: ?*anyopaque,
            alloc: Allocator,
            mode: AccountUsageCredentialRetryMode,
        ) !?chatgpt_oauth.Access {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.refresh_calls += 1;
            try std.testing.expectEqual(AccountUsageCredentialRetryMode.force_refresh, mode);
            const access_token = try alloc.dupe(u8, "other-access");
            errdefer alloc.free(access_token);
            return .{
                .access_token = access_token,
                .account_id = try alloc.dupe(u8, "other-account"),
                .refresh_after_ms = 0,
            };
        }
    };

    var fake: Fake = .{};
    var result = fetchAccountUsageWithRetry(
        std.testing.allocator,
        .{ .usage = @constCast("usage"), .profile = @constCast("profile") },
        "expired",
        "account",
        null,
        .{
            .context = &fake,
            .fetch_pair_fn = Fake.fetchPair,
            .load_credential_fn = Fake.loadCredential,
        },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), fake.pair_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.refresh_calls);
    try std.testing.expectEqual(codex_usage.FailureKind.credential_changed, result.failure.?.kind);
}

test "account usage provider reloads a concurrently replaced same-account credential" {
    const Fake = struct {
        pair_calls: usize = 0,
        load_calls: usize = 0,
        saw_reload: bool = false,
        saw_reloaded_access: bool = false,

        fn fetchPair(
            raw: ?*anyopaque,
            _: Allocator,
            _: codex_usage.Endpoints,
            access_token: []const u8,
            account_id: []const u8,
            _: ?*std.atomic.Value(bool),
        ) output_contracts.CodexAccountUsageSnapshot {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.pair_calls += 1;
            self.saw_reloaded_access = self.saw_reloaded_access or
                (std.mem.eql(u8, access_token, "replacement") and
                    std.mem.eql(u8, account_id, "account"));
            return if (self.pair_calls == 1)
                codexAccountUsageFailure(.credential_changed, null)
            else
                codexAccountUsageFailure(.forbidden, .forbidden);
        }

        fn loadCredential(
            raw: ?*anyopaque,
            alloc: Allocator,
            mode: AccountUsageCredentialRetryMode,
        ) !?chatgpt_oauth.Access {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.load_calls += 1;
            self.saw_reload = mode == .reload;
            const access_token = try alloc.dupe(u8, "replacement");
            errdefer alloc.free(access_token);
            return .{
                .access_token = access_token,
                .account_id = try alloc.dupe(u8, "account"),
                .refresh_after_ms = 0,
            };
        }
    };

    var fake: Fake = .{};
    var result = fetchAccountUsageWithRetry(
        std.testing.allocator,
        .{ .usage = @constCast("usage"), .profile = @constCast("profile") },
        "replaced",
        "account",
        null,
        .{
            .context = &fake,
            .fetch_pair_fn = Fake.fetchPair,
            .load_credential_fn = Fake.loadCredential,
        },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), fake.pair_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.load_calls);
    try std.testing.expect(fake.saw_reload);
    try std.testing.expect(fake.saw_reloaded_access);
    try std.testing.expectEqual(codex_usage.FailureKind.forbidden, result.failure.?.kind);
}

/// An fx login can reach several teams, so `/v1/credits` rejects it outright
/// unless the request names one. The endpoint reads the team from a `teamId`
/// query value and ignores `x-vercel-ai-gateway-team`, which is the reverse of
/// the inference endpoint. An API key carries its own team and resolves to no
/// team here, so the query value is added for logins only.
fn fetchCreditsWithFetch(
    alloc: Allocator,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    fetch_fn: FetchGatewayGetResultFn,
) output_contracts.CreditsSnapshot {
    var team_path: ?[]u8 = null;
    defer if (team_path) |path| alloc.free(path);
    if (gateway_team) |team| {
        if (shared_types.validGatewayTeam(team)) {
            team_path = std.fmt.allocPrint(alloc, "{s}?teamId={s}", .{ credits_path, team }) catch {
                return creditsErrorSnapshot(alloc, "failed to fetch credits from gateway");
            };
        } else {
            debug_trace.logf("credits", "team omitted from query; not url safe len={d}", .{team.len});
        }
    }

    var result = fetch_fn(alloc, api_key, team_path orelse credits_path) catch {
        return creditsErrorSnapshot(alloc, "failed to fetch credits from gateway");
    };
    defer result.deinit(alloc);

    if (result.status != .ok) {
        const message = gateway_error_format.formatHttpErrorMessage(alloc, result.status, result.body) catch {
            return creditsErrorSnapshot(alloc, "failed to fetch credits from gateway");
        };
        return .{ .err_message = message };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, result.body, .{}) catch {
        return creditsErrorSnapshot(alloc, "invalid JSON response from gateway");
    };
    defer parsed.deinit();

    return creditsSnapshotFromJsonValue(alloc, parsed.value) catch {
        return creditsErrorSnapshot(alloc, "invalid JSON response from gateway");
    };
}

fn creditsSnapshotFromJsonValue(
    alloc: Allocator,
    value: std.json.Value,
) !output_contracts.CreditsSnapshot {
    if (value != .object) {
        return creditsErrorSnapshot(alloc, "unexpected response format from gateway");
    }

    const obj = value.object;
    var snapshot = output_contracts.CreditsSnapshot{};
    errdefer snapshot.deinit(alloc);

    if (obj.get("balance")) |field| {
        if (field == .string) snapshot.balance = try alloc.dupe(u8, field.string);
    }
    if (obj.get("used")) |field| {
        if (field == .string) snapshot.used = try alloc.dupe(u8, field.string);
    }
    if (obj.get("plan")) |field| {
        if (field == .string) snapshot.plan = try alloc.dupe(u8, field.string);
    }

    return snapshot;
}

fn creditsErrorSnapshot(
    alloc: Allocator,
    message: []const u8,
) output_contracts.CreditsSnapshot {
    return .{
        .raw_json = null,
        .err_message = alloc.dupe(u8, message) catch null,
    };
}

fn executeOAuthRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: oauth_transport.Request,
) !oauth_transport.Response {
    var local_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = request.cancel_flag orelse &local_cancel;
    const deadline = request.deadline orelse std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(oauth_request_timeout_ms),
    });
    var operation = OAuthHttpOperation{
        .alloc = alloc,
        .request = request,
    };
    return gateway_client.runBoundedHttpOperation(
        oauth_transport.Response,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
}

const OAuthHttpOperation = struct {
    alloc: Allocator,
    request: oauth_transport.Request,

    pub fn run(self: *@This()) !oauth_transport.Response {
        var client: std.http.Client = .{
            .allocator = self.alloc,
            .io = io_mod.getIo(),
        };
        defer client.deinit();

        const response_buffer = try self.alloc.alloc(u8, oauth_response_max_bytes + 1);
        defer secret.zeroAndFree(self.alloc, response_buffer);
        var response_writer = std.Io.Writer.fixed(response_buffer);

        const result = client.fetch(.{
            .location = .{ .url = self.request.url },
            .method = switch (self.request.method) {
                .get => .GET,
                .post_form, .post_json => .POST,
            },
            .payload = self.request.payload,
            .headers = .{
                .content_type = switch (self.request.method) {
                    .get => .default,
                    .post_form => .{ .override = "application/x-www-form-urlencoded" },
                    .post_json => .{ .override = "application/json" },
                },
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
                .authorization = if (self.request.authorization) |value|
                    .{ .override = value }
                else
                    .default,
            },
            .redirect_behavior = .unhandled,
            .response_writer = &response_writer,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.OAuthResponseTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        if (body.len > oauth_response_max_bytes) return error.OAuthResponseTooLarge;

        return .{
            .disposition = if (result.status.class() == .success) .accepted else .rejected,
            .status = result.status,
            .body = try self.alloc.dupe(u8, body),
        };
    }
};

test "oauth transport user agent uses the product version" {
    try std.testing.expect(std.mem.startsWith(u8, gateway_client.user_agent, "fx/"));
    try std.testing.expect(gateway_client.user_agent.len > "fx/".len);
    try std.testing.expect(std.mem.find(u8, gateway_client.user_agent, "zig") == null);
    try std.testing.expect(std.mem.find(u8, gateway_client.user_agent, "std.http") == null);
}

fn validateApiKey(
    _: ?*anyopaque,
    alloc: Allocator,
    api_key: []const u8,
) api_key_validator_contract.Result {
    var result = gateway_client.fetchGatewayGetResult(alloc, api_key, models_path) catch |err| {
        debug_trace.logf("auth", "api key validation failed err={s}", .{@errorName(err)});
        return .unavailable;
    };
    defer result.deinit(alloc);
    return apiKeyValidationForStatus(result.status);
}

fn apiKeyValidationForStatus(status: std.http.Status) api_key_validator_contract.Result {
    return switch (status) {
        .ok => .accepted,
        .unauthorized, .forbidden => .refused,
        else => .unavailable,
    };
}

test "API key validator preserves Gateway status mapping" {
    try std.testing.expectEqual(api_key_validator_contract.Result.accepted, apiKeyValidationForStatus(.ok));
    try std.testing.expectEqual(api_key_validator_contract.Result.refused, apiKeyValidationForStatus(.unauthorized));
    try std.testing.expectEqual(api_key_validator_contract.Result.refused, apiKeyValidationForStatus(.forbidden));
    try std.testing.expectEqual(api_key_validator_contract.Result.unavailable, apiKeyValidationForStatus(.internal_server_error));
}

pub fn preferredWebSearchBackendsOverride(raw: ?[]const u8) !?[]const web_search_contract.SearchBackendId {
    const value = raw orelse return null;
    if (value.len == 0) return null;
    if (std.mem.eql(u8, value, "ai_gateway_perplexity_search")) return &perplexity_search_backend;
    if (std.mem.eql(u8, value, "ai_gateway_parallel_search")) return &parallel_search_backend;
    return error.InvalidWebSearchBackend;
}

pub fn selectedWebSearchBackend() !web_search_contract.SearchBackendId {
    if (try preferredWebSearchBackendsOverride(io_mod.getenv("FX_WEB_SEARCH_BACKEND"))) |backends| {
        return backends[0];
    }
    return default_web_search_backend_order[0];
}

fn resolvePreferredWebSearchBackends(
    _: ?*anyopaque,
    inputs: web_search_provider.Inputs,
) !?[]const web_search_contract.SearchBackendId {
    if (inputs.credential_source == .chatgpt_subscription) return &codex_search_backend;
    return preferredWebSearchBackendsOverride(io_mod.getenv("FX_WEB_SEARCH_BACKEND"));
}

fn executeWebSearchProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    inputs: web_search_provider.Inputs,
    request: Request,
    on_progress: ?ProgressFn,
    progress_ctx: ?*anyopaque,
) !Response {
    if (request.backend.eql(codex_search_backend_id)) {
        return executeCodexStandaloneSearch(
            alloc,
            inputs,
            request,
            on_progress,
            progress_ctx,
        );
    }
    if (inputs.credential_source == .chatgpt_subscription) {
        return error.InvalidWebSearchBackend;
    }
    return executeGatewayWorker(alloc, .{
        .api_key = inputs.api_key,
        .team = inputs.gateway_team,
        .model = inputs.worker_model,
        .retry_count = inputs.gateway_retry_count,
        .chat_url = inputs.gateway_chat_url,
        .usage = inputs.usage,
        .usage_allocator = inputs.usage_allocator,
    }, request, on_progress, progress_ctx);
}

fn executeCodexStandaloneSearch(
    alloc: Allocator,
    inputs: web_search_provider.Inputs,
    request: Request,
    on_progress: ?ProgressFn,
    progress_ctx: ?*anyopaque,
) !Response {
    if (inputs.credential_source != .chatgpt_subscription) return error.InvalidWebSearchBackend;
    if (inputs.api_key.len == 0) return error.MissingGatewaySearchConfiguration;
    const account_id = inputs.account_id orelse
        return error.CodexCredentialChanged;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (on_progress) |progress| progress(
        progress_ctx orelse return error.MissingProgressContext,
        .{ .query_update = request.query },
    );

    const endpoint = try provider_route.resolveSearchEndpointFromEnvironmentAlloc(
        alloc,
        .codex_responses_oauth,
    );
    defer alloc.free(endpoint);
    const commands = if (request.commands_json) |raw|
        try alloc.dupe(u8, raw)
    else
        try buildCodexSearchCommandsAlloc(alloc, request);
    defer alloc.free(commands);
    const settings = try buildCodexSearchSettingsAlloc(alloc, request);
    defer alloc.free(settings);
    const payload = try responses_search.buildRequest(alloc, .{
        .id = request.request_id orelse "fx_web_search",
        .model = provider_route.wireModel(.codex_responses_oauth, inputs.worker_model),
        .input_json = request.input_json,
        .commands_json = commands,
        .settings_json = settings,
        .max_output_tokens = request.max_output_tokens,
    });
    defer alloc.free(payload);

    var result = try gateway_client.fetchCodexJsonBounded(alloc, .{
        .method = .post_json,
        .url = endpoint,
        .access_token = inputs.api_key,
        .account_id = account_id,
        .payload = payload,
        .cancel_flag = @constCast(request.cancel_flag),
        .deadline = deadlineAfterMs(request.timeout_ms),
        .max_response_bytes = 512 * 1024,
    });
    defer result.deinit(alloc);
    if (result.status.class() != .success) return error.CodexSearchRequestFailed;

    var decoded = try responses_search.decodeResponse(alloc, result.body);
    defer decoded.deinit();
    const content = try materializeCodexSearchContent(
        alloc,
        decoded,
        request.request_id orelse "codex-search",
    );
    errdefer {
        for (content) |item| item.deinit(alloc);
        alloc.free(content);
    }
    if (on_progress) |progress| progress(
        progress_ctx orelse return error.MissingProgressContext,
        .{ .results_received = .{
            .query = request.query,
            .result_count = if (decoded.results) |items| items.len else 0,
        } },
    );
    return .{
        .content = content,
        .stop_reason = try alloc.dupe(u8, "stop"),
        .usage = .{ .web_search_requests = 1 },
    };
}

const max_codex_search_sources: usize = 64;
const max_codex_search_title_bytes: usize = 1024;

fn materializeCodexSearchContent(
    alloc: Allocator,
    decoded: responses_search.DecodedResponse,
    search_id: []const u8,
) ![]const web_search_contract.ResultItem {
    var content: std.ArrayList(web_search_contract.ResultItem) = .empty;
    errdefer {
        for (content.items) |item| item.deinit(alloc);
        content.deinit(alloc);
    }
    const commentary = try alloc.dupe(u8, decoded.output);
    content.append(alloc, .{ .commentary = commentary }) catch |err| {
        alloc.free(commentary);
        return err;
    };

    var source_count: usize = 0;
    for (decoded.results orelse &.{}) |result| {
        if (source_count >= max_codex_search_sources) break;
        const projected = responses_search.resultSource(result) orelse continue;
        var item = try materializeCodexSearchSourceItem(alloc, projected, search_id);
        content.append(alloc, item) catch |err| {
            item.deinit(alloc);
            return err;
        };
        source_count += 1;
    }
    return content.toOwnedSlice(alloc);
}

fn materializeCodexSearchSourceItem(
    alloc: Allocator,
    projected: responses_search.ResultSource,
    search_id: []const u8,
) !web_search_contract.ResultItem {
    const raw_title = projected.title orelse projected.url;
    const title = text_utils.utf8PrefixByBytes(raw_title, max_codex_search_title_bytes);
    const owned_url = try alloc.dupe(u8, projected.url);
    errdefer alloc.free(owned_url);
    const owned_title = try alloc.dupe(u8, if (title.len > 0) title else projected.url);
    errdefer alloc.free(owned_title);
    const sources = try alloc.alloc(web_search_contract.Source, 1);
    errdefer alloc.free(sources);
    sources[0] = .{ .title = owned_title, .url = owned_url };
    const tool_use_id = try alloc.dupe(u8, projected.ref_id orelse search_id);
    return .{ .search = .{
        .tool_use_id = tool_use_id,
        .content = sources,
    } };
}

test "Codex standalone search materializes structured result citations" {
    const alloc = std.testing.allocator;
    var decoded = try responses_search.decodeResponse(
        alloc,
        "{\"output\":\"Search answer\",\"results\":[{\"type\":\"text_result\",\"ref_id\":\"turn0search0\",\"title\":\"Primary source\",\"url\":\"https://example.com/source\"},{\"type\":\"text_result\",\"title\":\"Unsafe\",\"url\":\"javascript:alert(1)\"}]}",
    );
    defer decoded.deinit();
    const content = try materializeCodexSearchContent(alloc, decoded, "session-search");
    defer {
        for (content) |item| item.deinit(alloc);
        alloc.free(content);
    }

    try std.testing.expectEqual(@as(usize, 2), content.len);
    try std.testing.expectEqualStrings("Search answer", content[0].commentary);
    const search = content[1].search;
    try std.testing.expectEqualStrings("turn0search0", search.tool_use_id);
    try std.testing.expectEqual(@as(usize, 1), search.content.len);
    try std.testing.expectEqualStrings("Primary source", search.content[0].title);
    try std.testing.expectEqualStrings("https://example.com/source", search.content[0].url);
}

fn checkCodexSearchMaterializationAllocationFailures(alloc: Allocator) !void {
    var decoded = try responses_search.decodeResponse(
        alloc,
        "{\"output\":\"Search answer\",\"results\":[{\"ref_id\":\"turn0search0\",\"title\":\"Primary\",\"url\":\"https://example.com/one\"},{\"ref_id\":\"turn0search1\",\"url\":\"https://example.com/two\"}]}",
    );
    defer decoded.deinit();
    const content = try materializeCodexSearchContent(alloc, decoded, "session-search");
    defer {
        for (content) |item| item.deinit(alloc);
        alloc.free(content);
    }
}

test "Codex standalone search citation materialization cleans allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCodexSearchMaterializationAllocationFailures,
        .{},
    );
}

fn buildCodexSearchCommandsAlloc(alloc: Allocator, request: Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"search_query\":[{\"q\":");
    try std.json.Stringify.value(request.query, .{}, &out.writer);
    if (hasValues(request.allowed_domains)) {
        try out.writer.writeAll(",\"domains\":");
        try std.json.Stringify.value(request.allowed_domains.?, .{}, &out.writer);
    }
    try out.writer.writeAll("}]}");
    return out.toOwnedSlice();
}

fn buildCodexSearchSettingsAlloc(alloc: Allocator, request: Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"allowed_callers\":[\"direct\"],\"external_web_access\":true");
    if (hasValues(request.allowed_domains) or hasValues(request.blocked_domains)) {
        try out.writer.writeAll(",\"filters\":{");
        if (hasValues(request.allowed_domains)) {
            try out.writer.writeAll("\"allowed_domains\":");
            try std.json.Stringify.value(request.allowed_domains.?, .{}, &out.writer);
        } else {
            try out.writer.writeAll("\"blocked_domains\":");
            try std.json.Stringify.value(request.blocked_domains.?, .{}, &out.writer);
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

pub fn chatUrl(fallback: []const u8) []const u8 {
    return resolveChatUrl(fallback, io_mod.getenv(chat_url_env));
}

pub fn defaultChatUrl() []const u8 {
    return chatUrl(default_chat_url);
}

fn resolveChatUrlForProvider(_: ?*anyopaque, fallback: []const u8) []const u8 {
    return chatUrl(fallback);
}

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    const result = model_catalog.fetchWithPublicFallback(model_catalog_provider, alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    });
    return switch (result) {
        .loaded => |loaded| project: {
            var catalog = loaded.catalog;
            defer freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = loaded.provenance.anonymous_fallback_used,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :project .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failed| .{ .failure = failed },
    };
}

pub fn resolveChatUrl(fallback: []const u8, override: ?[]const u8) []const u8 {
    const candidate = override orelse return fallback;
    // The chat URL carries the bearer token and full request payload; only a
    // loopback HTTP override is trusted for local testing.
    if (!gateway_client.isLoopbackHttpUrl(candidate)) return fallback;
    return candidate;
}

pub const StreamFn = *const fn (
    *anyopaque,
    Allocator,
    []const u8,
    ?[]const u8,
    []const u8,
    usize,
    []const u8,
    []const u8,
    []const u8,
    std.Io.Clock.Timestamp,
    *gateway_client.DeliveryCertainty,
    *std.atomic.Value(bool),
) anyerror!gateway_client.StreamResult;

var default_stream_ctx: u8 = 0;

pub const GatewayWorkerConfig = struct {
    api_key: []const u8,
    team: ?[]const u8 = null,
    model: []const u8,
    retry_count: usize,
    chat_url: []const u8,
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
    stream_ctx: *anyopaque = @ptrCast(&default_stream_ctx),
    stream_fn: StreamFn = streamGatewayWorker,
};

pub const ProviderToolInput = struct {
    backend: web_search_contract.SearchBackendId,
    allowed_domains: ?[]const []const u8 = null,
    blocked_domains: ?[]const []const u8 = null,
    max_results: u8,
    max_output_tokens: u32 = 4096,
    max_output_chars: usize,
};

pub fn executeGatewayWorker(
    alloc: Allocator,
    config: GatewayWorkerConfig,
    request: Request,
    on_progress: ?ProgressFn,
    progress_ctx: ?*anyopaque,
) !Response {
    if (config.api_key.len == 0 or config.model.len == 0 or config.chat_url.len == 0) {
        return error.MissingGatewaySearchConfiguration;
    }
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const deadline = deadlineAfterMs(request.timeout_ms);
    if (on_progress) |progress| progress(progress_ctx orelse return error.MissingProgressContext, .{ .query_update = request.query });

    const tools_json = try providerToolsJson(alloc, .{
        .backend = request.backend,
        .allowed_domains = request.allowed_domains,
        .blocked_domains = request.blocked_domains,
        .max_results = request.max_results,
        .max_output_tokens = request.max_output_tokens,
        .max_output_chars = request.max_output_chars,
    });
    defer alloc.free(tools_json);

    const messages = [_]shared_types.ChatMessage{
        .{ .role = .system, .content = web_search_system_prompt },
        .{ .role = .user, .content = request.query },
    };
    const payload = try gateway_json.buildGatewayRequiredToolRequestBodyWithMaxOutputTokens(alloc, tools_json, &messages, request.max_output_tokens);
    defer alloc.free(payload);

    const usage_observation = try session_usage.GatewayObservation.begin(config.usage);
    var delivery = gateway_client.DeliveryCertainty.init();
    const provider_tool_name = try selectedToolName(request.backend);
    var stream = config.stream_fn(
        config.stream_ctx,
        alloc,
        config.api_key,
        config.team,
        config.model,
        @max(config.retry_count, 1),
        config.chat_url,
        payload,
        provider_tool_name,
        deadline,
        &delivery,
        @constCast(request.cancel_flag),
    ) catch |err| {
        try usage_observation.fail(if (delivery.load() == .possibly_sent)
            .ambiguous_delivery
        else
            .unbilled);
        return err;
    };
    defer stream.deinit(alloc);
    try usage_observation.complete(
        config.usage_allocator,
        stream.status,
        stream.completion,
        gateway_client.generationBaseUrl(),
        config.team,
    );
    if (!builtin.is_test) {
        if (config.usage) |ledger| {
            ledger.startReconciliation(config.usage_allocator, config.api_key);
        }
    }
    if (stream.status != .ok) return error.GatewayRequestFailed;
    return normalizeGatewayCompletion(alloc, request, stream.completion, on_progress, progress_ctx);
}

fn deadlineAfterMs(timeout_ms: u32) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    });
}

pub fn providerToolsJson(alloc: Allocator, input: ProviderToolInput) ![]u8 {
    if (hasValues(input.allowed_domains) and hasValues(input.blocked_domains)) {
        return error.ConflictingDomainFilters;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (input.backend.eql(perplexity_search_backend_id)) {
        try out.writer.print(
            "[{{\"type\":\"provider\",\"id\":\"gateway.perplexity_search\",\"name\":\"perplexity_search\",\"args\":{{\"maxResults\":{d},\"maxTokens\":{d}",
            .{ input.max_results, input.max_output_tokens },
        );
        if (hasValues(input.allowed_domains)) {
            try writePerplexityDomains(alloc, &out.writer, input.allowed_domains.?, false);
        } else if (hasValues(input.blocked_domains)) {
            try writePerplexityDomains(alloc, &out.writer, input.blocked_domains.?, true);
        }
        try out.writer.writeAll("}}]");
    } else if (input.backend.eql(parallel_search_backend_id)) {
        try out.writer.print(
            "[{{\"type\":\"provider\",\"id\":\"gateway.parallel_search\",\"name\":\"parallel_search\",\"args\":{{\"mode\":\"one-shot\",\"maxResults\":{d}",
            .{input.max_results},
        );
        if (hasValues(input.allowed_domains)) {
            try writeParallelDomains(&out.writer, "includeDomains", input.allowed_domains.?);
        } else if (hasValues(input.blocked_domains)) {
            try writeParallelDomains(&out.writer, "excludeDomains", input.blocked_domains.?);
        }
        try out.writer.print(",\"excerpts\":{{\"maxCharsTotal\":{d}}}}}}}]", .{input.max_output_chars});
    } else {
        return error.InvalidWebSearchBackend;
    }
    return try out.toOwnedSlice();
}

fn streamGatewayWorker(
    _: *anyopaque,
    alloc: Allocator,
    api_key: []const u8,
    team: ?[]const u8,
    model: []const u8,
    request_retry_count: usize,
    chat_url: []const u8,
    payload: []const u8,
    expected_provider_tool_name: []const u8,
    deadline: std.Io.Clock.Timestamp,
    delivery: *gateway_client.DeliveryCertainty,
    cancel_flag: *std.atomic.Value(bool),
) !gateway_client.StreamResult {
    return gateway_client.streamGatewayProviderToolCompletionBounded(
        alloc,
        .{
            .api_key = api_key,
            .team = team,
            .model = model,
            .retry_count = request_retry_count,
            .chat_url = chat_url,
            .payload = payload,
            .delivery = delivery,
        },
        expected_provider_tool_name,
        deadline,
        cancel_flag,
    );
}

fn normalizeGatewayCompletion(
    alloc: Allocator,
    request: Request,
    completion: shared_types.GatewayCompletion,
    on_progress: ?ProgressFn,
    progress_ctx: ?*anyopaque,
) !Response {
    var content: std.ArrayList(web_search_contract.ResultItem) = .empty;
    errdefer deinitItems(alloc, &content);

    var search_requests: u32 = 0;
    const admission = shared_types.authoritativeToolAdmission(completion);
    const admitted = switch (admission) {
        .admitted => true,
        .reject_duplicate_identity => blk: {
            try content.append(alloc, .{ .error_text = try alloc.dupe(u8, "provider search tool identity is duplicated") });
            break :blk false;
        },
        .reject_malformed_identity => |failure| blk: {
            try content.append(alloc, .{ .error_text = try std.fmt.allocPrint(
                alloc,
                "provider search tool identity is malformed ({s})",
                .{@tagName(failure)},
            ) });
            break :blk false;
        },
        .reject_malformed_provider_result => |failure| blk: {
            try content.append(alloc, .{ .error_text = try std.fmt.allocPrint(
                alloc,
                "provider search result identity is malformed ({s})",
                .{@tagName(failure)},
            ) });
            break :blk false;
        },
        .reject_malformed_provider_arguments => blk: {
            try content.append(alloc, .{
                .error_text = try alloc.dupe(
                    u8,
                    "provider search tool arguments are malformed",
                ),
            });
            break :blk false;
        },
    };
    if (admitted) {
        const expected_tool_name = try selectedToolName(request.backend);
        var provider_call: ?shared_types.ToolCall = null;
        for (completion.tool_calls) |call| {
            if (call.provenance != .provider_executed or !std.mem.eql(u8, call.name, expected_tool_name)) {
                try content.append(alloc, .{ .error_text = try alloc.dupe(u8, "private worker returned an unexpected tool call") });
                break;
            }
            if (provider_call != null) {
                try content.append(alloc, .{ .error_text = try alloc.dupe(u8, "private worker returned multiple provider search calls") });
                break;
            }
            provider_call = call;
        }

        if (content.items.len == 0) {
            if (provider_call) |call| {
                if (call.provider_result) |provider_result| {
                    search_requests += 1;
                    map_result: {
                        const hits = parseSearchHits(alloc, provider_result, request.max_results) catch |err| {
                            try content.append(alloc, .{ .error_text = try std.fmt.allocPrint(alloc, "provider search result decode failed: {s}", .{@errorName(err)}) });
                            break :map_result;
                        };
                        errdefer deinitHits(alloc, hits);
                        try content.append(alloc, .{ .search = .{
                            .tool_use_id = try alloc.dupe(u8, call.id),
                            .content = hits,
                        } });
                        if (on_progress) |progress| progress(progress_ctx orelse return error.MissingProgressContext, .{
                            .results_received = .{
                                .query = request.query,
                                .result_count = hits.len,
                            },
                        });
                    }
                } else {
                    try content.append(alloc, .{ .error_text = try alloc.dupe(u8, "provider search returned no result") });
                }
            } else {
                try content.append(alloc, .{ .error_text = try alloc.dupe(u8, "private worker returned no provider search call") });
            }
        }
    }

    if (completion.finish_reason == null) {
        try content.append(alloc, .{ .terminal_incomplete = .{
            .stop_reason = try alloc.dupe(u8, "missing_provider_finish"),
            .message = try alloc.dupe(u8, "private web search worker stopped before completion"),
        } });
    } else if (completion.finish_reason == .provider_error or completion.finish_reason == .content_filter) {
        const reason = completion.finish_reason.?;
        try content.append(alloc, .{ .terminal_incomplete = .{
            .stop_reason = try alloc.dupe(u8, reason.label()),
            .message = try alloc.dupe(u8, "private web search worker reported an unsuccessful completion"),
        } });
    }

    return .{
        .content = try content.toOwnedSlice(alloc),
        .stop_reason = if (completion.finish_reason) |reason| try alloc.dupe(u8, reason.label()) else null,
        .usage = .{
            .input_tokens = completion.usage.input_tokens orelse 0,
            .output_tokens = completion.usage.output_tokens orelse 0,
            .web_search_requests = search_requests,
        },
    };
}

fn parseSearchHits(alloc: Allocator, json_text: []const u8, max_results: u8) ![]web_search_contract.Source {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    const values = searchResultValues(parsed.value) orelse return &.{};
    var hits: std.ArrayList(web_search_contract.Source) = .empty;
    errdefer deinitHitsList(alloc, &hits);
    for (values) |value| {
        if (hits.items.len >= max_results) break;
        const hit = try decodeSearchHit(alloc, value) orelse continue;
        try hits.append(alloc, hit);
    }
    return try hits.toOwnedSlice(alloc);
}

fn searchResultValues(value: std.json.Value) ?[]const std.json.Value {
    if (value == .array) return value.array.items;
    if (value != .object) return null;
    inline for (&.{ "results", "sources", "data", "response" }) |name| {
        if (value.object.get(name)) |nested| {
            if (searchResultValues(nested)) |values| return values;
        }
    }
    return null;
}

fn decodeSearchHit(alloc: Allocator, value: std.json.Value) !?web_search_contract.Source {
    if (value != .object) return null;
    const url = stringField(value.object, &.{ "url", "link" }) orelse return null;
    if (!isSafeCitationUrl(url)) return null;
    const title = stringField(value.object, &.{ "title", "name" }) orelse url;
    const owned_title = try alloc.dupe(u8, title);
    errdefer alloc.free(owned_title);
    return .{
        .title = owned_title,
        .url = try alloc.dupe(u8, url),
    };
}

fn isSafeCitationUrl(url: []const u8) bool {
    const authority_start = if (std.mem.startsWith(u8, url, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, url, "http://"))
        "http://".len
    else
        return false;
    var authority_end = authority_start;
    while (authority_end < url.len) : (authority_end += 1) {
        const char = url[authority_end];
        if (char < 0x20 or char == 0x7f or std.ascii.isWhitespace(char)) return false;
        if (char == '/' or char == '?' or char == '#') break;
    }
    if (authority_end == authority_start) return false;
    if (std.mem.findScalar(u8, url[authority_start..authority_end], '@') != null) return false;
    for (url[authority_end..]) |char| {
        if (char < 0x20 or char == 0x7f or std.ascii.isWhitespace(char)) return false;
    }
    return true;
}

fn stringField(object: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        const value = object.get(name) orelse continue;
        if (value == .string) return value.string;
    }
    return null;
}

fn selectedToolName(backend: web_search_contract.SearchBackendId) ![]const u8 {
    if (backend.eql(perplexity_search_backend_id)) return "perplexity_search";
    if (backend.eql(parallel_search_backend_id)) return "parallel_search";
    return error.InvalidWebSearchBackend;
}

fn writePerplexityDomains(alloc: Allocator, writer: *std.Io.Writer, domains: []const []const u8, blocked: bool) !void {
    try writer.writeAll(",\"searchDomainFilter\":[");
    for (domains, 0..) |domain, index| {
        if (index > 0) try writer.writeByte(',');
        if (blocked) {
            const prefixed = try std.fmt.allocPrint(alloc, "-{s}", .{domain});
            defer alloc.free(prefixed);
            try std.json.Stringify.value(prefixed, .{}, writer);
        } else {
            try std.json.Stringify.value(domain, .{}, writer);
        }
    }
    try writer.writeByte(']');
}

fn writeParallelDomains(writer: *std.Io.Writer, name: []const u8, domains: []const []const u8) !void {
    try writer.print(",\"sourcePolicy\":{{\"{s}\":[", .{name});
    for (domains, 0..) |domain, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(domain, .{}, writer);
    }
    try writer.writeAll("]}");
}

fn boundedDupe(alloc: Allocator, text: []const u8, max_len: usize) ![]u8 {
    return try alloc.dupe(u8, text[0..@min(text.len, max_len)]);
}

fn hasValues(values: ?[]const []const u8) bool {
    return if (values) |actual| actual.len > 0 else false;
}

fn deinitItems(alloc: Allocator, items: *std.ArrayList(web_search_contract.ResultItem)) void {
    for (items.items) |item| item.deinit(alloc);
    items.deinit(alloc);
}

fn deinitHitsList(alloc: Allocator, hits: *std.ArrayList(web_search_contract.Source)) void {
    for (hits.items) |hit| hit.deinit(alloc);
    hits.deinit(alloc);
}

fn deinitHits(alloc: Allocator, hits: []web_search_contract.Source) void {
    for (hits) |hit| hit.deinit(alloc);
    if (hits.len > 0) alloc.free(hits);
}

test "built-in search rejects an unknown provider-owned backend identity" {
    try std.testing.expectError(error.InvalidWebSearchBackend, providerToolsJson(std.testing.allocator, .{
        .backend = .{ .value = "other.search" },
        .max_results = 1,
        .max_output_chars = 1024,
    }));
}

test "private perplexity worker advertises only selected gateway provider search tool" {
    const alloc = std.testing.allocator;
    const allowed_domains = [_][]const u8{"ziglang.org"};
    const tools_json = try providerToolsJson(alloc, .{
        .backend = perplexity_search_backend_id,
        .allowed_domains = &allowed_domains,
        .max_results = 7,
        .max_output_chars = 4096,
    });
    defer alloc.free(tools_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, tools_json, .{});
    defer parsed.deinit();

    try std.testing.expect(std.mem.find(u8, tools_json, "gateway.perplexity_search") != null);
    try std.testing.expect(std.mem.find(u8, tools_json, "gateway.parallel_search") == null);
    try std.testing.expect(std.mem.find(u8, tools_json, "\"maxResults\":7") != null);
    try std.testing.expect(std.mem.find(u8, tools_json, "\"searchDomainFilter\":[\"ziglang.org\"]") != null);
}

test "private perplexity worker serializes blocked domains as exclusions" {
    const alloc = std.testing.allocator;
    const blocked_domains = [_][]const u8{"example.com"};
    const tools_json = try providerToolsJson(alloc, .{
        .backend = perplexity_search_backend_id,
        .blocked_domains = &blocked_domains,
        .max_results = 7,
        .max_output_chars = 4096,
    });
    defer alloc.free(tools_json);

    try std.testing.expect(std.mem.find(u8, tools_json, "\"searchDomainFilter\":[\"-example.com\"]") != null);
}

test "private perplexity worker ignores empty allowed domains before blocked domains" {
    const alloc = std.testing.allocator;
    const allowed_domains = [_][]const u8{};
    const blocked_domains = [_][]const u8{"example.com"};
    const tools_json = try providerToolsJson(alloc, .{
        .backend = perplexity_search_backend_id,
        .allowed_domains = &allowed_domains,
        .blocked_domains = &blocked_domains,
        .max_results = 7,
        .max_output_chars = 4096,
    });
    defer alloc.free(tools_json);

    try std.testing.expect(std.mem.find(u8, tools_json, "\"searchDomainFilter\":[\"-example.com\"]") != null);
}

test "private parallel worker advertises only selected gateway provider search tool" {
    const alloc = std.testing.allocator;
    const blocked_domains = [_][]const u8{"example.com"};
    const tools_json = try providerToolsJson(alloc, .{
        .backend = parallel_search_backend_id,
        .blocked_domains = &blocked_domains,
        .max_results = 5,
        .max_output_chars = 6000,
    });
    defer alloc.free(tools_json);

    try std.testing.expect(std.mem.find(u8, tools_json, "gateway.parallel_search") != null);
    try std.testing.expect(std.mem.find(u8, tools_json, "gateway.perplexity_search") == null);
    try std.testing.expect(std.mem.find(u8, tools_json, "\"excludeDomains\":[\"example.com\"]") != null);
    try std.testing.expect(std.mem.find(u8, tools_json, "\"maxCharsTotal\":6000") != null);
}

test "private parallel worker ignores empty allowed domains before blocked domains" {
    const alloc = std.testing.allocator;
    const allowed_domains = [_][]const u8{};
    const blocked_domains = [_][]const u8{"example.com"};
    const tools_json = try providerToolsJson(alloc, .{
        .backend = parallel_search_backend_id,
        .allowed_domains = &allowed_domains,
        .blocked_domains = &blocked_domains,
        .max_results = 5,
        .max_output_chars = 6000,
    });
    defer alloc.free(tools_json);

    try std.testing.expect(std.mem.find(u8, tools_json, "\"excludeDomains\":[\"example.com\"]") != null);
}

test "provider search result drops unsafe citation urls" {
    const alloc = std.testing.allocator;
    const hits = try parseSearchHits(
        alloc,
        \\{"results":[
        \\  {"title":"safe","url":"https://example.com/docs"},
        \\  {"title":"script","url":"javascript:alert(1)"},
        \\  {"title":"credentials","url":"https://user:pass@example.com/docs"},
        \\  {"title":"space","url":"https://example.com/a b"}
        \\]}
    ,
        10,
    );
    defer deinitHits(alloc, hits);

    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("https://example.com/docs", hits[0].url);
}

fn expectGatewayWorkerAdapterExecutes(backend: web_search_contract.SearchBackendId) !void {
    const alloc = std.testing.allocator;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var fake = FakeStream{};
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var response = try executeGatewayWorker(alloc, .{
        .api_key = "key",
        .team = "team_123",
        .model = "provider/model",
        .retry_count = 1,
        .chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model",
        .usage = &usage,
        .usage_allocator = alloc,
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    }, .{
        .backend = backend,
        .query = "latest Zig release",
        .max_results = 1,
        .cancel_flag = &cancel_flag,
    }, null, null);
    defer response.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("team_123", fake.team.?);
    const deadline = fake.deadline orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(std.Io.Clock.awake, deadline.clock);
    try std.testing.expect(std.Io.Clock.Timestamp.compare(
        std.Io.Clock.Timestamp.now(std.testing.io, .awake),
        .lt,
        deadline,
    ));
    try std.testing.expect(fake.saw_inner_prompt);
    try std.testing.expect(fake.saw_output_bound);
    try std.testing.expect(fake.saw_required_tool_choice);
    try std.testing.expect(fake.saw_expected_provider_tool);
    var usage_snapshot = try usage.snapshot(alloc);
    defer usage_snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), usage_snapshot.pending.len);
    if (backend.eql(perplexity_search_backend_id)) {
        try std.testing.expect(fake.saw_perplexity);
        try std.testing.expect(!fake.saw_parallel);
    } else {
        try std.testing.expect(backend.eql(parallel_search_backend_id));
        try std.testing.expect(!fake.saw_perplexity);
        try std.testing.expect(fake.saw_parallel);
    }
    try std.testing.expectEqual(@as(usize, 1), response.content[0].search.content.len);
    try std.testing.expectEqual(@as(u32, 1), response.usage.?.web_search_requests);
}

test "gateway worker adapter executes private perplexity backend with bounded payload" {
    try expectGatewayWorkerAdapterExecutes(perplexity_search_backend_id);
}

test "gateway worker adapter executes private parallel backend with bounded payload" {
    try expectGatewayWorkerAdapterExecutes(parallel_search_backend_id);
}

test "gateway worker returns one bounded error for malformed provider result identity" {
    const failures = [_]shared_types.ProviderResultIdentityFailure{
        .absent,
        .empty,
        .wrong_type,
    };
    for (failures) |failure| {
        var cancel_flag = std.atomic.Value(bool).init(false);
        var response = try normalizeGatewayCompletion(std.testing.allocator, .{
            .backend = perplexity_search_backend_id,
            .query = "latest Zig release",
            .cancel_flag = &cancel_flag,
        }, .{
            .content = "must not escape malformed admission",
            .provider_result_identity_failure = failure,
            .finish_reason = .stop,
        }, null, null);
        defer response.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 1), response.content.len);
        try std.testing.expect(response.content[0] == .error_text);
        const expected = try std.fmt.allocPrint(
            std.testing.allocator,
            "provider search result identity is malformed ({s})",
            .{@tagName(failure)},
        );
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, response.content[0].error_text);
        try std.testing.expectEqual(@as(u32, 0), response.usage.?.web_search_requests);
    }
}

test "gateway worker rejects malformed provider arguments before accepting search results" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    var response = try normalizeGatewayCompletion(std.testing.allocator, .{
        .backend = perplexity_search_backend_id,
        .query = "latest Zig release",
        .cancel_flag = &cancel_flag,
    }, .{
        .tool_calls = &.{.{
            .id = "search_1",
            .name = "perplexity_search",
            .arguments_json = "{}",
            .argument_integrity = .malformed_json,
            .provider_result = "{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\"}]}",
            .provenance = .provider_executed,
        }},
        .finish_reason = .stop,
    }, null, null);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), response.content.len);
    try std.testing.expect(response.content[0] == .error_text);
    try std.testing.expectEqual(@as(u32, 0), response.usage.?.web_search_requests);
}

test "gateway worker rejects duplicate selected provider calls" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    var response = try normalizeGatewayCompletion(std.testing.allocator, .{
        .backend = perplexity_search_backend_id,
        .query = "latest Zig release",
        .cancel_flag = &cancel_flag,
    }, .{
        .tool_calls = &.{
            .{
                .id = "search_1",
                .name = "perplexity_search",
                .arguments_json = "{}",
                .provider_result = "{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\"}]}",
                .provenance = .provider_executed,
            },
            .{
                .id = "search_2",
                .name = "perplexity_search",
                .arguments_json = "{}",
                .provider_result = "{\"results\":[{\"title\":\"Zig downloads\",\"url\":\"https://ziglang.org/download\"}]}",
                .provenance = .provider_executed,
            },
        },
        .finish_reason = .stop,
    }, null, null);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), response.content.len);
    try std.testing.expect(response.content[0] == .error_text);
    try std.testing.expectEqual(@as(u32, 0), response.usage.?.web_search_requests);
}

test "gateway worker accepts refined provider input without worker commentary" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    var response = try normalizeGatewayCompletion(std.testing.allocator, .{
        .backend = perplexity_search_backend_id,
        .query = "current latest stable Zig release",
        .cancel_flag = &cancel_flag,
    }, .{
        .content = "private worker commentary",
        .tool_calls = &.{.{
            .id = "search_1",
            .name = "perplexity_search",
            .arguments_json = "{\"query\":\"current latest stable Zig release version\"}",
            .provider_result = "{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\"}]}",
            .provenance = .provider_executed,
        }},
        .finish_reason = .stop,
    }, null, null);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), response.content.len);
    try std.testing.expect(response.content[0] == .search);
    try std.testing.expectEqual(@as(usize, 1), response.content[0].search.content.len);
    try std.testing.expectEqual(@as(u32, 1), response.usage.?.web_search_requests);
}

test "gateway worker rejects an unselected provider call" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    var response = try normalizeGatewayCompletion(std.testing.allocator, .{
        .backend = perplexity_search_backend_id,
        .query = "latest Zig release",
        .cancel_flag = &cancel_flag,
    }, .{
        .tool_calls = &.{.{
            .id = "search_1",
            .name = "parallel_search",
            .arguments_json = "{}",
            .provider_result = "{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\"}]}",
            .provenance = .provider_executed,
        }},
        .finish_reason = .stop,
    }, null, null);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), response.content.len);
    try std.testing.expect(response.content[0] == .error_text);
    try std.testing.expectEqual(@as(u32, 0), response.usage.?.web_search_requests);
}

test "cancelled gateway worker performs zero stream requests" {
    var cancel_flag = std.atomic.Value(bool).init(true);
    var fake = FakeStream{};

    try std.testing.expectError(error.Cancelled, executeGatewayWorker(std.testing.allocator, .{
        .api_key = "key",
        .model = "provider/model",
        .retry_count = 1,
        .chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model",
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    }, .{
        .backend = perplexity_search_backend_id,
        .query = "latest Zig release",
        .cancel_flag = &cancel_flag,
    }, null, null));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "web search drops worker text when no provider result arrives" {
    const alloc = std.testing.allocator;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var response = try normalizeGatewayCompletion(alloc, .{
        .backend = perplexity_search_backend_id,
        .query = "latest Zig release",
        .cancel_flag = &cancel_flag,
    }, .{
        .content = "partial research",
        .finish_reason = null,
    }, null, null);
    defer response.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), response.content.len);
    try std.testing.expect(response.content[0] == .error_text);
    try std.testing.expectEqualStrings("private worker returned no provider search call", response.content[0].error_text);
    try std.testing.expect(response.content[1] == .terminal_incomplete);
    try std.testing.expectEqualStrings("missing_provider_finish", response.content[1].terminal_incomplete.stop_reason);
    try std.testing.expect(response.stop_reason == null);
}

const FakeStream = struct {
    calls: usize = 0,
    fail_before_send: bool = false,
    fail_after_send: bool = false,
    team: ?[]const u8 = null,
    deadline: ?std.Io.Clock.Timestamp = null,
    saw_perplexity: bool = false,
    saw_parallel: bool = false,
    saw_inner_prompt: bool = false,
    saw_output_bound: bool = false,
    saw_required_tool_choice: bool = false,
    saw_expected_provider_tool: bool = false,

    fn execute(
        raw_ctx: *anyopaque,
        alloc: Allocator,
        _: []const u8,
        team: ?[]const u8,
        _: []const u8,
        _: usize,
        _: []const u8,
        payload: []const u8,
        expected_provider_tool_name: []const u8,
        deadline: std.Io.Clock.Timestamp,
        delivery: *gateway_client.DeliveryCertainty,
        _: *std.atomic.Value(bool),
    ) anyerror!gateway_client.StreamResult {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        self.calls += 1;
        if (self.fail_before_send) return error.AccessDenied;
        if (self.fail_after_send) {
            delivery.markPossiblySent();
            return error.ConnectionResetByPeer;
        }
        self.team = team;
        self.deadline = deadline;
        self.saw_perplexity = std.mem.find(u8, payload, "gateway.perplexity_search") != null;
        self.saw_parallel = std.mem.find(u8, payload, "gateway.parallel_search") != null;
        self.saw_inner_prompt = std.mem.find(u8, payload, "Research the user's query with the web_search tool and preserve sources for citation.") != null;
        self.saw_output_bound = std.mem.find(u8, payload, "\"maxOutputTokens\":4096") != null;
        self.saw_required_tool_choice = std.mem.find(u8, payload, "\"toolChoice\":{\"type\":\"required\"}") != null;
        const tool_name = if (self.saw_parallel) "parallel_search" else "perplexity_search";
        self.saw_expected_provider_tool = std.mem.eql(u8, expected_provider_tool_name, tool_name);
        return .{
            .status = .ok,
            .completion = .{
                .generation_id = try alloc.dupe(
                    u8,
                    "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
                ),
                .finish_reason = .stop,
                .tool_calls = try alloc.dupe(shared_types.ToolCall, &.{
                    .{
                        .id = try alloc.dupe(u8, "search_1"),
                        .name = try alloc.dupe(u8, tool_name),
                        .arguments_json = try alloc.dupe(u8, "{}"),
                        .provider_result = try alloc.dupe(u8, "{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\"},{\"title\":\"Zig downloads\",\"url\":\"https://ziglang.org/download\"}]}"),
                        .provenance = .provider_executed,
                    },
                }),
                .usage = .{ .input_tokens = 2, .output_tokens = 3 },
            },
        };
    }
};

test "pre-send web search failure stays unbilled" {
    const alloc = std.testing.allocator;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var fake = FakeStream{ .fail_before_send = true };
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);

    try std.testing.expectError(error.AccessDenied, executeGatewayWorker(alloc, .{
        .api_key = "key",
        .model = "provider/model",
        .retry_count = 1,
        .chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model",
        .usage = &usage,
        .usage_allocator = alloc,
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    }, .{
        .backend = perplexity_search_backend_id,
        .query = "latest Zig release",
        .cancel_flag = &cancel_flag,
    }, null, null));

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(session_usage.Availability.complete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
    try std.testing.expectEqual(@as(u64, 1), snapshot.settled_through_sequence);
}

test "possibly sent web search failure marks billing incomplete" {
    const alloc = std.testing.allocator;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var fake = FakeStream{ .fail_after_send = true };
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);

    try std.testing.expectError(error.ConnectionResetByPeer, executeGatewayWorker(alloc, .{
        .api_key = "key",
        .model = "provider/model",
        .retry_count = 1,
        .chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model",
        .usage = &usage,
        .usage_allocator = alloc,
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    }, .{
        .backend = perplexity_search_backend_id,
        .query = "latest Zig release",
        .cancel_flag = &cancel_flag,
    }, null, null));

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(session_usage.Availability.incomplete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
    try std.testing.expectEqual(@as(u64, 1), snapshot.settled_through_sequence);
}

test "built-in gateway defaults preserve active provider policy" {
    try std.testing.expectEqualStrings("zai/glm-5.2", default_model);
    try std.testing.expectEqualStrings("https://ai-gateway.vercel.sh/v3/ai/language-model", default_chat_url);
    try std.testing.expectEqualStrings("/coding-agent/v1/models", models_path);
    try std.testing.expectEqual(@as(usize, 3), retry_count);
    try std.testing.expectEqualStrings("FX_GATEWAY_CHAT_URL", chat_url_env);
}

fn stubFetchCreditsError(
    _: Allocator,
    _: ?[]const u8,
    _: []const u8,
) anyerror!gateway_client.GetResult {
    return error.StubFetchFailed;
}

fn stubFetchInvalidCreditsJson(
    alloc: Allocator,
    _: ?[]const u8,
    _: []const u8,
) anyerror!gateway_client.GetResult {
    return .{
        .status = .ok,
        .body = try alloc.dupe(u8, "{"),
    };
}

fn stubFetchCreditsObject(
    alloc: Allocator,
    _: ?[]const u8,
    _: []const u8,
) anyerror!gateway_client.GetResult {
    return .{
        .status = .ok,
        .body = try alloc.dupe(u8, "{\"balance\":\"10\",\"used\":\"2\",\"plan\":\"pro\"}"),
    };
}

var captured_credits_path: [256]u8 = undefined;
var captured_credits_path_len: usize = 0;

fn stubCaptureCreditsPath(
    alloc: Allocator,
    _: ?[]const u8,
    path: []const u8,
) anyerror!gateway_client.GetResult {
    captured_credits_path_len = @min(path.len, captured_credits_path.len);
    @memcpy(
        captured_credits_path[0..captured_credits_path_len],
        path[0..captured_credits_path_len],
    );
    return .{
        .status = .ok,
        .body = try alloc.dupe(u8, "{\"balance\":\"10\",\"total_used\":\"2\"}"),
    };
}

fn stubFetchForbiddenCredits(
    alloc: Allocator,
    _: ?[]const u8,
    _: []const u8,
) anyerror!gateway_client.GetResult {
    return .{
        .status = .forbidden,
        .body = try alloc.dupe(u8, "{\"error\":{\"code\":\"credit_card_required\",\"message\":\"Buy credits to use AI Gateway.\"}}"),
    };
}

test "built-in credits provider names the team query only when valid" {
    const cases = [_]struct { team: ?[]const u8, want: []const u8 }{
        .{ .team = null, .want = "/coding-agent/v1/credits" },
        .{ .team = "team_000000000000000000000000", .want = "/coding-agent/v1/credits?teamId=team_000000000000000000000000" },
        .{ .team = "example-team", .want = "/coding-agent/v1/credits?teamId=example-team" },
        .{ .team = "team a/../b", .want = "/coding-agent/v1/credits" },
        .{ .team = "", .want = "/coding-agent/v1/credits" },
    };
    for (cases) |case| {
        captured_credits_path_len = 0;
        var snapshot = fetchCreditsWithFetch(
            std.testing.allocator,
            null,
            case.team,
            stubCaptureCreditsPath,
        );
        defer snapshot.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(
            case.want,
            captured_credits_path[0..captured_credits_path_len],
        );
    }
}

test "direct provider credentials are never sent to the Vercel credits endpoint" {
    for ([_]shared_types.CredentialSource{ .openai_api_key, .chatgpt_subscription }) |source| {
        var snapshot = fetchCredits(null, std.testing.allocator, .{
            .credential = "must-not-leave-process",
            .tenant = "must-not-cross-provider-boundary",
            .credential_source = source,
        });
        defer snapshot.deinit(std.testing.allocator);
        try std.testing.expect(snapshot.balance == null);
        try std.testing.expectEqualStrings(
            "credits are available only for Vercel AI Gateway credentials",
            snapshot.err_message.?,
        );
    }
}

test "built-in credits provider maps fetch failure" {
    var snapshot = fetchCreditsWithFetch(
        std.testing.allocator,
        null,
        null,
        stubFetchCreditsError,
    );
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expect(snapshot.balance == null);
    try std.testing.expect(snapshot.used == null);
    try std.testing.expect(snapshot.plan == null);
    try std.testing.expectEqualStrings(
        "failed to fetch credits from gateway",
        snapshot.err_message.?,
    );
}

test "built-in credits provider maps Gateway HTTP denial" {
    var snapshot = fetchCreditsWithFetch(
        std.testing.allocator,
        null,
        null,
        stubFetchForbiddenCredits,
    );
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expect(snapshot.balance == null);
    try std.testing.expect(snapshot.used == null);
    try std.testing.expect(snapshot.plan == null);
    try std.testing.expectEqualStrings(
        "API access denied · HTTP 403 · credit_card_required: Buy credits to use AI Gateway.",
        snapshot.err_message.?,
    );
}

test "built-in credits provider rejects malformed JSON" {
    var snapshot = fetchCreditsWithFetch(
        std.testing.allocator,
        null,
        null,
        stubFetchInvalidCreditsJson,
    );
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expect(snapshot.raw_json == null);
    try std.testing.expectEqualStrings(
        "invalid JSON response from gateway",
        snapshot.err_message.?,
    );
}

test "built-in credits provider rejects non-object JSON" {
    var snapshot = try creditsSnapshotFromJsonValue(
        std.testing.allocator,
        .{ .string = "nope" },
    );
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expect(snapshot.raw_json == null);
    try std.testing.expectEqualStrings(
        "unexpected response format from gateway",
        snapshot.err_message.?,
    );
}

test "built-in credits provider returns owned string fields" {
    var snapshot = fetchCreditsWithFetch(
        std.testing.allocator,
        null,
        null,
        stubFetchCreditsObject,
    );
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("10", snapshot.balance.?);
    try std.testing.expectEqualStrings("2", snapshot.used.?);
    try std.testing.expectEqualStrings("pro", snapshot.plan.?);

    const text = try snapshot.renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "[credits] balance=10\n[credits] used=2\n[credits] plan=pro\n",
        text,
    );
}

test "built-in credits provider ignores non-string fields" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"balance\":10,\"used\":false,\"plan\":null}",
        .{},
    );
    defer parsed.deinit();

    var snapshot = try creditsSnapshotFromJsonValue(
        std.testing.allocator,
        parsed.value,
    );
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expect(snapshot.balance == null);
    try std.testing.expect(snapshot.used == null);
    try std.testing.expect(snapshot.plan == null);
}

test "built-in model catalog owns default and loopback target resolution" {
    const default_url = try modelCatalogUrl(std.testing.allocator, models_path, null);
    defer std.testing.allocator.free(default_url);
    try std.testing.expectEqualStrings("https://ai-gateway.vercel.sh/coding-agent/v1/models", default_url);

    const loopback_url = try modelCatalogUrl(std.testing.allocator, models_path, "http://127.0.0.1:43123");
    defer std.testing.allocator.free(loopback_url);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/coding-agent/v1/models", loopback_url);

    const rejected_url = try modelCatalogUrl(std.testing.allocator, models_path, "https://gateway.example");
    defer std.testing.allocator.free(rejected_url);
    try std.testing.expectEqualStrings("https://ai-gateway.vercel.sh/coding-agent/v1/models", rejected_url);
}

test "model catalog request plan keeps direct credentials off the Vercel route" {
    const alloc = std.testing.allocator;
    var openai = try prepareModelCatalogRequest(
        alloc,
        credentials.catalogAccessForCredential(.openai_api_key, "openai-secret", "team_must_not_cross"),
        models_path,
        "http://127.0.0.1:43123",
        .{ .responses_base_url = "https://openai-proxy.example/v1/responses" },
    );
    defer openai.deinit(alloc);
    try std.testing.expectEqual(provider_route.ProviderRoute.openai_responses_byok, openai.route);
    try std.testing.expectEqualStrings("https://openai-proxy.example/v1/models", openai.url);
    try std.testing.expectEqualStrings("openai-secret", openai.api_key.?);
    try std.testing.expect(openai.gateway_team == null);

    var codex = try prepareModelCatalogRequest(
        alloc,
        credentials.catalogAccessForCredential(.chatgpt_subscription, "codex-secret", "team_must_not_cross"),
        models_path,
        "http://127.0.0.1:43123",
        .{ .codex_base_url = "https://codex-proxy.example/backend-api/codex" },
    );
    defer codex.deinit(alloc);
    try std.testing.expectEqual(provider_route.ProviderRoute.codex_responses_oauth, codex.route);
    try std.testing.expectEqualStrings(
        "https://codex-proxy.example/backend-api/codex/models?client_version=0.144.5",
        codex.url,
    );
    try std.testing.expectEqualStrings("codex-secret", codex.api_key.?);
    try std.testing.expect(codex.gateway_team == null);

    var vercel = try prepareModelCatalogRequest(
        alloc,
        credentials.catalogAccessForCredential(.ai_gateway_api_key, "gateway-secret", "team_123"),
        models_path,
        "http://127.0.0.1:43123",
        .{ .responses_base_url = "https://must-not-be-used.example/v1" },
    );
    defer vercel.deinit(alloc);
    try std.testing.expectEqual(provider_route.ProviderRoute.vercel_gateway, vercel.route);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/coding-agent/v1/models", vercel.url);
    try std.testing.expectEqualStrings("gateway-secret", vercel.api_key.?);
    try std.testing.expectEqualStrings("team_123", vercel.gateway_team.?);
}

test "built-in gateway owns the admitted web search provider policy" {
    try std.testing.expect(web_search_policy.hasAdmittedBackendPolicy(default_web_search_policy.backend_policies));
    try std.testing.expectEqual(@as(usize, 3), default_web_search_policy.backend_policies.len);
    try std.testing.expect(perplexity_search_backend_id.eql(default_web_search_policy.preferred_backends[0]));
    try std.testing.expect(parallel_search_backend_id.eql(default_web_search_policy.preferred_backends[1]));
    try std.testing.expect(codex_search_backend_id.eql(default_web_search_policy.backend_policies[2].id));

    for (default_web_search_policy.backend_policies) |backend| {
        try std.testing.expectEqual(web_search_contract.BackendFeatureMode.best_effort, backend.features.max_uses);
        try std.testing.expectEqual(web_search_contract.BackendFeatureMode.pass_through, backend.features.allowed_domains);
        try std.testing.expectEqual(web_search_contract.BackendFeatureMode.pass_through, backend.features.blocked_domains);
        try std.testing.expect(backend.features.ordered_sources);
        try std.testing.expect(backend.features.usage);
        try std.testing.expect(backend.features.terminal_incomplete);
        try std.testing.expect(backend.features.timeout);
        try std.testing.expect(backend.features.cancellation);
        try std.testing.expect(backend.features.result_bounds == .pass_through or backend.features.result_bounds == .post_filter);
    }
}

test "built-in web search provider preserves missing worker configuration error" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.MissingGatewaySearchConfiguration, default_web_search_provider.execute(
        std.testing.allocator,
        .{
            .api_key = "",
            .worker_model = "",
            .gateway_retry_count = retry_count,
            .gateway_chat_url = default_chat_url,
        },
        .{
            .backend = perplexity_search_backend_id,
            .query = "latest Zig release",
            .cancel_flag = &cancel_flag,
        },
        null,
        null,
    ));
}

test "built-in gateway web search override selects one backend and rejects unknown values" {
    try std.testing.expect((try preferredWebSearchBackendsOverride(null)) == null);
    try std.testing.expect((try preferredWebSearchBackendsOverride("")) == null);
    try std.testing.expect(perplexity_search_backend_id.eql((try preferredWebSearchBackendsOverride("ai_gateway_perplexity_search")).?[0]));
    try std.testing.expect(parallel_search_backend_id.eql((try preferredWebSearchBackendsOverride("ai_gateway_parallel_search")).?[0]));
    try std.testing.expectError(error.InvalidWebSearchBackend, preferredWebSearchBackendsOverride("parallel_search"));
}

test "Codex web search selects standalone backend and projects legacy filters" {
    const selected = (try resolvePreferredWebSearchBackends(null, .{
        .api_key = "access",
        .credential_source = .chatgpt_subscription,
        .account_id = "acct",
        .worker_model = "gpt-5.6-sol",
        .gateway_retry_count = 1,
        .gateway_chat_url = default_chat_url,
    })).?;
    try std.testing.expectEqual(@as(usize, 1), selected.len);
    try std.testing.expect(codex_search_backend_id.eql(selected[0]));

    var cancel = std.atomic.Value(bool).init(false);
    const allowed = [_][]const u8{"openai.com"};
    const request: Request = .{
        .backend = codex_search_backend_id,
        .query = "latest Codex API",
        .allowed_domains = &allowed,
        .cancel_flag = &cancel,
    };
    const commands = try buildCodexSearchCommandsAlloc(std.testing.allocator, request);
    defer std.testing.allocator.free(commands);
    const settings = try buildCodexSearchSettingsAlloc(std.testing.allocator, request);
    defer std.testing.allocator.free(settings);
    var parsed_commands = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, commands, .{});
    defer parsed_commands.deinit();
    var parsed_settings = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, settings, .{});
    defer parsed_settings.deinit();
    try std.testing.expectEqualStrings(
        "openai.com",
        parsed_commands.value.object.get("search_query").?.array.items[0].object.get("domains").?.array.items[0].string,
    );
    try std.testing.expectEqualStrings(
        "openai.com",
        parsed_settings.value.object.get("filters").?.object.get("allowed_domains").?.array.items[0].string,
    );
}

test "built-in gateway chat url honors loopback override before fallback" {
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:43123/chat",
        resolveChatUrl("https://fallback.test/chat", "http://127.0.0.1:43123/chat"),
    );
    try std.testing.expectEqualStrings(
        "https://fallback.test/chat",
        resolveChatUrl("https://fallback.test/chat", null),
    );
}

test "built-in gateway chat url ignores untrusted overrides and falls back" {
    const fallback = "https://ai-gateway.vercel.sh/v3/ai/language-model";
    for ([_][]const u8{
        "https://evil.example/chat",
        "http://evil.example/chat",
        "http://127.0.0.1:8080@evil.example/chat",
        "ftp://evil.example/chat",
        "not a url",
        "",
    }) |bad| {
        try std.testing.expectEqualStrings(fallback, resolveChatUrl(fallback, bad));
    }
}

test "built-in CLI catalog provider preserves cancellation detail" {
    var cancel_flag = std.atomic.Value(bool).init(true);
    const result = cli_model_catalog_provider.fetch(std.testing.allocator, .{
        .endpoint = models_path,
        .cancel_flag = &cancel_flag,
    });
    switch (result) {
        .failure => |failure| try std.testing.expectEqual(
            model_catalog.FailureCategory.cancellation,
            failure.failure.category,
        ),
        .loaded => |loaded| {
            var ids = loaded.ids;
            collections.freeStringList(std.testing.allocator, &ids);
            return error.TestExpectedEqual;
        },
    }
}

pub fn fetchModelIds(alloc: std.mem.Allocator, access: credentials.CatalogAccess, path: []const u8) !std.ArrayList([]u8) {
    return fetchModelIdsForView(alloc, access, path, null, .full);
}

pub fn fetchModelIdsCancellable(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !std.ArrayList([]u8) {
    return fetchModelIdsForView(alloc, access, path, cancel_flag, .full);
}

pub fn fetchPickerModelIdsCancellable(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !std.ArrayList([]u8) {
    return fetchModelIdsForView(alloc, access, path, cancel_flag, .picker);
}

pub fn fetchModelCatalog(alloc: std.mem.Allocator, access: credentials.CatalogAccess, path: []const u8) !std.ArrayList(ModelCatalogEntry) {
    return fetchModelCatalogForView(alloc, access, path, null, .full);
}

pub fn fetchModelCatalogCancellable(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !std.ArrayList(ModelCatalogEntry) {
    return fetchModelCatalogForView(alloc, access, path, cancel_flag, .full);
}

pub fn fetchPickerModelCatalog(alloc: std.mem.Allocator, access: credentials.CatalogAccess, path: []const u8) !std.ArrayList(ModelCatalogEntry) {
    return fetchModelCatalogForView(alloc, access, path, null, .picker);
}

pub fn fetchPickerModelCatalogCancellable(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !std.ArrayList(ModelCatalogEntry) {
    return fetchModelCatalogForView(alloc, access, path, cancel_flag, .picker);
}

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
};

pub const ModelCatalogEntry = model_catalog.ModelCatalogEntry;
pub const freeModelCatalog = model_catalog.freeModelCatalog;

fn parseSortedModelIds(alloc: std.mem.Allocator, json_text: []const u8) !std.ArrayList([]u8) {
    return parseModelIdsForView(alloc, json_text, .full);
}

const ModelCatalogView = model_catalog.View;

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    const route = modelCatalogRoute(input.access);
    const response = fetchModelCatalogResponse(
        alloc,
        input.access,
        input.endpoint,
        input.cancel_flag,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = catalogRequestFailure(err) };
    };
    const json_text = switch (response) {
        .success => |body| body,
        .http_status => |status| return .{
            .failure = model_catalog.failureForHttpStatus(status),
        },
    };
    defer alloc.free(json_text);

    const catalog = parseProviderModelCatalogForView(
        alloc,
        json_text,
        input.view,
        route.contract().catalog,
    ) catch |err| return .{
        .failure = .{
            .category = if (err == error.OutOfMemory) .resource_exhausted else .malformed_response,
            .http_status = .ok,
        },
    };
    return .{ .catalog = catalog };
}

fn fetchModelIdsForView(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    view: ModelCatalogView,
) !std.ArrayList([]u8) {
    var catalog = try fetchModelCatalogForView(alloc, access, path, cancel_flag, view);
    defer freeModelCatalog(alloc, &catalog);

    return model_catalog.projectModelIds(alloc, catalog.items);
}

fn fetchModelCatalogForView(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    view: ModelCatalogView,
) !std.ArrayList(ModelCatalogEntry) {
    const route = modelCatalogRoute(access);
    const response = try fetchModelCatalogResponse(alloc, access, path, cancel_flag);
    const json_text = switch (response) {
        .success => |body| body,
        .http_status => |status| return model_catalog.failureForHttpStatus(status).asError(),
    };
    defer alloc.free(json_text);

    return parseProviderModelCatalogForView(alloc, json_text, view, route.contract().catalog);
}

fn modelCatalogRoute(access: credentials.CatalogAccess) provider_route.ProviderRoute {
    const source = access.credentialSource() orelse return .vercel_gateway;
    return provider_route.fromCredentialSource(source) orelse unreachable;
}

const ModelCatalogRequestPlan = struct {
    route: provider_route.ProviderRoute,
    url: []u8,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,

    fn deinit(self: *ModelCatalogRequestPlan, alloc: Allocator) void {
        alloc.free(self.url);
        self.* = undefined;
    }
};

fn prepareModelCatalogRequest(
    alloc: Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    gateway_base_override: ?[]const u8,
    endpoint_overrides: provider_route.EndpointOverrides,
) !ModelCatalogRequestPlan {
    const route = modelCatalogRoute(access);
    if (route == .vercel_gateway) {
        const team_path = try modelCatalogTeamPath(alloc, path, access);
        defer if (team_path) |owned| alloc.free(owned);
        return .{
            .route = route,
            .url = try modelCatalogUrl(alloc, team_path orelse path, gateway_base_override),
            .api_key = access.authorizationCredential(),
            .gateway_team = modelCatalogHeaderTeam(access),
        };
    }

    return .{
        .route = route,
        .url = try directModelCatalogUrl(alloc, route, endpoint_overrides),
        .api_key = access.authorizationCredential(),
        // Team identifiers are a Vercel-only request capability. Codex account
        // identity is loaded and paired with the token in gateway/client.zig.
        .gateway_team = null,
    };
}

fn fetchModelCatalogResponse(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
) !gateway_client.GatewayJsonResult {
    if (cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return error.Cancelled;
    }

    var plan = try prepareModelCatalogRequest(
        alloc,
        access,
        path,
        io_mod.getenv(base_url_env),
        provider_route.EndpointOverrides.fromEnvironment(),
    );
    defer plan.deinit(alloc);

    return switch (plan.route) {
        .vercel_gateway => if (cancel_flag) |flag|
            gateway_client.fetchGatewayJsonCancellable(alloc, plan.api_key, plan.gateway_team, plan.url, flag)
        else
            gateway_client.fetchGatewayJson(alloc, plan.api_key, plan.gateway_team, plan.url),
        .openai_responses_byok, .codex_responses_oauth => direct: {
            const api_key = plan.api_key orelse break :direct .{ .http_status = .unauthorized };
            break :direct if (cancel_flag) |flag|
                gateway_client.fetchProviderJsonCancellable(alloc, access.credentialSource().?, api_key, plan.url, flag)
            else
                gateway_client.fetchProviderJson(alloc, access.credentialSource().?, api_key, plan.url);
        },
    };
}

fn modelCatalogTeamPath(
    alloc: Allocator,
    path: []const u8,
    access: credentials.CatalogAccess,
) Allocator.Error!?[]u8 {
    if (access.credentialSource() != .fx_login) return null;
    const team = access.teamContext() orelse return null;
    if (!shared_types.validGatewayTeam(team)) return null;
    return try std.fmt.allocPrint(alloc, "{s}?teamId={s}", .{ path, team });
}

fn modelCatalogHeaderTeam(access: credentials.CatalogAccess) ?[]const u8 {
    if (access.credentialSource() == .fx_login) return null;
    return access.teamContext();
}

fn catalogRequestFailure(err: anyerror) model_catalog.Failure {
    if (err == error.OutOfMemory) return .{ .category = .resource_exhausted };
    if (err == error.Cancelled) return .{ .category = .cancellation };
    if (isInvalidGatewayResponse(err)) return .{ .category = .malformed_response };
    return .{
        .category = .transport,
        .retryable = gateway_client.isRetryableGatewayError(err),
    };
}

fn isInvalidGatewayResponse(err: anyerror) bool {
    return switch (err) {
        error.HttpConnectionHeaderUnsupported,
        error.HttpContentEncodingUnsupported,
        error.HttpHeaderContinuationsUnsupported,
        error.HttpHeadersInvalid,
        error.HttpTransferEncodingUnsupported,
        error.InvalidContentLength,
        error.HttpChunkInvalid,
        error.HttpChunkTruncated,
        error.HttpHeadersOversize,
        error.UnsupportedCompressionMethod,
        => true,
        else => false,
    };
}

test "catalog request failures preserve transport and cancellation facts" {
    const network = catalogRequestFailure(error.ConnectionResetByPeer);
    try std.testing.expectEqual(model_catalog.FailureCategory.transport, network.category);
    try std.testing.expect(network.http_status == null);
    try std.testing.expect(network.retryable);

    const cancelled = catalogRequestFailure(error.Cancelled);
    try std.testing.expectEqual(model_catalog.FailureCategory.cancellation, cancelled.category);
    try std.testing.expect(!cancelled.retryable);

    const malformed = catalogRequestFailure(error.HttpHeadersInvalid);
    try std.testing.expectEqual(model_catalog.FailureCategory.malformed_response, malformed.category);
}

fn modelCatalogUrl(alloc: Allocator, path: []const u8, base_url_override: ?[]const u8) ![]u8 {
    const base_url = if (base_url_override) |candidate| blk: {
        if (gateway_client.isLoopbackHttpUrl(candidate)) break :blk candidate;
        debug_trace.logf("gateway", "ignoring {s}: not loopback http", .{base_url_env});
        break :blk default_model_catalog_base_url;
    } else default_model_catalog_base_url;

    return std.fmt.allocPrint(alloc, "{s}{s}", .{ base_url, path });
}

// This is the Codex model-catalog schema compatibility level implemented by
// parseCodexModelCatalog, not fx's independently versioned application release.
const codex_catalog_client_version = "0.144.5";

fn directModelCatalogUrl(
    alloc: Allocator,
    route: provider_route.ProviderRoute,
    overrides: provider_route.EndpointOverrides,
) ![]u8 {
    std.debug.assert(route != .vercel_gateway);
    const resolved_base = try provider_route.resolveBaseUrlAlloc(alloc, route, overrides);
    defer alloc.free(resolved_base);

    const models_url = try provider_route.appendModelsEndpointAlloc(alloc, resolved_base);
    if (route != .codex_responses_oauth) return models_url;
    defer alloc.free(models_url);
    return std.fmt.allocPrint(
        alloc,
        "{s}?client_version={s}",
        .{ models_url, codex_catalog_client_version },
    );
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

const ModelsUrlTestEnv = struct {
    alloc: std.mem.Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: std.mem.Allocator, models_url: []const u8) !*ModelsUrlTestEnv {
        _ = try stableModelsTestEnviron();

        const self = try alloc.create(ModelsUrlTestEnv);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();
        try self.map.put(e2e_gateway_models_url_env, models_url);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *ModelsUrlTestEnv) void {
        if (stable_models_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn installLoopbackModelsEnv(alloc: std.mem.Allocator, port: u16) !*ModelsUrlTestEnv {
    const models_url = try std.fmt.allocPrint(
        alloc,
        "http://127.0.0.1:{d}/v1/models",
        .{port},
    );
    defer alloc.free(models_url);
    return ModelsUrlTestEnv.install(alloc, models_url);
}

test "model catalog GET includes selected team header" {
    var fixture = try gateway_client.TestModelCatalogFixture.init();
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const env = try installLoopbackModelsEnv(std.testing.allocator, fixture.port());
    defer env.deinit();

    var ids = try fetchModelIds(std.testing.allocator, credentials.catalogAccessForCredential(.ai_gateway_api_key, "test-key", "team_123"), models_path);
    defer collections.freeStringList(std.testing.allocator, &ids);

    try std.testing.expectEqualStrings("Bearer test-key", fixture.capturedHeaderValue("authorization").?);
    try std.testing.expectEqualStrings("team_123", fixture.capturedHeaderValue(gateway_client.vercel_ai_gateway_team_header).?);
    if (fixture.failure()) |err| return err;
}

test "cancellable model catalog GET includes selected team header" {
    var fixture = try gateway_client.TestModelCatalogFixture.init();
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const env = try installLoopbackModelsEnv(std.testing.allocator, fixture.port());
    defer env.deinit();

    var cancel_flag = std.atomic.Value(bool).init(false);
    var ids = try fetchModelIdsCancellable(
        std.testing.allocator,
        credentials.catalogAccessForCredential(.ai_gateway_api_key, "test-key", "team_123"),
        models_path,
        &cancel_flag,
    );
    defer collections.freeStringList(std.testing.allocator, &ids);

    try std.testing.expectEqualStrings("Bearer test-key", fixture.capturedHeaderValue("authorization").?);
    try std.testing.expectEqualStrings("team_123", fixture.capturedHeaderValue(gateway_client.vercel_ai_gateway_team_header).?);
    if (fixture.failure()) |err| return err;
}

fn expectModelCatalogTeamHeaderOmitted(gateway_team: ?[]const u8) !void {
    var fixture = try gateway_client.TestModelCatalogFixture.init();
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const env = try installLoopbackModelsEnv(std.testing.allocator, fixture.port());
    defer env.deinit();

    var ids = try fetchModelIds(std.testing.allocator, credentials.catalogAccessForCredential(.ai_gateway_api_key, "test-key", gateway_team), models_path);
    defer collections.freeStringList(std.testing.allocator, &ids);

    try std.testing.expectEqualStrings("Bearer test-key", fixture.capturedHeaderValue("authorization").?);
    try std.testing.expect(fixture.capturedHeaderValue(gateway_client.vercel_ai_gateway_team_header) == null);
    if (fixture.failure()) |err| return err;
}

test "model catalog GET omits team header for null and empty team" {
    try expectModelCatalogTeamHeaderOmitted(null);
    try expectModelCatalogTeamHeaderOmitted("");
}

test "model catalog GET sends fx user agent without attribution headers" {
    var fixture = try gateway_client.TestModelCatalogFixture.init();
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const env = try installLoopbackModelsEnv(std.testing.allocator, fixture.port());
    defer env.deinit();

    var ids = try fetchModelIds(std.testing.allocator, credentials.catalogAccessForCredential(.ai_gateway_api_key, "test-key", null), models_path);
    defer collections.freeStringList(std.testing.allocator, &ids);

    try std.testing.expectEqualStrings(gateway_client.user_agent, fixture.capturedHeaderValue("user-agent").?);
    try std.testing.expect(std.mem.find(u8, fixture.capturedHeaderValue("user-agent").?, "zig") == null);
    // Attribution headers stay on model generation requests only.
    try std.testing.expect(fixture.capturedHeaderValue("http-referer") == null);
    try std.testing.expect(fixture.capturedHeaderValue("x-title") == null);
    if (fixture.failure()) |err| return err;
}

fn parseModelIdsForView(
    alloc: std.mem.Allocator,
    json_text: []const u8,
    view: ModelCatalogView,
) !std.ArrayList([]u8) {
    var catalog = try parseModelCatalogForView(alloc, json_text, view);
    defer freeModelCatalog(alloc, &catalog);

    return model_catalog.projectModelIds(alloc, catalog.items);
}

pub fn parseModelCatalogForView(
    alloc: std.mem.Allocator,
    json_text: []const u8,
    view: ModelCatalogView,
) !std.ArrayList(ModelCatalogEntry) {
    return parseProviderModelCatalogForView(alloc, json_text, view, .vercel_gateway);
}

fn parseProviderModelCatalogForView(
    alloc: std.mem.Allocator,
    json_text: []const u8,
    view: ModelCatalogView,
    catalog_kind: provider_route.CatalogKind,
) !std.ArrayList(ModelCatalogEntry) {
    var catalog = switch (catalog_kind) {
        .vercel_gateway => try parseSortedModelCatalog(alloc, json_text),
        .openai_models => try parseOpenAiModelCatalog(alloc, json_text),
        .codex_builtin => try parseCodexModelCatalog(alloc, json_text),
    };
    switch (view) {
        .full => return catalog,
        .picker => {
            defer freeModelCatalog(alloc, &catalog);
            return model_catalog.projectPickerModelCatalog(alloc, catalog.items);
        },
    }
}

/// Shared provider-aware catalog parser for transports that fetch outside the
/// native HTTP client (for example the JavaScript host bridge).
pub fn parseModelCatalogForProvider(
    alloc: Allocator,
    json_text: []const u8,
    view: model_catalog.View,
    catalog_kind: provider_route.CatalogKind,
) !std.ArrayList(ModelCatalogEntry) {
    return parseProviderModelCatalogForView(alloc, json_text, view, catalog_kind);
}

fn parseOpenAiModelCatalog(
    alloc: Allocator,
    json_text: []const u8,
) !std.ArrayList(ModelCatalogEntry) {
    var candidates: std.ArrayList(ModelCatalogEntry) = .empty;
    errdefer freeModelCatalog(alloc, &candidates);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedResponse;
    const data = parsed.value.object.get("data") orelse return error.MalformedResponse;
    if (data != .array) return error.MalformedResponse;

    for (data.array.items) |raw| {
        if (raw != .object) continue;
        const id_value = raw.object.get("id") orelse continue;
        if (id_value != .string or id_value.string.len == 0) continue;
        // Keep `/models` IDs in the same raw namespace used by direct request
        // capability lookup. `wireModel` still accepts `openai/` for existing
        // saved configuration, but the direct picker never introduces it.
        const id = try alloc.dupe(u8, id_value.string);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        const responses_model = provider_route.wireModel(.openai_responses_byok, id);
        const reasoning_model = isOpenAiReasoningModel(responses_model);
        const text_model = isOpenAiTextModel(responses_model);
        var reasoning_efforts: std.ArrayList(shared_types.ReasoningEffort) = .empty;
        errdefer reasoning_efforts.deinit(alloc);
        if (openAiModelHasKnownGpt56Controls(responses_model)) {
            try reasoning_efforts.appendSlice(alloc, &openai_gpt56_reasoning_efforts);
        }
        const released = optionalInteger(raw.object.get("created"));
        try candidates.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .released = released,
            // `/models` does not advertise capability metadata. These flags
            // describe the recognized Responses families only; arbitrary
            // OpenAI-compatible IDs remain selectable without invented traits.
            .has_tool_use = text_model,
            .has_reasoning = reasoning_model,
            .reasoning_efforts = reasoning_efforts,
            .supports_fast_mode = openAiModelHasKnownGpt56Controls(responses_model),
            .has_vision = text_model,
            .has_file_input = text_model,
            .has_web_search = text_model,
        });
    }
    sort_utils.sort(ModelCatalogEntry, candidates.items, {}, model_catalog.compareModelCatalogEntries);
    return candidates;
}

const openai_gpt56_reasoning_efforts = [_]shared_types.ReasoningEffort{
    shared_types.ReasoningEffort.literal("none"),
    shared_types.ReasoningEffort.literal("low"),
    shared_types.ReasoningEffort.literal("medium"),
    shared_types.ReasoningEffort.literal("high"),
    shared_types.ReasoningEffort.literal("xhigh"),
    shared_types.ReasoningEffort.literal("max"),
};

fn openAiModelHasKnownGpt56Controls(model: []const u8) bool {
    const exact_models = [_][]const u8{
        "gpt-5.6",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
    };
    for (exact_models) |candidate| {
        if (std.mem.eql(u8, model, candidate)) return true;
    }
    return false;
}

fn parseCodexModelCatalog(
    alloc: Allocator,
    json_text: []const u8,
) !std.ArrayList(ModelCatalogEntry) {
    var candidates: std.ArrayList(ModelCatalogEntry) = .empty;
    errdefer freeModelCatalog(alloc, &candidates);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedResponse;
    const models = parsed.value.object.get("models") orelse return error.MalformedResponse;
    if (models != .array) return error.MalformedResponse;

    for (models.array.items) |raw| {
        if (raw != .object) continue;
        const slug = raw.object.get("slug") orelse continue;
        if (slug != .string or slug.string.len == 0) continue;
        if (raw.object.get("visibility")) |visibility| {
            if (visibility != .string or !std.mem.eql(u8, visibility.string, "list")) continue;
        }

        var reasoning_efforts = try parseCodexReasoningEfforts(
            alloc,
            raw.object.get("supported_reasoning_levels"),
        );
        errdefer reasoning_efforts.deinit(alloc);
        const id = try alloc.dupe(u8, slug.string);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        const priority = optionalInteger(raw.object.get("priority"));
        const released = if (priority == std.math.minInt(i64))
            std.math.maxInt(i64)
        else
            -priority;
        const declared_context_window = optionalUnsignedU32(raw.object.get("context_window"));
        const context_window = if (declared_context_window > 0)
            declared_context_window
        else
            optionalUnsignedU32(raw.object.get("max_context_window"));
        const configured_auto_compact_limit = optionalUnsignedU32(raw.object.get("auto_compact_token_limit"));
        const derived_auto_compact_limit: u32 = @intCast((@as(u64, context_window) * 9) / 10);
        const auto_compact_token_limit = if (configured_auto_compact_limit == 0)
            derived_auto_compact_limit
        else if (derived_auto_compact_limit == 0)
            configured_auto_compact_limit
        else
            @min(configured_auto_compact_limit, derived_auto_compact_limit);
        const effective_context_window_percent: u8 = blk: {
            const raw_percent = optionalInteger(raw.object.get("effective_context_window_percent"));
            if (raw_percent <= 0) break :blk 95;
            break :blk @intCast(@min(raw_percent, 100));
        };
        try candidates.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .released = released,
            .has_tool_use = true,
            .has_reasoning = reasoning_efforts.items.len > 0,
            .reasoning_efforts = reasoning_efforts,
            .supports_fast_mode = codexSupportsFastMode(raw.object),
            .has_vision = codexSupportsImageInput(raw.object),
            .has_web_search = optionalBool(raw.object.get("supports_search_tool")),
            .context_window = context_window,
            .auto_compact_token_limit = auto_compact_token_limit,
            .effective_context_window_percent = effective_context_window_percent,
        });
    }
    sort_utils.sort(ModelCatalogEntry, candidates.items, {}, model_catalog.compareModelCatalogEntries);
    return candidates;
}

fn parseCodexReasoningEfforts(
    alloc: Allocator,
    levels: ?std.json.Value,
) !std.ArrayList(shared_types.ReasoningEffort) {
    var efforts: std.ArrayList(shared_types.ReasoningEffort) = .empty;
    errdefer efforts.deinit(alloc);
    const value = levels orelse return efforts;
    if (value != .array) return efforts;
    for (value.array.items) |level| {
        if (efforts.items.len >= shared_types.ReasoningEffort.max_options) break;
        if (level != .object) continue;
        const raw_effort = level.object.get("effort") orelse continue;
        if (raw_effort != .string) continue;
        const effort = shared_types.ReasoningEffort.parse(raw_effort.string) orelse continue;
        if (effort.isDefault()) continue;
        try efforts.append(alloc, effort);
    }
    return efforts;
}

fn isOpenAiReasoningModel(model: []const u8) bool {
    if (std.mem.startsWith(u8, model, "gpt-5")) return true;
    return model.len >= 2 and model[0] == 'o' and std.ascii.isDigit(model[1]);
}

fn isOpenAiTextModel(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "gpt-") or
        isOpenAiReasoningModel(model) or
        std.mem.startsWith(u8, model, "codex-") or
        std.mem.startsWith(u8, model, "chatgpt-");
}

fn codexSupportsFastMode(entry: std.json.ObjectMap) bool {
    if (entry.get("additional_speed_tiers")) |additional| {
        if (tagListContains(additional, "fast")) return true;
    }
    const tiers = entry.get("service_tiers") orelse return false;
    if (tiers != .array) return false;
    for (tiers.array.items) |tier| {
        if (tier != .object) continue;
        const id = tier.object.get("id") orelse continue;
        if (id == .string and
            (std.mem.eql(u8, id.string, "priority") or
                std.mem.eql(u8, id.string, "fast"))) return true;
    }
    return false;
}

fn codexSupportsImageInput(entry: std.json.ObjectMap) bool {
    const modalities = entry.get("input_modalities") orelse return true;
    return tagListContains(modalities, "image");
}

fn optionalInteger(value: ?std.json.Value) i64 {
    const actual = value orelse return 0;
    return if (actual == .integer) actual.integer else 0;
}

fn optionalBool(value: ?std.json.Value) bool {
    const actual = value orelse return false;
    return actual == .bool and actual.bool;
}

fn parseSortedModelCatalog(alloc: std.mem.Allocator, json_text: []const u8) !std.ArrayList(ModelCatalogEntry) {
    var candidates: std.ArrayList(ModelCatalogEntry) = .empty;
    errdefer freeModelCatalog(alloc, &candidates);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.MalformedResponse;
    const data_value = parsed.value.object.get("data") orelse return error.MalformedResponse;
    if (data_value != .array) return error.MalformedResponse;

    for (data_value.array.items) |entry| {
        const candidate = (try parseModelCatalogEntry(alloc, entry)) orelse continue;
        candidates.append(alloc, candidate) catch |err| {
            model_catalog.freeModelCatalogEntry(alloc, candidate);
            return err;
        };
    }

    sort_utils.sort(ModelCatalogEntry, candidates.items, {}, model_catalog.compareModelCatalogEntries);

    return candidates;
}

fn parsePickerModelIds(alloc: std.mem.Allocator, json_text: []const u8) !std.ArrayList([]u8) {
    return parseModelIdsForView(alloc, json_text, .picker);
}

fn parsePickerModelCatalog(alloc: std.mem.Allocator, json_text: []const u8) !std.ArrayList(ModelCatalogEntry) {
    return parseModelCatalogForView(alloc, json_text, .picker);
}

fn parseModelCatalogEntry(alloc: std.mem.Allocator, entry: std.json.Value) !?ModelCatalogEntry {
    if (entry != .object) return null;

    const model_type = if (entry.object.get("type")) |type_value| blk: {
        if (type_value == .string and !std.ascii.eqlIgnoreCase(type_value.string, "language")) {
            return null;
        }
        break :blk if (type_value == .string) type_value.string else "";
    } else "";

    const id_value = entry.object.get("id") orelse return null;
    if (id_value != .string) return null;

    const released = if (entry.object.get("released")) |value|
        switch (value) {
            .integer => value.integer,
            else => 0,
        }
    else
        0;

    const tags_value = entry.object.get("tags");
    const has_tool_use = optionalTagListContains(tags_value, "tool-use");
    var reasoning_efforts = try parseReasoningEfforts(alloc, entry.object.get("reasoning_options"));
    errdefer reasoning_efforts.deinit(alloc);
    const has_reasoning = optionalTagListContains(tags_value, "reasoning") or reasoning_efforts.items.len > 0;
    const supports_fast_mode = supportsFastMode(entry.object);
    const has_vision = optionalTagListContains(tags_value, "vision");
    const has_file_input = optionalTagListContains(tags_value, "file-input");
    const has_web_search = optionalTagListContains(tags_value, "web-search");
    const has_explicit_caching = optionalTagListContains(tags_value, "explicit-caching");
    const has_implicit_caching = optionalTagListContains(tags_value, "implicit-caching");

    const context_window = optionalUnsignedU32(entry.object.get("context_window"));
    const max_tokens = optionalUnsignedU32(entry.object.get("max_tokens"));
    const web_search_price = try parseWebSearchPrice(alloc, entry.object.get("pricing"));
    errdefer if (web_search_price) |value| alloc.free(value);

    const id = try alloc.dupe(u8, id_value.string);
    errdefer alloc.free(id);
    const owned_model_type = try alloc.dupe(u8, model_type);
    errdefer alloc.free(owned_model_type);

    return .{
        .id = id,
        .model_type = owned_model_type,
        .released = released,
        .has_tool_use = has_tool_use,
        .has_reasoning = has_reasoning,
        .reasoning_efforts = reasoning_efforts,
        .supports_fast_mode = supports_fast_mode,
        .has_vision = has_vision,
        .has_file_input = has_file_input,
        .has_web_search = has_web_search,
        .has_explicit_caching = has_explicit_caching,
        .has_implicit_caching = has_implicit_caching,
        .context_window = context_window,
        .max_tokens = max_tokens,
        .web_search_price = web_search_price,
    };
}

fn parseReasoningEfforts(alloc: std.mem.Allocator, options: ?std.json.Value) !std.ArrayList(shared_types.ReasoningEffort) {
    var efforts: std.ArrayList(shared_types.ReasoningEffort) = .empty;
    errdefer efforts.deinit(alloc);

    const value = options orelse return efforts;
    if (value != .array) return efforts;
    for (value.array.items) |option| {
        if (option != .object) continue;
        const option_type = option.object.get("type") orelse continue;
        if (option_type != .string or !std.mem.eql(u8, option_type.string, "effort")) continue;
        const values = option.object.get("values") orelse continue;
        if (values != .array) continue;
        for (values.array.items) |raw| {
            if (efforts.items.len >= shared_types.ReasoningEffort.max_options) break;
            if (raw != .string) continue;
            const effort = shared_types.ReasoningEffort.parse(raw.string) orelse continue;
            if (effort.isDefault()) continue;
            try efforts.append(alloc, effort);
        }
        break;
    }
    return efforts;
}

fn hasToggleOption(options: ?std.json.Value) bool {
    const value = options orelse return false;
    if (value != .array) return false;
    for (value.array.items) |option| {
        if (option != .object) continue;
        const option_type = option.object.get("type") orelse continue;
        if (option_type == .string and std.mem.eql(u8, option_type.string, "toggle")) return true;
    }
    return false;
}

fn supportsFastMode(entry: std.json.ObjectMap) bool {
    if (hasToggleOption(entry.get("fast_options"))) return true;

    const pricing = entry.get("pricing");
    if (hasObjectField(pricing, "fast")) return true;

    const owned_by = entry.get("owned_by") orelse return false;
    if (owned_by != .string or !std.ascii.eqlIgnoreCase(owned_by.string, "openai")) return false;
    return hasObjectField(objectField(pricing, "service_tiers"), "priority");
}

fn objectField(value: ?std.json.Value, key: []const u8) ?std.json.Value {
    const actual = value orelse return null;
    if (actual != .object) return null;
    return actual.object.get(key);
}

fn hasObjectField(value: ?std.json.Value, key: []const u8) bool {
    const field = objectField(value, key) orelse return false;
    return field == .object;
}

fn optionalUnsignedU32(value: ?std.json.Value) u32 {
    const actual = value orelse return 0;
    if (actual != .integer or actual.integer <= 0) return 0;
    return std.math.cast(u32, actual.integer) orelse 0;
}

fn parseWebSearchPrice(alloc: std.mem.Allocator, pricing: ?std.json.Value) !?[]u8 {
    const pricing_value = pricing orelse return null;
    if (pricing_value != .object) return null;
    const price = pricing_value.object.get("web_search") orelse return null;
    return switch (price) {
        .string => |value| try alloc.dupe(u8, value),
        .integer, .float => blk: {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try std.json.Stringify.value(price, .{}, &out.writer);
            break :blk try out.toOwnedSlice();
        },
        else => null,
    };
}

fn optionalTagListContains(value: ?std.json.Value, needle: []const u8) bool {
    return if (value) |actual| tagListContains(actual, needle) else false;
}

fn tagListContains(value: std.json.Value, needle: []const u8) bool {
    if (value != .array) return false;
    for (value.array.items) |item| {
        if (item == .string and std.ascii.eqlIgnoreCase(item.string, needle)) return true;
    }
    return false;
}

test "parseSortedModelIds filters non-language entries and surfaces popular models first" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"google/gemini-2.5-flash-image","type":"image-generation","released":30,"tags":["image-generation"]},
        \\  {"id":"anthropic/claude-haiku-4.5","type":"language","released":20,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5","type":"language","released":40,"tags":["tool-use"]},
        \\  {"id":"anthropic/claude-opus-4.6","type":"language","released":50,"tags":["tool-use"]}
        \\]}
    ;

    var ids = try parseSortedModelIds(std.testing.allocator, json_text);
    defer collections.freeStringList(std.testing.allocator, &ids);

    try std.testing.expectEqual(@as(usize, 3), ids.items.len);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.6", ids.items[0]);
    try std.testing.expectEqualStrings("openai/gpt-5", ids.items[1]);
    try std.testing.expectEqualStrings("anthropic/claude-haiku-4.5", ids.items[2]);
}

test "parseSortedModelIds prefers tool-use models over unsupported ones" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"openai/gpt-5","type":"language","released":10,"tags":[]},
        \\  {"id":"openai/gpt-5-mini","type":"language","released":9,"tags":["tool-use"]}
        \\]}
    ;

    var ids = try parseSortedModelIds(std.testing.allocator, json_text);
    defer collections.freeStringList(std.testing.allocator, &ids);

    try std.testing.expectEqualStrings("openai/gpt-5-mini", ids.items[0]);
    try std.testing.expectEqualStrings("openai/gpt-5", ids.items[1]);
}

fn idsContain(ids: []const []const u8, needle: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, needle)) return true;
    }
    return false;
}

test "parsePickerModelIds keeps highlights on top and exposes the full catalog" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"anthropic/claude-opus-4.8","type":"language","released":50,"tags":["tool-use"]},
        \\  {"id":"anthropic/claude-opus-4.7","type":"language","released":40,"tags":["tool-use"]},
        \\  {"id":"anthropic/claude-opus-4.6","type":"language","released":30,"tags":["tool-use"]},
        \\  {"id":"anthropic/claude-opus-4.5","type":"language","released":20,"tags":["tool-use"]},
        \\  {"id":"anthropic/claude-sonnet-4.6","type":"language","released":60,"tags":["tool-use"]},
        \\  {"id":"alibaba/qwen-3.7-max","type":"language","released":130,"tags":["tool-use"]},
        \\  {"id":"alibaba/qwen-3.7-plus","type":"language","released":120,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5.5","type":"language","released":90,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5.5-pro","type":"language","released":90,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5.4","type":"language","released":85,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5.4-mini","type":"language","released":85,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5.3-codex","type":"language","released":80,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5.2-codex","type":"language","released":70,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5.2","type":"language","released":70,"tags":["tool-use"]},
        \\  {"id":"openai/o3","type":"language","released":110,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-oss-120b","type":"language","released":100,"tags":["tool-use"]},
        \\  {"id":"xai/grok-build-0.1","type":"language","released":95,"tags":["tool-use"]},
        \\  {"id":"google/gemini-3.1-pro","type":"language","released":120,"tags":["tool-use"]},
        \\  {"id":"zai/glm-5.2","type":"language","released":100,"tags":["tool-use"]},
        \\  {"id":"zai/glm-5.2-fast","type":"language","released":100,"tags":["tool-use"]},
        \\  {"id":"zai/glm-5.1","type":"language","released":90,"tags":["tool-use"]},
        \\  {"id":"zai/glm-5","type":"language","released":80,"tags":["tool-use"]},
        \\  {"id":"deepseek/deepseek-v4","type":"language","released":110,"tags":["tool-use"]},
        \\  {"id":"deepseek/deepseek-v4-flash","type":"language","released":110,"tags":["tool-use"]},
        \\  {"id":"deepseek/deepseek-v4-pro","type":"language","released":110,"tags":["tool-use"]},
        \\  {"id":"minimax/minimax-m3","type":"language","released":140,"tags":["tool-use"]},
        \\  {"id":"minimax/minimax-m2.7","type":"language","released":130,"tags":["tool-use"]}
        \\]}
    ;

    var ids = try parsePickerModelIds(std.testing.allocator, json_text);
    defer collections.freeStringList(std.testing.allocator, &ids);

    const expected_featured = [_][]const u8{
        "openai/gpt-5.5",
        "xai/grok-build-0.1",
        "anthropic/claude-opus-4.8",
        "zai/glm-5.2",
        "deepseek/deepseek-v4-pro",
        "minimax/minimax-m3",
    };
    for (expected_featured, 0..) |model, index| {
        try std.testing.expectEqualStrings(model, ids.items[index]);
    }
    try std.testing.expectEqualStrings("alibaba/qwen-3.7-max", ids.items[expected_featured.len]);
    try std.testing.expectEqualStrings("alibaba/qwen-3.7-plus", ids.items[expected_featured.len + 1]);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.7", ids.items[expected_featured.len + 2]);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.6", ids.items[expected_featured.len + 3]);

    const all_models = [_][]const u8{
        "anthropic/claude-opus-4.8",
        "anthropic/claude-opus-4.7",
        "anthropic/claude-opus-4.6",
        "anthropic/claude-opus-4.5",
        "anthropic/claude-sonnet-4.6",
        "alibaba/qwen-3.7-max",
        "alibaba/qwen-3.7-plus",
        "openai/gpt-5.5",
        "openai/gpt-5.5-pro",
        "openai/gpt-5.4",
        "openai/gpt-5.4-mini",
        "openai/gpt-5.3-codex",
        "openai/gpt-5.2-codex",
        "openai/gpt-5.2",
        "openai/o3",
        "openai/gpt-oss-120b",
        "xai/grok-build-0.1",
        "google/gemini-3.1-pro",
        "zai/glm-5.2",
        "zai/glm-5.2-fast",
        "zai/glm-5.1",
        "zai/glm-5",
        "deepseek/deepseek-v4",
        "deepseek/deepseek-v4-flash",
        "deepseek/deepseek-v4-pro",
        "minimax/minimax-m3",
        "minimax/minimax-m2.7",
    };
    for (all_models) |model| {
        try std.testing.expect(idsContain(ids.items, model));
    }
    try std.testing.expectEqual(all_models.len, ids.items.len);
}

test "parsePickerModelIds features Fable as the top highlight" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"anthropic/claude-opus-4.8","type":"language","released":50,"tags":["tool-use"]},
        \\  {"id":"anthropic/claude-fable-5","type":"language","released":55,"tags":["tool-use"]},
        \\  {"id":"anthropic/claude-sonnet-4.6","type":"language","released":60,"tags":["tool-use"]}
        \\]}
    ;

    var ids = try parsePickerModelIds(std.testing.allocator, json_text);
    defer collections.freeStringList(std.testing.allocator, &ids);

    try std.testing.expectEqualStrings("anthropic/claude-fable-5", ids.items[0]);
    try std.testing.expect(idsContain(ids.items, "anthropic/claude-opus-4.8"));
    try std.testing.expect(idsContain(ids.items, "anthropic/claude-sonnet-4.6"));
    try std.testing.expectEqual(@as(usize, 3), ids.items.len);
}

test "gateway catalog rejects malformed envelope shapes" {
    const malformed_envelopes = [_][]const u8{
        "[]",
        "{}",
        "{\"data\":{}}",
    };

    for (malformed_envelopes) |json_text| {
        try std.testing.expectError(
            error.MalformedResponse,
            parseSortedModelCatalog(std.testing.allocator, json_text),
        );
    }
}

test "gateway catalog accepts an explicit empty data array" {
    var catalog = try parseSortedModelCatalog(std.testing.allocator, "{\"data\":[]}");
    defer freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 0), catalog.items.len);
}

test "OpenAI catalog data IDs stay in the direct wire capability namespace" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"gpt-5.6-sol","object":"model","created":42},
        \\  {"id":"text-embedding-3-large","object":"model","created":41}
        \\]}
    ;
    var catalog = try parseProviderModelCatalogForView(
        std.testing.allocator,
        json_text,
        .full,
        .openai_models,
    );
    defer freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", catalog.items[0].id);
    try std.testing.expectEqualStrings(
        "gpt-5.6-sol",
        provider_route.wireModel(.openai_responses_byok, catalog.items[0].id),
    );
    try std.testing.expect(catalog.items[0].has_tool_use);
    try std.testing.expect(catalog.items[0].has_reasoning);
    try std.testing.expect(catalog.items[0].has_vision);
    const capability_lookup = for (catalog.items) |*entry| {
        if (std.mem.eql(u8, entry.id, "gpt-5.6-sol")) break entry;
    } else return error.TestExpectedEqual;
    try std.testing.expect(capability_lookup.has_tool_use);
    try std.testing.expect(capability_lookup.has_reasoning);
    try std.testing.expectEqual(@as(usize, 6), capability_lookup.reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("none", capability_lookup.reasoning_efforts.items[0].label());
    try std.testing.expectEqualStrings("max", capability_lookup.reasoning_efforts.items[5].label());
    try std.testing.expect(capability_lookup.supports_fast_mode);
    try std.testing.expectEqualStrings("text-embedding-3-large", catalog.items[1].id);
    try std.testing.expect(!catalog.items[1].has_tool_use);
}

test "OpenAI catalog does not infer controls for compatible custom IDs" {
    const json_text =
        \\{"data":[
        \\  {"id":"gpt-5.6-company-custom","object":"model"},
        \\  {"id":"company/gpt-5.6-sol","object":"model"}
        \\]}
    ;
    var catalog = try parseProviderModelCatalogForView(
        std.testing.allocator,
        json_text,
        .full,
        .openai_models,
    );
    defer freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    for (catalog.items) |entry| {
        try std.testing.expectEqual(@as(usize, 0), entry.reasoning_efforts.items.len);
        try std.testing.expect(!entry.supports_fast_mode);
    }
}

fn checkOpenAiCatalogControlAllocationFailures(alloc: Allocator) !void {
    var catalog = try parseProviderModelCatalogForView(
        alloc,
        "{\"data\":[{\"id\":\"gpt-5.6-sol\",\"object\":\"model\"}]}",
        .full,
        .openai_models,
    );
    defer freeModelCatalog(alloc, &catalog);
}

test "OpenAI catalog controls clean all partial allocations" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkOpenAiCatalogControlAllocationFailures,
        .{},
    );
}

test "Codex catalog accepts models slug metadata and hides non-picker entries" {
    const json_text =
        \\{"models":[
        \\  {"slug":"gpt-5.6-sol","visibility":"list","priority":1,"supported_reasoning_levels":[{"effort":"low"},{"effort":"xhigh"}],"additional_speed_tiers":["fast"],"input_modalities":["text","image"],"supports_search_tool":true,"context_window":272000,"max_context_window":872000,"auto_compact_token_limit":null},
        \\  {"slug":"gpt-hidden","visibility":"hide","priority":0,"supported_reasoning_levels":[]},
        \\  {"slug":"o3","visibility":"list","priority":2,"supported_reasoning_levels":[],"service_tiers":[{"id":"priority"}],"input_modalities":["text"],"supports_search_tool":false,"max_context_window":200000}
        \\]}
    ;
    var catalog = try parseProviderModelCatalogForView(
        std.testing.allocator,
        json_text,
        .full,
        .codex_builtin,
    );
    defer freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", catalog.items[0].id);
    try std.testing.expectEqual(@as(usize, 2), catalog.items[0].reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("low", catalog.items[0].reasoning_efforts.items[0].label());
    try std.testing.expectEqualStrings("xhigh", catalog.items[0].reasoning_efforts.items[1].label());
    try std.testing.expect(catalog.items[0].supports_fast_mode);
    try std.testing.expect(catalog.items[0].has_vision);
    try std.testing.expect(catalog.items[0].has_web_search);
    try std.testing.expectEqual(@as(u32, 272_000), catalog.items[0].context_window);
    try std.testing.expectEqual(@as(u32, 244_800), catalog.items[0].auto_compact_token_limit);
    try std.testing.expectEqual(@as(u8, 95), catalog.items[0].effective_context_window_percent);
    try std.testing.expectEqualStrings("o3", catalog.items[1].id);
    try std.testing.expect(catalog.items[1].supports_fast_mode);
    try std.testing.expect(!catalog.items[1].has_vision);
    try std.testing.expect(!catalog.items[1].has_web_search);
}

fn checkCodexCatalogAllocationFailures(alloc: Allocator) !void {
    const json_text =
        \\{"models":[{"slug":"gpt-5.6-sol","visibility":"list","priority":1,"supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}],"input_modalities":["text","image"],"supports_search_tool":true}]}
    ;
    var catalog = try parseProviderModelCatalogForView(
        alloc,
        json_text,
        .full,
        .codex_builtin,
    );
    defer freeModelCatalog(alloc, &catalog);
}

test "Codex catalog parser cleans all partial allocations" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCodexCatalogAllocationFailures,
        .{},
    );
}

test "Codex catalog malformed envelopes leave the allocator clean" {
    try std.testing.expectError(
        error.MalformedResponse,
        parseProviderModelCatalogForView(
            std.testing.allocator,
            "{\"models\":{}}",
            .full,
            .codex_builtin,
        ),
    );
}

test "gateway catalog retains broad capability metadata" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"provider/search-priced-worker","type":"language","released":20,"tags":["reasoning","tool-use","vision","file-input","web-search","explicit-caching","implicit-caching"],"context_window":200000,"max_tokens":64000,"pricing":{"web_search":"0.01"}}
        \\]}
    ;

    var catalog = try parseSortedModelCatalog(std.testing.allocator, json_text);
    defer freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);
    try std.testing.expectEqualStrings("provider/search-priced-worker", catalog.items[0].id);
    try std.testing.expectEqualStrings("language", catalog.items[0].model_type);
    try std.testing.expect(catalog.items[0].has_tool_use);
    try std.testing.expect(catalog.items[0].has_reasoning);
    try std.testing.expectEqual(@as(usize, 0), catalog.items[0].reasoning_efforts.items.len);
    try std.testing.expect(catalog.items[0].has_vision);
    try std.testing.expect(catalog.items[0].has_file_input);
    try std.testing.expect(catalog.items[0].has_web_search);
    try std.testing.expect(catalog.items[0].has_explicit_caching);
    try std.testing.expect(catalog.items[0].has_implicit_caching);
    try std.testing.expectEqual(@as(u32, 200_000), catalog.items[0].context_window);
    try std.testing.expectEqual(@as(u32, 64_000), catalog.items[0].max_tokens);
    try std.testing.expectEqualStrings("0.01", catalog.items[0].web_search_price.?);
}

test "gateway catalog recognizes structured reasoning without a reasoning tag" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"provider/future","type":"language","tags":["tool-use","fast"],"reasoning_options":[{"type":"effort","values":["future-tier","high"]},{"type":"budget_tokens","min":1,"max":2048}],"fast_options":[{"type":"toggle"}]}
        \\]}
    ;

    var catalog = try parseSortedModelCatalog(std.testing.allocator, json_text);
    defer freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);
    try std.testing.expect(catalog.items[0].has_reasoning);
    try std.testing.expectEqual(@as(usize, 2), catalog.items[0].reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("future-tier", catalog.items[0].reasoning_efforts.items[0].label());
    try std.testing.expectEqualStrings("high", catalog.items[0].reasoning_efforts.items[1].label());
    try std.testing.expect(catalog.items[0].supports_fast_mode);
}

test "gateway catalog derives Fast support from explicit provider metadata" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"provider/tagged-fast","type":"language","owned_by":"provider","tags":["fast"]},
        \\  {"id":"provider/priced-fast","type":"language","owned_by":"provider","pricing":{"fast":{"input":"0.1","output":"0.2"}}},
        \\  {"id":"openai/priority","type":"language","owned_by":"openai","pricing":{"service_tiers":{"priority":{"input":"0.1","output":"0.2"}}}},
        \\  {"id":"google/priority","type":"language","owned_by":"google","pricing":{"service_tiers":{"priority":{"input":"0.1","output":"0.2"}}}},
        \\  {"id":"provider/malformed-fast","type":"language","owned_by":"provider","pricing":{"fast":"0.1","service_tiers":{"priority":"0.2"}}}
        \\ ]}
    ;

    var catalog = try parseSortedModelCatalog(std.testing.allocator, json_text);
    defer freeModelCatalog(std.testing.allocator, &catalog);

    const expected = [_]struct { id: []const u8, supports_fast_mode: bool }{
        .{ .id = "google/priority", .supports_fast_mode = false },
        .{ .id = "openai/priority", .supports_fast_mode = true },
        .{ .id = "provider/malformed-fast", .supports_fast_mode = false },
        .{ .id = "provider/priced-fast", .supports_fast_mode = true },
        .{ .id = "provider/tagged-fast", .supports_fast_mode = false },
    };
    try std.testing.expectEqual(expected.len, catalog.items.len);
    for (expected) |wanted| {
        const supports_fast_mode = for (catalog.items) |actual| {
            if (std.mem.eql(u8, wanted.id, actual.id)) break actual.supports_fast_mode;
        } else return error.TestExpectedEqual;
        try std.testing.expectEqual(wanted.supports_fast_mode, supports_fast_mode);
    }
}

test "gateway catalog controls are explicit ordered and bounded" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"provider/adversarial","type":"language","tags":["reasoning","fast"],"pricing":{"fast":"1"},"reasoning_options":[42,{"type":"toggle","values":["invented"]},{"type":"effort","values":["default","first",7,"bad value","second","third","fourth","fifth","sixth","seventh","eighth","ninth","tenth","eleventh","twelfth","thirteenth","fourteenth","fifteenth","sixteenth","seventeenth"]}],"fast_options":[null,{"type":"budget_tokens"}]},
        \\  {"id":"provider/explicit-fast","type":"language","fast_options":[{"type":"toggle"}]},
        \\  {"id":"provider/malformed","type":"language","reasoning_options":{"type":"effort","values":["high"]},"fast_options":{"type":"toggle"}}
        \\ ]}
    ;

    var catalog = try parseSortedModelCatalog(std.testing.allocator, json_text);
    defer freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 3), catalog.items.len);
    const adversarial = catalog.items[0];
    try std.testing.expectEqualStrings("provider/adversarial", adversarial.id);
    try std.testing.expectEqual(shared_types.ReasoningEffort.max_options, adversarial.reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("first", adversarial.reasoning_efforts.items[0].label());
    try std.testing.expectEqualStrings("sixteenth", adversarial.reasoning_efforts.items[15].label());
    try std.testing.expect(!adversarial.supports_fast_mode);

    try std.testing.expectEqualStrings("provider/explicit-fast", catalog.items[1].id);
    try std.testing.expect(catalog.items[1].supports_fast_mode);
    try std.testing.expectEqualStrings("provider/malformed", catalog.items[2].id);
    try std.testing.expectEqual(@as(usize, 0), catalog.items[2].reasoning_efforts.items.len);
    try std.testing.expect(!catalog.items[2].supports_fast_mode);
}
