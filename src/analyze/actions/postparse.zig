const std = @import("std");
const PostParser = @import("../PostParser.zig");
const MetaNode = @import("../element/MetaNode.zig");
const NodeKind = @import("../element/Node.zig").Kind;

pub const SemanticError = error{
    ImpossibleListNesting,
};

pub fn unordered_list_wrap(p: *PostParser) SemanticError!void {
    const first_item_idx = p.nodecursor;
    // node cursor is on current item node, so first iter always true
    while (std.meta.eql(p.nodes[p.nodecursor].kind, .{ .L0 = .Item })) : (p.nodecursor += 1) {
        if (p.nodecursor >= p.nodec) break;
    }
    // first iter always true: atleast 1 increment => correct
    // break means out of node array, if item node was last => also correct

    p.push_metanode(.{
        .kind = .ItemListClose,
        .before_node = first_item_idx,
    });
    p.push_metanode(.{
        .kind = .ItemListOpen,
        .before_node = p.nodecursor,
    });
}
