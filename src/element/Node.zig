const std = @import("std");

pub const L0 = struct {
    kind: L0Kind,
    span: ?@Vector(2, usize) = null,

    l1child0: ?usize = null,
    l1childhead: ?usize = null,

    contains_l1: bool = true,
};

pub const L1 = struct {
    kind: L1Kind,
    span: @Vector(2, usize), // mandatory, unlike above

    margin: @Vector(2, usize) = .{ 0, 0 },
};

pub const L0Kind = enum(u32) {
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

    nonparagraph,
    paragraph,

    footnote,
    footnote_block,

    code_block, // TODO, ``` with prism code class e.g. language-python in same name, otherwise err

    quote_block, // TODO, > err otherwise
    bold_quote_block, // TODO, >> err otherwise

    dash_item,
    dash_item_end,

    ordered_list_begin,
    ordered_list_end,

    unordered_list_begin,
    unordered_list_end,

    num_dot_item_label,
    num_dot_item_text,

    num_paren_item_label,
    num_paren_item_text,

    // attribute section
    style = 0xFF000000,
    script,
    header,
    abbreviation_def, // TODO!
    raw,

    pub fn is_attribute(self: @This()) bool {
        return @intFromEnum(self) & 0xFF000000 == 0xFF000000;
    }
};

pub const L1Kind = enum(u32) {
    inline_code,
    bold,
    strikethrough,

    italic,
    strikethrough_bold,

    bold_italic,
    strikethrough_italic,

    strikethrough_bold_italic,

    abbreviation, // TODO! with custom trigger letter

    // command section
    link = 0xFF000000,
    script,
    big, // TODO!
    small, // TODO!
    relsize, // TODO!
    color, // TODO!
    img, // TODO size
    import, // TODO!
    raw,

    pub fn is_command(self: @This()) bool {
        return @intFromEnum(self) & 0xFF000000 == 0xFF000000;
    }
};
