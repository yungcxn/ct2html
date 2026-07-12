const std = @import("std");
const DynBuf = @import("../ds/DynBuf.zig");
const Node = @import("../element/Node.zig");
const Rule = @import("../element/Rule.zig");
const Parser = @import("../input/Parser.zig");
const L0SyntaxError = Parser.ParsingError.L0SyntaxError;

// TODO custom commands through attributes, should be for l1 and l0
// since we parsing attributes is the first optional step during parsing, we
//   can generate custom commands for l0 and l1.
// because standard commands also may be complex (through running functions),
//   they get treated differently and are being handled in the `Generator`
attributed_cmd_table: DynBuf(void),

pub fn init(
    alloc: std.mem.Allocator,
) @This() {
    return .{
        .attributed_cmd_table = .init(alloc, 20),
        .cursor = 0,
    };
}

pub fn deinit(self: *@This()) void {
    self.attributed_cmd_table.deinit();
}

pub fn parse_block_command(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0Def.ApplyFinalState {
    const start = p.cursor;
    // we assume we are on '@'
    const atc: usize = p.skipc('@') catch {
        return p.e.file_report(L0SyntaxError, true, "Nothing after @ for blockcommand", null);
    };

    if (atc != 2) {
        // just do a par out of this, since it could be a usual @command() at the start of a par
        p.cursor = start;
        _ = @import("../input/l0_rules.zig").par(p, endat) catch |err| return err;
        return .transitioned;
    }

    const blockcmd_name_start = p.cursor;

    p.bounded_find(':', endat) catch {
        return p.e.file_report(L0SyntaxError, true, "Missing colon after blockcommand name", null);
    };

    // cursor is on ':', so we check if the blockcommand name is free of whitespace
    if (!p.bounds_freeof_whitesp(blockcmd_name_start, p.cursor)) {
        return p.e.file_report(L0SyntaxError, true, "Space between blockcommand name and colon", null);
    }

    const blockcmd_name = p.text[blockcmd_name_start..p.cursor];
    const blockcmd_kind = std.meta.stringToEnum(Node.L0Kind, blockcmd_name) orelse {
        return p.e.file_report(L0SyntaxError, true, "Unknown blockcommand name", null);
    };

    // cursor is at ':'...
    p.inc();
    // ...now at first char of value

    p.l0nodes.push(.{
        .kind = blockcmd_kind,
        .span = .{ p.cursor, endat },
        .contains_l1 = true,
    });

    return .success;
}

const InlineCommandLiterals = enum(u8) {
    link,
    fs,
    color,
    div,
    span,
    ar,
    raw,
};

// here, we abuse the fact that we could return null, so it seems that we generated nothing,
//   but we took advantage of p being available to push the arg nodes "under the hood".
pub fn parse_inline_command(p: *Parser, endat: usize) Parser.ParsingError!usize {
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
    var nodes_pushed: usize = 0;
    {
        const cursor_save = p.cursor;
        p.cursor = p.cursor - argareac;

        nodes_pushed = try parse_inline_command_args(
            p,
            cmd_type,
            argareac,
        );

        p.cursor = cursor_save;
    }

    return nodes_pushed;
}

// should push bare arg nodes into l1 buffer
// cursor is assumed to be on the first char in argareac
fn parse_inline_command_args(
    p: *Parser,
    cmd_type: InlineCommandLiterals,
    argareac: usize,
) Parser.ParsingError!usize {
    const parse_1arg = struct {
        pub fn parse(pa: *Parser, areac: usize, cmdtype: InlineCommandLiterals, kind: Node.L1Kind) Parser.ParsingError!usize {
            // cursor is on first char of arg
            const arg_start = pa.cursor;
            const arg_end = pa.cursor + areac;

            // push a node for the arg
            pa.l1nodes.push(Node.L1{
                .kind = kind,
                .span = .{ arg_start, arg_end },
                .margin = .{ "@".len + @tagName(cmdtype).len + "(".len, ")".len },
            });
            return 1; // created one node
        }
    }.parse;

    const parse_2arg = struct {
        pub fn parse(pa: *Parser, areac: usize, cmdtype: InlineCommandLiterals, kind0: Node.L1Kind, kind1: Node.L1Kind) Parser.ParsingError!usize {
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

            pa.inc(); // to be one space after the comma

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
            return 2; // created two nodes
        }
    }.parse;

    switch (cmd_type) {
        .raw => return parse_1arg(p, argareac, cmd_type, .cmd_ar_1arg_text),
        .ar => return parse_1arg(p, argareac, cmd_type, .cmd_raw_1arg_bytes),
        .link => return parse_2arg(p, argareac, cmd_type, .cmd_link_2arg_0_url, .cmd_link_2arg_1_displayname),
        .fs => return parse_2arg(p, argareac, cmd_type, .cmd_fs_2arg_0_size, .cmd_fs_2arg_1_text),
        .color => return parse_2arg(p, argareac, cmd_type, .cmd_color_2arg_0_color, .cmd_color_2arg_1_text),
        .div => return parse_2arg(p, argareac, cmd_type, .cmd_div_2arg_0_class, .cmd_div_2arg_1_text),
        .span => return parse_2arg(p, argareac, cmd_type, .cmd_span_2arg_0_class, .cmd_span_2arg_1_text),
    }
}
