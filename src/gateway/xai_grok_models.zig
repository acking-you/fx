const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const grok_session = @import("../core/auth/grok_session.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const gateway_client = @import("client.zig");

const max_catalog_models: usize = 128;
const max_model_id_bytes: usize = 256;
const max_catalog_bytes: usize = 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;
const default_models_endpoint = "https://cli-chat-proxy.grok.com/v1/models";
const default_modalities_endpoint = "https://api.x.ai/v1/language-models";
const e2e_models_endpoint_env = "FX_E2E_XAI_GROK_MODELS_URL";
const e2e_modalities_endpoint_env = "FX_E2E_XAI_GROK_MODALITIES_URL";

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

const grok46_reasoning_efforts = [_]types.ReasoningEffort{
    types.ReasoningEffort.literal("xhigh"),
    types.ReasoningEffort.literal("high"),
    types.ReasoningEffort.literal("medium"),
    types.ReasoningEffort.literal("low"),
};

const grok45_reasoning_efforts = [_]types.ReasoningEffort{
    types.ReasoningEffort.literal("high"),
    types.ReasoningEffort.literal("medium"),
    types.ReasoningEffort.literal("low"),
};

pub fn fallbackModelCapabilities(model: []const u8) model_capabilities.Capabilities {
    const id = grokModelId(model);
    var capabilities = model_capabilities.Capabilities{
        .supports_tool_use = true,
        .supports_web_search = true,
    };
    if (std.mem.eql(u8, id, "grok-4.6") or
        std.mem.startsWith(u8, id, "grok-4.6-") or
        std.mem.startsWith(u8, id, "grok-4.6."))
    {
        capabilities.supports_reasoning = true;
        capabilities.reasoning_efforts = .fromSlice(&grok46_reasoning_efforts);
        capabilities.default_reasoning_effort = types.ReasoningEffort.literal("high");
        return capabilities;
    }
    if (std.mem.eql(u8, id, "grok-4.5") or
        std.mem.startsWith(u8, id, "grok-4.5-") or
        std.mem.startsWith(u8, id, "grok-4.5.") or
        std.mem.eql(u8, id, "grok-4") or
        std.mem.startsWith(u8, id, "grok-4-") or
        std.mem.startsWith(u8, id, "grok-4."))
    {
        capabilities.supports_reasoning = true;
        capabilities.reasoning_efforts = .fromSlice(&grok45_reasoning_efforts);
        capabilities.default_reasoning_effort = types.ReasoningEffort.literal("high");
    }
    return capabilities;
}

fn grokModelId(model: []const u8) []const u8 {
    const xai_prefix = "xai/";
    if (std.mem.startsWith(u8, model, xai_prefix)) return model[xai_prefix.len..];
    return model;
}

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    return switch (model_catalog.fetchCatalog(model_catalog_provider, alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    })) {
        .loaded => |loaded| blk: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :blk .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failure| .{ .failure = failure },
    };
}

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    if (input.access.credentialSource() != .grok_subscription) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    const credential = input.access.authorizationCredential() orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    const account_id = input.access.accountId() orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    if (!grok_session.validAccountId(account_id)) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    const request_url = modelsUrl(alloc) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(request_url);
    const modalities_url = modalitiesUrl(alloc) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(modalities_url);

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });
    var response = fetchCatalogResponse(
        alloc,
        request_url,
        credential,
        account_id,
        cancel_flag,
        deadline,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = catalogFetchFailure(err) };
    };
    defer response.deinit(alloc);
    if (response.status != .ok) {
        return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    }
    var modalities_response = fetchCatalogResponse(
        alloc,
        modalities_url,
        credential,
        null,
        cancel_flag,
        deadline,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = catalogFetchFailure(err) };
    };
    defer modalities_response.deinit(alloc);
    if (modalities_response.status != .ok) {
        return .{ .failure = model_catalog.failureForHttpStatus(modalities_response.status) };
    }
    const catalog = parseCatalog(alloc, response.body, modalities_response.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

fn catalogFetchFailure(err: anyerror) model_catalog.Failure {
    if (err == error.Cancelled) return .{ .category = .cancellation };
    if (err == error.GrokModelCatalogTooLarge) return .{ .category = .malformed_response };
    return .{ .category = .transport, .retryable = true };
}

const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *FetchResponse, alloc: std.mem.Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

const FetchOperation = struct {
    alloc: std.mem.Allocator,
    url: []const u8,
    credential: []const u8,
    account_id: ?[]const u8,

    pub fn run(self: *@This()) !FetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const auth_header = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.credential});
        defer secret.zeroAndFree(self.alloc, auth_header);
        const body_buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer secret.zeroAndFree(self.alloc, body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);
        var extra_headers_buffer: [3]std.http.Header = undefined;
        var extra_headers_len: usize = 0;
        extra_headers_buffer[extra_headers_len] = .{ .name = "accept", .value = "application/json" };
        extra_headers_len += 1;
        if (self.account_id) |account_id| {
            extra_headers_buffer[extra_headers_len] = .{ .name = "X-XAI-Token-Auth", .value = "xai-grok-cli" };
            extra_headers_len += 1;
            extra_headers_buffer[extra_headers_len] = .{ .name = "x-userid", .value = account_id };
            extra_headers_len += 1;
        }
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .authorization = .{ .override = auth_header },
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = extra_headers_buffer[0..extra_headers_len],
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.GrokModelCatalogTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        try validateCatalogBodySize(body.len);
        return .{
            .status = result.status,
            .body = try self.alloc.dupe(u8, body),
        };
    }
};

