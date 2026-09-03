//! Bounded, self-contained Mermaid renderer for terminal transcripts.
//!
//! This renderer intentionally supports a useful Mermaid subset rather than
//! executing Mermaid or launching a browser. Unsupported syntax returns
//! `null`, allowing the caller to preserve the original source code block.

const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");

const Allocator = std.mem.Allocator;

const max_source_bytes = 64 * 1024;
const max_nodes = 128;
const max_edges = 512;
const max_members = 8;
const max_statements = 1024;
const max_canvas_cells = 1 << 20;
const wrap_width = 24;
const max_label_lines = 4;
const pad = 1;
const gap_x = 3;
const gap_y = 3;

pub const Styles = struct {
    dim: []const u8 = "",
    reset: []const u8 = "",
};

const MermaidError = Allocator.Error || error{TooComplex};

const Direction = enum {
    down,
    up,
    right,
    left,
};

const Shape = enum {
    rect,
    round,
    diamond,
    start,
    finish,
};

const Head = enum {
    none,
    arrow,
    circle,
    cross,
    triangle,
    diamond_fill,
    diamond_open,
};

const LineKind = enum {
    solid,
    dotted,
    thick,
};

const Node = struct {
    id: []u8,
    label: []u8,
    shape: Shape,
    members: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Node, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.label);
        for (self.members.items) |member| alloc.free(member);
        self.members.deinit(alloc);
        self.* = undefined;
    }
};

const Edge = struct {
    from: usize,
    to: usize,
    label: ?[]u8 = null,
    head_to: Head = .arrow,
    head_from: Head = .none,
    line: LineKind = .solid,

    fn deinit(self: *Edge, alloc: Allocator) void {
        if (self.label) |label| alloc.free(label);
        self.* = undefined;
    }
};

const Graph = struct {
    alloc: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    index: std.StringHashMap(usize),
    direction: Direction = .down,

    fn init(alloc: Allocator) Graph {
        return .{ .alloc = alloc, .index = std.StringHashMap(usize).init(alloc) };
    }

    fn deinit(self: *Graph) void {
        self.index.deinit();
        for (self.nodes.items) |*node| node.deinit(self.alloc);
        for (self.edges.items) |*edge| edge.deinit(self.alloc);
        self.nodes.deinit(self.alloc);
        self.edges.deinit(self.alloc);
        self.* = undefined;
    }

    fn addNode(self: *Graph, id: []const u8, label: ?[]const u8, shape: Shape) MermaidError!usize {
        if (self.index.get(id)) |index| {
            if (label) |value| {
                const clean = try cleanLabel(self.alloc, value);
                self.alloc.free(self.nodes.items[index].label);
                self.nodes.items[index].label = clean;
                self.nodes.items[index].shape = shape;
            } else if (shape == .diamond or shape == .start or shape == .finish) {
                self.nodes.items[index].shape = shape;
            }
            return index;
        }
        if (self.nodes.items.len >= max_nodes) return error.TooComplex;
        const owned_id = try self.alloc.dupe(u8, id);
        errdefer self.alloc.free(owned_id);
        const owned_label = try cleanLabel(self.alloc, label orelse id);
        errdefer self.alloc.free(owned_label);
        const index = self.nodes.items.len;
        try self.nodes.append(self.alloc, .{
            .id = owned_id,
            .label = owned_label,
            .shape = shape,
        });
        errdefer _ = self.nodes.pop();
        try self.index.put(owned_id, index);
        return index;
    }

    fn setLabel(self: *Graph, id: []const u8, label: []const u8, shape: ?Shape) MermaidError!usize {
        const index = try self.addNode(id, null, shape orelse .round);
        const clean = try cleanLabel(self.alloc, label);
        self.alloc.free(self.nodes.items[index].label);
        self.nodes.items[index].label = clean;
        if (shape) |value| self.nodes.items[index].shape = value;
        return index;
    }

    fn addMember(self: *Graph, index: usize, raw: []const u8) MermaidError!void {
        const text = std.mem.trim(u8, raw, " \t\r");
        if (text.len == 0) return;
        var node = &self.nodes.items[index];
        if (node.members.items.len >= max_members) {
            if (node.members.items.len == max_members and
                !std.mem.eql(u8, node.members.items[max_members - 1], "…"))
            {
                const ellipsis = try self.alloc.dupe(u8, "…");
                self.alloc.free(node.members.items[max_members - 1]);
                node.members.items[max_members - 1] = ellipsis;
            }
            return;
        }
        const owned = try cleanLabel(self.alloc, text);
        errdefer self.alloc.free(owned);
        try node.members.append(self.alloc, owned);
    }

    fn addEdge(self: *Graph, edge: Edge) MermaidError!void {
        if (self.edges.items.len >= max_edges) return error.TooComplex;
        try self.edges.append(self.alloc, edge);
    }
};

const Statements = struct {
    items: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Statements, alloc: Allocator) void {
        for (self.items.items) |item| alloc.free(item);
        self.items.deinit(alloc);
        self.* = undefined;
    }
};

