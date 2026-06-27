const std = @import("std");

pub const KindLevel0 = enum(u8) {
    BeginMeta,
    EndMeta,

    AttributeBeginMeta,
    AttributeStyle,
    AttributeHeader,
    AttributeEndMeta,

    Heading1,
    Heading2,
    Heading3,
    Heading4,
    Heading5,
    Heading6,
    Paragraph,

    DashItem,
    DashItemEndMeta, // sentinels are needed so that we do know when to separate two lists

    OrderedListBeginMeta,
    OrderedListEndMeta,

    UnorderedListBeginMeta,
    UnorderedListEndMeta,

    NumDotItemLabel,
    NumDotItemText,

    NumParenItemLabel,
    NumParenItemText,
};

pub const KindLevel1 = enum(u8) {
    CommandLink,
    CommandImage,

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

    pub fn auto(enum_literal: anytype) Kind {
        inline for (@typeInfo(KindLevel0).@"enum".fields) |f| {
            if (std.mem.eql(u8, f.name, @tagName(enum_literal))) {
                return .l0(enum_literal);
            }
        }
        inline for (@typeInfo(KindLevel1).@"enum".fields) |f| {
            if (std.mem.eql(u8, f.name, @tagName(enum_literal))) {
                return .l1(enum_literal);
            }
        }
        @compileError("Kind.auto got unexpected enum literal");
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
