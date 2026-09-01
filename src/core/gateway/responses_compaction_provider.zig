const std = @import("std");
const stream_provider = @import("../agent/stream_provider.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const image_attachments = @import("../images/image_attachments.zig");
const types = @import("../shared/types.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const StructuredResponseFormat = struct {
    name: []const u8,
    description: []const u8,
    schema_json: []const u8,
};

/// Provider-neutral input for a dedicated Responses compaction request.
/// This is separate from a live `ModelRequest`: compaction has no event sink,
/// delivery ledger, or retry ownership.
pub const BuildRequest = struct {
    credential_source: ?types.CredentialSource = null,
    provider_credential: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    model: []const u8,
    tool_registry: tool_dispatch.Registry = .{},
    serialized_tools: []const u8,
    messages: []const types.ChatMessage,
    tool_choice: types.ToolChoice,
    vision_mode: stream_provider.VisionMode = .unavailable,
    provider_options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: ?u32 = null,
    budget: ?stream_provider.BuildBudget = null,
    verified_images: ?[]const image_attachments.VerifiedSnapshot = null,
    response_format: ?StructuredResponseFormat = null,
    responses_input_json: ?[]const u8 = null,
    responses_text_options_json: ?[]const u8 = null,
    responses_reasoning_options_json: ?[]const u8 = null,
    responses_tool_choice_json: ?[]const u8 = null,
    responses_extra_fields_json: ?[]const u8 = null,
    responses_compaction_binding: ?types.ResponsesCompactionProviderBindingView = null,
    responses_compaction_trigger: bool = false,
};

/// Complete input for one dedicated Responses compaction attempt. Every slice
/// is borrowed for the duration of `Provider.fetch`.
pub const Request = struct {
    credential: []const u8,
    account_id: ?[]const u8 = null,
    provider_binding: types.ResponsesCompactionProviderBindingView,
    build_request: BuildRequest,
};

/// Provider-owned replacement history. `input_json` is the complete compact
/// response `output` array and is intentionally opaque to product state.
pub const Completed = struct {
    credential_source: types.CredentialSource,
    wire_model: []u8,
    input_json: []u8,
    usage: types.Usage = .{},

    pub fn deinit(self: *Completed, alloc: Allocator) void {
        alloc.free(self.wire_model);
        alloc.free(self.input_json);
        self.* = undefined;
    }
};

pub const Outcome = union(enum) {
    /// The active route intentionally retains fx's local compaction behavior.
    unsupported,
    /// The provider returned a complete HTTP response but rejected the compact
    /// request. Callers may safely use their single local fallback path.
    rejected: std.http.Status,
    compacted: Completed,

    pub fn deinit(self: *Outcome, alloc: Allocator) void {
        switch (self.*) {
            .compacted => |*completed| completed.deinit(alloc),
            .unsupported, .rejected => {},
        }
        self.* = undefined;
    }
};

pub const FetchFn = *const fn (
    context: ?*anyopaque,
    alloc: Allocator,
    request: Request,
) anyerror!Outcome;

pub const Provider = struct {
    /// When set, context must remain valid until every in-flight fetch returns.
    context: ?*anyopaque = null,
    fetch_fn: FetchFn,

    pub fn fetch(self: Provider, alloc: Allocator, request: Request) !Outcome {
        return self.fetch_fn(self.context, alloc, request);
    }
};

test "provider preserves the typed route and opaque replacement contract" {
    const Fake = struct {
        calls: usize = 0,

        fn fetch(
            raw: ?*anyopaque,
            alloc: Allocator,
            request: Request,
        ) !Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            try std.testing.expectEqual(types.CredentialSource.chatgpt_subscription, request.build_request.credential_source.?);
            try std.testing.expectEqualStrings("access", request.credential);
            try std.testing.expectEqualStrings("account", request.account_id.?);
            try std.testing.expectEqualStrings(
                "https://chatgpt.com/backend-api/codex/responses",
                request.provider_binding.normalized_origin,
            );
            return .{ .compacted = .{
                .credential_source = .chatgpt_subscription,
                .wire_model = try alloc.dupe(u8, "gpt-5.6-sol"),
                .input_json = try alloc.dupe(u8, "[{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"}]"),
            } };
        }
    };

    var fake: Fake = .{};
    const provider: Provider = .{ .context = &fake, .fetch_fn = Fake.fetch };
    var outcome = try provider.fetch(std.testing.allocator, .{
        .credential = "access",
        .account_id = "account",
        .provider_binding = .{
            .normalized_origin = "https://chatgpt.com/backend-api/codex/responses",
            .account_id = "account",
        },
        .build_request = .{
            .credential_source = .chatgpt_subscription,
            .model = "gpt-5.6-sol",
            .serialized_tools = "[]",
            .messages = &.{},
            .tool_choice = .auto,
            .provider_options = .{},
        },
    });
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings(
        "[{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"}]",
        outcome.compacted.input_json,
    );
}
