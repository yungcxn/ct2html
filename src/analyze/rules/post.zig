const std = @import("std");
const PostParser = @import("../PostParser.zig");
const MetaNode = @import("../element/MetaNode.zig");
const Node = @import("../element/Node.zig");

pub const SemanticError = error{
    ImpossibleListNesting,
};

pub const rules = [_]PostParser.Rule{
    .{ .nodetrigger = .{ .L0 = .Item }, .func = unordered_list_wrap },
};

fn spush_node(p: *PostParser, k: MetaNode.Kind, before_node: usize) void {
    p.push_metanode(.{
        .kind = k,
        .before_node = before_node,
    });
}

pub fn unordered_list_wrap(p: *PostParser) SemanticError!void {
    const first_item_idx = p.nodecursor;
    // node cursor is on current item node, so first iter always true
    while (std.meta.eql(p.nodes[p.nodecursor].kind, .{ .L0 = .Item })) : (p.nodecursor += 1) {
        if (p.nodecursor >= p.nodec) break;
    }
    // first iter always true: atleast 1 increment => correct
    // break means out of node array, if item node was last => also correct

    spush_node(p, .ItemListClose, first_item_idx);
    spush_node(p, .ItemListOpen, p.nodecursor);
}
