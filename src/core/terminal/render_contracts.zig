//! Bounded immutable cell-grid contracts shared by rendering and replay.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_cell_text_bytes: usize = 64;
pub const max_render_snapshot_bytes: usize = 8 * 1024 * 1024;
pub const max_checkpoint_payload_bytes: usize = 64 * 1024 * 1024;
pub const max_dimension: u16 = 4096;

pub const Dimensions = struct {
    rows: u16,
    columns: u16,

    pub fn validate(self: Dimensions) error{InvalidDimensions}!void {
        if (self.rows == 0 or self.columns == 0 or
            self.rows > max_dimension or self.columns > max_dimension)
        {
            return error.InvalidDimensions;
        }
    }
};

pub const RenderCursor = struct {
    row: u16,
    column: u16,
    visible: bool = true,
    shape: CursorShape = .block,
    blinking: bool = true,
};

pub const CursorShape = enum {
    block,
    underline,
    bar,
};

pub const TerminalModes = struct {
    alternate_screen: bool = false,
    origin: bool = false,
    autowrap: bool = true,
    insert: bool = false,
    bracketed_paste: bool = false,
    mouse_tracking: bool = false,
    focus_tracking: bool = false,
    application_cursor_keys: bool = false,
    application_keypad: bool = false,
    keyboard_protocol: bool = false,
    synchronized_updates: bool = false,
};

pub const CellColor = union(enum) {
    default,
    indexed: u8,
    rgb: struct {
        red: u8,
        green: u8,
        blue: u8,
    },
};

pub const CellStyle = struct {
    foreground: CellColor = .default,
    background: CellColor = .default,
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    strikethrough: bool = false,
};

pub const CellKind = enum {
    blank,
    single,
    wide,
    continuation,
};

pub const RenderCell = struct {
    kind: CellKind = .blank,
    text: []const u8 = "",
    style: CellStyle = .{},
};

pub const max_render_cells: usize =
    max_render_snapshot_bytes / @sizeOf(RenderCell);

/// Immutable row-major cell-grid projection. The producer retains ownership
/// of `cells` and each cell's UTF-8 `text`.
pub const RenderSnapshot = struct {
    dimensions: Dimensions,
    cursor: RenderCursor,
    modes: TerminalModes = .{},
    cells: []const RenderCell,

    pub fn validate(self: RenderSnapshot) error{
        InvalidDimensions,
        InvalidRenderSnapshot,
        InvalidRenderCell,
        RenderSnapshotTooLarge,
    }!void {
        try self.dimensions.validate();
        if (self.cursor.row >= self.dimensions.rows or
            self.cursor.column >= self.dimensions.columns)
        {
            return error.InvalidRenderSnapshot;
        }

        const cell_count = std.math.mul(
            usize,
            @intCast(self.dimensions.rows),
            @intCast(self.dimensions.columns),
        ) catch return error.RenderSnapshotTooLarge;
        if (cell_count > max_render_cells) return error.RenderSnapshotTooLarge;
        if (cell_count != self.cells.len) return error.InvalidRenderSnapshot;

        var total_bytes = std.math.mul(
            usize,
            self.cells.len,
            @sizeOf(RenderCell),
        ) catch return error.RenderSnapshotTooLarge;
        for (self.cells, 0..) |cell, index| {
            if (cell.text.len > max_cell_text_bytes) {
                return error.RenderSnapshotTooLarge;
            }
            total_bytes = std.math.add(
                usize,
                total_bytes,
                cell.text.len,
            ) catch return error.RenderSnapshotTooLarge;
            if (total_bytes > max_render_snapshot_bytes) {
                return error.RenderSnapshotTooLarge;
            }

            switch (cell.kind) {
                .blank, .continuation => {
                    if (cell.text.len != 0) return error.InvalidRenderCell;
                },
                .single, .wide => {
                    if (cell.text.len == 0 or
                        !std.unicode.utf8ValidateSlice(cell.text))
                    {
                        return error.InvalidRenderCell;
                    }
                },
            }

            const column = index % @as(usize, self.dimensions.columns);
            switch (cell.kind) {
                .wide => {
                    if (column + 1 >= @as(usize, self.dimensions.columns) or
                        self.cells[index + 1].kind != .continuation)
                    {
                        return error.InvalidRenderCell;
                    }
                },
                .continuation => {
                    if (column == 0 or self.cells[index - 1].kind != .wide) {
                        return error.InvalidRenderCell;
                    }
                },
                .blank, .single => {},
            }
        }
        if (total_bytes > max_render_snapshot_bytes) {
            return error.RenderSnapshotTooLarge;
        }
    }
};

