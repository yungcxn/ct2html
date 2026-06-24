const std = @import("std");
const PostParser = @import("../PostParser.zig");
const MetaNode = @import("../element/MetaNode.zig");
const Node = @import("../element/Node.zig");

pub const SemanticError = error{
    UnorderedListNeverClosed,
    OrderedListNeverClosed,
    UnknownOrderedListNodeType,
};

pub const rules = [_]PostParser.Rule{
    .{ .nodetrigger = .DashItem, .func = unordered_list_wrap },

    .{ .nodetrigger = .NumDotItemLabel, .func = ordered_list_wrap },
    .{ .nodetrigger = .NumParenItemLabel, .func = ordered_list_wrap },
    .{ .nodetrigger = .AlphDotItemLabel, .func = ordered_list_wrap },
    .{ .nodetrigger = .AlphParenItemLabel, .func = ordered_list_wrap },
    .{ .nodetrigger = .Begin, .func = head_wrap_bodystart },
    .{ .nodetrigger = .End, .func = bodyend },
};

fn spush_node(p: *PostParser, k: MetaNode.Kind, before_node: usize) void {
    p.push_metanode(.{
        .kind = k,
        .before_node = before_node,
    });
}

fn at_node_kind0(p: *PostParser, k: Node.KindLevel0) bool {
    return std.meta.eql(p.nodes[p.nodecursor].kind, .{ .L0 = k });
}

fn unordered_list_wrap(p: *PostParser) SemanticError!void {
    const first_item_idx = p.nodecursor;
    // node cursor is on current item node, so first iter always true
    while (at_node_kind0(p, .DashItem) and !at_node_kind0(p, .DashItemSentinel)) : (p.nodecursor += 1) {
        if (p.nodecursor >= p.nodec) return SemanticError.UnorderedListNeverClosed;
    }
    // first iter always true: atleast 1 increment => correct
    // break means out of node array, if item node was last => also correct

    spush_node(p, .UnorderedItemListClose, first_item_idx);
    spush_node(p, .UnorderedItemListOpen, p.nodecursor);
}

fn ordered_list_wrap(p: *PostParser) SemanticError!void {
    const first_item_idx = p.nodecursor;
    // this is flexible, we could be on any *ItemLabel, so we must get its type
    const itemlabelkind: Node.KindLevel0 = p.nodes[p.nodecursor].kind.L0;
    const itemtextkind: Node.KindLevel0 = switch (itemlabelkind) {
        .NumDotItemLabel => .NumDotItemText,
        .NumParenItemLabel => .NumParenItemText,
        .AlphDotItemLabel => .AlphDotItemText,
        .AlphParenItemLabel => .AlphParenItemText,
        else => return SemanticError.UnknownOrderedListNodeType, // should never happen
    };
    const itemsentinelkind: Node.KindLevel0 = switch (itemlabelkind) {
        .NumDotItemLabel => .NumDotItemSentinel,
        .NumParenItemLabel => .NumParenItemSentinel,
        .AlphDotItemLabel => .AlphDotItemSentinel,
        .AlphParenItemLabel => .AlphParenItemSentinel,
        else => return SemanticError.UnknownOrderedListNodeType, // should never happen
    };

    // node cursor is on current item node, so first iter always true
    while ((at_node_kind0(p, itemlabelkind) or at_node_kind0(p, itemtextkind)) and
        !at_node_kind0(p, itemsentinelkind)) : (p.nodecursor += 1)
    {
        if (p.nodecursor >= p.nodec) return SemanticError.OrderedListNeverClosed;
    }
    // first iter always true: atleast 1 increment => correct
    // break means out of node array, if item node was last => also correct

    spush_node(p, .OrderedItemListClose, first_item_idx);
    spush_node(p, .OrderedItemListOpen, p.nodecursor);
}

fn head_wrap_bodystart(p: *PostParser) SemanticError!void {
    spush_node(p, .HeadOpen, p.nodecursor);
    spush_node(p, .BodyOpen, p.nodecursor);
}

fn bodyend(p: *PostParser) SemanticError!void {
    spush_node(p, .BodyClose, p.nodecursor);
    spush_node(p, .HeadClose, p.nodecursor);
}

fn fig_wrap_img(p: *PostParser) SemanticError!void {
    spush_node(p, .FigureOpen, p.nodecursor);
    spush_node(p, .FigureClose, p.nodecursor);
}
