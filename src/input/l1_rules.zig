// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Rule = @import("../element/Rule.zig");
const Parser = @import("Parser.zig");
const hack = @import("../hack.zig");
const L1SyntaxError = Parser.ParsingError.L1SyntaxError;
const file_report = @import("../ErrorReporter.zig").file_report;

pub const datatable = hack.StructByteMap(.{
    .{ .{'@'}, Rule.L1Def.def(&command) },
    capture_def(&.{'`'}, .{.inline_code}),
    capture_def(&.{'*'}, .{ .bold, .italic, .bold_italic }),
    capture_def(&.{'_'}, .{ .strikethrough, .strikethrough_bold, .strikethrough_italic, .strikethrough_bold_italic }),
}).init();

// this is a common parser rule where we capture a substring withing a trigger
// or trigger set, e.g. '*bold-text*', and '**italic-text**' where the count of
// the trigger determines the node kind -> 1x*=Bold, 2x*=Italic, and so on...
fn capture_def(
    triggers: []const u8,
    comptime node_levels: anytype,
) struct {
    []const u8,
    Rule.L1Def,
} {
    return .{
        triggers,
        Rule.L1Def.def(struct {
            pub fn capture(p: *Parser, endat: usize) Parser.ParsingError!?Node.L1 {
                p.dec(); // to get cursor back to the first char on trigger
                const capturec = p.bounded_skipc(triggers, endat) catch {
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
                    chars_in_capture += p.bounded_findc(triggers, endat) catch {
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
                const capturec2 = p.bounded_skipc(triggers, endat) catch {
                    return p.e.file_report(error.L1SyntaxError, true, "Post-capture not found", level);
                };

                // e.g. ***txt-in-capture*** => capturec = 3, capturec2 = 3, must be same
                if (capturec2 != capturec) {
                    return p.e.file_report(error.L1SyntaxError, true, "Capture mismatch", level);
                }

                return Node.L1{
                    .kind = level.?,
                    .span = .{ text_start, text_start + chars_in_capture },
                    .margin = .{ capturec, capturec2 }, // both same len
                };

                // we return on cursor being +1 of the second capture, which is correct,
                // -> next pop gives the letter after the capture, as expected
            }
        }.capture),
    };
}

fn command(p: *Parser, endat: usize) Parser.ParsingError!?Node.L1 {
    // we only accept commands of type @key(arg), while having cursor on @+1
    const name_start = p.cursor;

    const namec = p.bounded_findc('(', endat) catch {
        return p.e.file_report(error.L1SyntaxError, true, "Missing command name", null);
    };

    if (namec == 0) {
        return p.e.file_report(error.L1SyntaxError, true, "Missing command name", null);
    }

    // cursor is on '('
    if (!p.bounds_freeof_whitesp(name_start, p.cursor)) {
        return p.e.file_report(error.L1SyntaxError, true, "White space in command name not allowed", null);
    }

    const cmd_name = p.text[name_start..p.cursor];
    const cmd_kind = std.meta.stringToEnum(
        Node.L1Kind,
        cmd_name,
    ) orelse {
        return p.e.file_report(error.L1SyntaxError, true, "Unknown command name", null);
    };

    p.inc(); // cursor is now on first letter of arg

    var argcharc: usize = 0;
    while (true) {
        argcharc += p.bounded_findc(')', endat) catch {
            return p.e.file_report(error.L1SyntaxError, true, "Missing command argument", cmd_kind);
        };
        // cursor is on trigger, and `argcharc` includes '\\'
        if (p.text[p.cursor - 1] == '\\') {
            // escaped trigger, so we skip it and continue searching
            argcharc += 1;
            p.inc();
            continue;
        } else {
            break;
        }
    }

    if (argcharc == 0) {
        return p.e.file_report(error.L1SyntaxError, true, "Missing command argument", cmd_kind);
    }

    // cursor is on ')', so for push we inc again after return
    defer p.inc();

    return Node.L1{
        .kind = cmd_kind,
        .span = .{ p.cursor - argcharc, p.cursor },
        .margin = .{ "@".len + cmd_name.len + "(".len, ")".len },
    };
}
