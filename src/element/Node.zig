const std = @import("std");
const hack = @import("../hack.zig");

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

    l1child0: ?usize = null,
    l1childhead: ?usize = null,

    contains_l1: bool = true,
};

pub const L0Kind = enum(u8) {
    begin,

    head_anchor,

    heading1,
    heading2,
    heading3,
    heading4,
    heading5,
    heading6,

    nonparagraph,
    paragraph,
    arabic_paragraph,

    // bare footnotes are not planned due to them being at the page end -- not user-friendly in web
    detail, // TODO - ausklappbar
    footnote_block, // TODO - block
    sidenote, // TODO - sidenote - beautiful

    // all code_block_* nodes get omitted besides _caption, which is not always present.
    code_block_header,
    code_block_meta,
    code_block, // TODO: should support more than one block in content

    quote_block,
    bold_quote_block,
    italic_quote_block,
    bold_italic_quote_block,

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

    // blockcommand section: @@commandname: // TODO!: for all special nodes, safety measures by type
    img,
    header,
    footer,
    ar,

    // attribute section
    style, // also a blockcommand
    script, // also a blockcommand
    title,
    heading_icon,
    abbreviation_def, // TODO!

    end,
};

pub const L1Kind = enum(u8) {
    inline_code = @intFromEnum(L0Kind.end) + 1,
    bold,
    strikethrough,

    italic,
    strikethrough_bold,

    bold_italic,
    strikethrough_italic,

    strikethrough_bold_italic,

    abbreviation, // TODO! with custom trigger letter

    math, // TODO with $

    // inline command section: @command(...)
    link,
    fs, // font-size
    color,
    div,
    span,
    ar,
    raw,
    datetime, // for under h1 in articles // TODO, should support the following styles:
    // 1. YYYY-MM-DD, 2. YYYY-MM-DD HH:mm, 3. YYYY-MM-DD HH:mm:ss
};
