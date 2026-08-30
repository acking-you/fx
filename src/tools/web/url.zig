const std = @import("std");

const Allocator = std.mem.Allocator;
const IpAddress = std.Io.net.IpAddress;

/// Failures here describe URLs the HTTP transport cannot represent. This
/// module intentionally does not classify hosts, addresses, credentials, or
/// redirect destinations as safe or unsafe.
pub const Error = error{
    EmptyUrl,
    UnsupportedScheme,
    MissingHost,
    MalformedHost,
    MalformedLocation,
    MalformedPercentEncoding,
    ControlByte,
    RequestTargetWhitespace,
    InvalidPort,
    WriteFailed,
    OutOfMemory,
};

pub const Scheme = enum {
    http,
    https,

    pub fn defaultPort(self: Scheme) u16 {
        return switch (self) {
            .http => 80,
            .https => 443,
        };
    }

    pub fn text(self: Scheme) []const u8 {
        return switch (self) {
            .http => "http",
            .https => "https",
        };
    }
};

pub const ParsedUrl = struct {
    scheme: Scheme,
    canonical_host: []u8,
    port: u16,
    explicit_port: ?u16,
    path_query: []u8,
    retrieval_url: []u8,
    basic_credentials: ?[]u8 = null,
    literal_address: ?IpAddress = null,

    pub fn deinit(self: *ParsedUrl, alloc: Allocator) void {
        alloc.free(self.canonical_host);
        alloc.free(self.path_query);
        alloc.free(self.retrieval_url);
        if (self.basic_credentials) |credentials| alloc.free(credentials);
        self.* = .{
            .scheme = .https,
            .canonical_host = &.{},
            .port = 443,
            .explicit_port = null,
            .path_query = &.{},
            .retrieval_url = &.{},
        };
    }
};

const ParsedAuthority = struct {
    userinfo: ?[]const u8,
    host: []const u8,
    port: ?u16,
    is_ipv6_literal: bool = false,
};

pub fn parse(alloc: Allocator, raw_url: []const u8) Error!ParsedUrl {
    if (raw_url.len == 0) return error.EmptyUrl;
    try rejectControlBytes(raw_url);
    try validatePercentEncoding(raw_url);

    const scheme_end = std.mem.find(u8, raw_url, "://") orelse return error.UnsupportedScheme;
    const raw_scheme = raw_url[0..scheme_end];
    const scheme: Scheme = if (std.ascii.eqlIgnoreCase(raw_scheme, "http"))
        .http
    else if (std.ascii.eqlIgnoreCase(raw_scheme, "https"))
        .https
    else
        return error.UnsupportedScheme;

    const authority_start = scheme_end + "://".len;
    const authority_end = authorityEnd(raw_url, authority_start);
    if (authority_end == authority_start) return error.MissingHost;

    const parsed_authority = try parseAuthority(raw_url[authority_start..authority_end]);
    const canonical_host = try canonicalizeHost(alloc, parsed_authority.host, parsed_authority.is_ipv6_literal);
    errdefer alloc.free(canonical_host.host);

    const port = parsed_authority.port orelse scheme.defaultPort();
    const explicit_port = if (parsed_authority.port != null and port != scheme.defaultPort()) port else null;
    const path_query = try normalizePathQuery(alloc, stripFragment(raw_url[authority_end..]));
    errdefer alloc.free(path_query);
    const retrieval_url = try formatUrl(
        alloc,
        scheme,
        parsed_authority.userinfo,
        canonical_host.host,
        explicit_port,
        path_query,
    );
    errdefer alloc.free(retrieval_url);
    const basic_credentials = if (parsed_authority.userinfo) |value| try decodeBasicCredentials(alloc, value) else null;
    errdefer if (basic_credentials) |value| alloc.free(value);

    return .{
        .scheme = scheme,
        .canonical_host = canonical_host.host,
        .port = port,
        .explicit_port = explicit_port,
        .path_query = path_query,
        .retrieval_url = retrieval_url,
        .basic_credentials = basic_credentials,
        .literal_address = canonical_host.literal_address,
    };
}

pub fn redirectTarget(alloc: Allocator, current: ParsedUrl, location: []const u8) Error!ParsedUrl {
    if (location.len == 0) return error.MalformedLocation;
    try rejectControlBytes(location);

    const absolute = try absoluteRedirectUrl(alloc, current, location);
    defer alloc.free(absolute);
    return parse(alloc, absolute) catch |err| switch (err) {
        error.UnsupportedScheme,
        error.ControlByte,
        error.RequestTargetWhitespace,
        error.MalformedPercentEncoding,
        => |direct| return direct,
        else => return error.MalformedLocation,
    };
}

