const std = @import("std");
const credentials = @import("credentials.zig");
const provider_oauth = @import("provider_oauth.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const login_flow = @import("login_flow.zig");
const model_provider = @import("../config/model_provider.zig");
const provider_catalog = @import("provider_catalog.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const SourceSet = std.EnumSet(credentials.Source);

pub const CredentialRefreshMode = enum {
    if_needed,
    force,
};

const credential_source_order = [_]credentials.Source{
    .openai_api_key,
    .chatgpt_subscription,
    .grok_subscription,
};

const SourceProbeFn = *const fn (?*anyopaque, Allocator, credentials.Source) anyerror!bool;
const CredentialLoaderFn = *const fn (?*anyopaque, Allocator, credentials.Source) anyerror!?credentials.Credential;
const max_manual_code_mask_glyphs: usize = 32;

const ManualCodeClearReason = enum {
    cancel,
    submitted,
    screen_replacement,
    runtime_deinit,
};

fn sourceLabelOrMissing(source: ?credentials.Source) []const u8 {
    return credentials.sourceLabel(source orelse return "missing");
}

pub const FailureReason = enum {
    credential_refresh_failed,
    http_unauthorized,
};

pub const FailureSnapshot = struct {
    source: credentials.Source,
    reason: FailureReason,
    http_status: ?std.http.Status = null,

    pub fn fromHttp(status: std.http.Status, source: ?credentials.Source) ?FailureSnapshot {
        if (status != .unauthorized) return null;
        return .{
            .source = source orelse return null,
            .reason = .http_unauthorized,
            .http_status = status,
        };
    }

    /// Returns owned, detail-free text. The caller owns the returned slice.
    pub fn renderText(self: FailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("{s} {s}", .{
            credentials.sourceLabel(self.source),
            switch (self.reason) {
                .credential_refresh_failed => "credential refresh failed",
                .http_unauthorized => "authentication failed",
            },
        });
        if (self.http_status) |status| {
            try out.writer.print(" · HTTP {d}", .{@intFromEnum(status)});
        }
        return try out.toOwnedSlice();
    }

    /// Returns owned JSON containing only the shared auth-failure facts.
    pub fn renderJson(self: FailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try self.writeJson(&out.writer);
        return try out.toOwnedSlice();
    }

    pub fn writeJson(self: FailureSnapshot, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"source\":");
        try std.json.Stringify.value(credentials.sourceLabel(self.source), .{}, writer);
        try writer.writeAll(",\"reason\":");
        try std.json.Stringify.value(@tagName(self.reason), .{}, writer);
        if (self.http_status) |status| {
            try writer.print(",\"http_status\":{d}", .{@intFromEnum(status)});
        }
        try writer.writeByte('}');
    }
};

/// Returns an owned token when the selected provider credential can refresh.
/// The caller must release it with `secret.zeroAndFree`.
pub fn refreshCredentialToken(
    transport: oauth_transport.Provider,
    alloc: Allocator,
    source: credentials.Source,
    mode: CredentialRefreshMode,
) !?[]u8 {
    return refreshCredentialTokenForAccount(transport, alloc, source, mode, null);
}

pub fn refreshCredentialTokenForAccount(
    transport: oauth_transport.Provider,
    alloc: Allocator,
    source: credentials.Source,
    mode: CredentialRefreshMode,
    expected_account_id: ?[]const u8,
) !?[]u8 {
    if (!credentials.sourceRefreshable(source)) return null;

    var credential = switch (source) {
        .chatgpt_subscription => switch (mode) {
            .if_needed => (try credentials.loadSource(alloc, transport, host.unavailable_secret_store, source)) orelse return null,
            .force => (try credentials.refreshChatGptCredential(alloc, transport)) orelse return null,
        },
        .grok_subscription => switch (mode) {
            .if_needed => (try credentials.loadSource(alloc, transport, host.unavailable_secret_store, source)) orelse return null,
            .force => (try credentials.refreshGrokCredential(alloc, transport)) orelse return null,
        },
        else => unreachable,
    };
    defer credential.deinit(alloc);
    if (expected_account_id) |expected| {
        const actual = credential.accountId() orelse return error.ChatGptAccountChanged;
        if (!std.mem.eql(u8, expected, actual)) return error.ChatGptAccountChanged;
    }

    const token = credential.token;
    credential.token = &.{};
    return token;
}

pub const AcquisitionAction = enum {
    chatgpt_login,
    grok_login,
    switch_credential,
    /// Clears a remembered choice so resolution returns to plain precedence.
    /// Without it the only way back would be editing settings.json by hand.
    automatic,
};

pub const PickerStage = enum {
    root,
    provider,
    sign_in,
    switch_credential,
};

pub const Choice = union(enum) {
    provider: model_provider.ProviderId,
    source: credentials.Source,
    action: AcquisitionAction,

    pub fn eql(self: Choice, other: Choice) bool {
        return switch (self) {
            .provider => |provider| switch (other) {
                .provider => |other_provider| provider == other_provider,
                .source, .action => false,
            },
            .source => |source| switch (other) {
                .source => |other_source| source == other_source,
                .provider, .action => false,
            },
            .action => |action| switch (other) {
                .provider, .source => false,
                .action => |other_action| action == other_action,
            },
        };
    }
};

pub const PickerView = struct {
    active: bool,
    available_sources: SourceSet,
    selected_choice: ?Choice,
    active_source: ?credentials.Source,
    active_provider: model_provider.ProviderId = .gateway,
    include_skip: bool,
    stage: PickerStage = .root,
    sign_in: login_flow.SignInSnapshot = .{},
    sign_in_source: credentials.Source = .chatgpt_subscription,
    sign_in_code_visible: bool = false,
    sign_in_code_mask_count: usize = 0,

    pub fn activeSourceLabel(self: PickerView) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn choiceCount(self: PickerView) usize {
        return switch (self.stage) {
            .root => if (self.include_skip)
                if (comptime host_target.is_wasm) 0 else 2
            else if (comptime host_target.is_wasm)
                1
            else
                3,
            .provider => if (comptime host_target.is_wasm) 2 else 3,
            .sign_in => 0,
            .switch_credential => gatewaySourceCount(self.available_sources) + 1,
        };
    }

    pub fn choiceAt(self: PickerView, index: usize) ?Choice {
        return switch (self.stage) {
            .root => if (self.include_skip)
                if (comptime host_target.is_wasm)
                    switch (index) {
                        else => null,
                    }
                else switch (index) {
                    0 => .{ .action = .chatgpt_login },
                    1 => .{ .action = .grok_login },
                    else => null,
                }
            else if (comptime host_target.is_wasm)
                switch (index) {
                    0 => .{ .action = .switch_credential },
                    else => null,
                }
            else switch (index) {
                0 => .{ .action = .chatgpt_login },
                1 => .{ .action = .grok_login },
                2 => .{ .action = .switch_credential },
                else => null,
            },
            .provider => switch (index) {
                0 => .{ .provider = .gateway },
                1 => .{ .provider = .codex },
                2 => if (comptime host_target.is_wasm) null else .{ .provider = .grok },
                else => null,
            },
            .sign_in => null,
            .switch_credential => if (index < gatewaySourceCount(self.available_sources))
                .{ .source = gatewaySourceAtIndex(self.available_sources, index).? }
            else if (index == gatewaySourceCount(self.available_sources))
                .{ .action = .automatic }
            else
                null,
        };
    }

    pub fn choiceIsSelected(self: PickerView, choice: Choice) bool {
        const selected = self.selected_choice orelse return false;
        return selected.eql(choice);
    }

    pub fn selectedIndex(self: PickerView) usize {
        const selected = self.selected_choice orelse return 0;
        var index: usize = 0;
        while (self.choiceAt(index)) |choice| : (index += 1) {
            if (choice.eql(selected)) return index;
        }
        return 0;
    }

    pub fn choiceLabel(_: PickerView, choice: Choice) []const u8 {
        return switch (choice) {
            .provider => |provider| provider_catalog.label(provider),
            .source => |source| credentials.sourceLabel(source),
            .action => |action| switch (action) {
                .chatgpt_login => "Sign in with Codex",
                .grok_login => "Sign in with Grok",
                .switch_credential => "Switch credential",
                .automatic => "Automatic",
            },
        };
    }

    pub fn choiceDescription(self: PickerView, choice: Choice) []const u8 {
        return switch (choice) {
            .provider => |provider| if (provider == self.active_provider) "current" else "available",
            .source => |source| if (self.active_source == source) "current" else "available",
            .action => |action| switch (action) {
                .chatgpt_login => if (self.available_sources.contains(.chatgpt_subscription)) "connected" else "",
                .grok_login => if (self.available_sources.contains(.grok_subscription)) "connected" else "",
                .switch_credential => "",
                .automatic => "use normal precedence",
            },
        };
    }

    pub fn choiceEnabled(_: PickerView, choice: Choice) bool {
        return switch (choice) {
            .action => |action| (action != .chatgpt_login or !host_target.is_wasm) and
                (action != .grok_login or !host_target.is_wasm),
            .provider, .source => true,
        };
    }
};

pub const MissingHelpSurface = enum {
    cli,
    interactive,
};

pub const StatusSnapshot = struct {
    active_source: ?credentials.Source = null,
    required_source: ?credentials.Source = null,
    gateway_connected: bool = false,
    chatgpt_connected: bool = false,
    grok_connected: bool = false,
    /// The active credential is past its refresh deadline. Distinct from `refreshable`,
    /// which answers whether this source type can refresh at all.
    expired: bool = false,

    pub fn deinit(self: *StatusSnapshot, _: Allocator) void {
        self.* = .{};
    }

    pub fn activeSourceLabel(self: StatusSnapshot) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn refreshable(self: StatusSnapshot) bool {
        const source = self.active_source orelse return false;
        return credentials.sourceRefreshable(source);
    }

    pub fn missingHelp(self: StatusSnapshot, surface: MissingHelpSurface) ?[]const u8 {
        if (self.active_source != null) return null;
        if (self.required_source == .chatgpt_subscription) {
            return switch (surface) {
                .cli => credentials.missing_chatgpt_credential_message,
                .interactive => credentials.missing_chatgpt_interactive_credential_message,
            };
        }
        if (self.required_source == .grok_subscription) {
            return switch (surface) {
                .cli => credentials.missing_grok_credential_message,
                .interactive => credentials.missing_grok_interactive_credential_message,
            };
        }
        return switch (surface) {
            .cli => credentials.missing_credential_message,
            .interactive => credentials.missing_interactive_credential_message,
        };
    }

    /// Returns owned doctor status text containing no credential bytes.
    pub fn formatDoctorDetail(self: StatusSnapshot, alloc: Allocator) ![]u8 {
        if (self.missingHelp(.cli)) |help| return alloc.dupe(u8, help);

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("{s} is configured", .{self.activeSourceLabel()});
        if (self.expired) try out.writer.writeAll("; session expired");
        try out.writer.print("; refreshable={s}", .{if (self.refreshable()) "true" else "false"});
        return try out.toOwnedSlice();
    }
};

pub fn loadStatusSnapshot(
    alloc: Allocator,
    secret_store: host.SecretStore,
    preferred: ?credentials.Source,
) !StatusSnapshot {
    return loadStatusSnapshotForProvider(alloc, secret_store, null, preferred);
}

pub fn loadStatusSnapshotForProvider(
    alloc: Allocator,
    secret_store: host.SecretStore,
    provider: ?model_provider.ProviderId,
    preferred: ?credentials.Source,
) !StatusSnapshot {
    const chatgpt_connected = credentials.sourceExists(
        alloc,
        secret_store,
        .chatgpt_subscription,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
    const grok_connected = credentials.sourceExists(
        alloc,
        secret_store,
        .grok_subscription,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
    // Resolves in `.stored` mode: a diagnostic must not refresh, because refreshing
    // rewrites the session file and performs network I/O. It reports the expired state
    // instead of repairing it.
    const resolution = (if (provider) |selected_provider|
        credentials.resolveForProvider(
            alloc,
            oauth_transport.unavailable_provider,
            secret_store,
            .stored,
            selected_provider,
            preferred,
        )
    else
        credentials.resolvePreferring(
            alloc,
            oauth_transport.unavailable_provider,
            secret_store,
            .stored,
            preferred,
        )) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // The store could not be interrogated, so its contents are unknown rather than absent.
        else => blk: {
            debug_trace.logf("auth", "status snapshot failed step=resolve err={s}", .{@errorName(err)});
            break :blk credentials.Resolution{};
        },
    };
    const resolved_source = if (resolution.credential) |credential| credential.source else null;
    var gateway_connected = resolved_source == .openai_api_key;
    const gateway_probe_required = provider == .codex or provider == .grok or
        resolved_source == .chatgpt_subscription or resolved_source == .grok_subscription;
    if (gateway_probe_required) {
        gateway_connected = credentials.sourceExists(alloc, secret_store, .openai_api_key) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => false,
        };
    }
    if (resolution.credential) |loaded| {
        var credential = loaded;
        defer credential.deinit(alloc);
        const expired = credential.needsRefreshAt(io_mod.milliTimestamp());
        return .{
            .active_source = credential.source,
            .gateway_connected = gateway_connected,
            .chatgpt_connected = chatgpt_connected,
            .grok_connected = grok_connected,
            .expired = expired,
        };
    }
    return .{
        .required_source = if (provider == .codex)
            .chatgpt_subscription
        else if (provider == .grok)
            .grok_subscription
        else
            null,
        .gateway_connected = gateway_connected,
        .chatgpt_connected = chatgpt_connected,
        .grok_connected = grok_connected,
    };
}

pub const View = struct {
    active_source: ?credentials.Source,
    available_inactive_sources: SourceSet,
    refreshable: bool,
    onboarding_skipped: bool,

    pub fn activeSourceLabel(self: View) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }
};