fn fetchCatalogResponse(
    alloc: std.mem.Allocator,
    url: []const u8,
    credential: []const u8,
    account_id: ?[]const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !FetchResponse {
    var operation = FetchOperation{
        .alloc = alloc,
        .url = url,
        .credential = credential,
        .account_id = account_id,
    };
    return gateway_client.runBoundedHttpOperation(
        FetchResponse,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
}

fn modelsUrl(alloc: std.mem.Allocator) ![]u8 {
    const base = io_mod.getenv(e2e_models_endpoint_env) orelse default_models_endpoint;
    if (io_mod.getenv(e2e_models_endpoint_env) != null and !gateway_client.isLoopbackUrl(base)) {
        return error.InvalidE2EGrokModelsEndpoint;
    }
    return alloc.dupe(u8, base);
}

fn modalitiesUrl(alloc: std.mem.Allocator) ![]u8 {
    const base = io_mod.getenv(e2e_modalities_endpoint_env) orelse default_modalities_endpoint;
    if (io_mod.getenv(e2e_modalities_endpoint_env) != null and !gateway_client.isLoopbackUrl(base)) {
        return error.InvalidE2EGrokModalitiesEndpoint;
    }
    return alloc.dupe(u8, base);
}

fn parseCatalog(
    alloc: std.mem.Allocator,
    subscription_json: []const u8,
    modalities_json: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var subscription = try std.json.parseFromSlice(std.json.Value, alloc, subscription_json, .{});
    defer subscription.deinit();
    if (subscription.value != .object) return error.InvalidGrokModelCatalog;
    const subscription_models = subscription.value.object.get("data") orelse
        return error.InvalidGrokModelCatalog;
    if (subscription_models != .array) return error.InvalidGrokModelCatalog;
    try validateCatalogModelCount(subscription_models.array.items.len);

    var modalities = try std.json.parseFromSlice(std.json.Value, alloc, modalities_json, .{});
    defer modalities.deinit();
    if (modalities.value != .object) return error.InvalidGrokModelCatalog;
    const modality_models = modalities.value.object.get("models") orelse
        return error.InvalidGrokModelCatalog;
    if (modality_models != .array) return error.InvalidGrokModelCatalog;
    try validateCatalogModelCount(modality_models.array.items.len);

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (subscription_models.array.items) |value| {
        if (value != .object) continue;
        const object = value.object;
        const api_backend = objectStringAliases(object, &.{ "api_backend", "apiBackend" }) orelse continue;
        if (!std.mem.eql(u8, api_backend, "responses")) continue;
        const raw_id = objectStringAliases(object, &.{ "model", "id" }) orelse continue;
        validateModelId(raw_id) catch continue;
        const modality = findModalityModel(modality_models.array.items, raw_id) orelse continue;
        if (!(stringArrayContains(modality, "output_modalities", "text") catch continue)) continue;

        const context_window = objectPositiveU32Aliases(object, &.{ "context_window", "contextWindow" }) orelse continue;
        const max_output_tokens = objectPositiveU32Aliases(object, &.{ "max_completion_tokens", "maxCompletionTokens" }) orelse 0;
        const has_vision = stringArrayContains(modality, "input_modalities", "image") catch false;
        const has_web_search = optionalBoolAliases(
            object,
            &.{ "supportsBackendSearch", "supports_backend_search" },
        ) catch continue orelse false;
        const supports_reasoning = optionalBoolAliases(
            object,
            &.{ "supports_reasoning_effort", "supportsReasoningEffort" },
        ) catch continue orelse false;

        var reasoning_efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        const default_effort = appendProviderReasoningEfforts(alloc, &reasoning_efforts, object) catch {
            reasoning_efforts.deinit(alloc);
            continue;
        };

        const id = alloc.dupe(u8, raw_id) catch {
            reasoning_efforts.deinit(alloc);
            return error.OutOfMemory;
        };
        const model_type = alloc.dupe(u8, "language") catch {
            alloc.free(id);
            reasoning_efforts.deinit(alloc);
            return error.OutOfMemory;
        };

        catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .has_tool_use = true,
            .has_reasoning = supports_reasoning or reasoning_efforts.items.len > 0,
            .reasoning_efforts = reasoning_efforts,
            .default_reasoning_effort = default_effort,
            .has_vision = has_vision,
            .has_file_input = has_vision,
            .has_web_search = has_web_search,
            .has_implicit_caching = true,
            .context_window = context_window,
            .max_tokens = max_output_tokens,
        }) catch |err| {
            alloc.free(id);
            alloc.free(model_type);
            reasoning_efforts.deinit(alloc);
            return err;
        };
    }
    return catalog;
}

