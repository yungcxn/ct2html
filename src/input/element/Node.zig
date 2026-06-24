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

    DashItem,
    DashItemSentinel, // sentinels are needed so that we do know when to separate two lists

    NumDotItemLabel,
    NumDotItemText,
    NumDotItemSentinel,

    NumParenItemLabel,
    NumParenItemText,
    NumParenItemSentinel,

    AlphDotItemLabel,
    AlphDotItemText,
    AlphDotItemSentinel,

    AlphParenItemLabel,
    AlphParenItemText,
    AlphParenItemSentinel,
};

pub const KindLevel1 = enum(u8) {
    CommandKey,
    CommandValue,

    InlineCode,

    Bold,
    Italic,
    BoldItalic,

    Strikethrough,
    StrikethroughBold,
    StrikethroughItalic,
    StrikethroughBoldItalic,
};

pub const Kind = union(enum) {
    L0: KindLevel0,
    L1: KindLevel1,

    pub fn l0(k: KindLevel0) Kind {
        return .{ .L0 = k };
    }

    pub fn l1(k: KindLevel1) Kind {
        return .{ .L1 = k };
    }

    pub fn is_l0(self: Kind) bool {
        return std.meta.activeTag(self) == .L0;
    }

    pub fn eq(self: Kind, other: Kind) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        if (self.is_l0()) {
            return self.L0 == other.L0;
        } else {
            return self.L1 == other.L1;
        }
    }
};

kind: Kind,
// these are all indices in the text buffer except for childc
textstart: usize,
textend: usize,

// we do not need children, if textstart and textend are in another node's
// text range, then it is a child of that node. this way we can avoid
// dynamic allocations for children lists.

pub fn is_l0(n: @This()) bool {
    return @TypeOf(n.kind) == KindLevel0;
}

fn is_kind(n: @This(), k: anytype) bool {
    if (@TypeOf(k) == KindLevel0) {
        return std.meta.eql(n.kind, .{ .L0 = k });
    } else if (@TypeOf(k) == KindLevel1) {
        return std.meta.eql(n.kind, .{ .L1 = k });
    } else {
        @compileError("k must be either KindLevel0 or KindLevel1");
    }
}
