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
    MissingCommandArg,
    UnknownCommandName,
    WhiteSpaceInCommandNameNotAllowed,
};

pub const SyntaxError = error{
    NotEnoughAsterisks,
    NotEnoughUnderlines,
    InlineCodeBacktick2NotFound,
} || CommandSyntaxError;

fn capture_for(
    p: *Parser,
    comptime capture: u8,
    k: Node.KindLevel1,
    endat: usize,
    err: SyntaxError,
) SyntaxError!Parser.Rule.ApplyState {
    // we assume cursor pos is +1 after capture
    const chars_in_capture = p.bounded(p.skip(capture, true), endat) catch {
        return err;
    };
    p.push_l1node(k, p.cursor - chars_in_capture, p.cursor);

    // cursor is at second capture now, and on return we must be on +1, such
    // that on next parse iter we pop (pop) the letter after the capture
    p.inc();

    return .did_not_transition;
}

fn capture_for_inlevels(
    p: *Parser,
    comptime capture: u8,
    comptime level_kinds: anytype,
    endat: usize,
    err: SyntaxError,
) SyntaxError!Parser.Rule.ApplyState {
    // we assume cursor pos is on second capture letter, so we move back
    // to cound the capture to get the level
    p.dec();
    const capturec = p.bounded(p.skip(capture, false), endat) catch {
        return err;
    };
    const text_start = p.cursor;

    var level: ?Node.KindLevel1 = null;
    {
        // TODO give l1 nodes a level number table field, rework `Node`
        // primitive, but needed in half-comptime half-runtime world

        inline for (level_kinds, 1..) |lk, idx| {
            if (capturec == idx) {
                level = lk;
            }
        }
        if (level == null) return err;
    }

    // cursor is at first letter after capture, much like in `capture_for`
    const chars_in_capture = p.bounded(p.skip(capture, true), endat) catch {
        return err;
    };

    // cursor is on the first of the capture, repeat
    const capturec2 = p.bounded(p.skip(capture, false), endat) catch {
        return err;
    };

    // e.g. ***txt-in-capture*** => capturec = 3, capturec2 = 3, must be same
    if (capturec2 != capturec) return err;

    p.push_l1node(level.?, text_start, text_start + chars_in_capture);

    // we return on cursor being +1 of the second capture, which is correct,
    // -> next pop gives the letter after the capture, as expected
    return .did_not_transition;
}

pub fn bold_italic_both(
    p: *Parser,
    endat: usize,
) SyntaxError!Parser.Rule.ApplyState {
    return capture_for_inlevels(
        p,
        '*',
        .{ .Bold, .Italic, .BoldItalic },
        endat,
        SyntaxError.NotEnoughAsterisks,
    );
}

pub fn st_stb_sti_all(
    p: *Parser,
    endat: usize,
) SyntaxError!Parser.Rule.ApplyState {
    return capture_for_inlevels(
        p,
        '_',
        .{ .Strikethrough, .StrikethroughBold, .StrikethroughItalic, .StrikethroughBoldItalic },
        endat,
        SyntaxError.NotEnoughUnderlines,
    );
}

pub fn inline_code(p: *Parser, endat: usize) SyntaxError!Parser.Rule.ApplyState {
    return capture_for(
        p,
        '`',
        .InlineCode,
        endat,
        SyntaxError.InlineCodeBacktick2NotFound,
    );
}

pub fn command(p: *Parser, endat: usize) SyntaxError!Parser.Rule.ApplyState {
    // we only accept commands of type @key(arg), while having cursor on @
    const name_start = p.cursor;

    const namec = p.bounded(p.skip('(', true), endat) catch {
        return CommandSyntaxError.MissingCommandName;
    };

    if (namec == 0) return CommandSyntaxError.MissingCommandName;

    // cursor is on '('
    const cmd_name = p.text[name_start..p.cursor];
    if (std.mem.containsAtLeast(u8, cmd_name, 0, &.{ ' ', '\t' })) {
        return CommandSyntaxError.WhiteSpaceInCommandNameNotAllowed;
    }

    const cmd_kind = cmd_nodekind_map.get(cmd_name) orelse {
        return CommandSyntaxError.UnknownCommandName;
    };

    p.inc(); // cursor is now on first letter of arg
    const argcharc = p.bounded(p.skip(')', true), endat) catch {
        return CommandSyntaxError.MissingCommandArg;
    };

    if (argcharc == 0) return CommandSyntaxError.MissingCommandArg;

    p.push_l1node(cmd_kind, name_start, p.cursor);

    // cursor is on ')', so for push we inc again
    p.inc();

    return .did_not_transition;
}