fn appendProviderReasoningEfforts(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(types.ReasoningEffort),
    object: std.json.ObjectMap,
) !types.ReasoningEffort {
    var default_effort: types.ReasoningEffort = .auto;
    if (objectValue(object, &.{ "reasoning_efforts", "reasoningEfforts" })) |value| {
        if (value != .array or value.array.items.len > types.ReasoningEffort.max_options) {
            return error.InvalidGrokModelCatalog;
        }
        for (value.array.items) |entry| {
            const parsed = parseEffortOption(entry) orelse continue;
            if (parsed.effort.isDefault()) continue;
            var duplicate = false;
            for (out.items) |existing| {
                if (existing.eql(parsed.effort)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            try out.append(alloc, parsed.effort);
            if (parsed.is_default) default_effort = parsed.effort;
        }
    }
    if (default_effort.isDefault()) {
        if (objectStringAliases(object, &.{ "reasoning_effort", "reasoningEffort" })) |raw| {
            if (types.ReasoningEffort.parse(raw)) |legacy| {
                if (!legacy.isDefault()) {
                    for (out.items) |existing| {
                        if (existing.eql(legacy)) {
                            default_effort = legacy;
                            break;
                        }
                    }
                }
            }
        }
    }
    if (default_effort.isDefault() and out.items.len > 0) {
        default_effort = out.items[0];
    }
    return default_effort;
}

const ParsedEffortOption = struct {
    effort: types.ReasoningEffort,
    is_default: bool = false,
};

fn parseEffortOption(entry: std.json.Value) ?ParsedEffortOption {
    switch (entry) {
        .string => |raw| {
            const effort = types.ReasoningEffort.parse(raw) orelse return null;
            if (effort.isDefault()) return null;
            return .{ .effort = effort };
        },
        .object => |object| {
            const raw = objectStringAliases(object, &.{ "value", "effort" }) orelse return null;
            const effort = types.ReasoningEffort.parse(raw) orelse return null;
            if (effort.isDefault()) return null;
            const is_default = optionalBoolAliases(object, &.{"default"}) catch null orelse false;
            return .{ .effort = effort, .is_default = is_default };
        },
        else => return null,
    }
}

fn objectValue(object: std.json.ObjectMap, keys: []const []const u8) ?std.json.Value {
    for (keys) |key| {
        if (object.get(key)) |value| return value;
    }
    return null;
}

fn objectStringAliases(object: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    const value = objectValue(object, keys) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn objectPositiveU32Aliases(object: std.json.ObjectMap, keys: []const []const u8) ?u32 {
    const value = objectValue(object, keys) orelse return null;
    if (value != .integer or value.integer <= 0) return null;
    return std.math.cast(u32, value.integer);
}

fn findModalityModel(
    models: []const std.json.Value,
    model_id: []const u8,
) ?std.json.ObjectMap {
    for (models) |value| {
        if (value != .object) continue;
        const candidate = objectStringAliases(value.object, &.{ "id", "model" }) orelse continue;
        validateModelId(candidate) catch continue;
        if (std.mem.eql(u8, candidate, model_id)) return value.object;
    }
    return null;
}

fn stringArrayContains(
    object: std.json.ObjectMap,
    key: []const u8,
    expected: []const u8,
) !bool {
    const value = object.get(key) orelse return error.InvalidGrokModelCatalog;
    if (value != .array or value.array.items.len > 32) return error.InvalidGrokModelCatalog;
    for (value.array.items) |entry| {
        if (entry != .string) return error.InvalidGrokModelCatalog;
        if (std.mem.eql(u8, entry.string, expected)) return true;
    }
    return false;
}

fn optionalBoolAliases(
    object: std.json.ObjectMap,
    keys: []const []const u8,
) !?bool {
    var resolved: ?bool = null;
    for (keys) |key| {
        const value = object.get(key) orelse continue;
        if (value != .bool) return error.InvalidGrokModelCatalog;
        if (resolved) |prior| {
            if (prior != value.bool) return error.InvalidGrokModelCatalog;
        } else {
            resolved = value.bool;
        }
    }
    return resolved;
}

fn validateModelId(id: []const u8) !void {
    if (id.len == 0 or id.len > max_model_id_bytes) return error.InvalidGrokModelCatalog;
    for (id) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidGrokModelCatalog;
    }
}

fn validateCatalogBodySize(size: usize) !void {
    if (size > max_catalog_bytes) return error.GrokModelCatalogTooLarge;
}

fn validateCatalogModelCount(count: usize) !void {
    if (count > max_catalog_models) return error.InvalidGrokModelCatalog;
}

test "Grok catalog parser joins provider-owned subscription capabilities and modalities" {
    const alloc = std.testing.allocator;
    const subscription_json =
        \\{"data":[
        \\  {"id":"current-a","model":"current-a","api_backend":"responses","context_window":500123,"max_completion_tokens":32768,"supports_reasoning_effort":true,"reasoning_efforts":[{"value":"xhigh"},{"value":"medium"}],"supportsBackendSearch":false},
        \\  {"id":"current-b","model":"current-b","api_backend":"responses","context_window":480321,"supports_reasoning_effort":true,"reasoning_efforts":[{"value":"provider-next"},{"value":"low"}],"supports_backend_search":true},
        \\  {"id":"chat-only","model":"chat-only","api_backend":"chat_completions","context_window":200000,"supports_reasoning_effort":false,"reasoning_efforts":[]}
        \\]}
    ;
    const modalities_json =
        \\{"models":[
        \\  {"id":"current-a","input_modalities":["text","image"],"output_modalities":["text"]},
        \\  {"id":"current-b","input_modalities":["text"],"output_modalities":["text"]},
        \\  {"id":"chat-only","input_modalities":["text"],"output_modalities":["text"]}
        \\]}
    ;
    var catalog = try parseCatalog(alloc, subscription_json, modalities_json);
    defer model_catalog.freeModelCatalog(alloc, &catalog);

    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    const first = catalog.items[0];
    try std.testing.expectEqualStrings("current-a", first.id);
    try std.testing.expectEqual(@as(u32, 500_123), first.context_window);
    try std.testing.expectEqual(@as(u32, 32_768), first.max_tokens);
    try std.testing.expectEqual(@as(usize, 2), first.reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("xhigh", first.reasoning_efforts.items[0].label());
    try std.testing.expectEqualStrings("medium", first.reasoning_efforts.items[1].label());
    try std.testing.expect(first.has_vision);
    try std.testing.expect(first.has_file_input);
    try std.testing.expect(!first.has_web_search);

    const second = catalog.items[1];
    try std.testing.expectEqualStrings("current-b", second.id);
    try std.testing.expectEqual(@as(u32, 480_321), second.context_window);
    try std.testing.expectEqual(@as(u32, 0), second.max_tokens);
    try std.testing.expectEqual(@as(usize, 2), second.reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("provider-next", second.reasoning_efforts.items[0].label());
    try std.testing.expectEqualStrings("low", second.reasoning_efforts.items[1].label());
    try std.testing.expect(!second.has_vision);
    try std.testing.expect(second.has_web_search);
    try std.testing.expectEqualStrings("xhigh", first.default_reasoning_effort.label());
    try std.testing.expectEqualStrings("provider-next", second.default_reasoning_effort.label());
}

test "Grok catalog skips incomplete models instead of failing the catalog" {
    const modalities =
        \\{"models":[{"id":"current","input_modalities":["text"],"output_modalities":["text"]}]}
    ;
    const missing_context =
        \\{"data":[{"id":"current","model":"current","api_backend":"responses","supports_reasoning_effort":false,"reasoning_efforts":[]}]}
    ;
    var skipped_context = try parseCatalog(std.testing.allocator, missing_context, modalities);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &skipped_context);
    try std.testing.expectEqual(@as(usize, 0), skipped_context.items.len);

    const empty_efforts =
        \\{"data":[{"id":"current","model":"current","api_backend":"responses","context_window":500000,"supports_reasoning_effort":true,"reasoning_efforts":[]}]}
    ;
    var kept = try parseCatalog(std.testing.allocator, empty_efforts, modalities);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &kept);
    try std.testing.expectEqual(@as(usize, 1), kept.items.len);
    try std.testing.expect(kept.items[0].has_reasoning);
    try std.testing.expectEqual(@as(usize, 0), kept.items[0].reasoning_efforts.items.len);

    const missing_modalities =
        \\{"models":[{"id":"other","input_modalities":["text"],"output_modalities":["text"]}]}
    ;
    const valid_subscription =
        \\{"data":[{"id":"current","model":"current","api_backend":"responses","context_window":500000,"supports_reasoning_effort":false,"reasoning_efforts":[]}]}
    ;
    var skipped_modality = try parseCatalog(std.testing.allocator, valid_subscription, missing_modalities);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &skipped_modality);
    try std.testing.expectEqual(@as(usize, 0), skipped_modality.items.len);
}

test "Grok catalog accepts camelCase effort menus and skips auto" {
    const alloc = std.testing.allocator;
    const subscription_json =
        \\{"data":[
        \\  {"id":"grok-4.6","model":"grok-4.6","apiBackend":"responses","contextWindow":500000,"supportsReasoningEffort":true,"reasoningEffort":"high","reasoningEfforts":[{"value":"auto"},{"value":"xhigh"},{"value":"high","default":true},{"value":"medium"},"low"],"supportsBackendSearch":true},
        \\  {"id":"orphan","model":"orphan","api_backend":"responses","context_window":1000,"supports_reasoning_effort":true,"reasoning_efforts":[{"value":"high"}]}
        \\]}
    ;
    const modalities_json =
        \\{"models":[{"id":"grok-4.6","input_modalities":["text","image"],"output_modalities":["text"]}]}
    ;
    var catalog = try parseCatalog(alloc, subscription_json, modalities_json);
    defer model_catalog.freeModelCatalog(alloc, &catalog);

    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);
    try std.testing.expectEqualStrings("grok-4.6", catalog.items[0].id);
    try std.testing.expectEqual(@as(usize, 4), catalog.items[0].reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("xhigh", catalog.items[0].reasoning_efforts.items[0].label());
    try std.testing.expectEqualStrings("high", catalog.items[0].reasoning_efforts.items[1].label());
    try std.testing.expectEqualStrings("medium", catalog.items[0].reasoning_efforts.items[2].label());
    try std.testing.expectEqualStrings("low", catalog.items[0].reasoning_efforts.items[3].label());
    try std.testing.expectEqualStrings("high", catalog.items[0].default_reasoning_effort.label());
    try std.testing.expect(catalog.items[0].has_web_search);
}

test "Grok fallback capabilities expose current model effort menus" {
    const grok46 = fallbackModelCapabilities("xai/grok-4.6");
    try std.testing.expect(grok46.supports_reasoning);
    try std.testing.expectEqual(@as(usize, 4), grok46.reasoning_efforts.len);
    try std.testing.expectEqualStrings("xhigh", grok46.reasoning_efforts.values[0].label());
    try std.testing.expectEqualStrings("high", grok46.default_reasoning_effort.label());
    try std.testing.expect(model_capabilities.reasoningEffortSupported(grok46, types.ReasoningEffort.literal("high")));

    const grok45 = fallbackModelCapabilities("grok-4.5");
    try std.testing.expectEqual(@as(usize, 3), grok45.reasoning_efforts.len);
    try std.testing.expectEqualStrings("high", grok45.reasoning_efforts.values[0].label());
    try std.testing.expect(!model_capabilities.reasoningEffortSupported(grok45, types.ReasoningEffort.literal("xhigh")));
}

test "Grok catalog URLs use provider-owned subscription and modality endpoints" {
    const subscription_url = try modelsUrl(std.testing.allocator);
    defer std.testing.allocator.free(subscription_url);
    try std.testing.expectEqualStrings(default_models_endpoint, subscription_url);
    const modalities_url = try modalitiesUrl(std.testing.allocator);
    defer std.testing.allocator.free(modalities_url);
    try std.testing.expectEqualStrings(default_modalities_endpoint, modalities_url);
}

test "Grok subscription catalog requires account identity before network I/O" {
    const result = try model_catalog_provider.fetch(std.testing.allocator, .{
        .access = .{ .authenticated = .{
            .source = .grok_subscription,
            .credential = "grok-token",
        } },
        .endpoint = "",
    });
    switch (result) {
        .failure => |failure| {
            try std.testing.expectEqual(model_catalog.FailureCategory.authentication, failure.category);
            try std.testing.expectEqual(std.http.Status.unauthorized, failure.http_status.?);
        },
        .catalog => |catalog| {
            var unexpected = catalog;
            model_catalog.freeModelCatalog(std.testing.allocator, &unexpected);
            return error.TestExpectedAuthenticationFailure;
        },
    }
    try expectCatalogProviderFailure(
        try model_catalog_provider.fetch(std.testing.allocator, .{
            .access = .{ .authenticated = .{
                .source = .grok_subscription,
                .credential = "grok-token",
                .account_id = "acct\r\ninjected",
            } },
            .endpoint = "",
        }),
        .authentication,
    );
}

test "Grok oversized catalog responses are terminal malformed data" {
    const failure = catalogFetchFailure(error.GrokModelCatalogTooLarge);
    try std.testing.expectEqual(model_catalog.FailureCategory.malformed_response, failure.category);
    try std.testing.expect(!failure.retryable);
}

test "Grok model ids enforce the exact provider-local bound" {
    const exact_json = try buildCatalogJson(std.testing.allocator, 1, max_model_id_bytes, 0);
    defer std.testing.allocator.free(exact_json);
    const exact_modalities = try buildModalitiesJson(std.testing.allocator, max_model_id_bytes);
    defer std.testing.allocator.free(exact_modalities);
    var exact = try parseCatalog(std.testing.allocator, exact_json, exact_modalities);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &exact);
    try std.testing.expectEqual(@as(usize, 1), exact.items.len);
    try std.testing.expectEqual(max_model_id_bytes, exact.items[0].id.len);

    const excess_json = try buildCatalogJson(std.testing.allocator, 1, max_model_id_bytes + 1, 0);
    defer std.testing.allocator.free(excess_json);
    const excess_modalities = try buildModalitiesJson(std.testing.allocator, max_model_id_bytes + 1);
    defer std.testing.allocator.free(excess_modalities);
    try expectCatalogParseError(error.InvalidGrokModelCatalog, excess_json, excess_modalities);
}