/// Renders a supported Mermaid diagram. The caller owns the returned bytes.
/// `null` means that the source should be rendered as an ordinary code block.
pub fn render(
    alloc: Allocator,
    source: []const u8,
    max_width: usize,
    styles: Styles,
) Allocator.Error!?[]u8 {
    if (source.len > max_source_bytes or max_width < 8) return null;
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return null;

    return renderBounded(alloc, trimmed, max_width, styles) catch |err| switch (err) {
        error.TooComplex => null,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn renderBounded(
    alloc: Allocator,
    source: []const u8,
    max_width: usize,
    styles: Styles,
) MermaidError!?[]u8 {
    const kind = firstWord(source);
    if (eqlIgnoreCase(kind, "sequencediagram")) {
        var sequence = (try parseSequence(alloc, source)) orelse return null;
        defer sequence.deinit();
        return try layoutSequence(alloc, &sequence, max_width, styles);
    }

    var graph = if (eqlIgnoreCase(kind, "graph") or eqlIgnoreCase(kind, "flowchart"))
        (try parseFlowchart(alloc, source)) orelse return null
    else if (startsWithIgnoreCase(kind, "statediagram"))
        (try parseState(alloc, source)) orelse return null
    else if (eqlIgnoreCase(kind, "classdiagram"))
        (try parseClass(alloc, source)) orelse return null
    else if (eqlIgnoreCase(kind, "erdiagram"))
        (try parseEr(alloc, source)) orelse return null
    else
        return null;
    defer graph.deinit();
    return try layoutGraph(alloc, &graph, max_width, styles);
}

fn splitStatements(alloc: Allocator, source: []const u8) MermaidError!Statements {
    var result: Statements = .{};
    errdefer result.deinit(alloc);
    var line_it = std.mem.splitScalar(u8, source, '\n');
    while (line_it.next()) |raw_line| {
        var start: usize = 0;
        var index: usize = 0;
        var quoted = false;
        while (index < raw_line.len) : (index += 1) {
            const byte = raw_line[index];
            if (byte == '"') quoted = !quoted;
            if (!quoted and byte == '%' and index + 1 < raw_line.len and raw_line[index + 1] == '%') {
                try appendStatement(alloc, &result, raw_line[start..index]);
                start = raw_line.len;
                break;
            }
            if (!quoted and byte == ';') {
                try appendStatement(alloc, &result, raw_line[start..index]);
                start = index + 1;
            }
        }
        if (start < raw_line.len) try appendStatement(alloc, &result, raw_line[start..]);
    }
    return result;
}

fn appendStatement(alloc: Allocator, result: *Statements, raw: []const u8) MermaidError!void {
    const value = std.mem.trim(u8, raw, " \t\r");
    if (value.len == 0) return;
    if (result.items.items.len >= max_statements) return error.TooComplex;
    const owned = try alloc.dupe(u8, value);
    errdefer alloc.free(owned);
    try result.items.append(alloc, owned);
}

fn parseFlowchart(alloc: Allocator, source: []const u8) MermaidError!?Graph {
    var statements = try splitStatements(alloc, source);
    defer statements.deinit(alloc);
    if (statements.items.items.len == 0) return null;

    var graph = Graph.init(alloc);
    errdefer graph.deinit();
    graph.direction = directionFromHeader(statements.items.items[0]);

    for (statements.items.items[1..]) |statement| {
        const first = firstWord(statement);
        if (eqlIgnoreCase(first, "subgraph") or eqlIgnoreCase(first, "end") or
            eqlIgnoreCase(first, "classDef") or eqlIgnoreCase(first, "class") or
            eqlIgnoreCase(first, "style") or eqlIgnoreCase(first, "linkStyle") or
            eqlIgnoreCase(first, "click"))
        {
            continue;
        }
        if (eqlIgnoreCase(first, "direction")) {
            graph.direction = directionFromHeader(statement);
            continue;
        }
        try parseFlowStatement(&graph, statement);
    }
    if (graph.nodes.items.len == 0) {
        graph.deinit();
        return null;
    }
    return graph;
}

const ParsedNode = struct { index: usize, end: usize };

fn parseFlowStatement(graph: *Graph, statement: []const u8) MermaidError!void {
    var cursor: usize = 0;
    var previous = (try parseFlowNode(graph, statement, cursor)) orelse return;
    cursor = previous.end;
    while (cursor < statement.len) {
        const link = parseFlowLink(statement, cursor) orelse break;
        const next = (try parseFlowNode(graph, statement, link.end)) orelse break;
        const owned_label = if (link.label) |label| try cleanLabel(graph.alloc, label) else null;
        errdefer if (owned_label) |label| graph.alloc.free(label);
        try graph.addEdge(.{
            .from = if (link.reverse) next.index else previous.index,
            .to = if (link.reverse) previous.index else next.index,
            .label = owned_label,
            .head_to = if (link.reverse) link.head_from else link.head_to,
            .head_from = if (link.reverse) link.head_to else link.head_from,
            .line = link.line,
        });
        previous = next;
        cursor = next.end;
    }
}

fn parseFlowNode(graph: *Graph, statement: []const u8, raw_start: usize) MermaidError!?ParsedNode {
    var index = skipSpace(statement, raw_start);
    const id_start = index;
    while (index < statement.len and isIdByte(statement[index])) : (index += 1) {}
    if (index == id_start) return null;
    const id = statement[id_start..index];
    var shape: Shape = .rect;
    var label: ?[]const u8 = null;

    if (index < statement.len) {
        const open = statement[index];
        const parsed = switch (open) {
            '[' => parseDelimitedLabel(statement, index, '[', ']', .rect),
            '(' => parseDelimitedLabel(statement, index, '(', ')', .round),
            '{' => parseDelimitedLabel(statement, index, '{', '}', .diamond),
            '>' => parseDelimitedLabel(statement, index, '>', ']', .rect),
            else => null,
        };
        if (parsed) |value| {
            shape = value.shape;
            label = value.label;
            index = value.end;
        }
    }
    return .{ .index = try graph.addNode(id, label, shape), .end = index };
}

const DelimitedLabel = struct { label: []const u8, shape: Shape, end: usize };

fn parseDelimitedLabel(
    source: []const u8,
    start: usize,
    open: u8,
    close: u8,
    shape: Shape,
) ?DelimitedLabel {
    var content_start = start + 1;
    var first_closer = close;
    var second_closer: ?u8 = null;
    if (content_start < source.len and source[content_start] == open) {
        content_start += 1;
        second_closer = close;
    } else if (open == '[' and content_start < source.len and source[content_start] == '(') {
        content_start += 1;
        first_closer = ')';
        second_closer = ']';
    } else if (open == '(' and content_start < source.len and source[content_start] == '[') {
        content_start += 1;
        first_closer = ']';
        second_closer = ')';
    }
    var quoted = false;
    var index = content_start;
    while (index < source.len) : (index += 1) {
        if (source[index] == '"') quoted = !quoted;
        if (quoted or source[index] != first_closer) continue;
        if (second_closer) |second| {
            if (index + 1 >= source.len or source[index + 1] != second) continue;
        }
        return .{
            .label = source[content_start..index],
            .shape = shape,
            .end = index + 1 + @intFromBool(second_closer != null),
        };
    }
    return null;
}

const ParsedLink = struct {
    end: usize,
    label: ?[]const u8,
    head_to: Head,
    head_from: Head,
    line: LineKind,
    reverse: bool,
};

fn parseFlowLink(source: []const u8, raw_start: usize) ?ParsedLink {
    var index = skipSpace(source, raw_start);
    var head_from: Head = .none;
    if (index + 1 < source.len and (source[index] == 'o' or source[index] == 'x') and
        isLinkByte(source[index + 1]))
    {
        head_from = if (source[index] == 'o') .circle else .cross;
        index += 1;
    }
    const op_start = index;
    while (index < source.len and isLinkByte(source[index])) : (index += 1) {}
    if (index == op_start) return null;
    const first_op = source[op_start..index];
    var line = lineKind(first_op);
    var head_to: Head = if (std.mem.findScalar(u8, first_op, '>') != null) .arrow else .none;
    if (head_from == .none and std.mem.startsWith(u8, first_op, "<")) head_from = .arrow;
    const reverse = head_from == .arrow and head_to == .none;
    if (head_to == .none and index < source.len and (source[index] == 'o' or source[index] == 'x')) {
        head_to = if (source[index] == 'o') .circle else .cross;
        index += 1;
    }

    if (index < source.len and source[index] == '|') {
        const label_start = index + 1;
        const label_end = std.mem.findScalarPos(u8, source, label_start, '|') orelse return null;
        return .{
            .end = label_end + 1,
            .label = source[label_start..label_end],
            .head_to = head_to,
            .head_from = head_from,
            .line = line,
            .reverse = reverse,
        };
    }

    if (head_to == .none) {
        const text_start = skipSpace(source, index);
        var op2_start = text_start;
        while (op2_start < source.len and !isLinkByte(source[op2_start])) : (op2_start += 1) {}
        if (op2_start > text_start and op2_start < source.len) {
            var op2_end = op2_start;
            while (op2_end < source.len and isLinkByte(source[op2_end])) : (op2_end += 1) {}
            const second_op = source[op2_start..op2_end];
            if (std.mem.findScalar(u8, second_op, '>') != null) head_to = .arrow;
            if (line == .solid) line = lineKind(second_op);
            return .{
                .end = op2_end,
                .label = std.mem.trim(u8, source[text_start..op2_start], " \t"),
                .head_to = head_to,
                .head_from = head_from,
                .line = line,
                .reverse = reverse,
            };
        }
    }

    return .{
        .end = index,
        .label = null,
        .head_to = head_to,
        .head_from = head_from,
        .line = line,
        .reverse = reverse,
    };
}

fn parseState(alloc: Allocator, source: []const u8) MermaidError!?Graph {
    var statements = try splitStatements(alloc, source);
    defer statements.deinit(alloc);
    if (statements.items.items.len == 0) return null;
    var graph = Graph.init(alloc);
    errdefer graph.deinit();
    var marker_id: usize = 0;
    var in_note = false;

    for (statements.items.items[1..]) |statement| {
        const first = firstWord(statement);
        if (eqlIgnoreCase(first, "direction")) {
            graph.direction = directionFromHeader(statement);
            continue;
        }
        if (eqlIgnoreCase(first, "note")) {
            in_note = true;
            continue;
        }
        if (in_note) {
            if (eqlIgnoreCase(first, "end") or eqlIgnoreCase(first, "end note")) in_note = false;
            continue;
        }
        if (eqlIgnoreCase(first, "state")) {
            try parseStateDeclaration(&graph, statement);
            continue;
        }
        if (eqlIgnoreCase(first, "end") or std.mem.eql(u8, statement, "}")) continue;
        if (std.mem.find(u8, statement, "-->") != null or std.mem.find(u8, statement, "--->") != null) {
            try parseStateTransition(&graph, statement, &marker_id);
            continue;
        }
        if (std.mem.findScalar(u8, statement, ':')) |colon| {
            const id = std.mem.trim(u8, statement[0..colon], " \t");
            const label = std.mem.trim(u8, statement[colon + 1 ..], " \t");
            if (id.len > 0 and label.len > 0) _ = try graph.setLabel(id, label, null);
        }
    }
    if (graph.nodes.items.len == 0) {
        graph.deinit();
        return null;
    }
    return graph;
}

fn parseStateDeclaration(graph: *Graph, statement: []const u8) MermaidError!void {
    var rest = std.mem.trim(u8, statement["state".len..], " \t");
    if (rest.len == 0) return;
    if (rest[0] == '"') {
        const close = std.mem.findScalarPos(u8, rest, 1, '"') orelse return;
        const label = rest[1..close];
        const suffix = std.mem.trim(u8, rest[close + 1 ..], " \t");
        if (!startsWithIgnoreCase(suffix, "as ")) return;
        const id = firstWord(std.mem.trim(u8, suffix[3..], " \t"));
        if (id.len > 0) _ = try graph.setLabel(id, label, .round);
        return;
    }
    if (std.mem.find(u8, rest, "<<choice>>")) |choice| {
        rest = std.mem.trim(u8, rest[0..choice], " \t");
        if (rest.len > 0) _ = try graph.addNode(firstWord(rest), null, .diamond);
        return;
    }
    const id = firstWord(rest);
    if (id.len > 0) _ = try graph.addNode(id, null, .round);
}

fn parseStateTransition(graph: *Graph, statement: []const u8, marker_id: *usize) MermaidError!void {
    const arrow = std.mem.find(u8, statement, "-->") orelse std.mem.find(u8, statement, "--->") orelse return;
    var arrow_end = arrow;
    while (arrow_end < statement.len and (statement[arrow_end] == '-' or statement[arrow_end] == '>')) : (arrow_end += 1) {}
    const left_raw = std.mem.trim(u8, statement[0..arrow], " \t");
    var right_raw = std.mem.trim(u8, statement[arrow_end..], " \t");
    var label: ?[]const u8 = null;
    if (std.mem.findScalar(u8, right_raw, ':')) |colon| {
        label = std.mem.trim(u8, right_raw[colon + 1 ..], " \t");
        right_raw = std.mem.trim(u8, right_raw[0..colon], " \t");
    }
    const from = try stateEndpoint(graph, left_raw, true, marker_id);
    const to = try stateEndpoint(graph, right_raw, false, marker_id);
    const owned_label = if (label) |value| try cleanLabel(graph.alloc, value) else null;
    errdefer if (owned_label) |value| graph.alloc.free(value);
    try graph.addEdge(.{ .from = from, .to = to, .label = owned_label });
}

fn stateEndpoint(graph: *Graph, raw: []const u8, source: bool, marker_id: *usize) MermaidError!usize {
    if (std.mem.eql(u8, raw, "[*]")) {
        const id = try std.fmt.allocPrint(graph.alloc, "__mermaid_{s}_{d}", .{ if (source) "start" else "end", marker_id.* });
        defer graph.alloc.free(id);
        marker_id.* += 1;
        return graph.addNode(id, if (source) "●" else "◉", if (source) .start else .finish);
    }
    return graph.addNode(firstWord(raw), null, .round);
}

fn parseClass(alloc: Allocator, source: []const u8) MermaidError!?Graph {
    var statements = try splitStatements(alloc, source);
    defer statements.deinit(alloc);
    if (statements.items.items.len == 0) return null;
    var graph = Graph.init(alloc);
    errdefer graph.deinit();
    var active: ?usize = null;

    for (statements.items.items[1..]) |statement| {
        if (active) |node_index| {
            if (std.mem.eql(u8, statement, "}")) {
                active = null;
            } else {
                try graph.addMember(node_index, statement);
            }
            continue;
        }
        const first = firstWord(statement);
        if (eqlIgnoreCase(first, "direction")) {
            graph.direction = directionFromHeader(statement);
            continue;
        }
        if (eqlIgnoreCase(first, "class")) {
            try parseClassDeclaration(&graph, statement, &active);
            continue;
        }
        if (std.mem.startsWith(u8, statement, "<<")) {
            const close = std.mem.find(u8, statement, ">>") orelse continue;
            const annotation = statement[2..close];
            const id = firstWord(std.mem.trim(u8, statement[close + 2 ..], " \t"));
            if (id.len > 0) {
                const node = try graph.addNode(id, null, .rect);
                const text = try std.fmt.allocPrint(graph.alloc, "«{s}»", .{annotation});
                defer graph.alloc.free(text);
                try graph.addMember(node, text);
            }
            continue;
        }
        if (findClassOperator(statement)) |relation| {
            try parseClassRelation(&graph, statement, relation);
            continue;
        }
        if (std.mem.findScalar(u8, statement, ':')) |colon| {
            const id = std.mem.trim(u8, statement[0..colon], " \t");
            const member = statement[colon + 1 ..];
            if (id.len > 0) try graph.addMember(try graph.addNode(id, null, .rect), member);
        }
    }
    if (graph.nodes.items.len == 0) {
        graph.deinit();
        return null;
    }
    return graph;
}

fn parseClassDeclaration(graph: *Graph, statement: []const u8, active: *?usize) MermaidError!void {
    var rest = std.mem.trim(u8, statement["class".len..], " \t");
    const brace = std.mem.findScalar(u8, rest, '{');
    const decl = if (brace) |at| std.mem.trim(u8, rest[0..at], " \t") else rest;
    if (decl.len == 0) return;
    var id = firstWord(decl);
    var label: ?[]const u8 = null;
    if (std.mem.findScalar(u8, decl, '[')) |open| {
        if (std.mem.findScalarPos(u8, decl, open + 1, ']')) |close| {
            id = std.mem.trim(u8, decl[0..open], " \t");
            label = decl[open + 1 .. close];
        }
    }
    const node = try graph.addNode(id, label, .rect);
    if (brace) |at| {
        rest = std.mem.trim(u8, rest[at + 1 ..], " \t");
        if (std.mem.findScalar(u8, rest, '}')) |close| {
            const inner = std.mem.trim(u8, rest[0..close], " \t");
            if (inner.len > 0) try graph.addMember(node, inner);
        } else {
            active.* = node;
        }
    }
}

const Relation = struct { at: usize, op: []const u8 };

fn findClassOperator(statement: []const u8) ?Relation {
    const operators = [_][]const u8{ "<|..", "..|>", "<|--", "--|>", "*--", "--*", "o--", "--o", "..>", "<..", "-->", "<--", "--" };
    var best: ?Relation = null;
    for (operators) |op| {
        if (std.mem.find(u8, statement, op)) |at| {
            if (best == null or at < best.?.at or (at == best.?.at and op.len > best.?.op.len)) {
                best = .{ .at = at, .op = op };
            }
        }
    }
    return best;
}

fn parseClassRelation(graph: *Graph, statement: []const u8, relation: Relation) MermaidError!void {
    const left_part = std.mem.trim(u8, statement[0..relation.at], " \t");
    var right_part = std.mem.trim(u8, statement[relation.at + relation.op.len ..], " \t");
    var label: ?[]const u8 = null;
    if (std.mem.findScalar(u8, right_part, ':')) |colon| {
        label = std.mem.trim(u8, right_part[colon + 1 ..], " \t");
        right_part = std.mem.trim(u8, right_part[0..colon], " \t");
    }
    const left_id = lastIdentifier(left_part);
    const right_id = firstIdentifier(right_part);
    if (left_id.len == 0 or right_id.len == 0) return;
    const from = try graph.addNode(left_id, null, .rect);
    const to = try graph.addNode(right_id, null, .rect);
    var edge = Edge{
        .from = from,
        .to = to,
        .label = if (label) |value| try cleanLabel(graph.alloc, value) else null,
        .line = if (std.mem.findScalar(u8, relation.op, '.') != null) .dotted else .solid,
        .head_to = .none,
    };
    errdefer edge.deinit(graph.alloc);
    if (std.mem.startsWith(u8, relation.op, "<|")) edge.head_from = .triangle;
    if (std.mem.endsWith(u8, relation.op, "|>")) edge.head_to = .triangle;
    if (std.mem.startsWith(u8, relation.op, "*")) edge.head_from = .diamond_fill;
    if (std.mem.endsWith(u8, relation.op, "*")) edge.head_to = .diamond_fill;
    if (std.mem.startsWith(u8, relation.op, "o")) edge.head_from = .diamond_open;
    if (std.mem.endsWith(u8, relation.op, "o")) edge.head_to = .diamond_open;
    if (std.mem.endsWith(u8, relation.op, ">") and edge.head_to == .none) edge.head_to = .arrow;
    if (std.mem.startsWith(u8, relation.op, "<") and edge.head_from == .none) edge.head_from = .arrow;
    try graph.addEdge(edge);
}

fn parseEr(alloc: Allocator, source: []const u8) MermaidError!?Graph {
    var statements = try splitStatements(alloc, source);
    defer statements.deinit(alloc);
    if (statements.items.items.len == 0) return null;
    var graph = Graph.init(alloc);
    errdefer graph.deinit();
    var active: ?usize = null;

    for (statements.items.items[1..]) |statement| {
        if (active) |node_index| {
            if (std.mem.eql(u8, statement, "}")) {
                active = null;
            } else {
                try graph.addMember(node_index, erAttribute(statement));
            }
            continue;
        }
        if (parseErRelationParts(statement)) |parts| {
            const from = try graph.addNode(parts.left, null, .rect);
            const to = try graph.addNode(parts.right, null, .rect);
            const relation_label = try erRelationLabel(graph.alloc, parts.left_card, parts.label, parts.right_card);
            errdefer if (relation_label) |value| graph.alloc.free(value);
            try graph.addEdge(.{
                .from = from,
                .to = to,
                .label = relation_label,
                .head_to = .none,
                .line = if (std.mem.find(u8, parts.operator, "..") != null) .dotted else .solid,
            });
            continue;
        }
        if (std.mem.findScalar(u8, statement, '{')) |brace| {
            const decl = std.mem.trim(u8, statement[0..brace], " \t");
            const id = firstIdentifier(decl);
            if (id.len > 0) {
                const node = try graph.addNode(id, erAlias(decl), .rect);
                const rest = std.mem.trim(u8, statement[brace + 1 ..], " \t");
                if (std.mem.findScalar(u8, rest, '}')) |close| {
                    const inner = std.mem.trim(u8, rest[0..close], " \t");
                    if (inner.len > 0) try graph.addMember(node, erAttribute(inner));
                } else {
                    active = node;
                }
            }
            continue;
        }
        const id = firstIdentifier(statement);
        if (id.len > 0) _ = try graph.addNode(id, erAlias(statement), .rect);
    }
    if (graph.nodes.items.len == 0) {
        graph.deinit();
        return null;
    }
    return graph;
}

const ErParts = struct {
    left: []const u8,
    left_card: []const u8,
    operator: []const u8,
    right_card: []const u8,
    right: []const u8,
    label: ?[]const u8,
};

fn parseErRelationParts(statement: []const u8) ?ErParts {
    var words = std.mem.tokenizeAny(u8, statement, " \t");
    const left = words.next() orelse return null;
    const op = words.next() orelse return null;
    const right = words.next() orelse return null;
    const split = splitErOperator(op) orelse return null;
    const colon = std.mem.findScalar(u8, statement, ':');
    const label = if (colon) |at| std.mem.trim(u8, statement[at + 1 ..], " \t") else null;
    return .{
        .left = left,
        .left_card = split.left,
        .operator = op,
        .right_card = split.right,
        .right = std.mem.trimEnd(u8, right, ":"),
        .label = label,
    };
}

const ErOperator = struct { left: []const u8, right: []const u8 };

fn splitErOperator(op: []const u8) ?ErOperator {
    const middle = std.mem.find(u8, op, "--") orelse std.mem.find(u8, op, "..") orelse return null;
    if (middle == 0 or middle + 2 >= op.len) return null;
    for (op[0..middle]) |byte| if (!isErCardinalityByte(byte)) return null;
    for (op[middle + 2 ..]) |byte| if (!isErCardinalityByte(byte)) return null;
    return .{ .left = op[0..middle], .right = op[middle + 2 ..] };
}

fn isErCardinalityByte(byte: u8) bool {
    return byte == '|' or byte == 'o' or byte == '{' or byte == '}';
}

fn erRelationLabel(
    alloc: Allocator,
    left: []const u8,
    label: ?[]const u8,
    right: []const u8,
) Allocator.Error!?[]u8 {
    const left_text = erCardinality(left);
    const right_text = erCardinality(right);
    const middle = if (label) |value| try cleanLabel(alloc, value) else null;
    defer if (middle) |value| alloc.free(value);
    const middle_text = middle orelse "";
    if (left_text.len == 0 and middle_text.len == 0 and right_text.len == 0) return null;
    const rendered = if (middle_text.len == 0)
        try std.fmt.allocPrint(alloc, "{s} ↔ {s}", .{ left_text, right_text })
    else
        try std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ left_text, middle_text, right_text });
    return rendered;
}