fn authorityEnd(url: []const u8, start: usize) usize {
    var index = start;
    while (index < url.len) : (index += 1) {
        switch (url[index]) {
            '/', '?', '#' => return index,
            else => {},
        }
    }
    return url.len;
}

fn parseAuthority(authority: []const u8) Error!ParsedAuthority {
    if (authority.len == 0) return error.MissingHost;
    const separator = std.mem.lastIndexOfScalar(u8, authority, '@');
    const userinfo = if (separator) |index| authority[0..index] else null;
    const host_port = if (separator) |index| authority[index + 1 ..] else authority;
    if (host_port.len == 0) return error.MissingHost;

    if (host_port[0] == '[') {
        const end = std.mem.findScalar(u8, host_port, ']') orelse return error.MalformedHost;
        if (end == 1) return error.MissingHost;
        if (end + 1 == host_port.len) return .{
            .userinfo = userinfo,
            .host = host_port[1..end],
            .port = null,
            .is_ipv6_literal = true,
        };
        if (host_port[end + 1] != ':') return error.MalformedHost;
        return .{
            .userinfo = userinfo,
            .host = host_port[1..end],
            .port = try parsePort(host_port[end + 2 ..]),
            .is_ipv6_literal = true,
        };
    }

    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse host_port.len;
    const host = host_port[0..colon];
    if (host.len == 0) return error.MissingHost;
    if (std.mem.findScalar(u8, host, ':') != null) return error.MalformedHost;
    return .{
        .userinfo = userinfo,
        .host = host,
        .port = if (colon == host_port.len) null else try parsePort(host_port[colon + 1 ..]),
    };
}

fn parsePort(raw: []const u8) Error!u16 {
    if (raw.len == 0) return error.InvalidPort;
    for (raw) |char| if (!std.ascii.isDigit(char)) return error.InvalidPort;
    return std.fmt.parseInt(u16, raw, 10) catch return error.InvalidPort;
}

const CanonicalHost = struct {
    host: []u8,
    literal_address: ?IpAddress = null,
};

fn canonicalizeHost(alloc: Allocator, raw_host: []const u8, is_ipv6_literal: bool) Error!CanonicalHost {
    if (raw_host.len == 0) return error.MissingHost;
    for (raw_host) |char| {
        if (char < 0x20 or char == 0x7f) return error.ControlByte;
        if (std.ascii.isWhitespace(char) or char == '\\' or char == '/') return error.MalformedHost;
    }

    if (is_ipv6_literal) {
        const address: IpAddress = .{
            .ip6 = std.Io.net.Ip6Address.parse(raw_host, 0) catch return error.MalformedHost,
        };
        return .{ .host = try lowerAscii(alloc, raw_host), .literal_address = address };
    }

    const without_root = if (raw_host.len > 1 and raw_host[raw_host.len - 1] == '.')
        raw_host[0 .. raw_host.len - 1]
    else
        raw_host;
    if (without_root.len == 0) return error.MalformedHost;

    const lowered = try lowerAscii(alloc, without_root);
    errdefer alloc.free(lowered);
    const literal_address: ?IpAddress = if (std.Io.net.Ip4Address.parse(lowered, 0)) |ip4|
        .{ .ip4 = ip4 }
    else |_|
        null;
    return .{ .host = lowered, .literal_address = literal_address };
}

fn lowerAscii(alloc: Allocator, value: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, value.len);
    for (value, 0..) |char, index| out[index] = std.ascii.toLower(char);
    return out;
}

fn rejectControlBytes(value: []const u8) Error!void {
    for (value) |char| if (char < 0x20 or char == 0x7f) return error.ControlByte;
}

fn validatePercentEncoding(value: []const u8) Error!void {
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (value[index] != '%') continue;
        if (index + 2 >= value.len or
            !std.ascii.isHex(value[index + 1]) or
            !std.ascii.isHex(value[index + 2])) return error.MalformedPercentEncoding;
        index += 2;
    }
}

fn percentDecode(alloc: Allocator, value: []const u8) Error![]u8 {
    const out = try alloc.alloc(u8, value.len);
    errdefer alloc.free(out);
    var read: usize = 0;
    var written: usize = 0;
    while (read < value.len) {
        if (value[read] == '%') {
            out[written] = std.fmt.parseInt(u8, value[read + 1 .. read + 3], 16) catch
                return error.MalformedPercentEncoding;
            read += 3;
        } else {
            out[written] = value[read];
            read += 1;
        }
        written += 1;
    }
    return alloc.realloc(out, written);
}