pub const GatewayCredential = struct {
    api_key: []const u8,
    source: credentials.Source,
};

pub const Runtime = struct {
    const Self = @This();

    oauth_transport: oauth_transport.Provider = oauth_transport.unavailable_provider,
    secret_store: host.SecretStore = host.unavailable_secret_store,
    selected_credential: ?credentials.Credential = null,
    credential_refresh_failure_source: ?credentials.Source = null,
    source_inventory: SourceSet = .empty,
    onboarding_skipped: bool = false,
    picker_active: bool = false,
    picker_selection: ?Choice = null,
    picker_include_skip: bool = false,
    picker_stage: PickerStage = .root,
    provider_picker_active: model_provider.ProviderId = .gateway,
    sign_in_flow: login_flow.SignInRuntime = .{},
    sign_in_source: credentials.Source = .chatgpt_subscription,
    sign_in_returns_to_root: bool = false,
    sign_in_code_visible: bool = false,
    sign_in_code_input: std.ArrayList(u8) = .empty,

    pub fn init(
        transport: oauth_transport.Provider,
        secret_store: host.SecretStore,
    ) Self {
        return .{
            .oauth_transport = transport,
            .secret_store = secret_store,
        };
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        self.sign_in_flow.deinit(alloc);
        self.clearSignInCodeInput(alloc, .runtime_deinit);
        if (self.selected_credential) |*credential| credential.deinit(alloc);
        self.* = .{};
    }

    /// Borrows the current credential until this runtime replaces or releases it.
    pub fn gatewayCredential(self: *const Self) ?GatewayCredential {
        return self.gatewayCredentialAt(io_mod.milliTimestamp());
    }

    fn gatewayCredentialAt(self: *const Self, now_ms: i64) ?GatewayCredential {
        const credential = self.selected_credential orelse return null;
        if (credential.needsRefreshAt(now_ms)) return null;
        return .{
            .api_key = credential.token,
            .source = credential.source,
        };
    }

    pub fn apiKey(self: *const Self) ?[]const u8 {
        const credential = self.gatewayCredential() orelse return null;
        return credential.api_key;
    }

    pub fn oauthTransport(self: *const Self) oauth_transport.Provider {
        return self.oauth_transport;
    }

    pub fn secretStore(self: *const Self) host.SecretStore {
        return self.secret_store;
    }

    pub fn modelCatalogAccess(self: *const Self) credentials.CatalogAccess {
        if (self.credential_refresh_failure_source) |source| {
            return credentials.catalogAccessAfterRefreshFailure(source);
        }
        return credentials.catalogAccessAt(self.selected_credential, io_mod.milliTimestamp());
    }

    pub fn recordCredentialRefreshFailure(self: *Self, source: credentials.Source) void {
        std.debug.assert(self.credentialSource() == source);
        self.credential_refresh_failure_source = source;
    }

    pub fn credentialSource(self: *const Self) ?credentials.Source {
        const credential = self.selected_credential orelse return null;
        return credential.source;
    }

    pub fn accountId(self: *const Self) ?[]const u8 {
        const credential = self.selected_credential orelse return null;
        return credential.accountId();
    }

    pub fn credentialNeedsRefresh(self: *const Self) bool {
        return self.credentialNeedsRefreshAt(io_mod.milliTimestamp());
    }

    fn credentialNeedsRefreshAt(self: *const Self, now_ms: i64) bool {
        const credential = self.selected_credential orelse return false;
        return credential.needsRefreshAt(now_ms);
    }

    pub fn statusSnapshot(self: *const Self) StatusSnapshot {
        return self.statusSnapshotAt(io_mod.milliTimestamp());
    }

    fn statusSnapshotAt(self: *const Self, now_ms: i64) StatusSnapshot {
        const gateway_connected = self.source_inventory.contains(.openai_api_key);
        const chatgpt_connected = self.source_inventory.contains(.chatgpt_subscription);
        const grok_connected = self.source_inventory.contains(.grok_subscription);
        const credential = self.selected_credential orelse return .{
            .gateway_connected = gateway_connected,
            .chatgpt_connected = chatgpt_connected,
            .grok_connected = grok_connected,
        };
        return .{
            .active_source = credential.source,
            .gateway_connected = gateway_connected,
            .chatgpt_connected = chatgpt_connected,
            .grok_connected = grok_connected,
            .expired = credential.needsRefreshAt(now_ms),
        };
    }

    pub fn view(self: *const Self) View {
        const active_source = self.credentialSource();
        var available_inactive_sources = self.source_inventory;
        if (active_source) |source| available_inactive_sources.remove(source);

        return .{
            .active_source = active_source,
            .available_inactive_sources = available_inactive_sources,
            .refreshable = if (active_source) |source| credentials.sourceRefreshable(source) else false,
            .onboarding_skipped = self.onboarding_skipped,
        };
    }

    pub fn recordStartupStatus(
        self: *Self,
        onboarding_skipped: bool,
    ) void {
        self.onboarding_skipped = onboarding_skipped;
    }

    pub fn skipOnboarding(self: *Self) void {
        self.onboarding_skipped = true;
    }

    pub fn refreshSourceInventory(self: *Self, alloc: Allocator) !void {
        try self.refreshSourceInventoryWithProbe(alloc, self, probeCredentialSource);
    }

    pub fn refreshChatGptSourceInventory(self: *Self, alloc: Allocator) !void {
        if (try credentials.sourceExists(alloc, self.secret_store, .chatgpt_subscription)) {
            self.source_inventory.insert(.chatgpt_subscription);
        } else if (self.credentialSource() != .chatgpt_subscription) {
            self.source_inventory.remove(.chatgpt_subscription);
        }
    }

    pub fn refreshGrokSourceInventory(self: *Self, alloc: Allocator) !void {
        if (try credentials.sourceExists(alloc, self.secret_store, .grok_subscription)) {
            self.source_inventory.insert(.grok_subscription);
        } else if (self.credentialSource() != .grok_subscription) {
            self.source_inventory.remove(.grok_subscription);
        }
    }

    fn refreshSourceInventoryWithProbe(
        self: *Self,
        alloc: Allocator,
        ctx: ?*anyopaque,
        probe: SourceProbeFn,
    ) !void {
        var detected: SourceSet = .empty;
        for (credential_source_order) |source| {
            if (try probe(ctx, alloc, source)) detected.insert(source);
        }
        if (self.credentialSource()) |source| detected.insert(source);
        self.source_inventory = detected;
    }

    pub fn openPicker(self: *Self, alloc: Allocator) void {
        self.openPickerWithSkip(alloc, false);
    }

    pub fn openPickerForProvider(
        self: *Self,
        alloc: Allocator,
        active_provider: model_provider.ProviderId,
    ) void {
        self.provider_picker_active = active_provider;
        self.openPicker(alloc);
    }

    pub fn openOnboardingPicker(self: *Self, alloc: Allocator) void {
        self.openPickerWithSkip(alloc, true);
    }

    fn openPickerWithSkip(self: *Self, alloc: Allocator, include_skip: bool) void {
        self.exitSignInStage(alloc);
        self.picker_active = true;
        self.picker_include_skip = include_skip;
        self.picker_stage = .root;
        self.picker_selection = self.pickerView().choiceAt(0);
    }

    pub fn pickerView(self: *const Self) PickerView {
        return .{
            .active = self.picker_active,
            .available_sources = self.source_inventory,
            .selected_choice = self.picker_selection,
            .active_source = self.credentialSource(),
            .active_provider = self.provider_picker_active,
            .include_skip = self.picker_include_skip,
            .stage = self.picker_stage,
            .sign_in = self.sign_in_flow.snapshot(),
            .sign_in_source = self.sign_in_source,
            .sign_in_code_visible = self.sign_in_code_visible,
            .sign_in_code_mask_count = @min(
                self.sign_in_code_input.items.len,
                max_manual_code_mask_glyphs,
            ),
        };
    }

    pub fn movePicker(self: *Self, delta: i32) bool {
        if (!self.picker_active or delta == 0) return false;
        const picker = self.pickerView();
        const choice_count = picker.choiceCount();
        if (choice_count < 2) return false;
        const selected_index = picker.selectedIndex();
        const next_index = if (delta < 0)
            if (selected_index == 0) choice_count - 1 else selected_index - 1
        else if (selected_index + 1 == choice_count)
            0
        else
            selected_index + 1;
        self.picker_selection = picker.choiceAt(next_index);
        return true;
    }

    pub fn openProviderPicker(
        self: *Self,
        alloc: Allocator,
        active_provider: model_provider.ProviderId,
    ) void {
        self.exitSignInStage(alloc);
        self.picker_active = true;
        self.picker_include_skip = false;
        self.picker_stage = .provider;
        self.provider_picker_active = active_provider;
        self.picker_selection = .{ .provider = active_provider };
    }

    pub fn openSwitchCredentialPicker(self: *Self, alloc: Allocator) void {
        self.exitSignInStage(alloc);
        self.picker_stage = .switch_credential;
        const active_source = self.credentialSource();
        self.picker_selection = if (active_source) |source|
            if (source != .chatgpt_subscription and source != .grok_subscription and self.source_inventory.contains(source))
                .{ .source = source }
            else
                self.pickerView().choiceAt(0)
        else
            self.pickerView().choiceAt(0);
    }

    pub fn openChatGptSignInPickerFromRoot(self: *Self, alloc: Allocator) !bool {
        if (comptime host_target.is_wasm) return error.ChatGptOAuthUnavailable;
        return self.openSignInPickerWithParent(alloc, true, .chatgpt_subscription);
    }

    pub fn openChatGptSignInPickerForProviderSwitch(self: *Self, alloc: Allocator) !bool {
        if (comptime host_target.is_wasm) return error.ChatGptOAuthUnavailable;
        return self.openSignInPickerWithParent(alloc, false, .chatgpt_subscription);
    }

    pub fn openGrokSignInPickerFromRoot(self: *Self, alloc: Allocator) !bool {
        if (comptime host_target.is_wasm) return error.GrokOAuthUnavailable;
        return self.openSignInPickerWithParent(alloc, true, .grok_subscription);
    }

    pub fn openGrokSignInPickerForProviderSwitch(self: *Self, alloc: Allocator) !bool {
        if (comptime host_target.is_wasm) return error.GrokOAuthUnavailable;
        return self.openSignInPickerWithParent(alloc, false, .grok_subscription);
    }

    fn openSignInPickerWithParent(
        self: *Self,
        alloc: Allocator,
        returns_to_root: bool,
        source: credentials.Source,
    ) !bool {
        self.exitSignInStage(alloc);
        const started = switch (source) {
            .chatgpt_subscription => try provider_oauth.startSignIn(.codex, &self.sign_in_flow, alloc, self.oauth_transport),
            .grok_subscription => try provider_oauth.startSignIn(.grok, &self.sign_in_flow, alloc, self.oauth_transport),
            else => return error.InvalidSignInSource,
        };
        if (!started) return false;
        self.picker_active = true;
        self.picker_stage = .sign_in;
        self.picker_selection = null;
        self.sign_in_source = source;
        self.sign_in_returns_to_root = returns_to_root;
        self.sign_in_code_visible = false;
        return true;
    }

    pub fn signInEntryActive(self: *const Self) bool {
        return self.picker_active and self.picker_stage == .sign_in;
    }

    pub fn signInCodeEntryActive(self: *const Self) bool {
        return self.signInEntryActive() and
            self.sign_in_flow.snapshot().accepts_manual_code and
            self.sign_in_code_visible;
    }

    pub fn toggleSignInCodeEntry(self: *Self) bool {
        if (!self.signInEntryActive() or
            !self.sign_in_flow.snapshot().accepts_manual_code)
        {
            return false;
        }
        self.sign_in_code_visible = !self.sign_in_code_visible;
        return true;
    }

    pub fn signInReturnsToRoot(self: *const Self) bool {
        return self.sign_in_returns_to_root;
    }

    pub fn signInBrowserUrlAlloc(self: *Self, alloc: Allocator) !?[]u8 {
        if (!self.signInEntryActive()) return null;
        return self.sign_in_flow.browserUrlAlloc(alloc);
    }

    pub fn pollSignInTransition(self: *Self, alloc: Allocator) login_flow.SignInTransition {
        return self.sign_in_flow.pollTransition(alloc);
    }

    pub fn pulseSignIn(self: *Self, alloc: Allocator) void {
        self.sign_in_flow.pulse(alloc);
    }

    pub fn appendSignInCodeByte(self: *Self, alloc: Allocator, byte: u8) !bool {
        if (!self.signInCodeEntryActive()) return false;
        if (byte <= 0x20 or byte > 0x7e) return true;
        if (self.sign_in_code_input.items.len >= login_flow.max_manual_code_bytes) return true;
        try self.sign_in_code_input.ensureTotalCapacityPrecise(
            alloc,
            login_flow.max_manual_code_bytes,
        );
        self.sign_in_code_input.appendAssumeCapacity(byte);
        return true;
    }

    pub fn deleteSignInCodeByte(self: *Self) bool {
        if (!self.signInCodeEntryActive()) return false;
        if (self.sign_in_code_input.items.len > 0) {
            self.sign_in_code_input.items.len -= 1;
            self.sign_in_code_input.allocatedSlice()[self.sign_in_code_input.items.len] = 0;
        }
        return true;
    }

    pub fn replaceSignInCodeInput(
        self: *Self,
        alloc: Allocator,
        input: []const u8,
    ) !bool {
        if (!self.signInCodeEntryActive()) return false;
        const code = std.mem.trim(u8, input, " \t\r\n");
        if (code.len == 0 or code.len > login_flow.max_manual_code_bytes) return false;
        for (code) |byte| {
            if (byte < 0x21 or byte > 0x7e) return false;
        }
        if (self.sign_in_code_input.capacity > 0) {
            self.sign_in_code_input.clearRetainingCapacity();
            @memset(self.sign_in_code_input.allocatedSlice(), 0);
        }
        try self.sign_in_code_input.ensureTotalCapacityPrecise(
            alloc,
            login_flow.max_manual_code_bytes,
        );
        self.sign_in_code_input.appendSliceAssumeCapacity(code);
        return true;
    }

    pub fn submitSignInCode(self: *Self, alloc: Allocator) !bool {
        if (!self.signInCodeEntryActive() or self.sign_in_code_input.items.len == 0) {
            return false;
        }
        if (!try self.sign_in_flow.submitManualCode(
            alloc,
            self.sign_in_code_input.items,
        )) return false;
        self.clearSignInCodeInput(alloc, .submitted);
        return true;
    }

    pub fn popPickerStage(self: *Self, alloc: Allocator) bool {
        if (!self.picker_active) return false;
        const stage = self.picker_stage;
        if (stage == .root) {
            self.closePicker(alloc);
            return true;
        }
        if (stage == .provider) {
            self.closePicker(alloc);
            return true;
        }

        if (stage == .sign_in) {
            const returns_to_root = self.sign_in_returns_to_root;
            _ = self.sign_in_flow.cancel(alloc);
            self.clearSignInCodeInput(alloc, .cancel);
            self.sign_in_returns_to_root = false;
            if (!returns_to_root) {
                self.picker_active = false;
                self.picker_stage = .root;
                self.picker_selection = null;
                return true;
            }
        }

        self.picker_stage = .root;
        self.picker_selection = .{ .action = switch (stage) {
            .root => unreachable,
            .provider => unreachable,
            .sign_in => if (self.sign_in_source == .chatgpt_subscription)
                .chatgpt_login
            else
                .grok_login,
            .switch_credential => .switch_credential,
        } };
        return true;
    }

    pub fn closePicker(self: *Self, alloc: Allocator) void {
        self.exitSignInStage(alloc);
        self.picker_active = false;
        self.picker_stage = .root;
    }

    pub fn takePickerChoice(self: *Self, alloc: Allocator) ?Choice {
        if (!self.picker_active) return null;
        if (self.picker_stage == .sign_in) return null;
        const choice = self.picker_selection;
        const selected = choice orelse return null;
        if (!self.pickerView().choiceEnabled(selected)) return null;

        switch (self.picker_stage) {
            .sign_in => unreachable,
            .provider => switch (selected) {
                .provider => self.closePicker(alloc),
                .source, .action => unreachable,
            },
            .root => switch (selected) {
                .provider => unreachable,
                .source => self.closePicker(alloc),
                .action => |action| switch (action) {
                    .switch_credential => {
                        self.openSwitchCredentialPicker(alloc);
                        return null;
                    },
                    // Only reachable from the switch screen, never the root.
                    .automatic => unreachable,
                    .chatgpt_login, .grok_login => self.closePicker(alloc),
                },
            },
            .switch_credential => switch (selected) {
                .source => self.closePicker(alloc),
                // Automatic is the only action this stage offers; the app
                // handler clears the stored choice and closes the picker.
                .action => |action| std.debug.assert(action == .automatic),
                .provider => unreachable,
            },
        }
        return choice;
    }

    fn exitSignInStage(self: *Self, alloc: Allocator) void {
        if (self.picker_stage != .sign_in) return;
        _ = self.sign_in_flow.cancel(alloc);
        self.clearSignInCodeInput(alloc, .screen_replacement);
        self.sign_in_returns_to_root = false;
    }

    fn clearSignInCodeInput(
        self: *Self,
        alloc: Allocator,
        reason: ManualCodeClearReason,
    ) void {
        const byte_count = self.sign_in_code_input.items.len;
        self.sign_in_code_visible = false;
        if (self.sign_in_code_input.capacity > 0) {
            secret.zeroAndFree(alloc, self.sign_in_code_input.allocatedSlice());
            self.sign_in_code_input = .empty;
        }
        if (byte_count > 0) {
            debug_trace.logf(
                "auth",
                "authorization code entry cleared reason={s} bytes={d}",
                .{ @tagName(reason), byte_count },
            );
        }
    }

    /// Moves the credential into this session and returns whether its source,
    /// token, account identity, or readiness changed.
    pub fn adoptCredential(self: *Self, alloc: Allocator, credential: *credentials.Credential) bool {
        const changed = if (self.selected_credential) |selected|
            selected.source != credential.source or
                !std.mem.eql(u8, selected.token, credential.token) or
                !optionalBytesEqual(selected.accountId(), credential.accountId()) or
                selected.refresh_after_ms != credential.refresh_after_ms
        else
            true;
        const source = credential.source;
        if (self.selected_credential) |*selected| selected.deinit(alloc);

        self.selected_credential = credential.*;
        self.credential_refresh_failure_source = null;
        credential.token = &.{};
        credential.account_id = null;
        self.source_inventory.insert(source);
        return changed;
    }

    fn selectSourceWithLoader(
        self: *Self,
        alloc: Allocator,
        source: credentials.Source,
        ctx: ?*anyopaque,
        loader: CredentialLoaderFn,
    ) !?bool {
        var credential = (try loader(ctx, alloc, source)) orelse return null;
        defer credential.deinit(alloc);
        if (credential.source != source) return error.CredentialSourceMismatch;
        return self.adoptCredential(alloc, &credential);
    }

    pub fn selectSource(self: *Self, alloc: Allocator, source: credentials.Source) !?bool {
        return self.selectSourceWithLoader(alloc, source, self, loadRuntimeCredentialSource);
    }

    pub fn selectForProvider(
        self: *Self,
        alloc: Allocator,
        provider: model_provider.ProviderId,
    ) !?bool {
        return switch (provider) {
            .codex => if (self.credentialSource() == .chatgpt_subscription)
                false
            else
                self.selectSourceWithLoader(
                    alloc,
                    .chatgpt_subscription,
                    self,
                    loadRuntimeCredentialSource,
                ),
            .grok => if (self.credentialSource() == .grok_subscription)
                false
            else
                self.selectSourceWithLoader(
                    alloc,
                    .grok_subscription,
                    self,
                    loadRuntimeCredentialSource,
                ),
            .gateway => if (self.credentialSource() != .chatgpt_subscription and self.credentialSource() != .grok_subscription)
                false
            else
                @as(?bool, try self.reselectByPrecedenceWithDeps(
                    alloc,
                    self,
                    probeCredentialSource,
                    loadRuntimeCredentialSource,
                )),
        };
    }

    pub fn refreshCredentialIfNeeded(self: *Self, alloc: Allocator) !bool {
        const source = self.credentialSource() orelse return false;
        if (!credentials.sourceRefreshable(source)) return false;

        const loaded = (try credentials.loadSource(alloc, self.oauth_transport, self.secret_store, source)) orelse {
            if (self.credentialNeedsRefresh()) return error.CredentialRefreshUnavailable;
            return false;
        };
        var credential = loaded;
        defer credential.deinit(alloc);
        return self.adoptCredential(alloc, &credential);
    }

    /// Drops the current selection and re-runs precedence after the user clears
    /// a remembered credential source.
    pub fn reselectByPrecedence(self: *Self, alloc: Allocator) !bool {
        return self.reselectByPrecedenceWithDeps(alloc, self, probeCredentialSource, loadRuntimeCredentialSource);
    }

    fn reselectByPrecedenceWithDeps(
        self: *Self,
        alloc: Allocator,
        ctx: ?*anyopaque,
        probe: SourceProbeFn,
        loader: CredentialLoaderFn,
    ) !bool {
        const previous = self.credentialSource();
        if (self.selected_credential) |*credential| credential.deinit(alloc);
        self.selected_credential = null;
        self.credential_refresh_failure_source = null;

        try self.refreshSourceInventoryWithProbe(alloc, ctx, probe);
        for (credential_source_order) |source| {
            if (source == .chatgpt_subscription or source == .grok_subscription) continue;
            if (!self.source_inventory.contains(source)) continue;
            if (try self.selectSourceWithLoader(alloc, source, ctx, loader) != null) {
                return self.credentialSource() != previous;
            }
            self.source_inventory.remove(source);
        }
        self.onboarding_skipped = false;
        return previous != null;
    }

    pub fn reconcileAfterChatGptLogout(self: *Self, alloc: Allocator) !bool {
        const was_available = self.source_inventory.contains(.chatgpt_subscription);
        const was_active = self.credentialSource() == .chatgpt_subscription;
        if (was_active) {
            if (self.selected_credential) |*credential| credential.deinit(alloc);
            self.selected_credential = null;
            self.credential_refresh_failure_source = null;
        }
        try self.refreshSourceInventory(alloc);
        return was_active or was_available;
    }

    pub fn reconcileAfterGrokLogout(self: *Self, alloc: Allocator) !bool {
        const was_available = self.source_inventory.contains(.grok_subscription);
        const was_active = self.credentialSource() == .grok_subscription;
        if (was_active) {
            if (self.selected_credential) |*credential| credential.deinit(alloc);
            self.selected_credential = null;
            self.credential_refresh_failure_source = null;
        }
        try self.refreshSourceInventory(alloc);
        return was_active or was_available;
    }
};

