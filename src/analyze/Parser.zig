const std = @import("std");
const Node = @import("element/Node.zig");
const Parser = @This();

const rules_l0 = @import("rules/l0.zig");
const rules_l1 = @import("rules/l1.zig");
const SyntaxError = rules_l0.SyntaxError || rules_l1.SyntaxError;

pub const ParsingError = error{
    InvalidSyntax,
    StopSignNotFound,
};

pub const Rule = struct {
    trigger: ?u8 = null,
    func: fn (*Parser, usize) SyntaxError!void,
    rescan_for_l1: bool = true, // could l1 rules be applied in this rule block?, not for l1 rules
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
    std.log.err("cursor={d}: Error parsing rule: {s}", .{ self.cursor, @errorName(err) });
    if (self.find_line_bounds()) |b| {
        const text = self.text[b.lbound..b.rbound];
        std.log.err("[in-line]: {s}", .{text});
    }
    std.process.exit(1);
}

// assume cursor is at the start of the block, and blockend is the end of the block
fn l0_parse_block(self: *@This(), endat: usize) bool { // returns if l1 rescan after rule
    inline for (rules_l0.rules[1..]) |rule| {
        if (self.peek() == rule.trigger) {
            rule.func(self, endat) catch |err| {
                self.error_handle(err);
            };
            return rule.rescan_for_l1;
        }
    }

    rules_l0.rules[0].func(self, endat) catch |err| {
        self.error_handle(err);
    };
    return rules_l0.rules[0].rescan_for_l1;
}

// assume cursor is at the start of the block, and blockend is the end of the block
// but cursor must be preserved after each func since it may move if the rule needs the cursor to
fn l1_parse_inblock(self: *@This(), blockend: usize) void {
    while (self.advance()) |c| {
        if (self.cursor >= blockend) break;
        inline for (rules_l1.rules) |rule| {
            if (c == rule.trigger) {
                rule.func(self, blockend) catch |err| {
                    self.error_handle(err);
                };
            }
        }
    }
}

pub fn build_nodes(self: *@This()) void {
    while (self.find_blockend()) |blockend| {
        const cursor_before = self.cursor;
        if (self.l0_parse_block(blockend)) { // rescan for l1
            self.cursor = cursor_before; // restart the block scanning now
            self.l1_parse_inblock(blockend);
            self.cursor = blockend;
        }
        self.skip_newline();
        self.skip_newline();
    }
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
