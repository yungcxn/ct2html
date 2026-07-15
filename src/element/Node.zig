const std = @import("std");
const hack = @import("../hack.zig");

// TODO: unify L0 and L1
pub const L0 = struct {
    kind: L0Kind,
    span: ?@Vector(2, usize) = null,

    l1child0: ?usize = null,
    l1childhead: ?usize = null,

    l1_containable: bool = true,

    // custom command nodes do not have enum kinds and need the identification
    //   to be done through this field, whereas something like
    //   `inl_cmd_link_0url` encodes command type (link) and the arg index
    custom_command_id_arg: ?@Vector(2, usize) = null,
};

pub const L1 = struct {
    kind: L1Kind,
    span: @Vector(2, usize), // mandatory, unlike above
    margin: @Vector(2, usize) = .{ 0, 0 },

    // i like naming them different than the l0 vars for clarity improvement
    //   but logically their the same
    l1child0: ?usize = null,
    l1childhead: ?usize = null,

    l1_containable: bool = true,

    // see above
    custom_command_id_arg: ?@Vector(2, usize) = null,
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
    sidenote,

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

    // blockcommand section: @commandname: arg0, arg1, ...
    blk_cmd_img_0src,
    blk_cmd_img_1size,
    blk_cmd_img_2caption,

    blk_cmd_header_text,
    blk_cmd_footer_text,

    blk_cmd_ar_text,

    blk_cmd_style_link,

    blk_cmd_script_link,

    blk_cmd_stylecode_code,

    blk_cmd_scriptcode_code,

    blk_cmd_details_0summary, // @details(<summary>, <text>)
    blk_cmd_details_1text,
    blk_cmd_info_0summary, // @info(<summary>, <text>)
    blk_cmd_info_1text,

    blk_custom_cmd_arg, // uses `L0.custom_command_id_arg`

    // attribute section
    style,
    script,
    stylecode,
    scriptcode,
    title,
    heading_icon,
    blkdef, // this and his brother below get used by `CommandEngine`
    inldef,

    abbreviation_def, // TODO! like env vars with $

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

    // since we need to encode the count of all sidenotes before this, and this cound gets embedded
    //   into the tag more than once, simple <pre>...<post> syntax is not feasible. Because of this,
    //   the `Parser` does not need to generate a sidenote-count node, but instead the `Generator`
    //   needs to generate the count in a complex pre-func.
    sidenote,

    // - inline command section: @command(...)
    // - no overloading!
    // - we do not push command node wrappers around args since they cost for nothing
    // - note: the `inl_cmd_` prefix is important since the `CommandEngine` parses commands out of them
    inl_cmd_link_0url,
    inl_cmd_link_1displayname,

    inl_cmd_color_0color,
    inl_cmd_color_1text,

    inl_cmd_div_0class,
    inl_cmd_div_1text,

    inl_cmd_span_0class,
    inl_cmd_span_1text,

    inl_cmd_ar_text,

    inl_cmd_fs_0size, // font-size
    inl_cmd_fs_1text,

    inl_cmd_raw_text,

    inl_custom_cmd_arg, // uses `L1.custom_command_id_arg`

    // TODO, datetime for under h1 in articles, should support the following styles:
    // 1. YYYY-MM-DD, 2. YYYY-MM-DD HH:mm, 3. YYYY-MM-DD HH:mm:ss
};