fn probeCredentialSource(raw_context: ?*anyopaque, alloc: Allocator, source: credentials.Source) !bool {
    const self: *Runtime = @ptrCast(@alignCast(raw_context.?));
    return credentials.sourceExists(alloc, self.secret_store, source);
}

fn loadCredentialSource(_: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
    return credentials.loadSource(
        alloc,
        oauth_transport.unavailable_provider,
        host.unavailable_secret_store,
        source,
    );
}

fn loadRuntimeCredentialSource(raw: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    return credentials.loadSource(alloc, self.oauth_transport, self.secret_store, source);
}

fn gatewaySourceCount(sources: SourceSet) usize {
    var count: usize = 0;
    for (credential_source_order) |source| {
        if (source == .chatgpt_subscription or source == .grok_subscription or !sources.contains(source)) continue;
        count += 1;
    }
    return count;
}

fn gatewaySourceAtIndex(sources: SourceSet, wanted_index: usize) ?credentials.Source {
    var index: usize = 0;
    for (credential_source_order) |source| {
        if (source == .chatgpt_subscription or source == .grok_subscription or !sources.contains(source)) continue;
        if (index == wanted_index) return source;
        index += 1;
    }
    return null;
}

fn optionalBytesEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn makeTestCredential(
    alloc: Allocator,
    token: []const u8,
    source: credentials.Source,
) !credentials.Credential {
    const owned_token = try alloc.dupe(u8, token);
    errdefer secret.zeroAndFree(alloc, owned_token);
    return .{
        .token = owned_token,
        .source = source,
    };
}

