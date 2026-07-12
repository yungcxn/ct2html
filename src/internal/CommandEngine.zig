const std = @import("std");
const DynBuf = @import("../ds/dynbuf.zig").DynBuf;
const Node = @import("../element/Node.zig");
const Rule = @import("../element/Rule.zig");
const Parser = @import("../input/Parser.zig");
const L0SyntaxError = Parser.ParsingError.L0SyntaxError;
const crash = @import("../ErrorReporter.zig").crash;
const par = @import("../input/l0_rules.zig").par;

// custom commands through attributes, should be for l1 and l0
// since we parsing attributes is the first optional step during parsing, we
//   can generate custom commands for l0 and l1.
// because standard commands also may be complex (through running functions),
//   they get treated differently and are being handled in the `Generator`
attributed_cmd_table: DynBuf(void),

pub fn init(
    alloc: std.mem.Allocator,
) @This() {
    return .{
        .attributed_cmd_table = .init(alloc, 10),
    };
}

pub fn deinit(self: *@This()) void {
    self.attributed_cmd_table.deinit();
}

// here we construct the `commandlit_argtable`, through l1 `inl_cmd_<literal>_*` l1node-kinds.
//                                           OR through l0 `blk_cmd_<literal>_*` l0node-kinds.
// row-format: { lit_string, .{arg0_kind, arg1_kind, ...} }
const block_commandlit_argtable = commandlit_argtable_init(Node.L0Kind, "blk_cmd_");
const inline_commandlit_argtable = commandlit_argtable_init(Node.L1Kind, "inl_cmd_");

fn get_commandlit_args(
    comptime Enum: type,
    comptime commandlit_argtable: anytype,
    lit: []const u8,
) ?[]const Enum {
    for (commandlit_argtable) |row| {
        if (std.mem.eql(u8, row[0], lit)) {
            return row[1];
        }
    }
    return null;
}

fn commandlit_argtable_init(
    comptime Enum: type,
    comptime name_prefix: []const u8,
) []const struct { []const u8, []const Enum } {
    @setEvalBranchQuota(10000);

    const fields = std.meta.fields(Enum);

    const column0 = comptime blk: {
        var list: []const []const u8 = &.{};
        inner: for (fields) |field| {
            if (std.mem.startsWith(u8, field.name, name_prefix)) {
                const front_cut_name = field.name[name_prefix.len..];
                const lit_len = std.mem.indexOf(u8, front_cut_name, "_") orelse continue :inner;
                const name = field.name[name_prefix.len .. name_prefix.len + lit_len];

                // check if `name` is already in `list` (dedupe)
                for (list) |existing| {
                    if (std.mem.eql(u8, existing, name)) continue :inner;
                }

                list = list ++ .{name};
            }
        }
        break :blk list;
    };

    const rows: []const struct { []const u8, []const Enum } = blk: {
        var list: []const struct { []const u8, []const Enum } = &.{};
        for (column0) |lit| {
            var argkinds: []const Enum = &.{};
            for (fields) |field| {
                if (std.mem.startsWith(u8, field.name, name_prefix ++ lit ++ "_")) {
                    argkinds = argkinds ++ .{@field(Enum, field.name)};
                }
            }
            list = list ++ .{.{ lit, argkinds }};
        }
        break :blk list;
    };

    return rows;
}

