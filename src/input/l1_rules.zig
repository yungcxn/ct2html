// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Rule = @import("../element/Rule.zig");
const Parser = @import("Parser.zig");
const allcmd_rules = @import("special/allcmd_rules.zig");
const hack = @import("../hack.zig");
const L1SyntaxError = Parser.ParsingError.L1SyntaxError;
const file_report = @import("../ErrorReporter.zig").file_report;
const crash = @import("../ErrorReporter.zig").crash;

pub const datatable = hack.StructByteMap(.{
    .{ .{'@'}, Rule.L1Def.def(&allcmd_rules.l1_parse_inline_command) },
    .{ .{'['}, Rule.L1Def.def(&sidenote) }, // for [[...]], and fallback to par on [] or escaped seq
    .{ .{'`'}, Rule.L1Def.def(&inline_code) },
    .{ .{'*'}, Rule.L1Def.def(&bold_and_sons) },
    .{ .{'_'}, Rule.L1Def.def(&strikethrough_and_sons) },
}).init();

fn sidenote(p: *Parser, endat: usize) Parser.ParsingError!usize {
    return generic_capture(p, endat, .{.sidenote}, 2);
}

fn inline_code(p: *Parser, endat: usize) Parser.ParsingError!usize {
    return generic_capture(p, endat, .{.inline_code}, 1);
}

fn bold_and_sons(p: *Parser, endat: usize) Parser.ParsingError!usize {
    return generic_capture(p, endat, .{ .bold, .italic, .bold_italic }, 1);
}

fn strikethrough_and_sons(p: *Parser, endat: usize) Parser.ParsingError!usize {
    return generic_capture(p, endat, .{ .strikethrough, .strikethrough_bold, .strikethrough_italic, .strikethrough_bold_italic }, 1);
}

inline fn generic_capture(
    p: *Parser,
    endat: usize,
    node_levels: anytype,
    level0_for: usize,
) Parser.ParsingError!usize {
    // to get cursor back to the first char on trigger
    p.dec();

    // we assume that the char we're on is the trigger:
    const opening_trigger = .{p.text[p.cursor]};
    const closing_trigger = switch (opening_trigger[0]) {
        '(' => .{')'},
        '[' => .{']'},
        '{' => .{'}'},
        '<' => .{'>'},
        else => opening_trigger,
    };

    const capturec = p.bounded_skipc(&opening_trigger, endat) catch {
        return p.e.file_report(error.L1SyntaxError, true, "Pre-capture not found", null);
    };
    const text_start = p.cursor;

    var level: ?Node.L1Kind = null;
    inline for (node_levels, level0_for..) |lk, idx| {
        if (capturec == idx) {
            level = lk;
        }
    }

    if (level == null) {
        // we have a start capture level, that is not to be searched for the given levels,
        //   which means, that the text is not to be captured. it still lives in parent text
        return 0;
    }

    // cursor is at first letter after capture, much like in `capture_for`
    var chars_in_capture: usize = 0;
    while (true) {
        chars_in_capture += p.bounded_findc(&closing_trigger, endat) catch {
            return p.e.file_report(error.L1SyntaxError, true, "Post-capture not found from text", level);
        };
        // cursor is on trigger, and `chars_in_capture` includes '\\'
        if (p.text[p.cursor - 1] == '\\') {
            // escaped trigger, so we skip it and continue searching
            chars_in_capture += 1;
            p.inc();
            continue;
        } else {
            break;
        }
    }

    var capturec2: usize = 0;
    while (p.cursor < endat and p.text[p.cursor] == closing_trigger[0]) {
        capturec2 += 1;
        p.inc();
    }

    if (capturec2 == 0) {
        return p.e.file_report(error.L1SyntaxError, true, "Post-capture not found from first closing-capture character", level);
    }

    // e.g. ***txt-in-capture*** => capturec = 3, capturec2 = 3, must be same
    if (capturec2 != capturec) {
        return p.e.file_report(error.L1SyntaxError, true, "Capture mismatch", level);
    }

    p.l1nodes.push(Node.L1{
        .kind = level.?,
        .span = .{ text_start, text_start + chars_in_capture },
        .margin = .{ capturec, capturec2 }, // both same len
    });

    // we return on cursor being +1 of the second capture, which is correct,
    // -> next pop gives the letter after the capture, as expected
    return 1; // created one node
}