test "auth runtime token refresher ignores non-refreshable credential sources" {
    for ([_]credentials.Source{.openai_api_key}) |source| {
        try std.testing.expect((try refreshCredentialToken(
            oauth_transport.unavailable_provider,
            std.testing.allocator,
            source,
            .force,
        )) == null);
    }
}

test "auth failure snapshot names every selected source without exposing styling" {
    const sources = [_]credentials.Source{
        .openai_api_key,
        .chatgpt_subscription,
        .grok_subscription,
    };
    for (sources) |source| {
        const snapshot = FailureSnapshot.fromHttp(.unauthorized, source).?;
        try std.testing.expectEqual(FailureReason.http_unauthorized, snapshot.reason);
        try std.testing.expectEqual(std.http.Status.unauthorized, snapshot.http_status.?);

        const message = try snapshot.renderText(std.testing.allocator);
        defer std.testing.allocator.free(message);
        try std.testing.expect(std.mem.find(u8, message, credentials.sourceLabel(source)) != null);
        try std.testing.expect(std.mem.find(u8, message, "HTTP 401") != null);
        try std.testing.expect(std.mem.find(u8, message, "\x1b") == null);

        const json = try snapshot.renderJson(std.testing.allocator);
        defer std.testing.allocator.free(json);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(credentials.sourceLabel(source), parsed.value.object.get("source").?.string);
        try std.testing.expectEqualStrings("http_unauthorized", parsed.value.object.get("reason").?.string);
        try std.testing.expectEqual(@as(i64, 401), parsed.value.object.get("http_status").?.integer);
        try std.testing.expect(std.mem.find(u8, json, "\x1b") == null);
    }
}