pub fn parse_block_command(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0Def.ApplyFinalState {
    const start = p.cursor;
    // we assume we are on '@'
    const atc: usize = p.skipc('@') catch {
        return p.e.file_report(L0SyntaxError, true, "Nothing after @ for blockcommand", null);
    };

    if (atc != 1) {
        // just do a par out of this, since it could be a usual @command() at the start of a par
        p.cursor = start;
        _ = par(p, endat) catch |err| return err;
        return .transitioned;
    }

    const blockcmd_name_start = p.cursor;

    p.bounded_find(':', endat) catch {
        // same as above
        p.cursor = start;
        _ = par(p, endat) catch |err| return err;
        return .transitioned;
    };

    // cursor is on ':', so we check if the blockcommand name is free of whitespace
    if (!p.bounds_freeof_whitesp(blockcmd_name_start, p.cursor)) {
        return p.e.file_report(L0SyntaxError, true, "Space between blockcommand name and colon", null);
    }

    if (!p.bounds_freeof(blockcmd_name_start, p.cursor, '(')) {
        // we possibly have a l1 inline command that has somewhere in that line
        //   a colon, therefore we fall back to `par` gain
        p.cursor = start;
        _ = par(p, endat) catch |err| return err;
        return .transitioned;
    }

    const blockcmd_name = p.text[blockcmd_name_start..p.cursor];
    const blockcmd_args = get_commandlit_args(Node.L0Kind, block_commandlit_argtable, blockcmd_name) orelse {
        const known_blockcmds = comptime blk: {
            var list: []const []const u8 = &.{};
            for (block_commandlit_argtable) |row| {
                list = list ++ .{row[0]};
            }
            break :blk list;
        };

        const known_blockcmds_str = comptime blk: {
            var list: []const u8 = &.{};
            for (known_blockcmds) |name| {
                list = list ++ name ++ ", ";
            }
            break :blk list;
        };

        return p.e.file_report(
            L0SyntaxError,
            true,
            .{ "Unknown blockcommand name, choose from: {s}", .{known_blockcmds_str} },
            null,
        );
    };

    // cursor is at ':'...
    p.inc();
    // ...now at first char of value

    const argareac = endat - p.cursor;

    if (argareac == 0) {
        return p.e.file_report(error.L1SyntaxError, true, "Missing command argument", null);
    }

    _ = try generic_parse_command_args(
        p,
        blockcmd_name,
        blockcmd_args,
        argareac,
    );

    return .success;
}

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
    const cmd_args = get_commandlit_args(Node.L1Kind, inline_commandlit_argtable, cmd_name) orelse {
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

        nodes_pushed = try generic_parse_command_args(
            p,
            cmd_name,
            cmd_args,
            argareac,
        );

        p.cursor = cursor_save;
    }

    return nodes_pushed;
}