fn buildCatalogJson(alloc: std.mem.Allocator, model_count: usize, id_bytes: usize, total_bytes: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"data\":[");
    for (0..model_count) |index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"id\":\"");
        try out.writer.splatByteAll('g', id_bytes);
        try out.writer.writeAll("\",\"model\":\"");
        try out.writer.splatByteAll('g', id_bytes);
        try out.writer.writeAll("\",\"api_backend\":\"responses\",\"context_window\":1000,\"supports_reasoning_effort\":false,\"reasoning_efforts\":[]}");
    }
    if (total_bytes > 0) {
        try out.writer.writeAll("],\"padding\":\"");
        const suffix = "\"}";
        if (out.written().len + suffix.len > total_bytes) return error.TestCatalogTargetTooSmall;
        try out.writer.splatByteAll('p', total_bytes - out.written().len - suffix.len);
        try out.writer.writeAll(suffix);
    } else {
        try out.writer.writeAll("]}");
    }
    return out.toOwnedSlice();
}

fn buildModalitiesJson(alloc: std.mem.Allocator, id_bytes: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"models\":[{\"id\":\"");
    try out.writer.splatByteAll('g', id_bytes);
    try out.writer.writeAll("\",\"input_modalities\":[\"text\"],\"output_modalities\":[\"text\"]}]}");
    return out.toOwnedSlice();
}