test "auth failure snapshot keeps refresh failures distinct from HTTP rejection" {
    const snapshot = FailureSnapshot{
        .source = .chatgpt_subscription,
        .reason = .credential_refresh_failed,
    };

    const message = try snapshot.renderText(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("Codex subscription credential refresh failed", message);

    const json = try snapshot.renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Codex subscription", parsed.value.object.get("source").?.string);
    try std.testing.expectEqualStrings("credential_refresh_failed", parsed.value.object.get("reason").?.string);
    try std.testing.expect(parsed.value.object.get("http_status") == null);

    try std.testing.expect(FailureSnapshot.fromHttp(.forbidden, .chatgpt_subscription) == null);
    try std.testing.expect(FailureSnapshot.fromHttp(.unauthorized, null) == null);
}

test "catalog access records a refresh failure until another credential is adopted" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    var login = try makeTestCredential(alloc, "login-token", .chatgpt_subscription);
    defer login.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &login);
    runtime.recordCredentialRefreshFailure(.chatgpt_subscription);

    const failed = runtime.modelCatalogAccess();
    try std.testing.expectEqual(credentials.CatalogPublicOnlyReason.credential_refresh_failed, failed.publicOnlyReason().?);

    var api_key = try makeTestCredential(alloc, "api-key", .openai_api_key);
    defer api_key.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &api_key);

    const authenticated = runtime.modelCatalogAccess();
    try std.testing.expectEqualStrings("api-key", authenticated.authorizationCredential().?);
}

