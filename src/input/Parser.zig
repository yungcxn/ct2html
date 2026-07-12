const std = @import("std");
const Node = @import("../element/Node.zig");
const Parser = @This();
const DynBuf = @import("../ds/dynbuf.zig").DynBuf;
const Rule = @import("../element/Rule.zig");
const l0_rules = @import("l0_rules.zig");
const l1_rules = @import("l1_rules.zig");
const Attributor = @import("../internal/Attributor.zig");
const ErrorReporter = @import("../ErrorReporter.zig");

// TODO errors should be way more detailed than this
pub const ParsingError = error{
    L0SyntaxError,
    L1SyntaxError,
    EOF,
    OutOfBounds,
};

io: std.Io, // for error logging only
e: *ErrorReporter,
attributor: *Attributor,
text: []const u8,
// TODO maybe stream based?
cursor: usize,

l0nodes: DynBuf(Node.L0),
l1nodes: DynBuf(Node.L1),

htmlerror: bool = false, // if true, we print the error as HTML instead of plain text

pub fn init(
    alloc: std.mem.Allocator,
    io: std.Io,
    e: *ErrorReporter,
    attributor: *Attributor,
    text: []const u8,
    htmlerror: bool,
) @This() {
    return .{
        .io = io,
        .text = text,
        .cursor = 0,
        .l0nodes = .init(alloc, 4096),
        .l1nodes = .init(alloc, 4096),
        .e = e,
        .attributor = attributor,
        .htmlerror = htmlerror,
    };
}

pub fn deinit(self: *@This()) void {
    self.l0nodes.deinit();
    self.l1nodes.deinit();
}

// returns blockend, sends cursor to first block sign.
fn align_for_block(self: *@This()) ?usize {
    // empty block if there was only whitespave between cursor and EOF
    self.skip_whitesp() catch return null;

    // block is now beginning
    const block_start = self.cursor;
    defer self.cursor = block_start;

    while (true) {
        self.find('\n') catch |err| switch (err) {
            ParsingError.EOF => {
                // this means, we did not find a '\n' and the file ended, and
                // cursor is out of bounds, but only for one char. so we
                // can return it since it's for an exclusive capture
                return self.cursor;
            },
            else => unreachable,
        };
        // cursor is now on '\n'
        self.inc();
        // now on first char on next line

        if ((self.peek() orelse return self.cursor) == '\n') {
            // double empty-line -> block end
            return self.cursor - 1; // first '\n', exclusive
        }

        // next iter: since we checked the next line's start, we go to its end
    }
}

// assume that cursor is at the start of the block, and we do not need to set
// cursor to some specific position afterwards
fn parse_l0nodes_from_block(self: *@This(), blockend: usize) Parser.ParsingError!bool {
    const l0_capture_c: u8 = self.peek().?;

    // cursor is at the first char of the block

    const l0_ri = l0_rules.datatable.lookup(l0_capture_c) orelse
        l0_rules.datatable.lookup(0).?;

    if (l0_ri.pre_node) |kind| self.l0nodes.push(
        .{ .kind = kind, .span = null, .contains_l1 = false },
    );

    const l0_apply_state = try l0_ri.parse(self, blockend);

    switch (l0_apply_state) {
        .transitioned => {
            // we pushed to head-1 the p node, and not yet l1 nodes
            // so if we had a l0_begin pushed node, we must replace it
            // by the p node and reset cursor by -1
            if (l0_ri.pre_node) |_| {
                const last_pnode = self.l0nodes.buf.?[self.l0nodes.head - 1];
                self.l0nodes.buf.?[self.l0nodes.head - 2] = last_pnode;
                self.l0nodes.head -= 1;
            }
        },
        .success => if (l0_ri.post_node) |kind| {
            self.l0nodes.push(.{ .kind = kind, .span = null, .contains_l1 = false });
        },
    }

    return l0_ri.preserve_cursor;
}

