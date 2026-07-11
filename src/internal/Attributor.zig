const std = @import("std");
const Node = @import("../element/Node.zig");
const DynBuf = @import("../ds/dynbuf.zig").DynBuf;
const Rule = @import("../element/Rule.zig");

attributes: DynBuf(Node.L0),
cursor: usize = 0, // for iterating

pub fn init(
    alloc: std.mem.Allocator,
) @This() {
    return .{
        .attributes = .init(alloc, 20),
        .cursor = 0,
    };
}

pub fn deinit(self: *@This()) void {
    self.attributes.deinit();
}

pub inline fn push(self: *@This(), node: Node.L0) void {
    self.attributes.push(node);
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