fn expectCatalogParseError(expected: anyerror, subscription: []const u8, modalities: []const u8) !void {
    var catalog = parseCatalog(std.testing.allocator, subscription, modalities) catch |err| {
        try std.testing.expectEqual(expected, err);
        return;
    };
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    return error.TestExpectedCatalogFailure;
}

const CatalogBodyFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    body: []const u8,
    thread: ?std.Thread = null,
    server_open: bool = true,
    stopping: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn init(body: []const u8) !@This() {
        var fixture: @This() = .{
            .server = undefined,
            .body = body,
        };
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        fixture.server = try address.listen(fixture.io(), .{ .reuse_address = true });
        return fixture;
    }

    fn start(self: *@This()) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
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

    fn io(self: *@This()) std.Io {
        return self.io_backend.io();
    }

    fn port(self: *@This()) u16 {
        return self.server.socket.address.getPort();
    }

    fn wakeAccept(self: *@This()) void {
        var wake_io_backend: std.Io.Threaded = .init_single_threaded;
        const zio = wake_io_backend.io();
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.port()) };
        var stream = address.connect(zio, .{ .mode = .stream }) catch return;
        stream.close(zio);
    }

    fn run(self: *@This()) void {
        self.runFallible() catch |err| {
            if (self.stopping.load(.seq_cst) and err == error.SocketNotListening) return;
            self.failure = err;
        };
    }

    fn runFallible(self: *@This()) !void {
        const zio = self.io();
        var stream = try self.server.accept(zio);
        defer stream.close(zio);
        if (self.stopping.load(.seq_cst)) return;
        var socket_buffer: [4096]u8 = undefined;
        var reader = stream.reader(zio, &socket_buffer);
        var request: [16 * 1024]u8 = undefined;
        var request_len: usize = 0;
        while (request_len < request.len) {
            request[request_len] = try reader.interface.takeByte();
            request_len += 1;
            if (std.mem.endsWith(u8, request[0..request_len], "\r\n\r\n")) break;
        } else return error.TestRequestTooLarge;

        var writer_buffer: [16 * 1024]u8 = undefined;
        var writer = stream.writer(zio, &writer_buffer);
        try writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{self.body.len},
        );
        try writer.interface.writeAll(self.body);
        try writer.interface.flush();
    }
};

