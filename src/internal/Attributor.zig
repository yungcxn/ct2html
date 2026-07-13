const std = @import("std");
const Node = @import("../element/Node.zig");
const DynBuf = @import("../ds/dynbuf.zig").DynBuf;
const Rule = @import("../element/Rule.zig");
const CCEngine = @import("CCEngine.zig");
const Parser = @import("../input/Parser.zig");
const crash = @import("../ErrorReporter.zig").crash;

attributes: DynBuf(Node.L0),
cursor: usize = 0, // for iterating
custom_cmd_engine: *CCEngine, // for command engine to run commands and get their output

pub fn init(
    alloc: std.mem.Allocator,
    custom_cmd_engine: *CCEngine,
) @This() {
    return .{
        .attributes = .init(alloc, 20),
        .cursor = 0,
        .custom_cmd_engine = custom_cmd_engine,
    };
}

pub fn deinit(self: *@This()) void {
    self.attributes.deinit();
}

pub inline fn push(self: *@This(), node: Node.L0) Parser.ParsingError!void {
    if (node.kind == .blkdef or node.kind == .inldef) {
        try self.custom_cmd_engine.new_cmd_def_from_attr(node);
    } else {
        self.attributes.push(node);
    }
}

pub inline fn peek(self: *@This()) ?Node.L0 {
    if (self.cursor >= self.attributes.head or self.cursor == std.math.maxInt(usize)) return null;
    return self.attributes.buf.?[self.cursor];
}

pub inline fn pop(self: *@This()) ?Node.L0 {
    defer self.cursor += 1;
    return self.peek();
}

// only the last one found is needed, for override semantics, so we search from end
pub inline fn get_newest(self: *@This(), kind: Node.L0Kind) ?Node.L0 {
    if (self.attributes.head == 0) return null;
    self.cursor = self.attributes.head - 1;
    defer self.reset_cursor();

    while (self.peek()) |l0node| : (self.cursor = self.cursor -% 1) {
        if (l0node.kind == kind) {
            return l0node;
        }
    }
    return null;
}

pub inline fn reset_cursor(self: *@This()) void {
    self.cursor = 0;
}
