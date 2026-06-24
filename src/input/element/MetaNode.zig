const std = @import("std");

pub const Kind = enum(u8) {
    UnorderedItemListOpen,
    UnorderedItemListClose,

    OrderedItemListOpen,
    OrderedItemListClose,

    // todo these openers need to be typed for metadata...
};

kind: Kind,
before_node: usize,
