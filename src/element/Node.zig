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

    // i like naming them different than the l0 vars for clarity improvement
    //   but logically their the same
    l1_in_l1child0: ?usize = null,
    l1_in_l1childhead: ?usize = null,

    l1_in_l1: bool = true,
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
    code_block,

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
    blk_cmd_img_0src,
    blk_cmd_img_1size,
    blk_cmd_img_2caption,

    blk_cmd_header_text,
    blk_cmd_footer_text,
    blk_cmd_ar_text,
    blk_cmd_style_link,
    blk_cmd_script_link,

    // attribute section
    style, // in head tag, unlike above
    script, // in head tag, unline above
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

    // - inline command section: @command(...)
    // - no overloading!
    // - we do not push command node wrappers around args since they cost for nothing
    // - note: the `inl_cmd_` prefix is important since the `CommandEngine` parses commands out of them
    inl_cmd_link_0url,
    inl_cmd_link_1displayname,

    inl_cmd_fs_0size, // font-size
    inl_cmd_fs_1text,

    inl_cmd_color_0color,
    inl_cmd_color_1text,

    inl_cmd_div_0class,
    inl_cmd_div_1text,

    inl_cmd_span_0class,
    inl_cmd_span_1text,

    inl_cmd_ar_text,
    inl_cmd_raw_text,

    // TODO, datetime for under h1 in articles, should support the following styles:
    // 1. YYYY-MM-DD, 2. YYYY-MM-DD HH:mm, 3. YYYY-MM-DD HH:mm:ss
};