fn erCardinality(token: []const u8) []const u8 {
    if (std.mem.eql(u8, token, "||")) return "1";
    if (std.mem.eql(u8, token, "o|") or std.mem.eql(u8, token, "|o")) return "0..1";
    if (std.mem.eql(u8, token, "|{") or std.mem.eql(u8, token, "}|")) return "1..*";
    if (std.mem.eql(u8, token, "o{") or std.mem.eql(u8, token, "}o")) return "0..*";
    return token;
}

fn erAlias(statement: []const u8) ?[]const u8 {
    const first_quote = std.mem.findScalar(u8, statement, '"') orelse return null;
    const second_quote = std.mem.findScalarPos(u8, statement, first_quote + 1, '"') orelse return null;
    return statement[first_quote + 1 .. second_quote];
}

fn erAttribute(statement: []const u8) []const u8 {
    return std.mem.trim(u8, statement, " \t");
}

const SequenceItem = union(enum) {
    message: struct {
        from: usize,
        to: usize,
        label: ?[]u8,
        dashed: bool,
        cross: bool,
    },
    note: struct {
        left: usize,
        right: usize,
        label: []u8,
    },
    divider: []u8,

    fn deinit(self: *SequenceItem, alloc: Allocator) void {
        switch (self.*) {
            .message => |message| if (message.label) |label| alloc.free(label),
            .note => |note| alloc.free(note.label),
            .divider => |label| alloc.free(label),
        }
        self.* = undefined;
    }
};

const Sequence = struct {
    alloc: Allocator,
    ids: std.ArrayList([]u8) = .empty,
    labels: std.ArrayList([]u8) = .empty,
    index: std.StringHashMap(usize),
    items: std.ArrayList(SequenceItem) = .empty,

    fn init(alloc: Allocator) Sequence {
        return .{ .alloc = alloc, .index = std.StringHashMap(usize).init(alloc) };
    }

    fn deinit(self: *Sequence) void {
        self.index.deinit();
        for (self.ids.items) |id| self.alloc.free(id);
        for (self.labels.items) |label| self.alloc.free(label);
        for (self.items.items) |*item| item.deinit(self.alloc);
        self.ids.deinit(self.alloc);
        self.labels.deinit(self.alloc);
        self.items.deinit(self.alloc);
        self.* = undefined;
    }

    fn participant(self: *Sequence, id: []const u8, label: ?[]const u8) MermaidError!usize {
        if (self.index.get(id)) |index| {
            if (label) |value| {
                const clean = try cleanLabel(self.alloc, value);
                self.alloc.free(self.labels.items[index]);
                self.labels.items[index] = clean;
            }
            return index;
        }
        if (self.labels.items.len >= max_nodes) return error.TooComplex;
        const owned_id = try self.alloc.dupe(u8, id);
        errdefer self.alloc.free(owned_id);
        const owned_label = try cleanLabel(self.alloc, label orelse id);
        errdefer self.alloc.free(owned_label);
        const index = self.labels.items.len;
        try self.ids.append(self.alloc, owned_id);
        errdefer _ = self.ids.pop();
        try self.labels.append(self.alloc, owned_label);
        errdefer _ = self.labels.pop();
        try self.index.put(owned_id, index);
        return index;
    }
};

