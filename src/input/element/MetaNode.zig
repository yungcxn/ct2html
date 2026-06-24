const std = @import("std");

pub const Kind = enum(u8) {
    UnorderedItemListOpen,
    UnorderedItemListClose,

    OrderedItemListOpen,
    OrderedItemListClose,

    HeadOpen,
    HeadClose,

    BodyOpen,
    BodyClose,
    // todo these openers need to be typed for metadata...

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }
};

kind: Kind,
before_node: usize,
