const std = @import("std");

pub const Kind = enum(u8) {
    UnorderedItemListOpen,
    UnorderedItemListClose,

    OrderedItemListOpen,
    OrderedItemListClose,
};

kind: Kind,
before_node: usize,
