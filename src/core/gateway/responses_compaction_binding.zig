const std = @import("std");

const provider_route = @import("provider_route.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const api_key_digest_hex_len = Sha256.digest_length * 2;
const max_origin_bytes = 4096;
const max_identity_component_bytes = 1024;

pub const BuildOptions = struct {
    endpoint_overrides: provider_route.EndpointOverrides = .{},
    organization: ?[]const u8 = null,
    project: ?[]const u8 = null,

    pub fn fromEnvironment() BuildOptions {
        return .{
            .endpoint_overrides = .fromEnvironment(),
            .organization = io_mod.getenv("OPENAI_ORG_ID"),
            .project = io_mod.getenv("OPENAI_PROJECT_ID"),
        };
    }
};

/// Builds an owned, non-secret identity for the exact direct Responses route
/// that may receive an opaque compaction checkpoint. The canonical Responses
/// endpoint binds custom base paths as well as scheme, host, and port.
pub fn buildAlloc(
    alloc: Allocator,
    credential_source: types.CredentialSource,
    credential: []const u8,
    account_id: ?[]const u8,
    options: BuildOptions,
) !types.ResponsesCompactionProviderBinding {
    const route = provider_route.fromCredentialSource(credential_source) orelse
        return error.UnsupportedCredentialSource;
    if (route.contract().remote_compaction == .unsupported) {
        return error.UnsupportedCredentialSource;
    }

    const normalized_origin = try provider_route.resolveEndpointAlloc(
        alloc,
        route,
        options.endpoint_overrides,
    );
    errdefer alloc.free(normalized_origin);

    const binding: types.ResponsesCompactionProviderBinding = switch (route) {
        .vercel_gateway => unreachable,
        .codex_responses_oauth => .{
            .normalized_origin = normalized_origin,
            .account_id = try dupeRequiredIdentityComponent(alloc, account_id),
        },
        .openai_responses_byok => blk: {
            if (credential.len == 0) return error.MissingOpenAIApiKey;
            var digest: [Sha256.digest_length]u8 = undefined;
            Sha256.hash(credential, &digest, .{});
            const digest_hex = std.fmt.bytesToHex(digest, .lower);
            const api_key_sha256 = try alloc.dupe(u8, &digest_hex);
            errdefer alloc.free(api_key_sha256);
            const organization = try dupeOptionalIdentityComponent(alloc, options.organization);
            errdefer if (organization) |value| alloc.free(value);
            break :blk .{
                .normalized_origin = normalized_origin,
                .api_key_sha256 = api_key_sha256,
                .organization = organization,
                .project = try dupeOptionalIdentityComponent(alloc, options.project),
            };
        },
    };
    errdefer types.freeResponsesCompactionProviderBinding(alloc, binding);
    try validate(credential_source, binding.view());
    return binding;
}

pub fn buildFromEnvironmentAlloc(
    alloc: Allocator,
    credential_source: types.CredentialSource,
    credential: []const u8,
    account_id: ?[]const u8,
) !types.ResponsesCompactionProviderBinding {
    return buildAlloc(
        alloc,
        credential_source,
        credential,
        account_id,
        .fromEnvironment(),
    );
}

pub fn validate(
    credential_source: types.CredentialSource,
    binding: types.ResponsesCompactionProviderBindingView,
) !void {
    if (binding.normalized_origin.len == 0 or
        binding.normalized_origin.len > max_origin_bytes)
    {
        return error.InvalidResponsesCompactionProviderBinding;
    }
    provider_route.validateBaseUrl(binding.normalized_origin) catch
        return error.InvalidResponsesCompactionProviderBinding;

    const route = provider_route.fromCredentialSource(credential_source) orelse
        return error.InvalidResponsesCompactionProviderBinding;
    switch (route) {
        .vercel_gateway => return error.InvalidResponsesCompactionProviderBinding,
        .codex_responses_oauth => {
            try validateRequiredIdentityComponent(binding.account_id);
            if (binding.api_key_sha256 != null or
                binding.organization != null or
                binding.project != null)
            {
                return error.InvalidResponsesCompactionProviderBinding;
            }
        },
        .openai_responses_byok => {
            if (binding.account_id != null) {
                return error.InvalidResponsesCompactionProviderBinding;
            }
            const digest = binding.api_key_sha256 orelse
                return error.InvalidResponsesCompactionProviderBinding;
            if (digest.len != api_key_digest_hex_len) {
                return error.InvalidResponsesCompactionProviderBinding;
            }
            for (digest) |byte| {
                if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) {
                    return error.InvalidResponsesCompactionProviderBinding;
                }
            }
            try validateOptionalIdentityComponent(binding.organization);
            try validateOptionalIdentityComponent(binding.project);
        },
    }
}

pub fn eql(
    left: types.ResponsesCompactionProviderBindingView,
    right: types.ResponsesCompactionProviderBindingView,
) bool {
    return std.mem.eql(u8, left.normalized_origin, right.normalized_origin) and
        optionalBytesEql(left.account_id, right.account_id) and
        optionalBytesEql(left.api_key_sha256, right.api_key_sha256) and
        optionalBytesEql(left.organization, right.organization) and
        optionalBytesEql(left.project, right.project);
}