test "auth runtime adopts credential ownership" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    var credential = try makeTestCredential(alloc, "token-a", .openai_api_key);
    defer credential.deinit(alloc);

    try std.testing.expect(runtime.adoptCredential(alloc, &credential));
    try std.testing.expectEqualStrings("token-a", runtime.apiKey().?);
    try std.testing.expectEqual(credentials.Source.openai_api_key, runtime.credentialSource().?);
    try std.testing.expectEqual(@as(usize, 0), credential.token.len);

    var replacement = try makeTestCredential(alloc, "token-b", .openai_api_key);
    defer replacement.deinit(alloc);

    try std.testing.expect(runtime.adoptCredential(alloc, &replacement));
    try std.testing.expectEqual(credentials.Source.openai_api_key, runtime.credentialSource().?);

    var unchanged = try makeTestCredential(alloc, "token-b", .openai_api_key);
    defer unchanged.deinit(alloc);
    try std.testing.expect(!runtime.adoptCredential(alloc, &unchanged));
}

test "auth runtime exposes one current credential for prompt admission" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    try std.testing.expect(runtime.gatewayCredential() == null);

    var credential = try makeTestCredential(alloc, "token-a", .openai_api_key);
    defer credential.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &credential);

    const gateway_credential = runtime.gatewayCredential().?;
    try std.testing.expectEqualStrings("token-a", gateway_credential.api_key);
    try std.testing.expectEqual(credentials.Source.openai_api_key, gateway_credential.source);
}

