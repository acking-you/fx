const std = @import("std");

const oauth_transport = @import("../core/auth/oauth_transport.zig");
const secret = @import("../core/auth/secret.zig");
const io_mod = @import("../core/shared/io.zig");
const http_client = @import("../gateway/client.zig");

const Allocator = std.mem.Allocator;
const request_timeout_ms: i64 = 15_000;
const response_max_bytes: usize = 64 * 1024;

pub const provider = oauth_transport.Provider{
    .execute_fn = execute,
};

fn execute(
    _: ?*anyopaque,
    alloc: Allocator,
    request: oauth_transport.Request,
) !oauth_transport.Response {
    var local_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = request.cancel_flag orelse &local_cancel;
    const deadline = request.deadline orelse std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(request_timeout_ms),
    });
    var operation = HttpOperation{
        .alloc = alloc,
        .request = request,
    };
    return http_client.runBoundedHttpOperation(
        oauth_transport.Response,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
}

const HttpOperation = struct {
    alloc: Allocator,
    request: oauth_transport.Request,

    pub fn run(self: *@This()) !oauth_transport.Response {
        var client: std.http.Client = .{
            .allocator = self.alloc,
            .io = io_mod.getIo(),
        };
        defer client.deinit();

        const response_buffer = try self.alloc.alloc(u8, response_max_bytes + 1);
        defer secret.zeroAndFree(self.alloc, response_buffer);
        var response_writer = std.Io.Writer.fixed(response_buffer);

        const uri = try std.Uri.parse(self.request.url);
        var req = try http_client.openHttpRequest(&client, switch (self.request.method) {
            .get => .GET,
            .post_form, .post_json => .POST,
        }, uri, .{
            .headers = .{
                .content_type = switch (self.request.method) {
                    .get => .default,
                    .post_form => .{ .override = "application/x-www-form-urlencoded" },
                    .post_json => .{ .override = "application/json" },
                },
                .user_agent = .{ .override = http_client.user_agent },
                .accept_encoding = .omit,
                .authorization = if (self.request.authorization) |value|
                    .{ .override = value }
                else
                    .default,
            },
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();
        if (self.request.payload) |payload|
            try req.sendBodyComplete(@constCast(payload))
        else
            try req.sendBodiless();

        var response = try req.receiveHead(&.{});
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.alloc.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.alloc.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer self.alloc.free(decompress_buffer);
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = reader.streamRemaining(&response_writer) catch |err| switch (err) {
            error.WriteFailed => return error.OAuthResponseTooLarge,
            error.ReadFailed => return response.bodyErr().?,
        };
        const body = response_writer.buffered();
        if (body.len > response_max_bytes) return error.OAuthResponseTooLarge;

        return .{
            .disposition = if (response.head.status == .ok) .accepted else .rejected,
            .status = response.head.status,
            .body = try self.alloc.dupe(u8, body),
        };
    }
};

test "OAuth transport user agent uses the product version" {
    try std.testing.expect(std.mem.startsWith(u8, http_client.user_agent, "fx/"));
    try std.testing.expect(http_client.user_agent.len > "fx/".len);
    try std.testing.expect(std.mem.find(u8, http_client.user_agent, "zig") == null);
    try std.testing.expect(std.mem.find(u8, http_client.user_agent, "std.http") == null);
}
