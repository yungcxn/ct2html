const std = @import("std");
const Node = @import("element/Node.zig");
const Parser = @This();

const rules_l0 = @import("rules/l0.zig");
const rules_l1 = @import("rules/l1.zig");
const SyntaxError = rules_l0.SyntaxError || rules_l1.SyntaxError;

pub const ParsingError = error{
    InvalidSyntax,
    StopSignNotFound,
    SearchingRuleAtEOF,
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
    if (self.find_line_bounds()) |b| {
        const text = self.text[b.lbound..b.rbound];
        std.log.err("[context]: {s}", .{text});
        const pos = self.cursor - b.lbound;
        const pos_marker = self.alloc.alloc(u8, pos + 1) catch {
            std.log.err("Failed to alloc for pos_marker", .{});
            std.process.exit(1);
        };
        defer self.alloc.free(pos_marker);
        for (pos_marker) |*c| c.* = ' ';
        pos_marker[pos] = '^';
        std.log.err("           {s}", .{pos_marker});
    }
    std.process.exit(1);
}

fn find_l0rule_at_cursor(self: *@This()) ?Rule {
    const c = self.peek() orelse return null;
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
    while (self.advance()) |c| {
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

        self.skip_newline();
        self.skip_newline();
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

pub fn push_node(self: *@This(), node: Node) void {
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

pub fn push_meta_l0node(self: *@This(), kind: Node.KindLevel0) void {
    self.push_node(Node{ .kind = .l0(kind), .textstart = 0, .textend = 0 });
}

pub fn peek(self: *@This()) ?u8 {
    if (self.cursor >= self.text.len) return null;
    return self.text[self.cursor];
}

pub fn advance(self: *@This()) ?u8 {
    const c = self.peek() orelse return null;
    self.cursor += 1;
    return c;
}

pub fn back(self: *@This()) ?u8 {
    if (self.cursor == 0) return null;
    self.cursor -= 1;
    return self.text[self.cursor];
}

pub fn is_whitesp(c: u8) bool {
    return c == '\n' or c == '\t' or c == ' ' or c == '\r';
}

pub fn at_whitesp(self: *@This()) bool {
    const c = self.peek() orelse return false;
    return is_whitesp(c);
}

pub fn skip_whitesp(self: *@This()) bool {
    while (self.peek()) |c| {
        if (!is_whitesp(c)) return true;
        self.cursor += 1;
    }
    return false;
}

pub fn skip_whitesp_until(self: *@This(), endat: usize) bool {
    while (self.peek()) |c| {
        if (self.cursor >= endat) return false;
        if (!is_whitesp(c)) return true;
        self.cursor += 1;
    }
    return false;
}

pub fn mustfind_until( // this function returns on cursor being ON STOPSET or parsing error
    self: *@This(),
    endat: usize,
    stopset: anytype,
) ParsingError!void {
    while (self.cursor < endat) : (self.cursor += 1) {
        const c = self.peek() orelse return ParsingError.StopSignNotFound;
        inline for (stopset) |s| {
            if (c == s) return;
        }
    }
    return ParsingError.StopSignNotFound;
}

pub fn peek_until(
    self: *@This(),
    endat: usize,
    stopset: anytype,
) ParsingError!void {
    const before = self.cursor;
    try self.mustfind_until(endat, stopset);
    self.cursor = before;
}

pub fn advance_until(
    self: *@This(),
    endat: usize,
    stopset: anytype,
) void {
    self.mustfind_until(endat, stopset) catch {
        self.cursor = endat;
    };
}

pub fn skip_newline(self: *@This()) void {
    if (self.peek() == '\n') self.cursor += 1;
}

fn find_blockend(self: *@This()) ?usize {
    if (!self.skip_whitesp()) return null;
    const start = self.cursor;

    while (self.advance()) |c| {
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

fn find_lineend(self: *@This(), blockend: usize) ?usize {
    if (!self.skip_whitesp()) return null;
    if (self.cursor >= blockend) return null;
    const start = self.cursor;

    while (self.cursor < blockend) {
        const c = self.advance() orelse break;
        if (c == '\n') {
            const end = self.cursor - 1;
            self.cursor = start;
            return end;
        }
    }

    self.cursor = start;
    return blockend;
}

// returns pos of last newline1 and next newline-1
fn find_line_bounds(self: *@This()) ?struct {
    lbound: usize,
    rbound: usize,
} {
    const cursor_save = self.cursor;
    defer self.cursor = cursor_save;

    if (!self.skip_whitesp()) return null;

    while (self.back()) |c| {
        if (c == '\n') {
            self.cursor += 1;
            break;
        }
    }
    const lbound = self.cursor;

    var rbound: usize = undefined;
    while (self.advance()) |c| {
        if (c == '\n') {
            rbound = self.cursor - 1;
            self.cursor = lbound;
            return .{ .lbound = lbound, .rbound = rbound };
        }
    }

    rbound = self.text.len;
    self.cursor = lbound;
    return .{ .lbound = lbound, .rbound = rbound };
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
