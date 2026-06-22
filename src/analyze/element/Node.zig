const std = @import("std");

pub const KindLevel0 = enum(u8) {
    AttributeKey,
    AttributeValue,

    Heading1,
    Heading2,
    Heading3,
    Heading4,
    Heading5,
    Heading6,
    Paragraph,
    Item,
};

pub const KindLevel1 = enum(u8) {
    CommandKey,
    CommandValue,

    Bold,
    Italic,
    InlineCode,
};

pub const Kind = union(enum) {
    L0: KindLevel0,
    L1: KindLevel1,
};

kind: Kind,
// these are all indices in the text buffer except for childc
textstart: usize,
textend: usize,

// we do not need children, if textstart and textend are in another node's
// text range, then it is a child of that node. this way we can avoid
// dynamic allocations for children lists.
