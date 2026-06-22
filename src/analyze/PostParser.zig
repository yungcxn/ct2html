const std = @import("std");
const Parser = @import("Parser.zig");
const PostParseRule = @import("rule/PostParseRule.zig");
const Node = @import("element/Node.zig");
const MetaNode = @import("element/MetaNode.zig");
const SemanticError = @import("actions/postparse.zig").SemanticError;

alloc: std.mem.Allocator,
nodes: []Node,
nodec: usize,
nodecursor: usize,
metanodes: []MetaNode,
metanodeshead: usize,

pub fn init(
    alloc: std.mem.Allocator,
    nodes: []Node,
    nodec: usize,
) !@This() {
    return .{
        .alloc = alloc,
        .nodes = nodes,
        .nodec = nodec,
        .nodecursor = 0,
        .metanodes = try alloc.alloc(MetaNode, 1024),
        .metanodeshead = 0,
    };
}

pub fn deinit(self: @This()) void {
    self.alloc.free(self.metanodes);
}

pub fn push_metanode(self: *@This(), node: MetaNode) void {
    self.metanodes[self.metanodeshead] = node;
    self.metanodeshead += 1;
}

pub fn build_metanodes(self: *@This()) SemanticError!void {
    while (self.nodecursor < self.nodec) : (self.nodecursor += 1) {
        const node = self.nodes[self.nodecursor];
        inline for (comptime PostParseRule.rules) |rule| {
            if (std.meta.eql(node.kind, rule.nodetrigger)) {
                // the rule func is assumed to not touch the cursor
                // except the case where it needs to consume +n nodes, e.g. +1
                // then it needs to move the cursor by +1, => +n
                try rule.func(self);
            }
        }
    }
}

pub fn debug_print(self: @This()) void {
    std.debug.print("Metanodes:\n", .{});
    for (self.metanodes[0..self.metanodeshead]) |mn| {
        std.debug.print("- kind={any}, before_node={d}\n", .{ mn.kind, mn.before_node });
    }
}