fn decodeBasicCredentials(alloc: Allocator, userinfo: []const u8) Error![]u8 {
    const decoded = try percentDecode(alloc, userinfo);
    errdefer alloc.free(decoded);
    if (std.mem.findScalar(u8, decoded, ':') != null) return decoded;
    const credentials = try alloc.realloc(decoded, decoded.len + 1);
    credentials[credentials.len - 1] = ':';
    return credentials;
}

fn stripFragment(path_query_fragment: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, path_query_fragment, '#') orelse path_query_fragment.len;
    return path_query_fragment[0..end];
}

fn normalizePathQuery(alloc: Allocator, path_query: []const u8) Error![]u8 {
    for (path_query) |char| if (std.ascii.isWhitespace(char)) return error.RequestTargetWhitespace;
    if (path_query.len == 0) return alloc.dupe(u8, "/");
    if (path_query[0] == '?') return std.fmt.allocPrint(alloc, "/{s}", .{path_query});
    return alloc.dupe(u8, path_query);
}

fn formatUrl(
    alloc: Allocator,
    scheme: Scheme,
    userinfo: ?[]const u8,
    host: []const u8,
    explicit_port: ?u16,
    path_query: []const u8,
) ![]u8 {
    const host_text = try hostForUrl(alloc, host);
    defer alloc.free(host_text);
    const authority = if (userinfo) |value|
        try std.fmt.allocPrint(alloc, "{s}@{s}", .{ value, host_text })
    else
        try alloc.dupe(u8, host_text);
    defer alloc.free(authority);
    if (explicit_port) |port| {
        return std.fmt.allocPrint(alloc, "{s}://{s}:{d}{s}", .{ scheme.text(), authority, port, path_query });
    }
    return std.fmt.allocPrint(alloc, "{s}://{s}{s}", .{ scheme.text(), authority, path_query });
}

fn hostForUrl(alloc: Allocator, canonical_host: []const u8) ![]u8 {
    if (std.mem.findScalar(u8, canonical_host, ':') == null) return alloc.dupe(u8, canonical_host);
    return std.fmt.allocPrint(alloc, "[{s}]", .{canonical_host});
}

fn absoluteRedirectUrl(alloc: Allocator, current: ParsedUrl, location: []const u8) Error![]u8 {
    const without_fragment = stripFragment(location);
    if (without_fragment.len == 0) return alloc.dupe(u8, current.retrieval_url);

    if (hasHttpScheme(without_fragment)) return alloc.dupe(u8, without_fragment);
    if (std.mem.startsWith(u8, without_fragment, "//")) {
        return std.fmt.allocPrint(alloc, "{s}:{s}", .{ current.scheme.text(), without_fragment });
    }
    if (hasAbsoluteScheme(without_fragment)) return error.UnsupportedScheme;

    if (without_fragment[0] == '?') {
        const path_end = std.mem.findScalar(u8, current.path_query, '?') orelse current.path_query.len;
        const path_query = try std.fmt.allocPrint(alloc, "{s}{s}", .{ current.path_query[0..path_end], without_fragment });
        defer alloc.free(path_query);
        return formatUrl(alloc, current.scheme, currentUserinfo(current), current.canonical_host, current.explicit_port, path_query);
    }

    if (without_fragment[0] == '/') {
        return formatUrl(alloc, current.scheme, currentUserinfo(current), current.canonical_host, current.explicit_port, without_fragment);
    }

    const merged = try mergeRelativePath(alloc, current.path_query, without_fragment);
    defer alloc.free(merged);
    return formatUrl(alloc, current.scheme, currentUserinfo(current), current.canonical_host, current.explicit_port, merged);
}

fn currentUserinfo(current: ParsedUrl) ?[]const u8 {
    const scheme_end = std.mem.find(u8, current.retrieval_url, "://") orelse return null;
    const start = scheme_end + "://".len;
    const end = authorityEnd(current.retrieval_url, start);
    const authority = current.retrieval_url[start..end];
    const separator = std.mem.lastIndexOfScalar(u8, authority, '@') orelse return null;
    return authority[0..separator];
}

fn hasHttpScheme(value: []const u8) bool {
    const separator = std.mem.find(u8, value, "://") orelse return false;
    return std.ascii.eqlIgnoreCase(value[0..separator], "http") or
        std.ascii.eqlIgnoreCase(value[0..separator], "https");
}

fn hasAbsoluteScheme(value: []const u8) bool {
    const colon = std.mem.findScalar(u8, value, ':') orelse return false;
    const slash = std.mem.findScalar(u8, value, '/') orelse value.len;
    const question = std.mem.findScalar(u8, value, '?') orelse value.len;
    return colon < slash and colon < question;
}

