const std = @import("std");
const Node = @import("../element/Node.zig");
const Parser = @This();

const l0_rules = @import("l0_rules.zig");
const l1_rules = @import("l1_rules.zig");
const AllSyntaxErrors = l0_rules.SyntaxError || l1_rules.SyntaxError;

pub const ParsingError = error{
    EOF,
    InvalidSyntax,
    OutOfBounds,
    BoundNotFreeOf,
    Unhandled,
};

alloc: std.mem.Allocator,
text: []const u8,
cursor: usize, // TODO we should provide a second cursor that replaces endat..

l0nodes: []Node.L0,
l0nodeshead: usize,

l1nodes: []Node.L1,
l1nodeshead: usize,

pub fn init(alloc: std.mem.Allocator, text: []const u8) !@This() {
    return .{
        .alloc = alloc,
        .text = text,
        .cursor = 0,
        .l0nodes = try alloc.alloc(Node.L0, 4096),
        .l0nodeshead = 0,
        .l1nodes = try alloc.alloc(Node.L1, 4096),
        .l1nodeshead = 0,
    };
}

pub fn deinit(self: @This()) void {
    self.alloc.free(self.l0nodes);
    self.alloc.free(self.l1nodes);
}

// TODO should do a single pass func erasing catch spamming
pub fn error_handle(self: *@This(), err: anyerror) void {
    const line, const col = self.get_line_col();

    std.log.err("in line {} (:{}) :: {s}", .{ line, col, @errorName(err) });
    const b = self.find_line_bounds();
    self.cursor = b[0];
    const text = self.text[b[0]..b[1]];
    std.log.err("[context]: {s}", .{text});
    const pos = self.cursor - b[0];
    const pos_marker = self.alloc.alloc(u8, pos + 1) catch {
        std.log.err("Failed to alloc for pos_marker", .{});
        std.process.exit(1);
    };
    defer self.alloc.free(pos_marker);
    for (pos_marker) |*c| c.* = ' ';
    pos_marker[pos] = '^';
    std.log.err("           {s}", .{pos_marker});
}

// returns pos of last newline1 and next newline-1
fn find_line_bounds(self: *@This()) struct { usize, usize } {
    const cursor_save = self.cursor;
    defer self.cursor = cursor_save;

    // we expect to hit EOF, and since this is a generator function,
    // we return null on end instead of propagating the error
    var rbound_available = true;
    self.skip_whitesp() catch {
        rbound_available = false;
    };

    while (self.cursor > 0) {
        self.dec();
        if (self.peek().? == '\n') {
            self.cursor += 1;
            break;
        }
    }
    const lbound = self.cursor;

    var rbound: usize = undefined;
    if (rbound_available) {
        while (self.pop()) |c| {
            if (c == '\n') {
                rbound = self.cursor - 1;
                return .{ lbound, rbound };
            }
        }
    }

    rbound = self.text.len;
    return .{ lbound, rbound };
}

fn get_line_col(self: *@This()) struct { usize, usize } {
    var line: usize = 1;
    var col: usize = 1;
    for (self.text[0..self.cursor]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ line, col };
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
fn parse_l0nodes_from_block(self: *@This(), blockend: usize) void {
    const l0_capture_c = self.peek().?;

    // cursor is at the first char of the block

    var l0_rule = l0_rules.def[0]; // default rule, should be a paragraph
    inline for (l0_rules.def) |rule| {
        if (rule.in_triggers(l0_capture_c)) l0_rule = rule;
    }

    if (l0_rule.pre_node) |kind| self.push_l0node(
        .{ .kind = kind, .span = null, .contains_l1 = false },
    );

    const l0_apply_state = l0_rule.parse(self, blockend) catch |err| {
        return self.error_handle(err);
    };

    switch (l0_apply_state) {
        .transitioned => {
            // we pushed to head-1 the p node, and not yet l1 nodes
            // so if we had a l0_begin pushed node, we must replace it
            // by the p node and reset cursor by -1
            if (l0_rule.pre_node) |_| {
                const last_pnode = self.l0nodes[self.l0nodeshead - 1];
                self.l0nodes[self.l0nodeshead - 2] = last_pnode;
                self.l0nodeshead -= 1;
            }
        },
        .success => if (l0_rule.post_node) |kind| {
            self.push_l0node(
                .{ .kind = kind, .span = null, .contains_l1 = false },
            );
        },
    }
}

// assume cursor is at the start of the block, and blockend is the end of the block
// but cursor must be preserved after each func since it may move if the rule needs the cursor to
fn parse_l1_in_l0node(self: *@This(), l0node: *Node.L0) void {
    // assume span exists
    self.cursor = l0node.span.?[0];
    const node_end = l0node.span.?[1];
    while (self.bounded_pop(node_end)) |c| {
        inline for (l1_rules.def) |rule| {
            if (rule.in_triggers(c)) {
                const l1node = rule.parse_node(self, node_end) catch |err| {
                    return self.error_handle(err);
                };

                defer self.l1nodeshead += 1;
                self.l1nodes[self.l1nodeshead] = l1node;
                l0node.l1childc += 1;
                if (l0node.l1child0 == null) {
                    l0node.l1child0 = self.l1nodeshead;
                }
            }
        }
    }
}

pub fn build_nodes(self: *@This()) void {
    self.push_l0node(.{ .kind = .begin, .span = null, .contains_l1 = false });

    // l0 phase
    while (self.align_for_block()) |blockend| {
        self.parse_l0nodes_from_block(blockend);
        self.cursor = blockend;
    }

    self.push_l0node(.{ .kind = .end, .span = null, .contains_l1 = false });

    // l1 phase, reiterate over created l0 nodes
    for (self.l0nodes[0..self.l0nodeshead]) |*l0node| {
        if (l0node.contains_l1 and l0node.span != null) {
            self.parse_l1_in_l0node(l0node);
        }
    }
}

pub fn debug_print(self: @This()) void {
    std.debug.print("Nodes (L0):\n", .{});
    for (self.l0nodes[0..self.l0nodeshead], 0..) |node, idx| {
        var text: []const u8 = "";
        if (node.span) |s| text = self.text[s[0]..s[1]];
        std.debug.print(
            "{d}: {any}\n   [{s}]\n\n",
            .{ idx, node.kind, text },
        );
    }

    std.debug.print("Nodes (L1):\n", .{});
    for (self.l1nodes[0..self.l1nodeshead], 0..) |node, idx| {
        var text: []const u8 = "";
        if (node.span) |s| text = self.text[s[0]..s[1]];
        std.debug.print(
            "{d}: {any}\n   [{s}]\n\n",
            .{ idx, node.kind, text },
        );
    }
}

pub fn push_l0node(
    self: *@This(),
    l0node: Node.L0,
) void {
    self.l0nodes[self.l0nodeshead] = l0node;
    self.l0nodeshead += 1;
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
    const count = try self.findc(val);
    if (!self.in_bound(endat)) return ParsingError.OutOfBounds;
    return count;
}

pub inline fn skip_whitesp(self: *@This()) ParsingError!void {
    try self.skip(.{ ' ', '\t', '\r', '\n' });
}
pub inline fn bounded_skip_whitesp(self: *@This(), endat: usize) ParsingError!void {
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