// assume cursor is at the start of the block, and blockend is the end of the block
// but cursor must be preserved after each func since it may move if the rule needs the cursor to
fn parse_all_l1s(self: *@This(), l0node: *Node.L0) Parser.ParsingError!void {
    // assume span exists
    self.cursor = l0node.span.?[0];
    const node_end = l0node.span.?[1];
    // we run through the text span of the l0 node TODO
    while (self.bounded_pop(node_end)) |c| {
        if (c == '\\') {
            _ = self.bounded_pop(node_end); // skip escaped char
            continue;
        }

        const l1_ri = l1_rules.datatable.lookup(c) orelse continue;
        const l1nodes_pushedc = try l1_ri.parse_node(self, node_end);

        if (l1nodes_pushedc != 0) {
            if (l0node.l1child0 == null) {
                l0node.l1child0 = self.l1nodes.head - l1nodes_pushedc;
                l0node.l1childhead = l0node.l1child0.? + l1nodes_pushedc;
            } else {
                l0node.l1childhead = l0node.l1childhead.? + l1nodes_pushedc;
            }
        }
    }
}

pub fn build_nodes(self: *@This()) Parser.ParsingError!void {
    self.l0nodes.push(.{ .kind = .begin, .span = null, .contains_l1 = false });

    // l0 phase
    while (self.align_for_block()) |blockend| {
        const preserve_cursor = try self.parse_l0nodes_from_block(blockend); // testmode err propagation
        if (!preserve_cursor) {
            self.cursor = blockend;
        }
    }

    self.l0nodes.push(.{ .kind = .end, .span = null, .contains_l1 = false });

    // l1 phase, reiterate over created l0 nodes
    for (self.l0nodes.slice_view()) |*node| {
        if (node.contains_l1 and node.span != null) {
            try self.parse_all_l1s(node); // err progapation here aswell
        }
    }
}

pub fn debug_print(self: @This()) void {
    std.debug.print("Nodes (L0):\n", .{});
    for (self.l0nodes.slice_view(), 0..) |node, idx| {
        var text: []const u8 = "";
        if (node.span) |s| text = self.text[s[0]..s[1]];
        std.debug.print(
            "{d}: {any} (children:{any}..{any})), (contains l1?{any}))\n   ({any})\n   [{s}]\n\n",
            .{ idx, node.kind, node.l1child0, node.l1childhead, node.contains_l1, node.span, text },
        );
    }

    std.debug.print("Nodes (L1):\n", .{});
    for (self.l1nodes.slice_view(), 0..) |node, idx| {
        const text: []const u8 = self.text[node.span[0]..node.span[1]];
        std.debug.print(
            "{d}: {any} (margin:{any})\n   ({any})\n   [{s}]\n\n",
            .{ idx, node.kind, node.margin, node.span, text },
        );
    }
}

pub inline fn inc(self: *@This()) void {
    self.cursor += 1;
}

pub inline fn dec(self: *@This()) void {
    self.cursor -= 1;
}

pub inline fn in_bound(self: *@This(), endat: usize) bool {
    return self.cursor < endat;
}

pub inline fn peek(self: *@This()) ?u8 {
    if (!self.in_bound(self.text.len)) return null;
    return self.text[self.cursor];
}

pub inline fn pop(self: *@This()) ?u8 {
    if (!self.in_bound(self.text.len)) return null;
    defer self.inc();
    return self.text[self.cursor];
}

pub inline fn bounded_pop(self: *@This(), endat: usize) ?u8 {
    if (!self.in_bound(endat) or !self.in_bound(self.text.len)) return null;
    defer self.inc();
    return self.text[self.cursor];
}

pub inline fn bounded_peek(self: *@This(), endat: usize) ?u8 {
    if (!self.in_bound(endat) or !self.in_bound(self.text.len)) return null;
    return self.text[self.cursor];
}