fn parseSequence(alloc: Allocator, source: []const u8) MermaidError!?Sequence {
    var statements = try splitStatements(alloc, source);
    defer statements.deinit(alloc);
    if (statements.items.items.len == 0) return null;
    var sequence = Sequence.init(alloc);
    errdefer sequence.deinit();
    var autonumber = false;
    var message_number: usize = 0;
    var blocks: std.ArrayList(bool) = .empty;
    defer blocks.deinit(alloc);

    for (statements.items.items[1..]) |statement| {
        const first = firstWord(statement);
        if (eqlIgnoreCase(first, "participant") or eqlIgnoreCase(first, "actor")) {
            const rest = std.mem.trim(u8, statement[first.len..], " \t");
            if (findAsciiIgnoreCase(rest, " as ")) |as_pos| {
                _ = try sequence.participant(
                    std.mem.trim(u8, rest[0..as_pos], " \t"),
                    std.mem.trim(u8, rest[as_pos + 4 ..], " \t"),
                );
            } else if (rest.len > 0) {
                _ = try sequence.participant(firstWord(rest), null);
            }
            continue;
        }
        if (eqlIgnoreCase(first, "autonumber")) {
            autonumber = true;
            continue;
        }
        if (eqlIgnoreCase(first, "note")) {
            try parseSequenceNote(&sequence, statement[first.len..]);
            continue;
        }
        if (isSequenceDivider(first)) {
            const continuation = isSequenceDividerContinuation(first);
            if (continuation) {
                if (blocks.items.len == 0 or !blocks.items[blocks.items.len - 1]) continue;
            } else {
                try blocks.append(alloc, true);
            }
            if (sequence.items.items.len >= max_edges) return error.TooComplex;
            const label = try cleanLabel(alloc, statement);
            errdefer alloc.free(label);
            try sequence.items.append(alloc, .{ .divider = label });
            continue;
        }
        if (eqlIgnoreCase(first, "end")) {
            const visible = blocks.pop() orelse false;
            if (!visible) continue;
            if (sequence.items.items.len >= max_edges) return error.TooComplex;
            const label = try alloc.dupe(u8, "end");
            errdefer alloc.free(label);
            try sequence.items.append(alloc, .{ .divider = label });
            continue;
        }
        if (eqlIgnoreCase(first, "activate") or eqlIgnoreCase(first, "deactivate") or
            eqlIgnoreCase(first, "create") or eqlIgnoreCase(first, "destroy") or
            eqlIgnoreCase(first, "title"))
        {
            continue;
        }
        if (eqlIgnoreCase(first, "rect") or eqlIgnoreCase(first, "box")) {
            try blocks.append(alloc, false);
            continue;
        }
        try parseSequenceMessage(&sequence, statement, autonumber, &message_number);
    }
    if (sequence.labels.items.len == 0) {
        sequence.deinit();
        return null;
    }
    return sequence;
}

const SequenceOperator = struct { at: usize, text: []const u8, dashed: bool, cross: bool };

fn findSequenceOperator(statement: []const u8) ?SequenceOperator {
    const operators = [_]struct { text: []const u8, dashed: bool, cross: bool }{
        .{ .text = "-->>", .dashed = true, .cross = false },
        .{ .text = "->>", .dashed = false, .cross = false },
        .{ .text = "--x", .dashed = true, .cross = true },
        .{ .text = "-x", .dashed = false, .cross = true },
        .{ .text = "--)", .dashed = true, .cross = false },
        .{ .text = "-)", .dashed = false, .cross = false },
        .{ .text = "-->", .dashed = true, .cross = false },
        .{ .text = "->", .dashed = false, .cross = false },
    };
    var best: ?SequenceOperator = null;
    for (operators) |operator| {
        if (std.mem.find(u8, statement, operator.text)) |at| {
            if (best == null or at < best.?.at or
                (at == best.?.at and operator.text.len > best.?.text.len))
            {
                best = .{ .at = at, .text = operator.text, .dashed = operator.dashed, .cross = operator.cross };
            }
        }
    }
    return best;
}

fn parseSequenceMessage(
    sequence: *Sequence,
    statement: []const u8,
    autonumber: bool,
    message_number: *usize,
) MermaidError!void {
    const operator = findSequenceOperator(statement) orelse return;
    const from_id = std.mem.trim(u8, statement[0..operator.at], " \t");
    var right = std.mem.trim(u8, statement[operator.at + operator.text.len ..], " \t+-");
    var label: ?[]const u8 = null;
    if (std.mem.findScalar(u8, right, ':')) |colon| {
        label = std.mem.trim(u8, right[colon + 1 ..], " \t");
        right = std.mem.trim(u8, right[0..colon], " \t");
    }
    if (from_id.len == 0 or right.len == 0) return;
    const from = try sequence.participant(from_id, null);
    const to = try sequence.participant(right, null);
    var owned_label: ?[]u8 = null;
    if (autonumber) {
        message_number.* += 1;
        owned_label = if (label) |value| blk: {
            const clean = try cleanLabel(sequence.alloc, value);
            defer sequence.alloc.free(clean);
            break :blk try std.fmt.allocPrint(sequence.alloc, "{d}. {s}", .{ message_number.*, clean });
        } else try std.fmt.allocPrint(sequence.alloc, "{d}.", .{message_number.*});
    } else if (label) |value| {
        owned_label = try cleanLabel(sequence.alloc, value);
    }
    errdefer if (owned_label) |value| sequence.alloc.free(value);
    if (sequence.items.items.len >= max_edges) return error.TooComplex;
    try sequence.items.append(sequence.alloc, .{ .message = .{
        .from = from,
        .to = to,
        .label = owned_label,
        .dashed = operator.dashed,
        .cross = operator.cross,
    } });
}

fn parseSequenceNote(sequence: *Sequence, raw: []const u8) MermaidError!void {
    const rest = std.mem.trim(u8, raw, " \t");
    const colon = std.mem.findScalar(u8, rest, ':') orelse return;
    const anchor = std.mem.trim(u8, rest[0..colon], " \t");
    const label = std.mem.trim(u8, rest[colon + 1 ..], " \t");
    var ids: []const u8 = undefined;
    if (startsWithIgnoreCase(anchor, "over ")) {
        ids = std.mem.trim(u8, anchor[5..], " \t");
    } else if (startsWithIgnoreCase(anchor, "left of ")) {
        ids = std.mem.trim(u8, anchor[8..], " \t");
    } else if (startsWithIgnoreCase(anchor, "right of ")) {
        ids = std.mem.trim(u8, anchor[9..], " \t");
    } else return;
    const comma = std.mem.findScalar(u8, ids, ',');
    const first_id = std.mem.trim(u8, if (comma) |at| ids[0..at] else ids, " \t");
    const second_id = std.mem.trim(u8, if (comma) |at| ids[at + 1 ..] else first_id, " \t");
    const first = try sequence.participant(first_id, null);
    const second = try sequence.participant(second_id, null);
    if (sequence.items.items.len >= max_edges) return error.TooComplex;
    const owned_label = try cleanLabel(sequence.alloc, label);
    errdefer sequence.alloc.free(owned_label);
    try sequence.items.append(sequence.alloc, .{ .note = .{
        .left = @min(first, second),
        .right = @max(first, second),
        .label = owned_label,
    } });
}

fn isSequenceDivider(first: []const u8) bool {
    return eqlIgnoreCase(first, "loop") or eqlIgnoreCase(first, "alt") or
        eqlIgnoreCase(first, "opt") or eqlIgnoreCase(first, "par") or
        eqlIgnoreCase(first, "critical") or eqlIgnoreCase(first, "break") or
        eqlIgnoreCase(first, "else") or eqlIgnoreCase(first, "and") or
        eqlIgnoreCase(first, "option");
}

fn isSequenceDividerContinuation(first: []const u8) bool {
    return eqlIgnoreCase(first, "else") or eqlIgnoreCase(first, "and") or
        eqlIgnoreCase(first, "option");
}

const CellClass = enum { empty, border, text, edge, edge_label };

const Cell = struct {
    glyph: []const u8 = " ",
    class: CellClass = .empty,
    mask: u8 = 0,
    line: LineKind = .solid,
    occupied: bool = false,
};

const up_bit: u8 = 1;
const down_bit: u8 = 2;
const left_bit: u8 = 4;
const right_bit: u8 = 8;

