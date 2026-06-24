// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Parser = @import("../Parser.zig");
const ParsingError = Parser.ParsingError;

pub const cmd_nodekind_map = std.StaticStringMap(Node.KindLevel1).initComptime(.{
    .{ "link", .CommandLink },
    .{ "img", .CommandImage },
});

// every func here IS required to have the cursor moved on some non-to-scan position afterwards
pub const rules = [_]Parser.Rule{
    .{ .trigger = '*', .apply = &bold_italic_both },
    .{ .trigger = '_', .apply = &st_stb_sti_all }, // strikethrough, bold, italic, all
    .{ .trigger = '`', .apply = &inline_code },
    .{ .trigger = '@', .apply = &command },
};

pub const CommandSyntaxError = error{
    MissingCommandName,
    SpaceBeforeCommandNameNotAllowed,
    MissingCommandArg,
    UnknownCommandName,
};

pub const SyntaxError = error{
    NotEnoughAsterisks,
    NotEnoughUnderlines,
    InlineCodeBacktick2NotFound,
} || CommandSyntaxError;

fn spush_node(p: *Parser, k: Node.KindLevel1, textstart: usize, textend: usize) void {
    p.push_node(.{
        .kind = .{ .L1 = k },
        .textstart = textstart,
        .textend = textend,
    });
}

fn capture_for(p: *Parser, comptime capture: u8, k: Node.KindLevel1, endat: usize, err: SyntaxError) SyntaxError!void {
    const after_capture = p.cursor;
    if (after_capture >= endat) return err;
    p.mustfind_until(endat, .{capture}) catch return err;
    // cursor is at second capture now, and on return we must be on +1, such that on next parse iter
    //   we advance (pop) the letter after the capture
    p.cursor += 1;
    spush_node(p, k, after_capture, p.cursor - 1);
}

fn capture_for_inlevels(
    p: *Parser,
    comptime capture: u8,
    comptime level_kinds: anytype,
    endat: usize,
    err: SyntaxError,
) SyntaxError!void {
    var capturec: usize = 1;
    while (p.advance()) |c| {
        if (c != capture) break;
        capturec += 1;
    }
    if (p.cursor >= endat) return err;

    var level: ?Node.KindLevel1 = null;
    inline for (level_kinds, 1..) |lk, idx| { // primitive, but needed in half-comptime half-rt
        if (capturec == idx) {
            level = lk;
        }
    }
    if (level == null) return err;

    // cursor is at first letter after capture, much like in the normal `capture_for`
    const after_capture = p.cursor - 1;
    if (after_capture >= endat) return err;
    p.mustfind_until(endat, .{capture}) catch return err;
    // our cursor is on the first of the capture, go forth
    const first_captureend = p.cursor;
    var check_capturec: usize = 0;
    while (p.peek()) |c| {
        if (c != capture) break;
        check_capturec += 1;
        p.cursor += 1;
    }
    if (p.cursor >= endat) return err;
    if (check_capturec != capturec) return err;
    spush_node(p, level.?, after_capture, first_captureend);
}

pub fn bold_italic_both(p: *Parser, endat: usize) SyntaxError!void {
    try capture_for_inlevels(
        p,
        '*',
        .{ .Bold, .Italic, .BoldItalic },
        endat,
        SyntaxError.NotEnoughAsterisks,
    );
}

pub fn st_stb_sti_all(p: *Parser, endat: usize) SyntaxError!void {
    try capture_for_inlevels(
        p,
        '_',
        .{ .Strikethrough, .StrikethroughBold, .StrikethroughItalic, .StrikethroughBoldItalic },
        endat,
        SyntaxError.NotEnoughUnderlines,
    );
}

pub fn inline_code(p: *Parser, endat: usize) SyntaxError!void {
    try capture_for(p, '`', .InlineCode, endat, SyntaxError.InlineCodeBacktick2NotFound);
}

pub fn command(p: *Parser, endat: usize) SyntaxError!void {
    // we only accept commands of type @key(arg), while having cursor on @
    const name_start = p.cursor;
    while (p.advance()) |c| {
        if (c == '(') break;
        if (Parser.is_whitesp(c)) return CommandSyntaxError.SpaceBeforeCommandNameNotAllowed;
    }
    if (p.cursor >= endat or name_start == p.cursor) return CommandSyntaxError.MissingCommandName;
    // cursor is +1 of '(', so we exclusively add the command name
    const cmd_name = p.text[name_start .. p.cursor - 1];
    const cmd_kind = cmd_nodekind_map.get(cmd_name) orelse {
        p.cursor = name_start;
        return CommandSyntaxError.UnknownCommandName;
    };
    const arg_start = p.cursor;
    while (p.advance()) |c| {
        if (c == ')') break;
    }
    if (p.cursor >= endat or arg_start == p.cursor) return CommandSyntaxError.MissingCommandArg;
    // cursor is +1 of ')', so we exclusively add the command arg
    spush_node(p, cmd_kind, arg_start, p.cursor - 1);
}