inline fn eq_any(c: u8, val: anytype) bool {
    if (@TypeOf(val) == u8 or @TypeOf(val) == comptime_int) return c == val;

    inline for (val) |s| {
        if (c == s) return true;
    }
    return false;
}

inline fn eq_none(c: u8, val: anytype) bool {
    if (@TypeOf(val) == u8 or @TypeOf(val) == comptime_int) return c != val;

    inline for (val) |s| {
        if (c == s) return false;
    }
    return true;
}

pub inline fn skip(self: *@This(), val: anytype) ParsingError!void {
    while (self.peek()) |p| : (self.inc()) {
        if (eq_none(p, val)) return;
    }
    return ParsingError.EOF;
}
pub inline fn bounded_skip(self: *@This(), val: anytype, endat: usize) ParsingError!void {
    const cursor_safe = self.cursor;
    errdefer self.cursor = cursor_safe; // restore cursor if we return an error for reporting
    try self.skip(val);
    if (!self.in_bound(endat)) return ParsingError.OutOfBounds;
}

pub inline fn find(self: *@This(), val: anytype) ParsingError!void {
    while (self.peek()) |p| : (self.inc()) {
        if (eq_any(p, val)) return;
    }
    return ParsingError.EOF;
}
pub inline fn bounded_find(self: *@This(), val: anytype, endat: usize) ParsingError!void {
    const cursor_safe = self.cursor;
    errdefer self.cursor = cursor_safe;
    try self.find(val);
    if (!self.in_bound(endat)) return ParsingError.OutOfBounds;
}

pub inline fn skipc(self: *@This(), val: anytype) ParsingError!usize {
    const cs = self.cursor;
    while (self.peek()) |p| : (self.inc()) {
        if (eq_none(p, val)) return self.cursor - cs;
    }
    return ParsingError.EOF;
}
pub inline fn bounded_skipc(self: *@This(), val: anytype, endat: usize) ParsingError!usize {
    const cursor_safe = self.cursor;
    errdefer self.cursor = cursor_safe;
    const count = try self.skipc(val);
    if (!self.in_bound(endat)) return ParsingError.OutOfBounds;
    return count;
}

pub inline fn findc(self: *@This(), val: anytype) ParsingError!usize {
    const cs = self.cursor;
    while (self.peek()) |p| : (self.inc()) {
        if (eq_any(p, val)) return self.cursor - cs;
    }
    return ParsingError.EOF;
}
pub inline fn bounded_findc(self: *@This(), val: anytype, endat: usize) ParsingError!usize {
    const cursor_safe = self.cursor;
    errdefer self.cursor = cursor_safe;
    const count = try self.findc(val);
    if (!self.in_bound(endat)) return ParsingError.OutOfBounds;
    return count;
}

pub inline fn skip_whitesp(self: *@This()) ParsingError!void {
    try self.skip(.{ ' ', '\t', '\r', '\n' });
}
pub inline fn bounded_skip_whitesp(self: *@This(), endat: usize) ParsingError!void {
    const cursor_safe = self.cursor;
    errdefer self.cursor = cursor_safe;
    try self.skip_whitesp();
    if (!self.in_bound(endat)) return ParsingError.OutOfBounds;
}

pub fn bounds_freeof(self: *@This(), startat: usize, endat: usize, c: anytype) bool {
    const cursor_save = self.cursor;
    self.cursor = startat;
    defer self.cursor = cursor_save;

    while (self.peek()) |p| : (self.inc()) {
        if (!self.in_bound(endat)) return true;
        if (@TypeOf(c) == u8 or @TypeOf(c) == comptime_int) {
            if (p == c) return false;
        } else {
            inline for (c) |s| {
                if (p == s) return false;
            }
        }
    }
    return true;
}

pub fn bounds_freeof_whitesp(self: *@This(), startat: usize, endat: usize) bool {
    return self.bounds_freeof(startat, endat, .{ ' ', '\t', '\r', '\n' });
}