// for l0 block commands, aswell as l1 inline commands
fn generic_parse_command_args(
    p: *Parser,
    cmd_name: []const u8,
    cmd_args: anytype, // []Node.L0Kind or []Node.L1Kind
    argareac: usize,
) Parser.ParsingError!usize { // returns created node cound, irrelevant for l0
    const parse_1arg = struct {
        pub fn parse(pa: *Parser, areac: usize, cmdname: []const u8, kind: anytype) Parser.ParsingError!usize {
            // cursor is on first char of arg
            const arg_start = pa.cursor;
            const arg_end = pa.cursor + areac;

            // push a node for the arg
            if (comptime @typeInfo(@TypeOf(cmd_args)).pointer.child == Node.L0Kind) {
                pa.l0nodes.push(Node.L0{
                    .kind = kind,
                    .span = .{ arg_start, arg_end },
                    .contains_l1 = true,
                });
            } else if (comptime @typeInfo(@TypeOf(cmd_args)).pointer.child == Node.L1Kind) {
                pa.l1nodes.push(Node.L1{
                    .kind = kind,
                    .span = .{ arg_start, arg_end },
                    .margin = .{ "@".len + cmdname.len + "(".len, ")".len },
                });
            } else {
                @compileError("cmd_args must be []Node.L0Kind or []Node.L1Kind");
            }
            return 1; // created one node
        }
    }.parse;

    const parse_2arg = struct {
        pub fn parse(pa: *Parser, areac: usize, cmdname: []const u8, kind0: anytype, kind1: anytype) Parser.ParsingError!usize {
            // cursor is on first char of arg
            const arg0_start = pa.cursor;
            const area_end = pa.cursor + areac;

            // find the comma separating the two args
            const arg0c = pa.bounded_findc(',', area_end) catch {
                return pa.e.file_report(error.CommandSyntaxError, true, "Missing comma in 2-arg command", null);
            };

            if (arg0c == 0) {
                return pa.e.file_report(error.CommandSyntaxError, true, "Missing first argument in 2-arg command", null);
            }

            pa.inc(); // to be one space after the comma

            pa.bounded_skip_whitesp(area_end) catch {
                return pa.e.file_report(error.CommandSyntaxError, true, "Missing second argument in 2-arg command", null);
            };

            const arg1_start = pa.cursor;
            const whitesp_pre_arg1 = arg1_start - (arg0_start + arg0c + ",".len);

            if (comptime @typeInfo(@TypeOf(cmd_args)).pointer.child == Node.L0Kind) {
                pa.l0nodes.push(Node.L0{
                    .kind = kind0,
                    .span = .{ arg0_start, arg0_start + arg0c },
                    .contains_l1 = true,
                });

                pa.l0nodes.push(Node.L0{
                    .kind = kind1,
                    .span = .{ arg1_start, area_end },
                    .contains_l1 = true,
                });
            } else if (comptime @typeInfo(@TypeOf(cmd_args)).pointer.child == Node.L1Kind) {
                pa.l1nodes.push(Node.L1{
                    .kind = kind0,
                    .span = .{ arg0_start, arg0_start + arg0c },
                    .margin = .{ "@".len + cmdname.len + "(".len, ",".len },
                });

                pa.l1nodes.push(Node.L1{
                    .kind = kind1,
                    .span = .{ arg1_start, area_end },
                    .margin = .{ whitesp_pre_arg1, ")".len },
                });
            } else {
                @compileError("cmd_args must be []Node.L0Kind or []Node.L1Kind");
            }
            return 2; // created two nodes
        }
    }.parse;

    const parse_3arg = struct {
        pub fn parse(
            pa: *Parser,
            areac: usize,
            cmdname: []const u8,
            kind0: anytype,
            kind1: anytype,
            kind2: anytype,
        ) Parser.ParsingError!usize {
            // cursor is on first char of arg
            const arg0_start = pa.cursor;
            const area_end = pa.cursor + areac;

            // find the first comma separating the three args
            const arg0c = pa.bounded_findc(',', area_end) catch {
                return pa.e.file_report(error.CommandSyntaxError, true, "Missing first comma in 3-arg command", null);
            };

            if (arg0c == 0) {
                return pa.e.file_report(error.CommandSyntaxError, true, "Missing first argument in 3-arg command", null);
            }

            pa.inc(); // to be one space after the comma

            pa.bounded_skip_whitesp(area_end) catch {
                return pa.e.file_report(error.CommandSyntaxError, true, "Missing second argument in 3-arg command", null);
            };

            const arg1_start = pa.cursor;

            // find the second comma separating the three args
            const arg1c = pa.bounded_findc(',', area_end) catch {
                return pa.e.file_report(error.CommandSyntaxError, true, "Missing second comma in 3-arg command", null);
            };

            if (arg1c == 0) {
                return pa.e.file_report(error.CommandSyntaxError, true, "Missing second argument in 3-arg command", null);
            }

            pa.inc(); // to be one space after the comma

            pa.bounded_skip_whitesp(area_end) catch {
                return pa.e.file_report(error.CommandSyntaxError, true, "Missing third argument in 3-arg command", null);
            };

            const arg2_start = pa.cursor;

            if (comptime @typeInfo(@TypeOf(cmd_args)).pointer.child == Node.L0Kind) {
                pa.l0nodes.push(Node.L0{
                    .kind = kind0,
                    .span = .{ arg0_start, arg0_start + arg0c },
                    .contains_l1 = true,
                });

                pa.l0nodes.push(Node.L0{
                    .kind = kind1,
                    .span = .{ arg1_start, arg1_start + arg1c },
                    .contains_l1 = true,
                });

                pa.l0nodes.push(Node.L0{
                    .kind = kind2,
                    .span = .{ arg2_start, area_end },
                    .contains_l1 = true,
                });
            } else if (comptime @typeInfo(@TypeOf(cmd_args)).pointer.child == Node.L1Kind) {
                pa.l1nodes.push(Node.L1{
                    .kind = kind0,
                    .span = .{ arg0_start, arg0_start + arg0c },
                    .margin = .{ "@".len + cmdname.len + "(".len, ",".len },
                });

                pa.l1nodes.push(Node.L1{
                    .kind = kind1,
                    .span = .{ arg1_start, arg1_start + arg1c },
                    .margin = .{ 0, ",".len },
                });

                pa.l1nodes.push(Node.L1{
                    .kind = kind2,
                    .span = .{ arg2_start, area_end },
                    .margin = .{ 0, ")".len },
                });
            } else {
                @compileError("cmd_args must be []Node.L0Kind or []Node.L1Kind");
            }
            return 3; // created three nodes
        }
    }.parse;

    switch (cmd_args.len) {
        1 => return parse_1arg(p, argareac, cmd_name, cmd_args[0]),
        2 => return parse_2arg(p, argareac, cmd_name, cmd_args[0], cmd_args[1]),
        3 => return parse_3arg(p, argareac, cmd_name, cmd_args[0], cmd_args[1], cmd_args[2]),
        else => crash("Unsupported number of command arguments"),
    }
}
