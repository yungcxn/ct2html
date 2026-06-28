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
nodes: []Node,
nodeshead: usize,

pub fn init(alloc: std.mem.Allocator, text: []const u8) !@This() {
    return .{
        .alloc = alloc,
        .text = text,
        .cursor = 0,
        .nodes = try alloc.alloc(Node, 4096),
        .nodeshead = 0,
    };
}

pub fn deinit(self: @This()) void {
    self.alloc.free(self.nodes);
}

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

// assume cursor is at the start of the block, and blockend is the end of the block
// but cursor must be preserved after each func since it may move if the rule needs the cursor to
fn l1_parse_inblock(self: *@This(), blockend: usize) l1_rules.SyntaxError!void {
    while (self.pop()) |c| {
        if (self.cursor >= blockend) break;
        inline for (l1_rules.def) |rule| {
            if (rule.in_triggers(c)) {
                _ = try rule.apply(self, blockend); // TODO
            }
        }
    }
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

pub fn build_nodes(self: *@This()) void {
    self.push_node(.begin, null);

    while (self.align_for_block()) |blockend| {
        const cursor_before = self.cursor;
        const l0_capture_c = self.peek().?;

        // cursor is at the first char of the block

        var l0_rule = l0_rules.def[0]; // default rule, should be a paragraph
        inline for (l0_rules.def) |rule| {
            if (rule.in_triggers(l0_capture_c)) l0_rule = rule;
        }

        if (l0_rule.l0_begin) |kind| {
            self.push_node(kind, null);
        }

        const l0_apply_state = l0_rule.apply(self, blockend) catch |err| {
            return self.error_handle(err);
        };

        switch (l0_apply_state) {
            .transitioned => {
                // we pushed to head-1 the p node, and not yet l1 nodes
                // so if we had a l0_begin pushed node, we must replace it
                // by the p node and reset cursor by -1
                if (l0_rule.l0_begin) |_| {
                    const last_pnode = self.nodes[self.nodeshead - 1];
                    self.nodes[self.nodeshead - 2] = last_pnode;
                    self.nodeshead -= 1;
                }
            },
            .success => {}, // good
        }

        // reset cursor to scan for l1 rules
        if (l0_rule.l1_rescan) {
            self.cursor = cursor_before;

            self.l1_parse_inblock(blockend) catch |err| {
                return self.error_handle(err);
            };
        }

        // l0 and l1 is done, now we can end with the optional l0_end node
        if (l0_apply_state == .success) {
            if (l0_rule.l0_end) |kind| {
                self.push_node(kind, null);
            }
        }

        self.cursor = blockend;
    }

    self.push_node(.end, null);
}

pub fn debug_print(self: @This()) void {
    std.debug.print("Nodes:\n", .{});
    for (self.nodes[0..self.nodeshead], 0..) |node, idx| {
        var text: []const u8 = "";
        if (node.span) |s| text = self.text[s.start..s.end];
        std.debug.print(
            "{d}: {any}\n   [{s}]\n\n",
            .{ idx, node.kind, text },
        );
    }
}

pub fn push_node(self: *@This(), kind: Node.Kind, span: ?Node.Span) void {
    if (self.nodeshead >= self.nodes.len) {
        const newlen = self.nodes.len * 2;
        const newnodes = self.alloc.realloc(self.nodes, newlen) catch |err| {
            return self.error_handle(err);
        };
        self.nodes = newnodes;
    }
    self.nodes[self.nodeshead] = Node{ .kind = kind, .span = span };
    self.nodeshead += 1;
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