fn mergeRelativePath(alloc: Allocator, current_path_query: []const u8, relative: []const u8) ![]u8 {
    const current_path_end = std.mem.findScalar(u8, current_path_query, '?') orelse current_path_query.len;
    const current_path = current_path_query[0..current_path_end];
    const base_end = if (std.mem.lastIndexOfScalar(u8, current_path, '/')) |slash| slash + 1 else 0;
    const query_start = std.mem.findScalar(u8, relative, '?') orelse relative.len;
    const joined = try std.fmt.allocPrint(alloc, "{s}{s}", .{ current_path[0..base_end], relative[0..query_start] });
    defer alloc.free(joined);
    const normalized_path = try removeDotSegments(alloc, joined);
    defer alloc.free(normalized_path);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ normalized_path, relative[query_start..] });
}

fn removeDotSegments(alloc: Allocator, path: []const u8) ![]u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(alloc);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (segments.items.len > 0) _ = segments.pop();
            continue;
        }
        try segments.append(alloc, segment);
    }

    var writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer writer.deinit();
    try writer.writer.writeByte('/');
    for (segments.items, 0..) |segment, index| {
        if (index > 0) try writer.writer.writeByte('/');
        try writer.writer.writeAll(segment);
    }
    if (std.mem.endsWith(u8, path, "/") and segments.items.len > 0) try writer.writer.writeByte('/');
    return writer.toOwnedSlice();
}

test "web_fetch URL parsing preserves HTTP and accepts local private and credentialed targets" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "http://localhost:3000/status",
        "http://127.0.0.1/status",
        "http://169.254.169.254/latest/meta-data/",
        "http://192.168.1.10/status",
        "http://[::1]/status",
        "https://user:pass@intranet/private",
    };
    for (cases) |raw| {
        var parsed = try parse(alloc, raw);
        defer parsed.deinit(alloc);
        try std.testing.expectEqualStrings(raw, parsed.retrieval_url);
    }
}

test "web_fetch URL parsing canonicalizes host and strips fragments without upgrading HTTP" {
    const alloc = std.testing.allocator;
    var parsed = try parse(alloc, "http://Example.COM.:80/docs?q=1#frag");
    defer parsed.deinit(alloc);
    try std.testing.expectEqual(.http, parsed.scheme);
    try std.testing.expectEqual(@as(u16, 80), parsed.port);
    try std.testing.expectEqualStrings("example.com", parsed.canonical_host);
    try std.testing.expectEqualStrings("http://example.com/docs?q=1", parsed.retrieval_url);
}

test "web_fetch redirects may change host protocol port and credentials" {
    const alloc = std.testing.allocator;
    var current = try parse(alloc, "http://localhost:3000/a/b/page");
    defer current.deinit(alloc);

    var relative = try redirectTarget(alloc, current, "../next?q=1");
    defer relative.deinit(alloc);
    try std.testing.expectEqualStrings("http://localhost:3000/a/next?q=1", relative.retrieval_url);

    var cross_boundary = try redirectTarget(alloc, current, "https://user:pass@169.254.169.254:8443/meta");
    defer cross_boundary.deinit(alloc);
    try std.testing.expectEqualStrings("https://user:pass@169.254.169.254:8443/meta", cross_boundary.retrieval_url);
    try std.testing.expectEqualStrings("user:pass", cross_boundary.basic_credentials.?);

    var query_only = try redirectTarget(alloc, current, "?page=2");
    defer query_only.deinit(alloc);
    try std.testing.expectEqualStrings("http://localhost:3000/a/b/page?page=2", query_only.retrieval_url);
}

test "web_fetch URL credentials use HTTP Basic user password form" {
    const alloc = std.testing.allocator;
    var with_password = try parse(alloc, "http://user:p%40ss@localhost/private");
    defer with_password.deinit(alloc);
    try std.testing.expectEqualStrings("user:p@ss", with_password.basic_credentials.?);

    var without_password = try parse(alloc, "http://user@localhost/private");
    defer without_password.deinit(alloc);
    try std.testing.expectEqualStrings("user:", without_password.basic_credentials.?);
}

test "web_fetch rejects only URLs the HTTP request cannot represent" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.EmptyUrl, parse(alloc, ""));
    try std.testing.expectError(error.UnsupportedScheme, parse(alloc, "ftp://example.com/file"));
    try std.testing.expectError(error.MissingHost, parse(alloc, "https:///file"));
    try std.testing.expectError(error.RequestTargetWhitespace, parse(alloc, "https://example.com/a b"));
    try std.testing.expectError(error.ControlByte, parse(alloc, "https://example.com/a\nb"));
}
