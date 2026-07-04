// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Rule = @import("../element/Rule.zig");
const Parser = @import("Parser.zig");
const L1SyntaxError = Parser.ParsingError.L1SyntaxError;
const force_tup = @import("../hack.zig").force_tup;
const file_report = @import("../ErrorReporter.zig").file_report;

pub const def = [_]Rule.L1{
    l1capture_rule('`', .inline_code),
    l1capture_rule('*', .{ .bold, .italic, .bold_italic }),
    l1capture_rule('_', .{
        .strikethrough,
        .strikethrough_bold,
        .strikethrough_italic,
        .strikethrough_bold_italic,
    }),

    .{ .triggers = &.{'@'}, .parse_node = &command },
};

// this is a common parser rule where we capture a substring withing a trigger
// or trigger set, e.g. '*bold-text*', and '**italic-text**' where the count of
// the trigger determines the node kind -> 1x*=Bold, 2x*=Italic, and so on...
fn l1capture_rule(
    trigger: anytype,
    comptime node_levels: anytype,
) Rule.L1 {
    return Rule.L1{
        .triggers = &.{trigger},
        .parse_node = struct {
            pub fn capture(p: *Parser, endat: usize) Parser.ParsingError!?Node.L1 {
                p.dec(); // to get cursor back to the first char on trigger
                const capturec = p.bounded_skipc(trigger, endat) catch {
                    file_report(error.L1Capture, true, "Pre-capture not found", null);
                    return L1SyntaxError;
                };
                const text_start = p.cursor;

                var level: ?Node.L1Kind = null;
                inline for (force_tup(node_levels), 1..) |lk, idx| {
                    if (capturec == idx) {
                        level = lk;
                    }
                }
                if (level == null) {
                    file_report(error.L1Capture, true, "No node kind for capture count", null);
                    return L1SyntaxError;
                }

                // cursor is at first letter after capture, much like in `capture_for`
                var chars_in_capture: usize = 0;
                while (true) {
                    chars_in_capture += p.bounded_findc(trigger, endat) catch {
                        file_report(error.L1Capture, true, "Post-capture not found", level);
                        return L1SyntaxError;
                    };
                    // cursor is on trigger, and `chars_in_capture` includes '\\'
                    if (p.text[p.cursor - 1] == '\\') {
                        // escaped trigger, so we skip it and continue searching
                        chars_in_capture += 1; // include capture
                        p.cursor += 1; // skip the trigger
                        continue;
                    } else {
                        break;
                    }
                }

                // cursor is on the first of the capture, repeat
                const capturec2 = p.bounded_skipc(trigger, endat) catch {
                    file_report(error.L1Capture, true, "Post-capture not found", level);
                    return L1SyntaxError;
                };

                // e.g. ***txt-in-capture*** => capturec = 3, capturec2 = 3, must be same
                if (capturec2 != capturec) {
                    file_report(error.L1Capture, true, "Capture mismatch", level);
                    return L1SyntaxError;
                }

                return Node.L1{
                    .kind = level.?,
                    .span = .{ text_start, text_start + chars_in_capture },
                    .margin = .{ capturec, capturec2 }, // both same len
                };

                // we return on cursor being +1 of the second capture, which is correct,
                // -> next pop gives the letter after the capture, as expected
            }
        }.capture,
    };
}

fn command(p: *Parser, endat: usize) Parser.ParsingError!?Node.L1 {
    // we only accept commands of type @key(arg), while having cursor on @+1
    const name_start = p.cursor;

    const namec = p.bounded_findc('(', endat) catch {
        file_report(error.L1Command, true, "Missing command name", null);
        return L1SyntaxError;
    };

    if (namec == 0) {
        file_report(error.L1Command, true, "Missing command name", null);
        return L1SyntaxError;
    }

    // cursor is on '('
    if (!p.bounds_freeof_whitesp(name_start, p.cursor)) {
        file_report(error.L1Command, true, "White space in command name not allowed", null);
        return L1SyntaxError;
    }

    const cmd_name = p.text[name_start..p.cursor];
    const cmd_kind = std.meta.stringToEnum(
        Node.L1Kind,
        cmd_name,
    ) orelse {
        file_report(error.L1Command, true, "Unknown command name", null);
        return L1SyntaxError;
    };

    if (!cmd_kind.is_command()) {
        file_report(error.L1Command, true, "Unknown command name", cmd_kind);
        return L1SyntaxError;
    }

    p.inc(); // cursor is now on first letter of arg

    var argcharc: usize = 0;
    while (true) {
        argcharc += p.bounded_findc(')', endat) catch {
            file_report(error.L1Command, true, "Missing command argument", cmd_kind);
            return L1SyntaxError;
        };
        // cursor is on trigger, and `argcharc` includes '\\'
        if (p.text[p.cursor - 1] == '\\') {
            // escaped trigger, so we skip it and continue searching
            argcharc += 1; // include capture
            p.cursor += 1; // skip the trigger
            continue;
        } else {
            break;
        }
    }

    if (argcharc == 0) {
        file_report(error.L1Command, true, "Missing command argument", cmd_kind);
        return L1SyntaxError;
    }

    // cursor is on ')', so for push we inc again after return
    defer p.inc();

    return Node.L1{
        .kind = cmd_kind,
        .span = .{ p.cursor - argcharc, p.cursor },
        .margin = .{ "@".len + cmd_name.len + "(".len, ")".len },
    };
}