test "Grok catalog fixture cleanup joins without a client" {
    var fixture = try CatalogBodyFixture.init("{}");
    defer fixture.deinit();
    try fixture.start();
    fixture.deinit();
    try std.testing.expect(fixture.thread == null);
    try std.testing.expect(fixture.failure == null);
}

var stable_catalog_test_environ: ?*std.process.Environ.Map = null;

fn stableCatalogTestEnviron() !*const std.process.Environ.Map {
    if (stable_catalog_test_environ) |map| return map;
    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_catalog_test_environ = map;
    return map;
}

const CatalogEndpointEnvironment = struct {
    alloc: std.mem.Allocator,
    map: std.process.Environ.Map,

    fn install(
        alloc: std.mem.Allocator,
        models_url: []const u8,
        modalities_url: []const u8,
    ) !*@This() {
        _ = try stableCatalogTestEnviron();
        const self = try alloc.create(@This());
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();
        try self.map.put(e2e_models_endpoint_env, models_url);
        try self.map.put(e2e_modalities_endpoint_env, modalities_url);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *@This()) void {
        if (stable_catalog_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn catalogFixtureUrl(alloc: std.mem.Allocator, fixture: *CatalogBodyFixture, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/{s}", .{ fixture.port(), path });
}

fn expectCatalogProviderFailure(
    result: model_catalog.ProviderResult,
    expected: model_catalog.FailureCategory,
) !void {
    switch (result) {
        .failure => |failure| {
            try std.testing.expectEqual(expected, failure.category);
            try std.testing.expect(!failure.retryable);
        },
        .catalog => |catalog| {
            var unexpected = catalog;
            model_catalog.freeModelCatalog(std.testing.allocator, &unexpected);
            return error.TestExpectedCatalogFailure;
        },
    }
}

fn fetchCatalogFixture(body: []const u8) !FetchResponse {
    var fixture = try CatalogBodyFixture.init(body);
    defer fixture.deinit();
    try fixture.start();
    const url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/models",
        .{fixture.port()},
    );
    defer std.testing.allocator.free(url);
    var operation = FetchOperation{
        .alloc = std.testing.allocator,
        .url = url,
        .credential = "grok-test-token",
        .account_id = "acct_test",
    };
    const result = operation.run();
    fixture.deinit();
    if (fixture.failure) |err| return err;
    return result;
}

fn expectCatalogFetchError(expected: anyerror, body: []const u8) !void {
    var response = fetchCatalogFixture(body) catch |err| {
        try std.testing.expectEqual(expected, err);
        return;
    };
    defer response.deinit(std.testing.allocator);
    return error.TestExpectedCatalogFailure;
}

test "Grok catalog fetch and parser enforce body and model-count bounds" {
    const exact_body = try buildCatalogJson(std.testing.allocator, 1, 8, max_catalog_bytes);
    defer std.testing.allocator.free(exact_body);
    var exact_response = try fetchCatalogFixture(exact_body);
    defer exact_response.deinit(std.testing.allocator);
    try std.testing.expectEqual(max_catalog_bytes, exact_response.body.len);
    const modalities = try buildModalitiesJson(std.testing.allocator, 8);
    defer std.testing.allocator.free(modalities);
    var exact_catalog = try parseCatalog(std.testing.allocator, exact_response.body, modalities);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &exact_catalog);
    try std.testing.expectEqual(@as(usize, 1), exact_catalog.items.len);

    const excess_body = try buildCatalogJson(std.testing.allocator, 1, 8, max_catalog_bytes + 1);
    defer std.testing.allocator.free(excess_body);
    try expectCatalogFetchError(error.GrokModelCatalogTooLarge, excess_body);

    const exact_count = try buildCatalogJson(std.testing.allocator, max_catalog_models, 8, 0);
    defer std.testing.allocator.free(exact_count);
    var count_catalog = try parseCatalog(std.testing.allocator, exact_count, modalities);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &count_catalog);
    try std.testing.expectEqual(max_catalog_models, count_catalog.items.len);

    const excess_count = try buildCatalogJson(std.testing.allocator, max_catalog_models + 1, 8, 0);
    defer std.testing.allocator.free(excess_count);
    try expectCatalogParseError(error.InvalidGrokModelCatalog, excess_count, modalities);
}

