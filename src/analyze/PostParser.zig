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

pub fn error_handle(self: *@This(), err: anyerror) void {
    std.log.err("nodecursor={d}: Error parsing node: {s}", .{ self.nodecursor, @errorName(err) });
    std.process.exit(1);
}

pub fn push_metanode(self: *@This(), node: MetaNode) void {
    if (self.metanodeshead >= self.metanodes.len) {
        const newlen = self.metanodes.len * 2;
        const newmetanodes = self.alloc.realloc(self.metanodes, newlen) catch |err| {
            return self.error_handle(err);
        };
        self.metanodes = newmetanodes;
    }
    self.metanodes[self.metanodeshead] = node;
    self.metanodeshead += 1;
}

pub fn build_metanodes(self: *@This()) void {
    while (self.nodecursor < self.nodec) : (self.nodecursor += 1) {
        const node = self.nodes[self.nodecursor];
        var rule_applied = false;
        inline for (comptime PostParseRule.rules) |rule| {
            if (std.meta.eql(node.kind, rule.nodetrigger) and !rule_applied) {
                // the rule func is assumed to not touch the cursor
                // except the case where it needs to consume +n nodes, e.g. +1
                // then it needs to move the cursor by +1, => +n
                rule.func(self) catch |err| {
                    self.error_handle(err);
                };
                rule_applied = true;
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
