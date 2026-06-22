// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Parser = @import("../Parser.zig");
const ParsingError = Parser.ParsingError;

// every func here IS required to have the cursor moved on some non-to-scan position afterwards
pub const rules = [_]Parser.Rule{
    .{ .trigger = '*', .func = bold_italic_both },
    .{ .trigger = '_', .func = st_stb_sti_all }, // strikethrough, bold, italic, all
    .{ .trigger = '`', .func = inline_code },
    // .{ .trigger = '@', .func = l1_parse.command },
};

pub const SyntaxError = error{
    NotEnoughAsterisks,
    NotEnoughUnderlines,
    InlineCodeBacktick2NotFound,
};

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
