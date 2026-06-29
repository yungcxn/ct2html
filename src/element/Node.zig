const std = @import("std");

// TODO split up kinds! and move margins into the l1 node def
pub const Kind = enum(u32) {

    // *kinds* are differentiated in:
    // - l0 (0b000...), with standard l0 nodes and l0-attribute nodes (0b001...)
    // - l1 (0b010...), with standard l1 nodes and l1-command nodes (0b100...)
    // ...this info occupies: 0xFF000000

    // *l1-nodes* share a different kind of info all along:
    // at 0x0000FF00 store enum values: 1: command, 2: capture

    pub const min_l0_attr_val: u32 = 1 << 29;
    pub const min_l1_val: u32 = 1 << 30;
    pub const min_l1_cmd_val: u32 = 1 << 31;
    fn new_l1_level(level: u32) u32 {
        return min_l1_val | (0x00000100 * level);
    }

    // --- l0 start ---
    begin,
    end,

    attribute_begin,
    attribute_end,

    heading1,
    heading2,
    heading3,
    heading4,
    heading5,
    heading6,
    paragraph,

    dash_item,
    dash_item_end, // sentinels are needed so that we do know when to separate two lists

    ordered_list_begin,
    ordered_list_end,

    unordered_list_begin,
    unordered_list_end,

    num_dot_item_label,
    num_dot_item_text,

    num_paren_item_label,
    num_paren_item_text,

    // attributes
    style = min_l0_attr_val,
    header,

    // --- l1 start ---
    inline_code = new_l1_level(1),
    bold,
    strikethrough,

    italic = new_l1_level(2),
    strikethrough_bold,

    bold_italic = new_l1_level(3),
    strikethrough_italic,

    strikethrough_bold_italic = new_l1_level(4),

    // commands
    link = min_l1_cmd_val, // collision avoidance
    img,

    pub fn is_l0(self: @This()) bool {
        return @intFromEnum(self) < min_l1_val;
    }

    pub fn is_l1(self: @This()) bool {
        return @intFromEnum(self) >= min_l1_val;
    }

    pub fn is_l0_attr(self: @This()) bool {
        return @intFromEnum(self) >= min_l0_attr_val and @intFromEnum(self) < min_l1_val;
    }

    pub fn is_l1_cmd(self: @This()) bool {
        return @intFromEnum(self) >= min_l1_cmd_val;
    }

    // according to the rule mentioned above
    pub fn l1_margin(self: @This()) struct { usize, usize } {
        const level = (@intFromEnum(self) & 0x0000FF00) >> 8;
        const is_command = self.is_l1_cmd() and level == 0;
        if (is_command) {
            return .{ "@".len + @tagName(self).len + "(".len, ")".len };
        } else {
            return .{ level, level };
        }
    }
};

pub const Span = struct {
    start: usize,
    end: usize,
};

kind: Kind,

// these are all indices in the text buffer except for childc
span: ?Span,

l1child0: ?usize = null,
l1childc: usize = 0,

contains_l1: bool = true,
