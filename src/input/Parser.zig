const std = @import("std");
const Node = @import("element/Node.zig");
const Parser = @This();

const rules_l0 = @import("rules/l0.zig");
const rules_l1 = @import("rules/l1.zig");
const SyntaxError = rules_l0.SyntaxError || rules_l1.SyntaxError;

pub const ParsingError = error{
    EOF,
    InvalidSyntax,
    OutOfBounds,
    BoundNotFreeOf,
};

pub const Rule = struct {
    pub const ApplyState = enum(u8) {
        transitioned_to_p,
        did_not_transition,
        errd,
    };

    trigger: ?u8 = null,
    apply: *const fn (*Parser, usize) SyntaxError!ApplyState, //
    rescan_for_l1: bool = true, // could l1 rules be applied in this block?

    l0_begin: ?Node.KindLevel0 = null,
    l0_end: ?Node.KindLevel0 = null,
};

alloc: std.mem.Allocator,
text: []const u8,
cursor: usize,
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
    _ = self.skip_whitesp() catch {
        rbound_available = false;
    };

    while (self.back()) |c| {
        if (c == '\n') {
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

fn find_l0rule_at_cursor(self: *@This()) ?Rule {
    const c = self.peek().?;
    inline for (rules_l0.vtable) |rule| {
        if (c == rule.trigger) return rule;
    }
    return null;
}

// assume cursor is at the start of the block, and blockend is the end of the block
fn l0_parse_block(
    self: *@This(),
    l0rule: Parser.Rule,
    endat: usize,
) Parser.Rule.ApplyState {
    return l0rule.apply(self, endat) catch |err| {
        self.error_handle(err);
        return .errd;
    };
}

// assume cursor is at the start of the block, and blockend is the end of the block
// but cursor must be preserved after each func since it may move if the rule needs the cursor to
fn l1_parse_inblock(self: *@This(), blockend: usize) Parser.Rule.ApplyState {
    while (self.pop()) |c| {
        if (self.cursor >= blockend) break;
        inline for (rules_l1.rules) |rule| {
            if (c == rule.trigger) {
                return rule.apply(self, blockend) catch |err| {
                    self.error_handle(err);
                    return .errd;
                };
            }
        }
    }
    return .errd;
}

fn find_blockend(self: *@This()) ?usize {
    const start = self.cursor;

    while (self.pop()) |c| {
        if (c != '\n') continue;
        const next = self.peek() orelse break;
        if (next == '\n') {
            const end = self.cursor - 1;
            self.cursor = start;
            return end;
        }
    }

    const end = self.text.len;
    self.cursor = start;
    return end;
}

pub fn build_nodes(self: *@This()) void {
    self.push_meta_l0node(.BeginMeta);

    while (self.find_blockend()) |blockend| {
        const cursor_before = self.cursor;
        const l0rule = self.find_l0rule_at_cursor() orelse rules_l0.vtable[0];

        {
            var apply_state: Rule.ApplyState = undefined;

            if (l0rule.l0_begin) |kind| self.push_meta_l0node(kind);

            defer if (l0rule.l0_end) |kind| {
                if (apply_state == .did_not_transition) {
                    self.push_meta_l0node(kind);
                }
            };

            apply_state = self.l0_parse_block(l0rule, blockend);

            switch (apply_state) {
                .transitioned_to_p => {
                    // we pushed to head-1 the p node, and not yet l1 nodes
                    // so if we had a l0_begin pushed node, we must replace it
                    // by the p node and reset cursor by -1
                    if (l0rule.l0_begin) |_| {
                        const last_pnode = self.nodes[self.nodeshead - 1];
                        self.nodes[self.nodeshead - 2] = last_pnode;
                        self.nodeshead -= 1;
                    }
                },
                .did_not_transition => {}, // good
                .errd => return self.error_handle(ParsingError.InvalidSyntax),
            }

            if (l0rule.rescan_for_l1) {
                self.cursor = cursor_before; // restart the block scanning now
                _ = self.l1_parse_inblock(blockend); // TODO
                self.cursor = blockend;
            }
        }
        // skip \n\n
        self.inc();
        self.inc();
    }

    self.push_meta_l0node(.EndMeta);
}

pub fn debug_print(self: @This()) void {
    std.debug.print("Nodes:\n", .{});
    for (self.nodes[0..self.nodeshead], 0..) |node, idx| {
        const text = self.text[node.textstart..node.textend];
        std.debug.print(
            "{d}: {any}\n   [{s}]\n\n",
            .{ idx, node.kind, text },
        );
    }
}

fn push_node(self: *@This(), node: Node) void {
    if (self.nodeshead >= self.nodes.len) {
        const newlen = self.nodes.len * 2;
        const newnodes = self.alloc.realloc(self.nodes, newlen) catch |err| {
            return self.error_handle(err);
        };
        self.nodes = newnodes;
    }
    self.nodes[self.nodeshead] = node;
    self.nodeshead += 1;
}

pub fn push_l0node(self: *@This(), kind: Node.KindLevel0, textstart: usize, textend: usize) void {
    self.push_node(Node{ .kind = .l0(kind), .textstart = textstart, .textend = textend });
}

pub fn push_l1node(self: *@This(), kind: Node.KindLevel1, textstart: usize, textend: usize) void {
    self.push_node(Node{ .kind = .l1(kind), .textstart = textstart, .textend = textend });
}

pub fn push_meta_l0node(self: *@This(), kind: Node.KindLevel0) void {
    self.push_node(Node{ .kind = .l0(kind), .textstart = 0, .textend = 0 });
}

/// cursor helpers /////////////////////////////////////////////////////////////
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
    if (self.in_bound(self.text.len)) return null;
    return self.text[self.cursor];
}

pub inline fn pop(self: *@This()) ?u8 {
    defer self.inc();
    return self.peek();
}

// we return on cursor being on the first non-c char
pub inline fn skip(self: *@This(), c: u8, comptime reverse_cond: bool) ParsingError!usize {
    const cs = self.cursor;
    while (self.peek()) |p| : (self.inc()) {
        if (comptime reverse_cond) {
            if (p == c) return self.cursor - cs;
        } else {
            if (p != c) return self.cursor - cs;
        }
    }

    return ParsingError.EOF;
}

pub inline fn skip_set(
    self: *@This(),
    set: anytype,
    comptime reverse_cond: bool,
) ParsingError!usize {
    const cs = self.cursor;
    while (self.peek()) |p| : (self.inc()) {
        // reverse_cond=false => we skip on set, meaning we think we're on until !=
        // reverse_cond=true => we are not on set until we are on it
        var on_set = !reverse_cond;
        inline for (set) |s| {
            if (reverse_cond) {
                if (p == s) on_set = true;
            } else {
                if (p != s) on_set = false;
            }
        }
        if (reverse_cond == on_set) return self.cursor - cs;
    }

    return ParsingError.EOF;
}

pub inline fn skip_whitesp(self: *@This()) ParsingError!usize {
    return self.skip_set(.{ ' ', '\t', '\n', '\r' }, false);
}
pub inline fn bounded(
    self: *@This(),
    retval: anytype,
    endat: usize,
) ParsingError!(switch (@typeInfo(@TypeOf(retval))) {
    .error_union => |e| e.payload,
    else => @TypeOf(retval),
}) {
    // retval got evaluated; cursor may or may not be out of endat now
    if (!self.in_bound(endat)) {
        self.cursor = endat;
        return ParsingError.OutOfBounds;
    }
    return retval;
}

pub inline fn bounded_skip_whitesp(
    self: *@This(),
    endat: usize,
) ParsingError!usize {
    return self.bounded(self.skip_whitesp(), endat);
}

pub inline fn back(self: *@This()) ?u8 {
    if (self.cursor == 0) return null;
    self.cursor -= 1;
    return self.text[self.cursor];
}

// does only the check, not advancing cursor
pub fn bound_free_of_set(self: *@This(), endat: usize, forbiddenset: anytype) bool {
    const cursor_save = self.cursor;
    defer self.cursor = cursor_save;
    while (self.peek()) |c| : (self.inc()) {
        if (!self.in_bound(endat)) return false;
        inline for (forbiddenset) |s| {
            if (c == s) return false;
        }
    }
    return true;
}

pub fn bound_free_of(self: *@This(), endat: usize, skipc: u8) bool {
    return self.bound_free_of_set(endat, .{skipc});
}