const Canvas = struct {
    alloc: Allocator,
    width: usize,
    height: usize,
    cells: []Cell,
    current_line: LineKind = .solid,

    fn init(alloc: Allocator, width: usize, height: usize) MermaidError!Canvas {
        if (width == 0 or height == 0 or width > max_canvas_cells / height) return error.TooComplex;
        const cells = try alloc.alloc(Cell, width * height);
        @memset(cells, .{});
        return .{ .alloc = alloc, .width = width, .height = height, .cells = cells };
    }

    fn deinit(self: *Canvas) void {
        self.alloc.free(self.cells);
        self.* = undefined;
    }

    fn at(self: *Canvas, x: usize, y: usize) ?*Cell {
        if (x >= self.width or y >= self.height) return null;
        return &self.cells[y * self.width + x];
    }

    fn set(self: *Canvas, x: usize, y: usize, glyph: []const u8, class: CellClass) void {
        const cell = self.at(x, y) orelse return;
        cell.glyph = glyph;
        cell.class = class;
        cell.mask = 0;
    }

    fn addBits(self: *Canvas, x: usize, y: usize, bits: u8) void {
        const cell = self.at(x, y) orelse return;
        if (cell.occupied) return;
        const had_mask = cell.mask != 0;
        cell.mask |= bits;
        cell.line = if (had_mask) mergeLineKind(cell.line, self.current_line) else self.current_line;
        if (cell.class != .border) cell.class = .edge;
    }

    fn junction(self: *Canvas, x: usize, y: usize, bits: u8) void {
        const cell = self.at(x, y) orelse return;
        if (cell.mask == 0) cell.line = self.current_line;
        cell.mask |= bits;
        if (cell.class != .border) cell.class = .edge;
    }

    fn horizontal(self: *Canvas, y: usize, raw_x0: usize, raw_x1: usize) void {
        const x0 = @min(raw_x0, raw_x1);
        const x1 = @max(raw_x0, raw_x1);
        var x = x0;
        while (x <= x1) : (x += 1) {
            var bits: u8 = 0;
            if (x > x0) bits |= left_bit;
            if (x < x1) bits |= right_bit;
            self.addBits(x, y, bits);
        }
    }

    fn vertical(self: *Canvas, x: usize, raw_y0: usize, raw_y1: usize) void {
        const y0 = @min(raw_y0, raw_y1);
        const y1 = @max(raw_y0, raw_y1);
        var y = y0;
        while (y <= y1) : (y += 1) {
            var bits: u8 = 0;
            if (y > y0) bits |= up_bit;
            if (y < y1) bits |= down_bit;
            self.addBits(x, y, bits);
        }
    }

    fn finalize(self: *Canvas) void {
        for (self.cells) |*cell| {
            if (cell.mask == 0 or !std.mem.eql(u8, cell.glyph, " ")) continue;
            const glyph = maskGlyph(cell.mask);
            cell.glyph = switch (cell.line) {
                .solid => glyph,
                .dotted => dottedGlyph(glyph),
                .thick => thickGlyph(glyph),
            };
        }
    }

    fn flipVertical(self: *Canvas) void {
        var y: usize = 0;
        while (y < self.height / 2) : (y += 1) {
            const other = self.height - 1 - y;
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                std.mem.swap(Cell, &self.cells[y * self.width + x], &self.cells[other * self.width + x]);
            }
        }
        for (self.cells) |*cell| cell.glyph = flipGlyphVertical(cell.glyph);
    }

    fn flipHorizontal(self: *Canvas) void {
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width / 2) : (x += 1) {
                const other = self.width - 1 - x;
                std.mem.swap(Cell, &self.cells[y * self.width + x], &self.cells[y * self.width + other]);
            }
            for (self.cells[y * self.width .. (y + 1) * self.width]) |*cell| {
                cell.glyph = flipGlyphHorizontal(cell.glyph);
            }
            x = 0;
            while (x < self.width) {
                const class = self.cells[y * self.width + x].class;
                if (class != .text and class != .edge_label) {
                    x += 1;
                    continue;
                }
                const start = x;
                while (x < self.width and self.cells[y * self.width + x].class == class) : (x += 1) {}
                std.mem.reverse(Cell, self.cells[y * self.width + start .. y * self.width + x]);
            }
        }
    }

    fn toOwnedBytes(self: *Canvas, styles: Styles) Allocator.Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.alloc);
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var last: usize = 0;
            var x = self.width;
            while (x > 0) {
                x -= 1;
                const cell = self.cells[y * self.width + x];
                if (!std.mem.eql(u8, cell.glyph, " ") and cell.glyph.len > 0) {
                    last = x + 1;
                    break;
                }
            }
            var active_dim = false;
            x = 0;
            while (x < last) : (x += 1) {
                const cell = self.cells[y * self.width + x];
                if (cell.glyph.len == 0) continue;
                const want_dim = (cell.class == .border or cell.class == .edge) and
                    styles.dim.len > 0 and styles.reset.len > 0;
                if (want_dim != active_dim) {
                    try output.appendSlice(self.alloc, if (want_dim) styles.dim else styles.reset);
                    active_dim = want_dim;
                }
                try output.appendSlice(self.alloc, cell.glyph);
            }
            if (active_dim) try output.appendSlice(self.alloc, styles.reset);
            try output.append(self.alloc, '\n');
        }
        return output.toOwnedSlice(self.alloc);
    }
};

const Wrapped = struct {
    lines: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Wrapped, alloc: Allocator) void {
        for (self.lines.items) |line| alloc.free(line);
        self.lines.deinit(alloc);
        self.* = undefined;
    }
};

const NodeLayout = struct {
    x: usize = 0,
    y: usize = 0,
    width: usize,
    height: usize,
    center_x: usize = 0,
    center_y: usize = 0,
    rank: usize = 0,
    wrapped: Wrapped,

    fn deinit(self: *NodeLayout, alloc: Allocator) void {
        self.wrapped.deinit(alloc);
    }
};

fn layoutGraph(alloc: Allocator, graph: *const Graph, max_width: usize, styles: Styles) MermaidError!?[]u8 {
    if (graph.nodes.items.len == 0) return null;
    const ranks = try computeRanks(alloc, graph);
    defer alloc.free(ranks);
    var max_rank: usize = 0;
    for (ranks) |rank| max_rank = @max(max_rank, rank);

    const layouts = try alloc.alloc(NodeLayout, graph.nodes.items.len);
    var initialized: usize = 0;
    defer {
        for (layouts[0..initialized]) |*layout| layout.deinit(alloc);
        alloc.free(layouts);
    }
    for (graph.nodes.items, 0..) |node, index| {
        var wrapped = try wrapLabel(alloc, node.label);
        errdefer wrapped.deinit(alloc);
        var content_width: usize = 1;
        for (wrapped.lines.items) |line| content_width = @max(content_width, display_width.visibleWidth(line));
        for (node.members.items) |member| content_width = @max(content_width, @min(wrap_width, display_width.visibleWidth(member)));
        const marker = node.shape == .start or node.shape == .finish;
        layouts[index] = .{
            .width = if (marker) 1 else content_width + 2 * pad + 2,
            .height = if (marker) 1 else wrapped.lines.items.len + 2 + if (node.members.items.len > 0) node.members.items.len + 1 else 0,
            .wrapped = wrapped,
            .rank = ranks[index],
        };
        initialized += 1;
    }

    const rows = try alloc.alloc(std.ArrayList(usize), max_rank + 1);
    defer {
        for (rows) |*row| row.deinit(alloc);
        alloc.free(rows);
    }
    for (rows) |*row| row.* = .empty;
    for (ranks, 0..) |rank, index| try rows[rank].append(alloc, index);

    const vertical = graph.direction == .down or graph.direction == .up;
    var diagram_width: usize = 1;
    var diagram_height: usize = 1;
    if (vertical) {
        var row_widths = try alloc.alloc(usize, rows.len);
        defer alloc.free(row_widths);
        var row_heights = try alloc.alloc(usize, rows.len);
        defer alloc.free(row_heights);
        for (rows, 0..) |row, rank| {
            var width: usize = 0;
            var height: usize = 1;
            for (row.items, 0..) |node_index, position| {
                if (position > 0) width += gap_x;
                width += layouts[node_index].width;
                height = @max(height, layouts[node_index].height);
            }
            row_widths[rank] = width;
            row_heights[rank] = height;
            diagram_width = @max(diagram_width, width);
        }
        var label_margin: usize = 0;
        for (graph.edges.items) |edge| {
            if (edge.label) |label| {
                label_margin = @max(label_margin, @min(wrap_width, display_width.visibleWidth(label)) + 1);
            }
        }
        diagram_width += label_margin;
        var y: usize = 0;
        for (rows, 0..) |row, rank| {
            var x = (diagram_width - row_widths[rank]) / 2;
            for (row.items) |node_index| {
                layouts[node_index].x = x;
                layouts[node_index].y = y + (row_heights[rank] - layouts[node_index].height) / 2;
                layouts[node_index].center_x = x + layouts[node_index].width / 2;
                layouts[node_index].center_y = layouts[node_index].y + layouts[node_index].height / 2;
                x += layouts[node_index].width + gap_x;
            }
            y += row_heights[rank];
            if (rank < max_rank) y += gap_y;
        }
        diagram_height = y;
    } else {
        var top_margin: usize = 0;
        var rank_gap: usize = gap_x + 2;
        for (graph.edges.items) |edge| {
            if (edge.label) |label| {
                top_margin = 2;
                rank_gap = @max(rank_gap, @min(wrap_width, display_width.visibleWidth(label)) + 3);
            }
        }
        var col_widths = try alloc.alloc(usize, rows.len);
        defer alloc.free(col_widths);
        var col_heights = try alloc.alloc(usize, rows.len);
        defer alloc.free(col_heights);
        for (rows, 0..) |row, rank| {
            var width: usize = 1;
            var height: usize = 0;
            for (row.items, 0..) |node_index, position| {
                width = @max(width, layouts[node_index].width);
                if (position > 0) height += 1;
                height += layouts[node_index].height;
            }
            col_widths[rank] = width;
            col_heights[rank] = height;
            diagram_height = @max(diagram_height, height);
        }
        var x: usize = 0;
        for (rows, 0..) |row, rank| {
            var y = (diagram_height - col_heights[rank]) / 2;
            for (row.items) |node_index| {
                layouts[node_index].x = x + (col_widths[rank] - layouts[node_index].width) / 2;
                layouts[node_index].y = top_margin + y;
                layouts[node_index].center_x = layouts[node_index].x + layouts[node_index].width / 2;
                layouts[node_index].center_y = layouts[node_index].y + layouts[node_index].height / 2;
                y += layouts[node_index].height + 1;
            }
            x += col_widths[rank];
            if (rank < max_rank) x += rank_gap;
        }
        diagram_width = x;
        diagram_height += top_margin;
    }

    var back_edges: usize = 0;
    for (graph.edges.items) |edge| {
        if (edge.from == edge.to or ranks[edge.to] <= ranks[edge.from]) back_edges += 1;
    }
    var canvas_width = diagram_width;
    var canvas_height = diagram_height;
    if (vertical and back_edges > 0) canvas_width += 2 + back_edges * 2;
    if (!vertical and back_edges > 0) canvas_height += 1 + back_edges * 2;
    if (canvas_width > max_width or canvas_width == 0 or canvas_height == 0 or
        canvas_width > max_canvas_cells / canvas_height)
    {
        return null;
    }

    var canvas = try Canvas.init(alloc, canvas_width, canvas_height);
    defer canvas.deinit();
    for (graph.nodes.items, layouts) |node, layout| drawNode(&canvas, node, layout);

    var back_index: usize = 0;
    for (graph.edges.items) |edge| {
        canvas.current_line = edge.line;
        const from = layouts[edge.from];
        const to = layouts[edge.to];
        if (edge.from == edge.to) {
            drawSelfEdge(&canvas, from, edge);
        } else if (ranks[edge.to] > ranks[edge.from]) {
            if (vertical) drawForwardVertical(&canvas, from, to, edge) else drawForwardHorizontal(&canvas, from, to, edge);
        } else {
            if (vertical) {
                drawBackVertical(&canvas, from, to, edge, diagram_width + 1 + back_index * 2);
            } else {
                drawBackHorizontal(&canvas, from, to, edge, diagram_height + 1 + back_index * 2);
            }
            back_index += 1;
        }
    }
    canvas.finalize();
    if (graph.direction == .up) canvas.flipVertical();
    if (graph.direction == .left) canvas.flipHorizontal();
    return try canvas.toOwnedBytes(styles);
}