/// Owned immutable snapshot produced by the terminal engine. The caller frees
/// it with `deinit` using the allocator passed to the producer.
pub const OwnedRenderSnapshot = struct {
    dimensions: Dimensions,
    cursor: RenderCursor,
    modes: TerminalModes,
    cells: []RenderCell,
    text_storage: []u8,

    pub fn view(self: *const OwnedRenderSnapshot) RenderSnapshot {
        return .{
            .dimensions = self.dimensions,
            .cursor = self.cursor,
            .modes = self.modes,
            .cells = self.cells,
        };
    }

    pub fn deinit(self: *OwnedRenderSnapshot, alloc: Allocator) void {
        alloc.free(self.cells);
        alloc.free(self.text_storage);
        self.* = undefined;
    }
};

fn test_render_cells() [4]RenderCell {
    return .{
        .{
            .kind = .single,
            .text = "A",
            .style = .{
                .foreground = .{ .rgb = .{
                    .red = 10,
                    .green = 20,
                    .blue = 30,
                } },
                .bold = true,
            },
        },
        .{ .kind = .blank },
        .{ .kind = .wide, .text = "界" },
        .{ .kind = .continuation },
    };
}

test "render snapshots validate exact cell grids cursor and checked bounds" {
    const cells = test_render_cells();
    const snapshot = RenderSnapshot{
        .dimensions = .{ .rows = 2, .columns = 2 },
        .cursor = .{
            .row = 1,
            .column = 1,
            .shape = .bar,
            .blinking = false,
        },
        .modes = .{
            .alternate_screen = true,
            .bracketed_paste = true,
        },
        .cells = &cells,
    };
    try snapshot.validate();
    try std.testing.expect(max_render_snapshot_bytes <= max_checkpoint_payload_bytes);

    try std.testing.expectError(
        error.InvalidDimensions,
        (RenderSnapshot{
            .dimensions = .{ .rows = 0, .columns = 80 },
            .cursor = .{ .row = 0, .column = 0 },
            .cells = &.{},
        }).validate(),
    );
    try std.testing.expectError(
        error.InvalidRenderSnapshot,
        (RenderSnapshot{
            .dimensions = .{ .rows = 2, .columns = 2 },
            .cursor = .{ .row = 2, .column = 0 },
            .cells = &cells,
        }).validate(),
    );
    try std.testing.expectError(
        error.InvalidRenderSnapshot,
        (RenderSnapshot{
            .dimensions = .{ .rows = 2, .columns = 3 },
            .cursor = .{ .row = 0, .column = 0 },
            .cells = &cells,
        }).validate(),
    );
    try std.testing.expectError(
        error.RenderSnapshotTooLarge,
        (RenderSnapshot{
            .dimensions = .{
                .rows = max_dimension,
                .columns = max_dimension,
            },
            .cursor = .{ .row = 0, .column = 0 },
            .cells = &.{},
        }).validate(),
    );

    var invalid_wide = cells;
    invalid_wide[2].kind = .blank;
    try std.testing.expectError(
        error.InvalidRenderCell,
        (RenderSnapshot{
            .dimensions = .{ .rows = 2, .columns = 2 },
            .cursor = .{ .row = 0, .column = 0 },
            .cells = &invalid_wide,
        }).validate(),
    );
}
