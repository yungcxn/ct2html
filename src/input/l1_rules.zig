// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Rule = @import("../element/Rule.zig");
const Parser = @import("Parser.zig");
const CommandEngine = @import("../internal/CommandEngine.zig");
const hack = @import("../hack.zig");
const L1SyntaxError = Parser.ParsingError.L1SyntaxError;
const file_report = @import("../ErrorReporter.zig").file_report;
const crash = @import("../ErrorReporter.zig").crash;

pub const datatable = hack.StructByteMap(.{
    .{ .{'@'}, Rule.L1Def.def(&CommandEngine.l1_parse_inline_command) },
    .{ .{'`'}, Rule.L1Def.def(&inline_code) },
    .{ .{'*'}, Rule.L1Def.def(&bold_and_sons) },
    .{ .{'_'}, Rule.L1Def.def(&strikethrough_and_sons) },
}).init();

pub fn inline_code(p: *Parser, endat: usize) Parser.ParsingError!usize {
    return generic_capture(p, endat, .{.inline_code});
}

pub fn bold_and_sons(p: *Parser, endat: usize) Parser.ParsingError!usize {
    return generic_capture(p, endat, .{ .bold, .italic, .bold_italic });
}

pub fn strikethrough_and_sons(p: *Parser, endat: usize) Parser.ParsingError!usize {
    return generic_capture(p, endat, .{ .strikethrough, .strikethrough_bold, .strikethrough_italic, .strikethrough_bold_italic });
}

// this is a common parser rule where we capture a substring withing a trigger
// or trigger set, e.g. '*bold-text*', and '**italic-text**' where the count of
// the trigger determines the node kind -> 1x*=Bold, 2x*=Italic, and so on...
inline fn generic_capture(
    p: *Parser,
    endat: usize,
    node_levels: anytype,
) Parser.ParsingError!usize {
    p.dec(); // to get cursor back to the first char on trigger
    // we assume that the char we're on is the trigger:
    const trigger = .{p.text[p.cursor]};

    const capturec = p.bounded_skipc(&trigger, endat) catch {
        return p.e.file_report(error.L1SyntaxError, true, "Pre-capture not found", null);
    };
    const text_start = p.cursor;

    var level: ?Node.L1Kind = null;
    inline for (node_levels, 1..) |lk, idx| {
        if (capturec == idx) {
            level = lk;
        }
    }
    if (level == null) {
        return p.e.file_report(error.L1SyntaxError, true, "No node kind for capture count", null);
    }

    // cursor is at first letter after capture, much like in `capture_for`
    var chars_in_capture: usize = 0;
    while (true) {
        chars_in_capture += p.bounded_findc(&trigger, endat) catch {
            return p.e.file_report(error.L1SyntaxError, true, "Post-capture not found", level);
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

    // cursor is on the first of the capture, repeat
    const capturec2 = p.bounded_skipc(&trigger, endat) catch {
        return p.e.file_report(error.L1SyntaxError, true, "Post-capture not found", level);
    };

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