fn computeRanks(alloc: Allocator, graph: *const Graph) Allocator.Error![]usize {
    const count = graph.nodes.items.len;
    const ranks = try alloc.alloc(usize, count);
    errdefer alloc.free(ranks);
    @memset(ranks, 0);
    const indegree = try alloc.alloc(usize, count);
    defer alloc.free(indegree);
    @memset(indegree, 0);
    for (graph.edges.items) |edge| if (edge.from != edge.to) {
        indegree[edge.to] += 1;
    };
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(alloc);
    for (indegree, 0..) |degree, index| if (degree == 0) try queue.append(alloc, index);
    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const node = queue.items[cursor];
        for (graph.edges.items) |edge| {
            if (edge.from != node or edge.from == edge.to) continue;
            ranks[edge.to] = @max(ranks[edge.to], ranks[node] + 1);
            indegree[edge.to] -= 1;
            if (indegree[edge.to] == 0) try queue.append(alloc, edge.to);
        }
    }
    // Cyclic components stay at rank zero. This keeps layout bounded and their
    // edges are routed through the explicit back-edge lanes.
    return ranks;
}

fn drawNode(canvas: *Canvas, node: Node, layout: NodeLayout) void {
    if (node.shape == .start or node.shape == .finish) {
        canvas.set(layout.x, layout.y, if (node.shape == .start) "●" else "◉", .border);
        if (canvas.at(layout.x, layout.y)) |cell| cell.occupied = true;
        return;
    }
    const right = layout.x + layout.width - 1;
    const bottom = layout.y + layout.height - 1;
    const rounded = node.shape == .round or node.shape == .diamond;
    canvas.set(layout.x, layout.y, if (rounded) "╭" else "┌", .border);
    canvas.set(right, layout.y, if (rounded) "╮" else "┐", .border);
    canvas.set(layout.x, bottom, if (rounded) "╰" else "└", .border);
    canvas.set(right, bottom, if (rounded) "╯" else "┘", .border);
    var x = layout.x + 1;
    while (x < right) : (x += 1) {
        canvas.set(x, layout.y, "─", .border);
        canvas.set(x, bottom, "─", .border);
    }
    var y = layout.y + 1;
    while (y < bottom) : (y += 1) {
        canvas.set(layout.x, y, "│", .border);
        canvas.set(right, y, "│", .border);
    }
    y = layout.y;
    while (y <= bottom) : (y += 1) {
        x = layout.x;
        while (x <= right) : (x += 1) {
            if (canvas.at(x, y)) |cell| cell.occupied = true;
        }
    }

    const inner_width = layout.width - 2 * pad - 2;
    for (layout.wrapped.lines.items, 0..) |line, line_index| {
        const text = fitLabel(line, inner_width);
        const text_width = display_width.visibleWidth(text);
        drawText(canvas, text, layout.x + 1 + pad + (inner_width -| text_width) / 2, layout.y + 1 + line_index, .text);
    }
    if (node.members.items.len > 0) {
        const divider_y = layout.y + 1 + layout.wrapped.lines.items.len;
        canvas.set(layout.x, divider_y, "├", .border);
        canvas.set(right, divider_y, "┤", .border);
        x = layout.x + 1;
        while (x < right) : (x += 1) canvas.set(x, divider_y, "─", .border);
        for (node.members.items, 0..) |member, member_index| {
            drawText(canvas, fitLabel(member, inner_width), layout.x + 1 + pad, divider_y + 1 + member_index, .text);
        }
    }
}

fn drawForwardVertical(canvas: *Canvas, from: NodeLayout, to: NodeLayout, edge: Edge) void {
    const start_y = from.y + from.height - 1;
    if (to.y == 0 or to.y <= start_y) return;
    const end_y = to.y - 1;
    const bus_y = start_y + (end_y - start_y) / 2;
    canvas.junction(from.center_x, start_y, down_bit);
    canvas.vertical(from.center_x, start_y, bus_y);
    canvas.horizontal(bus_y, from.center_x, to.center_x);
    canvas.vertical(to.center_x, bus_y, end_y);
    drawHead(canvas, to.center_x, end_y, edge.head_to, "▼", up_bit);
    if (edge.head_from != .none) drawHead(canvas, from.center_x, start_y, edge.head_from, "▲", down_bit);
    if (edge.label) |label| drawEdgeLabel(canvas, label, bus_y, @min(from.center_x, to.center_x) + 1);
}

fn drawForwardHorizontal(canvas: *Canvas, from: NodeLayout, to: NodeLayout, edge: Edge) void {
    const start_x = from.x + from.width - 1;
    if (to.x == 0 or to.x <= start_x) return;
    const end_x = to.x - 1;
    const bus_x = start_x + (end_x - start_x) / 2;
    canvas.junction(start_x, from.center_y, right_bit);
    canvas.horizontal(from.center_y, start_x, bus_x);
    canvas.vertical(bus_x, from.center_y, to.center_y);
    canvas.horizontal(to.center_y, bus_x, end_x);
    drawHead(canvas, end_x, to.center_y, edge.head_to, "▶", left_bit);
    if (edge.head_from != .none) drawHead(canvas, start_x, from.center_y, edge.head_from, "◄", right_bit);
    if (edge.label) |label| {
        const label_width = end_x -| start_x -| 1;
        const fitted = fitLabel(label, label_width);
        const label_x = start_x + 1 + (label_width -| display_width.visibleWidth(fitted)) / 2;
        drawText(canvas, fitted, label_x, @min(from.center_y, to.center_y) -| 2, .edge_label);
    }
}

fn drawBackVertical(canvas: *Canvas, from: NodeLayout, to: NodeLayout, edge: Edge, lane_x: usize) void {
    const from_x = from.x + from.width - 1;
    const to_x = to.x + to.width - 1;
    canvas.junction(from_x, from.center_y, right_bit);
    canvas.horizontal(from.center_y, from_x, lane_x);
    canvas.vertical(lane_x, from.center_y, to.center_y);
    canvas.horizontal(to.center_y, to_x + 1, lane_x);
    drawHead(canvas, to_x + 1, to.center_y, edge.head_to, "◄", right_bit);
    if (edge.label) |label| drawEdgeLabel(canvas, label, @min(from.center_y, to.center_y), lane_x + 1);
}

fn drawBackHorizontal(canvas: *Canvas, from: NodeLayout, to: NodeLayout, edge: Edge, lane_y: usize) void {
    const from_y = from.y + from.height - 1;
    const to_y = to.y + to.height - 1;
    canvas.junction(from.center_x, from_y, down_bit);
    canvas.vertical(from.center_x, from_y, lane_y);
    canvas.horizontal(lane_y, from.center_x, to.center_x);
    canvas.vertical(to.center_x, lane_y, to_y + 1);
    drawHead(canvas, to.center_x, to_y + 1, edge.head_to, "▲", down_bit);
    if (edge.label) |label| drawEdgeLabel(canvas, label, lane_y, @min(from.center_x, to.center_x) + 1);
}

fn drawSelfEdge(canvas: *Canvas, node: NodeLayout, edge: Edge) void {
    const right = node.x + node.width - 1;
    if (right + 3 >= canvas.width) return;
    canvas.junction(right, node.center_y, right_bit);
    canvas.horizontal(node.center_y, right, right + 2);
    if (node.center_y + 2 < canvas.height) {
        canvas.vertical(right + 2, node.center_y, node.center_y + 2);
        canvas.horizontal(node.center_y + 2, right, right + 2);
        drawHead(canvas, right + 1, node.center_y + 2, edge.head_to, "◄", right_bit);
        if (edge.label) |label| drawEdgeLabel(canvas, label, node.center_y + 1, right + 3);
    }
}

fn drawHead(canvas: *Canvas, x: usize, y: usize, head: Head, arrow: []const u8, continuation: u8) void {
    if (head == .none) {
        canvas.addBits(x, y, continuation);
        return;
    }
    canvas.set(x, y, switch (head) {
        .none => arrow,
        .arrow => arrow,
        .circle => "o",
        .cross => "×",
        .triangle => if (std.mem.eql(u8, arrow, "▼")) "▽" else if (std.mem.eql(u8, arrow, "▲")) "△" else if (std.mem.eql(u8, arrow, "◄")) "◁" else "▷",
        .diamond_fill => "◆",
        .diamond_open => "◇",
    }, .edge);
}

fn drawEdgeLabel(canvas: *Canvas, label: []const u8, y: usize, x: usize) void {
    if (y >= canvas.height or x >= canvas.width) return;
    drawText(canvas, fitLabel(label, @min(wrap_width, canvas.width - x)), x, y, .edge_label);
}

fn layoutSequence(alloc: Allocator, sequence: *const Sequence, max_width: usize, styles: Styles) MermaidError!?[]u8 {
    const count = sequence.labels.items.len;
    if (count == 0) return null;
    const widths = try alloc.alloc(usize, count);
    defer alloc.free(widths);
    const centers = try alloc.alloc(usize, count);
    defer alloc.free(centers);
    for (sequence.labels.items, 0..) |label, index| widths[index] = @min(wrap_width, display_width.visibleWidth(label)) + 4;
    centers[0] = widths[0] / 2;
    var index: usize = 1;
    while (index < count) : (index += 1) {
        centers[index] = centers[index - 1] + @max(@as(usize, 8), widths[index - 1] / 2 + widths[index] / 2 + 2);
    }
    var canvas_width = centers[count - 1] + (widths[count - 1] + 1) / 2 + 1;
    var rows: usize = 4;
    for (sequence.items.items) |item| {
        rows += switch (item) {
            .message => |message| if (message.from == message.to) 4 else if (message.label != null) 3 else 2,
            .note => 4,
            .divider => 2,
        };
    }
    const bottom_y = rows;
    const canvas_height = bottom_y + 3;
    for (sequence.items.items) |item| switch (item) {
        .message => |message| if (message.from == message.to) {
            const label_width = if (message.label) |label| display_width.visibleWidth(label) else 0;
            canvas_width = @max(canvas_width, centers[message.from] + 6 + label_width);
        },
        .note => |note| {
            const note_width = @min(wrap_width, display_width.visibleWidth(note.label)) + 4;
            canvas_width = @max(canvas_width, (centers[note.left] + centers[note.right]) / 2 + note_width / 2 + 1);
        },
        .divider => |label| canvas_width = @max(canvas_width, @min(wrap_width, display_width.visibleWidth(label)) + 4),
    };
    if (canvas_width > max_width or canvas_width > max_canvas_cells / canvas_height) return null;
    var canvas = try Canvas.init(alloc, canvas_width, canvas_height);
    defer canvas.deinit();

    for (sequence.labels.items, 0..) |label, participant| {
        const actor_x = centers[participant] - widths[participant] / 2;
        drawSingleLineBox(&canvas, label, actor_x, 0, widths[participant]);
        drawSingleLineBox(&canvas, label, actor_x, bottom_y, widths[participant]);
        canvas.vertical(centers[participant], 2, bottom_y);
    }

    var y: usize = 4;
    for (sequence.items.items) |item| switch (item) {
        .message => |message| {
            const from_x = centers[message.from];
            const to_x = centers[message.to];
            if (from_x == to_x) {
                canvas.set(from_x + 1, y, if (message.dashed) "╌" else "─", .edge);
                canvas.set(from_x + 2, y, if (message.dashed) "╌" else "─", .edge);
                canvas.set(from_x + 3, y, "╮", .edge);
                canvas.set(from_x + 3, y + 1, "│", .edge);
                canvas.set(from_x + 3, y + 2, "╯", .edge);
                canvas.set(from_x + 2, y + 2, if (message.dashed) "╌" else "─", .edge);
                canvas.set(from_x + 1, y + 2, if (message.cross) "×" else "◄", .edge);
                if (message.label) |label| drawText(&canvas, fitLabel(label, wrap_width), from_x + 5, y + 1, .text);
                y += 4;
            } else {
                const low = @min(from_x, to_x);
                const high = @max(from_x, to_x);
                const arrow_y = y + if (message.label != null) @as(usize, 1) else 0;
                var x = low + 1;
                while (x < high) : (x += 1) canvas.set(x, arrow_y, if (message.dashed) "╌" else "─", .edge);
                const rightward = to_x > from_x;
                canvas.set(if (rightward) to_x - 1 else to_x + 1, arrow_y, if (message.cross) "×" else if (rightward) "▶" else "◄", .edge);
                if (message.label) |label| {
                    const fitted = fitLabel(label, high - low -| 2);
                    drawText(&canvas, fitted, low + 1 + (high - low -| 2 -| display_width.visibleWidth(fitted)) / 2, y, .text);
                }
                y += if (message.label != null) 3 else 2;
            }
        },
        .note => |note| {
            const note_width = @min(wrap_width, display_width.visibleWidth(note.label)) + 4;
            const center = (centers[note.left] + centers[note.right]) / 2;
            drawSingleLineBox(&canvas, note.label, center -| note_width / 2, y, note_width);
            y += 4;
        },
        .divider => |label| {
            var x: usize = 0;
            while (x < canvas.width) : (x += 1) canvas.set(x, y, "─", .edge);
            const fitted = fitLabel(label, canvas.width -| 4);
            drawText(&canvas, fitted, 2, y, .edge_label);
            y += 2;
        },
    };
    return try canvas.toOwnedBytes(styles);
}