test "Grok catalog adapter classifies oversized bodies at both provider origins" {
    const alloc = std.testing.allocator;
    const oversized_subscription = try buildCatalogJson(alloc, 1, 8, max_catalog_bytes + 1);
    defer alloc.free(oversized_subscription);
    var subscription_fixture = try CatalogBodyFixture.init(oversized_subscription);
    defer subscription_fixture.deinit();
    try subscription_fixture.start();
    const subscription_url = try catalogFixtureUrl(alloc, &subscription_fixture, "models");
    defer alloc.free(subscription_url);
    const access: credentials.CatalogAccess = .{ .authenticated = .{
        .source = .grok_subscription,
        .credential = "grok-token",
        .account_id = "acct_grok",
    } };
    {
        const environment = try CatalogEndpointEnvironment.install(
            alloc,
            subscription_url,
            "http://127.0.0.1:1/modalities",
        );
        defer environment.deinit();
        try expectCatalogProviderFailure(
            try model_catalog_provider.fetch(alloc, .{ .access = access, .endpoint = "" }),
            .malformed_response,
        );
    }
    subscription_fixture.deinit();
    if (subscription_fixture.failure) |err| return err;

    const valid_subscription = try buildCatalogJson(alloc, 1, 8, 0);
    defer alloc.free(valid_subscription);
    const oversized_modalities = try alloc.alloc(u8, max_catalog_bytes + 1);
    defer alloc.free(oversized_modalities);
    @memset(oversized_modalities, 'x');
    var valid_fixture = try CatalogBodyFixture.init(valid_subscription);
    defer valid_fixture.deinit();
    var modalities_fixture = try CatalogBodyFixture.init(oversized_modalities);
    defer modalities_fixture.deinit();
    try valid_fixture.start();
    try modalities_fixture.start();
    const valid_url = try catalogFixtureUrl(alloc, &valid_fixture, "models");
    defer alloc.free(valid_url);
    const modalities_url = try catalogFixtureUrl(alloc, &modalities_fixture, "modalities");
    defer alloc.free(modalities_url);
    const modalities_environment = try CatalogEndpointEnvironment.install(alloc, valid_url, modalities_url);
    defer modalities_environment.deinit();
    try expectCatalogProviderFailure(
        try model_catalog_provider.fetch(alloc, .{ .access = access, .endpoint = "" }),
        .malformed_response,
    );
    valid_fixture.deinit();
    modalities_fixture.deinit();
    if (valid_fixture.failure) |err| return err;
    if (modalities_fixture.failure) |err| return err;
}
