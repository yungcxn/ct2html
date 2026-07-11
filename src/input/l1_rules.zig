// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Rule = @import("../element/Rule.zig");
const Parser = @import("Parser.zig");
const hack = @import("../hack.zig");
const L1SyntaxError = Parser.ParsingError.L1SyntaxError;
const file_report = @import("../ErrorReporter.zig").file_report;
const crash = @import("../ErrorReporter.zig").crash;

pub const datatable = hack.StructByteMap(.{
    .{ .{'@'}, Rule.L1Def.def(&inline_command) },
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

// here, we abuse the fact that we could return null, so it seems that we generated nothing,
//   but we took advantage of p being available to push the arg nodes "under the hood".
fn inline_command(p: *Parser, endat: usize) Parser.ParsingError!?Node.L1 {
    const InlineCommandLiterals = enum(u8) {
        rawlink,
        link,
        fs,
        color,
        div,
        span,
        ar,
        raw,
    };

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
    const cmd_type = std.meta.stringToEnum(
        InlineCommandLiterals,
        cmd_name,
    ) orelse {
        return p.e.file_report(error.L1SyntaxError, true, "Unknown command name", null);
    };

    p.inc(); // cursor is now on first letter of arg

    var argareac: usize = 0;
    while (true) {
        argareac += p.bounded_findc(')', endat) catch {
            return p.e.file_report(error.L1SyntaxError, true, "Missing command argument", null);
        };
        // cursor is on trigger, and `argareac` includes '\\'
        if (p.text[p.cursor - 1] == '\\') {
            // escaped trigger, so we skip it and continue searching
            argareac += 1;
            p.inc();
            continue;
        } else {
            break;
        }
    }

    if (argareac == 0) {
        return p.e.file_report(error.L1SyntaxError, true, "Missing command argument", null);
    }

    // cursor is on ')', and it will be restored after the following block,
    //   so we just need to incr once to be on first char after ')'
    defer p.inc();
    {
        const cursor_save = p.cursor;
        p.cursor = p.cursor - argareac;

        parse_inline_command_args(InlineCommandLiterals, p, cmd_type, argareac) catch |err| {
            return p.e.file_report(error.L1SyntaxError, true, err, null);
        };
        p.cursor = cursor_save;
    }

    return null;
}

// should push bare arg nodes into l1 buffer
// cursor is assumed to be on the first char in argareac
fn parse_inline_command_args(
    comptime InlineCommandLiterals: type,
    p: *Parser,
    cmd_type: InlineCommandLiterals,
    argareac: usize,
) Parser.ParsingError!void {
    const parse_1arg = struct {
        pub fn parse(pa: *Parser, areac: usize, cmdtype: InlineCommandLiterals, kind: Node.L1Kind) Parser.ParsingError!void {
            // cursor is on first char of arg
            const arg_start = pa.cursor;
            const arg_end = pa.cursor + areac;

            // push a node for the arg
            pa.l1nodes.push(Node.L1{
                .kind = kind,
                .span = .{ arg_start, arg_end },
                .margin = .{ "@".len + @tagName(cmdtype).len + "(".len, ")".len },
            });
        }
    }.parse;

    const parse_2arg = struct {
        pub fn parse(pa: *Parser, areac: usize, cmdtype: InlineCommandLiterals, kind0: Node.L1Kind, kind1: Node.L1Kind) Parser.ParsingError!void {
            // cursor is on first char of arg
            const arg0_start = pa.cursor;
            const area_end = pa.cursor + areac;

            // find the comma separating the two args
            const arg0c = pa.bounded_findc(',', area_end) catch {
                return pa.e.file_report(error.L1SyntaxError, true, "Missing comma in 2-arg command", null);
            };

            if (arg0c == 0) {
                return pa.e.file_report(error.L1SyntaxError, true, "Missing first argument in 2-arg command", null);
            }

            pa.bounded_skip_whitesp(area_end) catch {
                return pa.e.file_report(error.L1SyntaxError, true, "Missing second argument in 2-arg command", null);
            };

            const arg1_start = pa.cursor;
            const whitesp_pre_arg1 = arg1_start - (arg0_start + arg0c + ",".len);

            pa.l1nodes.push(Node.L1{
                .kind = kind0,
                .span = .{ arg0_start, arg0_start + arg0c },
                .margin = .{ "@".len + @tagName(cmdtype).len + "(".len, ",".len },
            });

            pa.l1nodes.push(Node.L1{
                .kind = kind1,
                .span = .{ arg1_start, area_end },
                .margin = .{ whitesp_pre_arg1, ")".len },
            });
        }
    }.parse;

    switch (cmd_type) {
        .rawlink => return parse_1arg(p, argareac, cmd_type, .cmd_rawlink_1arg_url),
        .link => return parse_2arg(p, argareac, cmd_type, .cmd_link_2arg_0_url, .cmd_link_2arg_1_displayname),
        .fs => return parse_2arg(p, argareac, cmd_type, .cmd_fs_2arg_0_size, .cmd_fs_2arg_1_text),
        .color => return parse_2arg(p, argareac, cmd_type, .cmd_color_2arg_0_color, .cmd_color_2arg_1_text),
        .div => return parse_2arg(p, argareac, cmd_type, .cmd_div_2arg_0_class, .cmd_div_2arg_1_text),
        .span => return parse_2arg(p, argareac, cmd_type, .cmd_span_2arg_0_class, .cmd_span_2arg_1_text),
        else => crash("Unhandled command type in parse_inline_command_args"),
    }
}