fn drawSingleLineBox(canvas: *Canvas, label: []const u8, x: usize, y: usize, width: usize) void {
    if (width < 4 or x + width > canvas.width or y + 2 >= canvas.height) return;
    const right = x + width - 1;
    canvas.set(x, y, "┌", .border);
    canvas.set(right, y, "┐", .border);
    canvas.set(x, y + 1, "│", .border);
    canvas.set(right, y + 1, "│", .border);
    canvas.set(x, y + 2, "└", .border);
    canvas.set(right, y + 2, "┘", .border);
    var col = x + 1;
    while (col < right) : (col += 1) {
        canvas.set(col, y, "─", .border);
        canvas.set(col, y + 2, "─", .border);
    }
    var row = y;
    while (row <= y + 2) : (row += 1) {
        col = x;
        while (col <= right) : (col += 1) {
            if (canvas.at(col, row)) |cell| cell.occupied = true;
        }
    }
    const fitted = fitLabel(label, width - 4);
    const label_width = display_width.visibleWidth(fitted);
    drawText(canvas, fitted, x + 2 + (width - 4 -| label_width) / 2, y + 1, .text);
}

fn wrapLabel(alloc: Allocator, label: []const u8) Allocator.Error!Wrapped {
    var result: Wrapped = .{};
    errdefer result.deinit(alloc);
    var rest = std.mem.trim(u8, label, " \t\r\n");
    while (rest.len > 0 and result.lines.items.len < max_label_lines) {
        var prefix = display_width.prefixByWidth(rest, wrap_width);
        if (prefix.len == 0) {
            const unit = display_width.displayUnitAt(rest, 0);
            prefix = rest[0..@max(@as(usize, 1), unit.byte_len)];
        }
        if (prefix.len < rest.len) {
            if (std.mem.lastIndexOfScalar(u8, prefix, ' ')) |space| {
                if (space > 0) prefix = prefix[0..space];
            }
        }
        const line = std.mem.trim(u8, prefix, " \t");
        const owned = try alloc.dupe(u8, line);
        errdefer alloc.free(owned);
        try result.lines.append(alloc, owned);
        rest = std.mem.trimStart(u8, rest[prefix.len..], " \t");
    }
    if (result.lines.items.len == 0) {
        const empty = try alloc.dupe(u8, "");
        errdefer alloc.free(empty);
        try result.lines.append(alloc, empty);
    }
    if (rest.len > 0) {
        const last = result.lines.items.len - 1;
        const fitted = try fitLabelOwned(alloc, result.lines.items[last], wrap_width - 1);
        defer alloc.free(fitted);
        const truncated = try std.fmt.allocPrint(alloc, "{s}…", .{fitted});
        alloc.free(result.lines.items[last]);
        result.lines.items[last] = truncated;
    }
    return result;
}

fn fitLabel(label: []const u8, width: usize) []const u8 {
    if (width == 0) return "";
    return display_width.prefixByWidth(label, width);
}

fn fitLabelOwned(alloc: Allocator, label: []const u8, width: usize) Allocator.Error![]u8 {
    return alloc.dupe(u8, fitLabel(label, width));
}

fn drawText(canvas: *Canvas, text: []const u8, start_x: usize, y: usize, class: CellClass) void {
    var source_index: usize = 0;
    var x = start_x;
    while (source_index < text.len and x < canvas.width and y < canvas.height) {
        const unit = display_width.displayUnitAt(text, source_index);
        if (unit.byte_len == 0) break;
        const cell_width = @max(@as(usize, 1), unit.cell_width);
        if (x + cell_width > canvas.width) break;
        canvas.set(x, y, text[source_index .. source_index + unit.byte_len], class);
        if (canvas.at(x, y)) |cell| cell.occupied = true;
        var continuation: usize = 1;
        while (continuation < cell_width) : (continuation += 1) {
            canvas.set(x + continuation, y, "", class);
            if (canvas.at(x + continuation, y)) |cell| cell.occupied = true;
        }
        x += cell_width;
        source_index += unit.byte_len;
    }
}

fn cleanLabel(alloc: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
        (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        value = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    }
    if (value.len >= 2 and value[0] == '`' and value[value.len - 1] == '`') {
        value = value[1 .. value.len - 1];
    }
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '<') {
            if (std.mem.findScalarPos(u8, value, index + 1, '>')) |close| {
                const tag = std.mem.trim(u8, value[index + 1 .. close], " /\t");
                const name = firstWord(tag);
                if (eqlIgnoreCase(name, "br")) {
                    try output.append(alloc, ' ');
                    index = close + 1;
                    continue;
                }
                if (isFormattingTag(name)) {
                    index = close + 1;
                    continue;
                }
            }
        }
        if (value[index] == '&') {
            if (decodeEntity(value[index..])) |entity| {
                try appendCodepoint(alloc, &output, entity.codepoint);
                index += entity.bytes;
                continue;
            }
        }
        const byte = value[index];
        if (byte < 0x20 or byte == 0x7f) {
            index += 1;
            continue;
        }
        if ((byte == '*' or byte == '`') or
            (byte == '_' and (index == 0 or index + 1 == value.len or !std.ascii.isAlphanumeric(value[index - 1]) or !std.ascii.isAlphanumeric(value[index + 1]))))
        {
            index += 1;
            continue;
        }
        const unit = display_width.displayUnitAt(value, index);
        const length = @max(@as(usize, 1), unit.byte_len);
        try output.appendSlice(alloc, value[index..@min(value.len, index + length)]);
        index += length;
    }
    return output.toOwnedSlice(alloc);
}

fn isFormattingTag(name: []const u8) bool {
    const tags = [_][]const u8{
        "b",    "strong", "i",     "em",   "u",    "s",   "strike", "del",
        "ins",  "mark",   "small", "big",  "sub",  "sup", "code",   "kbd",
        "samp", "var",    "tt",    "span", "font", "q",   "abbr",   "cite",
        "pre",
    };
    for (tags) |tag| if (eqlIgnoreCase(name, tag)) return true;
    return false;
}

const Entity = struct { codepoint: u21, bytes: usize };

fn decodeEntity(source: []const u8) ?Entity {
    const end = std.mem.findScalarPos(u8, source, 1, ';') orelse return null;
    if (end > 10) return null;
    const body = source[1..end];
    const codepoint: u21 = if (std.mem.eql(u8, body, "lt")) '<' else if (std.mem.eql(u8, body, "gt")) '>' else if (std.mem.eql(u8, body, "amp")) '&' else if (std.mem.eql(u8, body, "quot")) '"' else if (std.mem.eql(u8, body, "apos")) '\'' else blk: {
        if (!std.mem.startsWith(u8, body, "#")) return null;
        const number = body[1..];
        const parsed: u21 = if (number.len > 1 and (number[0] == 'x' or number[0] == 'X'))
            std.fmt.parseInt(u21, number[1..], 16) catch return null
        else
            std.fmt.parseInt(u21, number, 10) catch return null;
        if (parsed < 0x20 or (parsed >= 0x7f and parsed < 0xa0)) return null;
        break :blk parsed;
    };
    return .{ .codepoint = codepoint, .bytes = end + 1 };
}

fn appendCodepoint(alloc: Allocator, output: *std.ArrayList(u8), codepoint: u21) Allocator.Error!void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch return;
    try output.appendSlice(alloc, buffer[0..length]);
}

fn firstWord(source: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, source, " \t\r\n");
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t' and trimmed[end] != '\r' and trimmed[end] != '\n') : (end += 1) {}
    return trimmed[0..end];
}

fn directionFromHeader(header: []const u8) Direction {
    var words = std.mem.tokenizeAny(u8, header, " \t");
    _ = words.next();
    const direction = words.next() orelse return .down;
    if (eqlIgnoreCase(direction, "LR")) return .right;
    if (eqlIgnoreCase(direction, "RL")) return .left;
    if (eqlIgnoreCase(direction, "BT")) return .up;
    return .down;
}

fn skipSpace(source: []const u8, raw_index: usize) usize {
    var index = raw_index;
    while (index < source.len and (source[index] == ' ' or source[index] == '\t')) : (index += 1) {}
    return index;
}

fn isIdByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isLinkByte(byte: u8) bool {
    return byte == '-' or byte == '.' or byte == '=' or byte == '<' or byte == '>';
}

fn lineKind(operator: []const u8) LineKind {
    if (std.mem.findScalar(u8, operator, '=') != null) return .thick;
    if (std.mem.findScalar(u8, operator, '.') != null) return .dotted;
    return .solid;
}

fn mergeLineKind(left: LineKind, right: LineKind) LineKind {
    if (left == .thick or right == .thick) return .thick;
    if (left == .dotted and right == .dotted) return .dotted;
    return .solid;
}

