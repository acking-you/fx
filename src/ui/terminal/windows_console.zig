const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");

const windows = std.os.windows;

const enable_processed_input: windows.DWORD = 0x0001;
const enable_line_input: windows.DWORD = 0x0002;
const enable_echo_input: windows.DWORD = 0x0004;
const enable_virtual_terminal_input: windows.DWORD = 0x0200;
const enable_processed_output: windows.DWORD = 0x0001;
const enable_virtual_terminal_processing: windows.DWORD = 0x0004;
const cp_utf8: windows.UINT = 65001;

pub const State = struct {
    input_handle: windows.HANDLE = undefined,
    output_handle: windows.HANDLE = undefined,
    original_input_mode: windows.DWORD = 0,
    original_output_mode: windows.DWORD = 0,
    original_input_cp: windows.UINT = 0,
    original_output_cp: windows.UINT = 0,
    captured: bool = false,

    pub fn capture(self: *State) !void {
        self.input_handle = std.Io.File.stdin().handle;
        self.output_handle = std.Io.File.stdout().handle;
        if (GetConsoleMode(self.input_handle, &self.original_input_mode) == .FALSE or
            GetConsoleMode(self.output_handle, &self.original_output_mode) == .FALSE)
        {
            return error.NotATerminal;
        }
        self.original_input_cp = GetConsoleCP();
        self.original_output_cp = GetConsoleOutputCP();
        self.captured = true;
    }

    pub fn enableRaw(self: *State) !void {
        if (!self.captured) try self.capture();
        return self.enableRawWith(.{ .set_mode = nativeSetConsoleMode });
    }

    fn enableRawWith(self: *State, api: ModeApi) !void {
        const input_mode = (self.original_input_mode &
            ~(enable_processed_input | enable_line_input | enable_echo_input)) |
            enable_virtual_terminal_input;
        const output_mode = self.original_output_mode |
            enable_processed_output | enable_virtual_terminal_processing;
        errdefer self.restoreModesWith(api);
        if (api.set_mode(api.ctx, self.input_handle, input_mode) == .FALSE or
            api.set_mode(api.ctx, self.output_handle, output_mode) == .FALSE)
        {
            return error.UnableToConfigureTerminal;
        }
        _ = SetConsoleCP(cp_utf8);
        _ = SetConsoleOutputCP(cp_utf8);
    }

    pub fn restore(self: *State) void {
        if (!self.captured) return;
        self.restoreModesWith(.{ .set_mode = nativeSetConsoleMode });
        if (self.original_input_cp != 0) _ = SetConsoleCP(self.original_input_cp);
        if (self.original_output_cp != 0) _ = SetConsoleOutputCP(self.original_output_cp);
    }

    fn restoreModesWith(self: *State, api: ModeApi) void {
        _ = api.set_mode(api.ctx, self.input_handle, self.original_input_mode);
        _ = api.set_mode(api.ctx, self.output_handle, self.original_output_mode);
    }
};

const ModeApi = struct {
    ctx: ?*anyopaque = null,
    set_mode: *const fn (?*anyopaque, windows.HANDLE, windows.DWORD) windows.BOOL,
};

fn nativeSetConsoleMode(_: ?*anyopaque, handle: windows.HANDLE, mode: windows.DWORD) windows.BOOL {
    return SetConsoleMode(handle, mode);
}

test "raw console setup restores captured modes after a partial failure" {
    const Trace = struct {
        modes: [4]windows.DWORD = undefined,
        len: usize = 0,

        fn setMode(ctx: ?*anyopaque, _: windows.HANDLE, mode: windows.DWORD) windows.BOOL {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.modes[self.len] = mode;
            self.len += 1;
            return if (self.len == 2) .FALSE else .TRUE;
        }
    };

    var trace: Trace = .{};
    var state: State = .{
        .input_handle = @ptrFromInt(1),
        .output_handle = @ptrFromInt(2),
        .original_input_mode = enable_processed_input | enable_line_input | enable_echo_input,
        .original_output_mode = enable_processed_output,
        .captured = true,
    };

    try std.testing.expectError(error.UnableToConfigureTerminal, state.enableRawWith(.{
        .ctx = &trace,
        .set_mode = Trace.setMode,
    }));
    try std.testing.expectEqual(@as(usize, 4), trace.len);
    try std.testing.expectEqual(state.original_input_mode, trace.modes[2]);
    try std.testing.expectEqual(state.original_output_mode, trace.modes[3]);
}

pub fn ensureInteractive() !void {
    if (!try std.Io.File.stdin().isTty(io_mod.getIo()) or
        !try std.Io.File.stdout().isTty(io_mod.getIo()))
    {
        return error.NotATerminal;
    }
}

pub const Size = struct { rows: u16, cols: u16 };

pub fn querySize() !Size {
    var info: ConsoleScreenBufferInfo = undefined;
    if (GetConsoleScreenBufferInfo(std.Io.File.stdout().handle, &info) == .FALSE)
        return error.UnableToReadTerminalSize;
    const rows_i32 = @as(i32, info.window.bottom) - @as(i32, info.window.top) + 1;
    const cols_i32 = @as(i32, info.window.right) - @as(i32, info.window.left) + 1;
    if (rows_i32 <= 0 or cols_i32 <= 0) return error.UnableToReadTerminalSize;
    return .{ .rows = @intCast(rows_i32), .cols = @intCast(cols_i32) };
}

pub const WaitResult = enum { input, wake, timeout };

pub fn waitForInputOrWake(wake: windows.HANDLE, timeout_ms: i32) !WaitResult {
    const handles = [_]windows.HANDLE{ std.Io.File.stdin().handle, wake };
    const timeout: windows.DWORD = if (timeout_ms < 0) std.math.maxInt(windows.DWORD) else @intCast(timeout_ms);
    return switch (WaitForMultipleObjects(handles.len, &handles, .FALSE, timeout)) {
        wait_object_0 => .input,
        wait_object_0 + 1 => .wake,
        wait_timeout => .timeout,
        else => error.TerminalWaitFailed,
    };
}

const SmallRect = extern struct {
    left: windows.SHORT,
    top: windows.SHORT,
    right: windows.SHORT,
    bottom: windows.SHORT,
};

const ConsoleScreenBufferInfo = extern struct {
    size: windows.COORD,
    cursor_position: windows.COORD,
    attributes: windows.WORD,
    window: SmallRect,
    maximum_window_size: windows.COORD,
};

const wait_object_0: windows.DWORD = 0;
const wait_timeout: windows.DWORD = 258;

extern "kernel32" fn GetConsoleMode(handle: windows.HANDLE, mode: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetConsoleMode(handle: windows.HANDLE, mode: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) windows.UINT;
extern "kernel32" fn SetConsoleCP(code_page: windows.UINT) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) windows.UINT;
extern "kernel32" fn SetConsoleOutputCP(code_page: windows.UINT) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(handle: windows.HANDLE, info: *ConsoleScreenBufferInfo) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForMultipleObjects(count: windows.DWORD, handles: [*]const windows.HANDLE, wait_all: windows.BOOL, timeout: windows.DWORD) callconv(.winapi) windows.DWORD;