test "auth runtime withholds a refreshable credential across its expiry boundary" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    var credential = try makeTestCredential(alloc, "stale-token", .chatgpt_subscription);
    defer credential.deinit(alloc);
    credential.refresh_after_ms = 40_000;
    _ = runtime.adoptCredential(alloc, &credential);

    try std.testing.expect(!runtime.credentialNeedsRefreshAt(39_999));
    try std.testing.expect(runtime.gatewayCredentialAt(39_999) != null);
    try std.testing.expect(runtime.credentialNeedsRefreshAt(40_000));
    try std.testing.expect(runtime.gatewayCredentialAt(40_000) == null);
    try std.testing.expectEqual(credentials.Source.chatgpt_subscription, runtime.credentialSource().?);
    try std.testing.expectEqual(credentials.Source.chatgpt_subscription, runtime.statusSnapshotAt(40_000).active_source.?);

    // The source is still reported; only its freshness changes across the boundary.
    try std.testing.expect(!runtime.statusSnapshotAt(39_999).expired);
    try std.testing.expect(runtime.statusSnapshotAt(40_000).expired);
    try std.testing.expect(runtime.statusSnapshotAt(40_000).refreshable());

    var refreshed = try makeTestCredential(alloc, "stale-token", .chatgpt_subscription);
    defer refreshed.deinit(alloc);
    refreshed.refresh_after_ms = 140_000;
    try std.testing.expect(runtime.adoptCredential(alloc, &refreshed));
    try std.testing.expect(!runtime.credentialNeedsRefreshAt(40_000));
    try std.testing.expectEqualStrings("stale-token", runtime.gatewayCredentialAt(40_000).?.api_key);
}

test "auth runtime view preserves missing and loaded states" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    runtime.recordStartupStatus(true);
    const missing = runtime.view();
    try std.testing.expect(missing.active_source == null);
    try std.testing.expect(!missing.refreshable);
    try std.testing.expect(missing.onboarding_skipped);
    try std.testing.expectEqual(@as(usize, 0), missing.available_inactive_sources.count());

    runtime.source_inventory.insert(.chatgpt_subscription);
    var credential = try makeTestCredential(alloc, "token", .chatgpt_subscription);
    defer credential.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &credential);
    const loaded = runtime.view();
    try std.testing.expectEqual(credentials.Source.chatgpt_subscription, loaded.active_source.?);
    try std.testing.expect(loaded.refreshable);
    try std.testing.expect(!loaded.available_inactive_sources.contains(.chatgpt_subscription));
}

test "auth status snapshot labels every credential source without exposing tokens" {
    const alloc = std.testing.allocator;
    const sources = [_]credentials.Source{
        .openai_api_key,
        .chatgpt_subscription,
        .grok_subscription,
    };

    for (sources) |source| {
        var runtime: Runtime = .{};
        defer runtime.deinit(alloc);
        var credential = try makeTestCredential(alloc, "credential-secret", source);
        defer credential.deinit(alloc);
        _ = runtime.adoptCredential(alloc, &credential);

        const snapshot = runtime.statusSnapshot();
        try std.testing.expectEqualStrings(credentials.sourceLabel(source), snapshot.activeSourceLabel());
        try std.testing.expectEqual(credentials.sourceRefreshable(source), snapshot.refreshable());
        const detail = try snapshot.formatDoctorDetail(alloc);
        defer alloc.free(detail);
        try std.testing.expect(std.mem.find(u8, detail, snapshot.activeSourceLabel()) != null);
        try std.testing.expect(std.mem.find(u8, detail, "credential-secret") == null);
    }
}

test "auth status snapshot preserves surface-specific missing help" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    const missing = runtime.statusSnapshot();
    try std.testing.expectEqualStrings(credentials.missing_credential_message, missing.missingHelp(.cli).?);
    try std.testing.expectEqualStrings(credentials.missing_interactive_credential_message, missing.missingHelp(.interactive).?);

    var credential = try makeTestCredential(alloc, "token", .openai_api_key);
    defer credential.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &credential);

    const selected = runtime.statusSnapshot();
    try std.testing.expect(selected.missingHelp(.cli) == null);
}

test "auth status snapshot reports an expired subscription without claiming it is unrefreshable" {
    const alloc = std.testing.allocator;

    const fresh = StatusSnapshot{ .active_source = .chatgpt_subscription };
    const fresh_detail = try fresh.formatDoctorDetail(alloc);
    defer alloc.free(fresh_detail);
    try std.testing.expectEqualStrings(
        "Codex subscription is configured; refreshable=true",
        fresh_detail,
    );

    const stale = StatusSnapshot{ .active_source = .chatgpt_subscription, .expired = true };
    const stale_detail = try stale.formatDoctorDetail(alloc);
    defer alloc.free(stale_detail);
    try std.testing.expectEqualStrings(
        "Codex subscription is configured; session expired; refreshable=true",
        stale_detail,
    );

    // The expired signal is additional state, never a downgrade of `refreshable`.
    try std.testing.expect(stale.refreshable());
    try std.testing.expect(stale.missingHelp(.cli) == null);
}

test "auth runtime view lists only detected credential sources" {
    var runtime: Runtime = .{};

    try std.testing.expectEqual(@as(usize, 0), runtime.view().available_inactive_sources.count());
}

test "auth runtime detects only credential sources that exist" {
    const Probe = struct {
        existing: SourceSet,

        fn exists(ctx: ?*anyopaque, _: Allocator, source: credentials.Source) !bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return self.existing.contains(source);
        }
    };

    var runtime: Runtime = .{};
    var probe = Probe{ .existing = SourceSet.initMany(&.{ .openai_api_key, .chatgpt_subscription }) };

    try runtime.refreshSourceInventoryWithProbe(std.testing.allocator, &probe, Probe.exists);

    const inventory = runtime.view().available_inactive_sources;
    try std.testing.expectEqual(@as(usize, 2), inventory.count());
    try std.testing.expect(inventory.contains(.openai_api_key));
    try std.testing.expect(inventory.contains(.chatgpt_subscription));
    try std.testing.expect(!inventory.contains(.grok_subscription));
}

test "auth runtime owns onboarding skip state" {
    var runtime: Runtime = .{};

    try std.testing.expect(!runtime.view().onboarding_skipped);
    runtime.skipOnboarding();
    try std.testing.expect(runtime.view().onboarding_skipped);
}

test "auth runtime pins every supported credential source to the session" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    const sources = [_]credentials.Source{
        .openai_api_key,
        .chatgpt_subscription,
        .grok_subscription,
    };
    for (sources) |source| {
        var credential = try makeTestCredential(alloc, @tagName(source), source);
        defer credential.deinit(alloc);
        _ = runtime.adoptCredential(alloc, &credential);

        try std.testing.expectEqual(source, runtime.credentialSource().?);
        try std.testing.expectEqualStrings(@tagName(source), runtime.apiKey().?);
    }
}

test "auth runtime explicitly selects the requested credential source" {
    const Loader = struct {
        fn load(_: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
            return try makeTestCredential(alloc, @tagName(source), source);
        }
    };

    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    var startup = try makeTestCredential(alloc, "startup-token", .openai_api_key);
    defer startup.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &startup);

    try std.testing.expect((try runtime.selectSourceWithLoader(alloc, .openai_api_key, null, Loader.load)).?);
    try std.testing.expectEqual(credentials.Source.openai_api_key, runtime.credentialSource().?);
    try std.testing.expectEqualStrings("openai_api_key", runtime.apiKey().?);
}

