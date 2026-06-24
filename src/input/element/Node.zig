const std = @import("std");

pub const KindLevel0 = enum(u8) {
    AttributeStyle,
    AttributeHeader,

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
    CommandLink,
    CommandImage,
    CommandFigCaption,

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
        std.log.debug("is_l0: {any} for {any}", .{ std.meta.activeTag(self), self });
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

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .L0 => |a| @tagName(a),
            .L1 => |b| @tagName(b),
        };
    }
};

kind: Kind,
// these are all indices in the text buffer except for childc
textstart: usize,
textend: usize,

// we do not need children, if textstart and textend are in another node's
// text range, then it is a child of that node. this way we can avoid
// dynamic allocations for children lists.