fn firstIdentifier(source: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, source, " \t\"");
    var end: usize = 0;
    while (end < trimmed.len and isIdByte(trimmed[end])) : (end += 1) {}
    return trimmed[0..end];
}

fn lastIdentifier(source: []const u8) []const u8 {
    var trimmed = std.mem.trimEnd(u8, source, " \t\"");
    var start = trimmed.len;
    while (start > 0 and isIdByte(trimmed[start - 1])) : (start -= 1) {}
    trimmed = trimmed[start..];
    return trimmed;
}

fn eqlIgnoreCase(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn startsWithIgnoreCase(source: []const u8, prefix: []const u8) bool {
    return source.len >= prefix.len and std.ascii.eqlIgnoreCase(source[0..prefix.len], prefix);
}

fn findAsciiIgnoreCase(source: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    var index: usize = 0;
    while (index + needle.len <= source.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(source[index .. index + needle.len], needle)) return index;
    }
    return null;
}

fn maskGlyph(mask: u8) []const u8 {
    return switch (mask) {
        0 => " ",
        up_bit, down_bit, up_bit | down_bit => "│",
        left_bit, right_bit, left_bit | right_bit => "─",
        down_bit | right_bit => "┌",
        down_bit | left_bit => "┐",
        up_bit | right_bit => "└",
        up_bit | left_bit => "┘",
        up_bit | down_bit | right_bit => "├",
        up_bit | down_bit | left_bit => "┤",
        down_bit | left_bit | right_bit => "┬",
        up_bit | left_bit | right_bit => "┴",
        else => "┼",
    };
}

fn dottedGlyph(glyph: []const u8) []const u8 {
    if (std.mem.eql(u8, glyph, "─")) return "╌";
    if (std.mem.eql(u8, glyph, "│")) return "╎";
    return glyph;
}

fn thickGlyph(glyph: []const u8) []const u8 {
    if (std.mem.eql(u8, glyph, "─")) return "━";
    if (std.mem.eql(u8, glyph, "│")) return "┃";
    if (std.mem.eql(u8, glyph, "┌")) return "┏";
    if (std.mem.eql(u8, glyph, "┐")) return "┓";
    if (std.mem.eql(u8, glyph, "└")) return "┗";
    if (std.mem.eql(u8, glyph, "┘")) return "┛";
    if (std.mem.eql(u8, glyph, "├")) return "┣";
    if (std.mem.eql(u8, glyph, "┤")) return "┫";
    if (std.mem.eql(u8, glyph, "┬")) return "┳";
    if (std.mem.eql(u8, glyph, "┴")) return "┻";
    if (std.mem.eql(u8, glyph, "┼")) return "╋";
    return glyph;
}

fn flipGlyphVertical(glyph: []const u8) []const u8 {
    if (std.mem.eql(u8, glyph, "┌")) return "└";
    if (std.mem.eql(u8, glyph, "┐")) return "┘";
    if (std.mem.eql(u8, glyph, "└")) return "┌";
    if (std.mem.eql(u8, glyph, "┘")) return "┐";
    if (std.mem.eql(u8, glyph, "╭")) return "╰";
    if (std.mem.eql(u8, glyph, "╮")) return "╯";
    if (std.mem.eql(u8, glyph, "╰")) return "╭";
    if (std.mem.eql(u8, glyph, "╯")) return "╮";
    if (std.mem.eql(u8, glyph, "┬")) return "┴";
    if (std.mem.eql(u8, glyph, "┴")) return "┬";
    if (std.mem.eql(u8, glyph, "┳")) return "┻";
    if (std.mem.eql(u8, glyph, "┻")) return "┳";
    if (std.mem.eql(u8, glyph, "▼")) return "▲";
    if (std.mem.eql(u8, glyph, "▲")) return "▼";
    if (std.mem.eql(u8, glyph, "▽")) return "△";
    if (std.mem.eql(u8, glyph, "△")) return "▽";
    return glyph;
}

fn flipGlyphHorizontal(glyph: []const u8) []const u8 {
    if (std.mem.eql(u8, glyph, "┌")) return "┐";
    if (std.mem.eql(u8, glyph, "┐")) return "┌";
    if (std.mem.eql(u8, glyph, "└")) return "┘";
    if (std.mem.eql(u8, glyph, "┘")) return "└";
    if (std.mem.eql(u8, glyph, "╭")) return "╮";
    if (std.mem.eql(u8, glyph, "╮")) return "╭";
    if (std.mem.eql(u8, glyph, "╰")) return "╯";
    if (std.mem.eql(u8, glyph, "╯")) return "╰";
    if (std.mem.eql(u8, glyph, "├")) return "┤";
    if (std.mem.eql(u8, glyph, "┤")) return "├";
    if (std.mem.eql(u8, glyph, "┣")) return "┫";
    if (std.mem.eql(u8, glyph, "┫")) return "┣";
    if (std.mem.eql(u8, glyph, "◄")) return "▶";
    if (std.mem.eql(u8, glyph, "▶")) return "◄";
    if (std.mem.eql(u8, glyph, "◁")) return "▷";
    if (std.mem.eql(u8, glyph, "▷")) return "◁";
    return glyph;
}

test "mermaid renders flowchart nodes edges labels and wide glyphs" {
    const alloc = std.testing.allocator;
    const rendered = (try render(
        alloc,
        "flowchart TD\n  A[开始] -->|检查| B{Ready?}\n  B --> C[Done]",
        80,
        .{},
    )).?;
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "开始") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Ready?") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "检查") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "▼") != null);
    var lines = std.mem.splitScalar(u8, rendered, '\n');
    while (lines.next()) |line| try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 80);
}

test "mermaid renders state class er and sequence diagrams" {
    const alloc = std.testing.allocator;
    const sources = [_][]const u8{
        "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Active: start\n  Active --> [*]",
        "classDiagram\n  class Animal {\n    +name String\n    +move()\n  }\n  Animal <|-- Dog",
        "erDiagram\n  CUSTOMER ||--o{ ORDER : places\n  CUSTOMER {\n    string name\n  }",
        "sequenceDiagram\n  participant A as Alice\n  participant B as Bob\n  A->>B: Hello\n  B-->>A: Hi",
    };
    const needles = [_][]const u8{ "start", "+move()", "places", "Alice" };
    for (sources, needles) |source, needle| {
        const rendered = (try render(alloc, source, 100, .{})).?;
        defer alloc.free(rendered);
        try std.testing.expect(std.mem.find(u8, rendered, "┌") != null or std.mem.find(u8, rendered, "╭") != null);
        try std.testing.expect(std.mem.find(u8, rendered, needle) != null);
        try std.testing.expect(std.unicode.utf8ValidateSlice(rendered));
    }
}

test "mermaid unsupported and bounded diagrams fall back" {
    const alloc = std.testing.allocator;
    try std.testing.expect((try render(alloc, "pie\n title Pets", 80, .{})) == null);
    try std.testing.expect((try render(alloc, "sequenceDiagram\n loop empty\n end", 80, .{})) == null);
    try std.testing.expect((try render(alloc, "flowchart LR\n A --> B", 8, .{})) == null);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(alloc);
    try source.appendSlice(alloc, "flowchart TD\n");
    var index: usize = 0;
    while (index <= max_nodes) : (index += 1) try source.print(alloc, "N{d}\n", .{index});
    try std.testing.expect((try render(alloc, source.items, 200, .{})) == null);
}

test "mermaid labels cannot inject terminal controls" {
    const alloc = std.testing.allocator;
    const rendered = (try render(alloc, "flowchart TD\n A[ok&#27;bad]", 80, .{})).?;
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.findScalar(u8, rendered, 0x1b) == null);
}

test "mermaid preserves compact links line styles and reversed direction" {
    const alloc = std.testing.allocator;
    const dotted = (try render(alloc, "flowchart TD\nA-.->B", 80, .{})).?;
    defer alloc.free(dotted);
    try std.testing.expect(std.mem.find(u8, dotted, "╎") != null or std.mem.find(u8, dotted, "╌") != null);

    const thick = (try render(alloc, "flowchart TD\nA==>B", 80, .{})).?;
    defer alloc.free(thick);
    try std.testing.expect(std.mem.find(u8, thick, "┃") != null or std.mem.find(u8, thick, "━") != null);

    const reversed = (try render(alloc, "flowchart RL\nA[Vec<T>] --> B[<b>done</b><br/>now]", 80, .{})).?;
    defer alloc.free(reversed);
    try std.testing.expect(std.mem.find(u8, reversed, "Vec<T>") != null);
    try std.testing.expect(std.mem.find(u8, reversed, "done now") != null);
    try std.testing.expect(std.mem.find(u8, reversed, "◄") != null);

    const paired_shapes = (try render(alloc, "flowchart TD\nA([Start]) --> B[[End]]", 80, .{})).?;
    defer alloc.free(paired_shapes);
    try std.testing.expect(std.mem.find(u8, paired_shapes, "Start") != null);
    try std.testing.expect(std.mem.find(u8, paired_shapes, "[Start]") == null);
    try std.testing.expect(std.mem.find(u8, paired_shapes, "End") != null);
}

test "mermaid sequence renders notes self messages and autonumber" {
    const alloc = std.testing.allocator;
    const rendered = (try render(
        alloc,
        "sequenceDiagram\n  autonumber\n  participant A as Alice\n  participant B as Bob\n  Note over A,B: handshake\n  A->>A: prepare\n  A-->>B: send",
        100,
        .{},
    )).?;
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "handshake") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "1. prepare") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "2. send") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "╮") != null);

    const boxed = (try render(
        alloc,
        "sequenceDiagram\n  box Team\n  participant A as Alice\n  end\n  A->>A: ready",
        80,
        .{},
    )).?;
    defer alloc.free(boxed);
    try std.testing.expect(std.mem.find(u8, boxed, "Alice") != null);
    try std.testing.expect(std.mem.find(u8, boxed, " end ") == null);
}

fn checkRenderAllocationFailures(alloc: Allocator) !void {
    const sources = [_][]const u8{
        "flowchart LR\n  A[Request] -->|validate| B[Response]",
        "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Active: start",
        "classDiagram\n  class Worker {\n    +name String\n    +run()\n  }\n  Worker <|-- Agent : extends",
        "erDiagram\n  CUSTOMER ||--o{ ORDER : places",
        "sequenceDiagram\n  participant A as Alice\n  participant B as Bob\n  A->>B: Hello",
    };
    for (sources) |source| {
        const rendered = try render(alloc, source, 100, .{});
        if (rendered) |owned| alloc.free(owned);
    }
}

test "mermaid renderer cleans partial allocations" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkRenderAllocationFailures,
        .{},
    );
}
