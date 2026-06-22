const std = @import("std");
const Node = @import("element/Node.zig");
const Parser = @This();
const ParseRule = @import("rule/ParseRule.zig");

pub const ParsingError = error{
    InvalidSyntax,
    StopSignNotFound,
};

alloc: std.mem.Allocator,
text: []const u8,
cursor: usize,
nodes_l0: []Node,
nodes_l1: []Node,
nodeshead_l0: usize,
nodeshead_l1: usize,

pub fn init(alloc: std.mem.Allocator, text: []const u8) !@This() {
    return .{
        .alloc = alloc,
        .text = text,
        .cursor = 0,
        .nodes_l0 = try alloc.alloc(Node, 4096),
        .nodes_l1 = try alloc.alloc(Node, 4096),
        .nodeshead_l0 = 0,
        .nodeshead_l1 = 0,
    };
}

pub fn deinit(self: @This()) void {
    self.alloc.free(self.nodes_l0);
    self.alloc.free(self.nodes_l1);
}

fn error_handle(self: *@This(), err: anyerror) ParsingError {
    std.log.err("cursor={d}: Error parsing rule: {s}", .{ self.cursor, @errorName(err) });
    if (self.find_line_bounds()) |b| {
        const text = self.text[b.lbound..b.rbound];
        std.log.err("[in-line]: {s}", .{text});
    }
    return ParsingError.InvalidSyntax;
}

fn parse_ruletyped_unit(
    self: *@This(),
    comptime ruletype: ParseRule.RType,
    endat: usize,
) ParsingError!void {
    inline for (comptime ParseRule.rules_by_ruletype(ruletype)) |rule| {
        if (self.peek() == rule.trigger) {
            return rule.func(self, endat) catch |err| {
                return self.error_handle(err);
            };
        }
    }
    const def_rule = ParseRule.default_rule_by_ruletype(ruletype) orelse return;
    return def_rule.func(self, endat) catch |err| {
        return self.error_handle(err);
    };
}

fn parse_block(self: *@This(), endat: usize) ParsingError!void {
    return parse_ruletyped_unit(self, .BlockStart, endat);
}

fn parse_line(self: *@This(), endat: usize) ParsingError!void {
    return parse_ruletyped_unit(self, .LineStart, endat);
}

fn parse_inline(self: *@This(), endat: usize) ParsingError!void {
    while (self.cursor < endat) {
        const before = self.cursor;
        try parse_ruletyped_unit(self, .Inline, endat);
        if (self.cursor <= before) {
            self.cursor = endat;
            return;
        }
    }
}

pub fn build_nodes(self: *@This()) ParsingError!void {
    while (self.find_blockend()) |blockend| {
        try self.parse_block(blockend);

        while (self.find_lineend(blockend)) |lineend| {
            try self.parse_line(lineend);
            try self.parse_inline(lineend);
            self.skip_newline();
        }

        self.cursor = blockend;
        self.skip_newline();
        self.skip_newline();
    }
}

pub fn debug_print(self: @This()) void {
    std.debug.print("L0 Nodes:\n", .{});
    for (self.nodes_l0[0..self.nodeshead_l0], 0..) |node, idx| {
        const text = self.text[node.textstart..node.textend];
        std.debug.print("{d}: {any}\n   [{s}]\n\n", .{ idx, node.kind, text });
    }
    std.debug.print("L1 Nodes:\n", .{});
    for (self.nodes_l1[0..self.nodeshead_l1], 0..) |node, idx| {
        const text = self.text[node.textstart..node.textend];
        std.debug.print("{d}: {any}\n   [{s}]\n\n", .{ idx, node.kind, text });
    }
}

pub fn push_node(self: *@This(), node: Node) void {
    switch (node.kind) {
        .L0 => {
            self.nodes_l0[self.nodeshead_l0] = node;
            self.nodeshead_l0 += 1;
        },
        .L1 => {
            self.nodes_l1[self.nodeshead_l1] = node;
            self.nodeshead_l1 += 1;
        },
    }
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

pub fn mustfind_until(
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