test "auth runtime failed selection preserves the active credential" {
    const Loader = struct {
        missing: credentials.Source,
        failing: credentials.Source,

        fn load(ctx: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (source == self.failing) return error.SourceReadFailed;
            if (source == self.missing) return null;
            return try makeTestCredential(alloc, @tagName(source), source);
        }
    };

    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    var active = try makeTestCredential(alloc, "active-token", .openai_api_key);
    defer active.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &active);

    var loader = Loader{ .missing = .chatgpt_subscription, .failing = .grok_subscription };
    try std.testing.expect((try runtime.selectSourceWithLoader(alloc, .chatgpt_subscription, &loader, Loader.load)) == null);
    try std.testing.expectEqual(credentials.Source.openai_api_key, runtime.credentialSource().?);
    try std.testing.expectEqualStrings("active-token", runtime.apiKey().?);

    try std.testing.expectError(
        error.SourceReadFailed,
        runtime.selectSourceWithLoader(alloc, .grok_subscription, &loader, Loader.load),
    );
    try std.testing.expectEqual(credentials.Source.openai_api_key, runtime.credentialSource().?);
    try std.testing.expectEqualStrings("active-token", runtime.apiKey().?);
}

const LogoutFixture = struct {
    existing: SourceSet,
    load_count: usize = 0,

    fn probe(ctx: ?*anyopaque, _: Allocator, source: credentials.Source) !bool {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        return self.existing.contains(source);
    }

    fn load(ctx: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.load_count += 1;
        if (!self.existing.contains(source)) return null;
        return try makeTestCredential(alloc, @tagName(source), source);
    }
};

test "auth picker root keeps sign in and credential actions" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    runtime.source_inventory = SourceSet.initOne(.openai_api_key);
    var credential = try makeTestCredential(alloc, "token", .openai_api_key);
    defer credential.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &credential);

    runtime.openPicker(alloc);

    const picker = runtime.pickerView();
    try std.testing.expect(picker.active);
    try std.testing.expect((Choice{ .action = .chatgpt_login }).eql(picker.selected_choice.?));
    try std.testing.expectEqual(@as(usize, 3), picker.choiceCount());
    try std.testing.expectEqualStrings("Switch credential", picker.choiceLabel(picker.choiceAt(2).?));
    try std.testing.expect(picker.choiceAt(3) == null);
}

test "credential switcher excludes provider-routed subscription sessions" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    runtime.source_inventory = SourceSet.initMany(&.{ .openai_api_key, .chatgpt_subscription, .grok_subscription });
    runtime.openPicker(alloc);
    runtime.openSwitchCredentialPicker(alloc);

    const picker = runtime.pickerView();
    try std.testing.expectEqual(@as(usize, 2), picker.choiceCount());
    try std.testing.expect((Choice{ .source = .openai_api_key }).eql(picker.choiceAt(0).?));
    try std.testing.expect((Choice{ .action = .automatic }).eql(picker.choiceAt(1).?));
}

test "auth picker navigation wraps across the three login hub actions" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    runtime.source_inventory = SourceSet.initOne(.openai_api_key);
    runtime.openPicker(alloc);

    try std.testing.expect(runtime.movePicker(1));
    try std.testing.expect((Choice{ .action = .grok_login }).eql(runtime.pickerView().selected_choice.?));
    try std.testing.expect(runtime.movePicker(1));
    try std.testing.expect((Choice{ .action = .switch_credential }).eql(runtime.pickerView().selected_choice.?));
    try std.testing.expect(runtime.movePicker(1));
    try std.testing.expect((Choice{ .action = .chatgpt_login }).eql(runtime.pickerView().selected_choice.?));
    try std.testing.expect(runtime.movePicker(-1));
    try std.testing.expect((Choice{ .action = .switch_credential }).eql(runtime.pickerView().selected_choice.?));
}

test "auth picker selection closes before returning its typed choice" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    runtime.source_inventory = SourceSet.initOne(.openai_api_key);

    try std.testing.expect(runtime.takePickerChoice(alloc) == null);
    runtime.openPicker(alloc);

    try std.testing.expect((Choice{ .action = .chatgpt_login }).eql(runtime.takePickerChoice(alloc).?));
    try std.testing.expect(!runtime.pickerView().active);
}

test "auth picker without credentials exposes acquisition actions" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    runtime.openPicker(alloc);

    const picker = runtime.pickerView();
    try std.testing.expect(picker.active_source == null);
    try std.testing.expect((Choice{ .action = .chatgpt_login }).eql(picker.selected_choice.?));
    try std.testing.expectEqual(@as(usize, 0), picker.available_sources.count());
    try std.testing.expectEqual(@as(usize, 3), picker.choiceCount());
    try std.testing.expectEqualStrings("missing", picker.activeSourceLabel());
}

test "auth onboarding picker exposes provider login paths" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    runtime.openOnboardingPicker(alloc);

    const picker = runtime.pickerView();
    try std.testing.expect(picker.include_skip);
    try std.testing.expectEqual(@as(usize, 2), picker.choiceCount());
    try std.testing.expect((Choice{ .action = .chatgpt_login }).eql(picker.choiceAt(0).?));
    try std.testing.expect((Choice{ .action = .grok_login }).eql(picker.choiceAt(1).?));
    try std.testing.expect(picker.choiceAt(2) == null);
}

test "switch credential stage includes the active source and pops to its root action" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    var active = try makeTestCredential(alloc, "active-token", .openai_api_key);
    defer active.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &active);
    runtime.openPicker(alloc);
    runtime.openSwitchCredentialPicker(alloc);

    const switch_view = runtime.pickerView();
    try std.testing.expectEqual(PickerStage.switch_credential, switch_view.stage);
    // One resolvable source plus the trailing Automatic row.
    try std.testing.expectEqual(@as(usize, 2), switch_view.choiceCount());
    try std.testing.expect((Choice{ .action = .automatic }).eql(switch_view.choiceAt(1).?));
    try std.testing.expect((Choice{ .source = .openai_api_key }).eql(switch_view.selected_choice.?));
    try std.testing.expectEqualStrings(
        credentials.sourceLabel(.openai_api_key),
        switch_view.choiceLabel(switch_view.selected_choice.?),
    );

    try std.testing.expect(runtime.popPickerStage(alloc));
    const root_view = runtime.pickerView();
    try std.testing.expect(root_view.active);
    try std.testing.expectEqual(PickerStage.root, root_view.stage);
    try std.testing.expect((Choice{ .action = .switch_credential }).eql(root_view.selected_choice.?));
}

test "standalone provider stage closes when cancelled" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    runtime.openPicker(alloc);
    runtime.openProviderPicker(alloc, .codex);

    try std.testing.expect(runtime.popPickerStage(alloc));
    try std.testing.expect(!runtime.pickerView().active);
}

test "auth picker cancellation preserves the active credential source" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    runtime.source_inventory = SourceSet.initOne(.openai_api_key);
    var active = try makeTestCredential(alloc, "active-token", .openai_api_key);
    defer active.deinit(alloc);
    _ = runtime.adoptCredential(alloc, &active);

    runtime.openPicker(alloc);
    _ = runtime.movePicker(1);
    runtime.closePicker(alloc);

    try std.testing.expectEqual(credentials.Source.openai_api_key, runtime.credentialSource().?);
    try std.testing.expectEqualStrings("active-token", runtime.apiKey().?);
}