pub fn credentialMatches(
    credential_source: types.CredentialSource,
    credential: []const u8,
    account_id: ?[]const u8,
    binding: types.ResponsesCompactionProviderBindingView,
) bool {
    validate(credential_source, binding) catch return false;
    const route = provider_route.fromCredentialSource(credential_source) orelse return false;
    return switch (route) {
        .vercel_gateway => false,
        .codex_responses_oauth => optionalBytesEql(account_id, binding.account_id),
        .openai_responses_byok => blk: {
            if (credential.len == 0) break :blk false;
            var digest: [Sha256.digest_length]u8 = undefined;
            Sha256.hash(credential, &digest, .{});
            const digest_hex = std.fmt.bytesToHex(digest, .lower);
            break :blk std.mem.eql(u8, &digest_hex, binding.api_key_sha256.?);
        },
    };
}

fn dupeRequiredIdentityComponent(
    alloc: Allocator,
    value: ?[]const u8,
) ![]u8 {
    const present = value orelse return error.MissingCodexAccountId;
    try validateRequiredIdentityComponent(present);
    return alloc.dupe(u8, present);
}

fn dupeOptionalIdentityComponent(
    alloc: Allocator,
    value: ?[]const u8,
) !?[]u8 {
    const present = value orelse return null;
    if (present.len == 0) return null;
    try validateRequiredIdentityComponent(present);
    return try alloc.dupe(u8, present);
}

fn validateRequiredIdentityComponent(value: ?[]const u8) !void {
    const present = value orelse return error.InvalidResponsesCompactionProviderBinding;
    if (present.len == 0 or present.len > max_identity_component_bytes or
        !std.unicode.utf8ValidateSlice(present) or
        !std.mem.eql(u8, present, std.mem.trim(u8, present, " \t\r\n")))
    {
        return error.InvalidResponsesCompactionProviderBinding;
    }
    for (present) |byte| {
        if (std.ascii.isControl(byte)) {
            return error.InvalidResponsesCompactionProviderBinding;
        }
    }
}

fn validateOptionalIdentityComponent(value: ?[]const u8) !void {
    if (value) |present| try validateRequiredIdentityComponent(present);
}

fn optionalBytesEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

test "provider binding separates account key origin organization and project" {
    const alloc = std.testing.allocator;
    const openai_a = try buildAlloc(
        alloc,
        .openai_api_key,
        "sk-a-secret",
        null,
        .{
            .endpoint_overrides = .{ .responses_base_url = "https://proxy-a.example/v1/" },
            .organization = "org-a",
            .project = "project-a",
        },
    );
    defer types.freeResponsesCompactionProviderBinding(alloc, openai_a);
    try std.testing.expectEqualStrings(
        "https://proxy-a.example/v1/responses",
        openai_a.normalized_origin,
    );
    try std.testing.expectEqual(@as(usize, api_key_digest_hex_len), openai_a.api_key_sha256.?.len);
    try std.testing.expect(std.mem.find(u8, openai_a.api_key_sha256.?, "sk-a-secret") == null);

    const cases = [_]BuildOptions{
        .{
            .endpoint_overrides = .{ .responses_base_url = "https://proxy-b.example/v1" },
            .organization = "org-a",
            .project = "project-a",
        },
        .{
            .endpoint_overrides = .{ .responses_base_url = "https://proxy-a.example/v1" },
            .organization = "org-b",
            .project = "project-a",
        },
        .{
            .endpoint_overrides = .{ .responses_base_url = "https://proxy-a.example/v1" },
            .organization = "org-a",
            .project = "project-b",
        },
    };
    for (cases) |options| {
        const changed = try buildAlloc(alloc, .openai_api_key, "sk-a-secret", null, options);
        defer types.freeResponsesCompactionProviderBinding(alloc, changed);
        try std.testing.expect(!eql(openai_a.view(), changed.view()));
    }
    const changed_key = try buildAlloc(
        alloc,
        .openai_api_key,
        "sk-b-secret",
        null,
        .{
            .endpoint_overrides = .{ .responses_base_url = "https://proxy-a.example/v1" },
            .organization = "org-a",
            .project = "project-a",
        },
    );
    defer types.freeResponsesCompactionProviderBinding(alloc, changed_key);
    try std.testing.expect(!eql(openai_a.view(), changed_key.view()));

    const codex_a = try buildAlloc(
        alloc,
        .chatgpt_subscription,
        "access-token-not-persisted",
        "account-a",
        .{ .endpoint_overrides = .{ .codex_base_url = "https://codex-a.example/api" } },
    );
    defer types.freeResponsesCompactionProviderBinding(alloc, codex_a);
    const codex_b = try buildAlloc(
        alloc,
        .chatgpt_subscription,
        "other-access-token-not-persisted",
        "account-b",
        .{ .endpoint_overrides = .{ .codex_base_url = "https://codex-a.example/api" } },
    );
    defer types.freeResponsesCompactionProviderBinding(alloc, codex_b);
    try std.testing.expect(codex_a.api_key_sha256 == null);
    try std.testing.expect(!eql(codex_a.view(), codex_b.view()));
}
