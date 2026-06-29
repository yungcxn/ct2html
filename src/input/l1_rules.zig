// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Rule = @import("../element/Rule.zig");
const Parser = @import("Parser.zig");
const force_tup = @import("../hack.zig").force_tup;

pub const CommandSyntaxError = error{
    MissingCommandName,
    MissingCommandArg,
    UnknownCommandName,
    WhiteSpaceInCommandNameNotAllowed,
};

pub const SyntaxError = error{LevelsAndCaptureLenMismatch} || CommandSyntaxError;

// .def TODO
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
            pub fn capture(
                p: *Parser,
                endat: usize,
            ) SyntaxError!Node {
                // we assume cursor pos is on second capture letter, so we move back
                // to cound the capture to get the level
                p.dec();
                const capturec = p.bounded_skipc(trigger, endat) catch {
                    return SyntaxError.LevelsAndCaptureLenMismatch;
                };
                const text_start = p.cursor;

                var level: ?Node.Kind = null;
                {
                    // TODO give l1 nodes a level number table field, rework `Node`
                    // primitive, but needed in half-comptime half-runtime world

                    inline for (force_tup(node_levels), 1..) |lk, idx| {
                        if (capturec == idx) {
                            level = lk;
                        }
                    }
                    if (level == null) return SyntaxError.LevelsAndCaptureLenMismatch;
                }

                // cursor is at first letter after capture, much like in `capture_for`
                const chars_in_capture = p.bounded_findc(trigger, endat) catch {
                    return SyntaxError.LevelsAndCaptureLenMismatch;
                };

                // cursor is on the first of the capture, repeat
                const capturec2 = p.bounded_skipc(trigger, endat) catch {
                    return SyntaxError.LevelsAndCaptureLenMismatch;
                };

                // e.g. ***txt-in-capture*** => capturec = 3, capturec2 = 3, must be same
                if (capturec2 != capturec) return SyntaxError.LevelsAndCaptureLenMismatch;

                return Node{
                    .kind = level.?,
                    .span = .{ .start = text_start, .end = text_start + chars_in_capture },
                };

                // we return on cursor being +1 of the second capture, which is correct,
                // -> next pop gives the letter after the capture, as expected
            }
        }.capture,
    };
}

fn command(p: *Parser, endat: usize) SyntaxError!Node {
    // we only accept commands of type @key(arg), while having cursor on @
    const name_start = p.cursor;

    const namec = p.bounded_findc('(', endat) catch {
        return CommandSyntaxError.MissingCommandName;
    };

    if (namec == 0) return CommandSyntaxError.MissingCommandName;

    // cursor is on '('
    if (!p.bounds_freeof_whitesp(name_start, p.cursor)) {
        return CommandSyntaxError.WhiteSpaceInCommandNameNotAllowed;
    }

    const cmd_kind = std.meta.stringToEnum(
        Node.Kind,
        p.text[name_start..p.cursor],
    ) orelse return CommandSyntaxError.UnknownCommandName;

    p.inc(); // cursor is now on first letter of arg
    const argcharc = p.bounded_findc(')', endat) catch {
        return CommandSyntaxError.MissingCommandArg;
    };

    if (argcharc == 0) return CommandSyntaxError.MissingCommandArg;

    // cursor is on ')', so for push we inc again after return
    defer p.inc();

    return Node{
        .kind = cmd_kind,
        .span = .{ .start = p.cursor - argcharc, .end = p.cursor },
    };
}
