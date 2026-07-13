const std = @import("std");
const Parser = @import("../Parser.zig");
const Rule = @import("../../element/Rule.zig");
const Node = @import("../../element/Node.zig");
const CCEngine = @import("../../internal/CCEngine.zig");
const L0SyntaxError = Parser.ParsingError.L0SyntaxError;
const ErrorReporter = @import("../../ErrorReporter.zig");
const crash = @import("../../ErrorReporter.zig").crash;
const par = @import("../l0_rules.zig").par;

// here we construct the `commandlit_argtable`, through l1 `inl_cmd_<literal>_*`
//                                           OR through l0 `blk_cmd_<literal>_*`
// row-format: { lit_string, .{arg0_kind, arg1_kind, ...} }
const builtin_blk_cmdlit_argtbl = init_builtin_cmdlit_argtable(Node.L0Kind, "blk_cmd_");
const builtin_inl_cmdlit_argtbl = init_builtin_cmdlit_argtable(Node.L1Kind, "inl_cmd_");

fn get_builtin_cmdlit_args(
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

fn init_builtin_cmdlit_argtable(
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

// [L0 RULE]
pub fn l0_parse_block_command(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0Def.ApplyFinalState {
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

    const blkcmd_name_start = p.cursor;

    p.bounded_find(':', endat) catch {
        // same as above
        p.cursor = start;
        _ = par(p, endat) catch |err| return err;
        return .transitioned;
    };

    const blkcmd_name_end = p.cursor;

    // cursor is on ':', so we check if the blockcommand name is free of whitespace
    if (!p.bounds_freeof_whitesp(blkcmd_name_start, blkcmd_name_end)) {
        return p.e.file_report(L0SyntaxError, true, "Space between blockcommand name and colon", null);
    }

    if (!p.bounds_freeof(blkcmd_name_start, blkcmd_name_end, '(')) {
        // we possibly have a l1 inline command that has somewhere in that line
        //   a colon, therefore we fall back to `par` gain
        p.cursor = start;
        _ = par(p, endat) catch |err| return err;
        return .transitioned;
    }

    // cursor is at ':'...
    p.inc();
    // ...now at first char of value

    const argareac = endat - p.cursor;

    if (argareac == 0) {
        return p.e.file_report(error.L1SyntaxError, true, "Missing command argument", null);
    }

    const blkcmd_name = p.text[blkcmd_name_start..blkcmd_name_end];

    if (get_builtin_cmdlit_args(Node.L0Kind, builtin_blk_cmdlit_argtbl, blkcmd_name)) |builtin_blkcmd_argtup| {
        try generic_parse_cmd_args(p, blkcmd_name, .l0, builtin_blkcmd_argtup.len, builtin_blkcmd_argtup, argareac);
        return .success;
    }

    if (p.custom_cmd_engine.get_custom_cmd_by_literal(true, @Vector(2, usize){ blkcmd_name_start, blkcmd_name_end })) |custom_cmd_info| {
        try generic_parse_cmd_args(p, blkcmd_name, .custom_l0, custom_cmd_info.argc, custom_cmd_info.id, argareac);
        return .success;
    }

    // error case when there is no builtin and no custom command found
    const known_builtin_blkcmds_str = comptime blk: {
        var list: []const u8 = &.{};
        for (builtin_blk_cmdlit_argtbl) |row| {
            list = list ++ row[0] ++ ", ";
        }
        break :blk list;
    };

    const known_custom_blkcmd_info = p.custom_cmd_engine.alloc_debug_cmd_list(true);
    defer p.custom_cmd_engine.alloc.free(known_custom_blkcmd_info);

    return p.e.file_report(
        L0SyntaxError,
        true,
        .{
            "Unknown block-command: \"{s}\", choose from:\n- BUILTIN: {s}\n- CUSTOM: {s}",
            .{ blkcmd_name, known_builtin_blkcmds_str, known_custom_blkcmd_info },
        },
        null,
    );
}

// [L1 RULE]
// here, we abuse the fact that we could return null, so it seems that we generated nothing,
//   but we took advantage of p being available to push the arg nodes "under the hood".
pub fn l1_parse_inline_command(p: *Parser, endat: usize) Parser.ParsingError!usize {
    // we only accept commands of type @key(arg), while having cursor on @+1
    const inlcmd_name_start = p.cursor;

    const namec = p.bounded_findc('(', endat) catch {
        return p.e.file_report(error.L1SyntaxError, true, "Missing command name", null);
    };

    const inlcmd_name_end = p.cursor;

    if (namec == 0) {
        return p.e.file_report(error.L1SyntaxError, true, "Missing command name", null);
    }

    // cursor is on '('
    if (!p.bounds_freeof_whitesp(inlcmd_name_start, p.cursor)) {
        return p.e.file_report(error.L1SyntaxError, true, "White space in command name not allowed", null);
    }

    p.inc(); // cursor is now on first letter of arg

    const argarea0_at = p.cursor;

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
    p.inc();
    const cursor_postall_save = p.cursor;
    defer p.cursor = cursor_postall_save; // to be back on the first char after ')'

    p.cursor = argarea0_at;

    const inlcmd_name = p.text[inlcmd_name_start..inlcmd_name_end];
    if (get_builtin_cmdlit_args(Node.L1Kind, builtin_inl_cmdlit_argtbl, inlcmd_name)) |builtin_inlcmd_argtup| {
        const cursor_save = p.cursor;
        defer p.cursor = cursor_save; // to be back on the first char after ')'

        p.cursor = argarea0_at;

        try generic_parse_cmd_args(p, inlcmd_name, .l1, builtin_inlcmd_argtup.len, builtin_inlcmd_argtup, argareac);
        return builtin_inlcmd_argtup.len;
    }

    if (p.custom_cmd_engine.get_custom_cmd_by_literal(false, @Vector(2, usize){ inlcmd_name_start, inlcmd_name_end })) |custom_cmd_info| {
        try generic_parse_cmd_args(p, inlcmd_name, .custom_l1, custom_cmd_info.argc, custom_cmd_info.id, argareac);
        return custom_cmd_info.argc;
    }

    // error case when there is no builtin and no custom command found
    const known_builtin_inlcmds_str = comptime blk: {
        var list: []const u8 = &.{};
        for (builtin_inl_cmdlit_argtbl) |row| {
            list = list ++ row[0] ++ ", ";
        }
        break :blk list;
    };

    const known_custom_inlcmd_info = p.custom_cmd_engine.alloc_debug_cmd_list(false);
    defer p.custom_cmd_engine.alloc.free(known_custom_inlcmd_info);

    return p.e.file_report(
        L0SyntaxError,
        true,
        .{
            "Unknown inline-command: \"{s}\", choose from:\n- BUILTIN: {s}\n- CUSTOM: {s}",
            .{ inlcmd_name, known_builtin_inlcmds_str, known_custom_inlcmd_info },
        },
        null,
    );
}

fn generic_parse_cmd_args(
    p: *Parser,
    cmd_name: []const u8,
    comptime generic_cmd_data_info: enum { l0, l1, custom_l0, custom_l1 },
    argc: usize,
    generic_cmd_data: anytype,
    argareac: usize,
) Parser.ParsingError!void {
    if (argc == 0) crash("generic_parse_cmd_args called with argc=0, which is not allowed");

    const area_end = p.cursor + argareac;
    const prefix_len = "@".len + cmd_name.len + "(".len;

    var arg_start = p.cursor;
    var left_margin: usize = prefix_len;

    var i: usize = 0;
    while (i < argc) : (i += 1) {
        const is_last = (i == argc - 1);
        var arg_end: usize = undefined;
        var whitesp_pre_next: usize = 0;

        if (!is_last) {
            // scan for the next unescaped comma; skip escaped ones (\,) in place,
            // using backslash-run parity so `\\,` (escaped backslash + real comma)
            // is handled correctly, not just a single-char lookback
            var argi_c: usize = 0;
            while (true) {
                argi_c += p.bounded_findc(',', area_end) catch {
                    return p.e.file_report(error.CommandSyntaxError, true, .{ "Missing comma in command arguments, needed {d}", .{argc} }, null);
                };
                // cursor is on ','; count consecutive backslashes immediately before it
                var bs_count: usize = 0;
                var back = p.cursor;
                while (back > arg_start and p.text[back - 1] == '\\') : (back -= 1) bs_count += 1;

                if (bs_count % 2 == 0) break; // even (incl. 0) => not escaped, real delimiter

                // odd => this comma is escaped, skip past it and keep searching
                argi_c += 1;
                p.inc();
            }

            if (argi_c == 0) {
                return p.e.file_report(error.CommandSyntaxError, true, .{ "Missing argument in command, needed {d}", .{argc} }, null);
            }
            arg_end = arg_start + argi_c;

            p.inc(); // step past the comma

            p.bounded_skip_whitesp(area_end) catch {
                return p.e.file_report(error.CommandSyntaxError, true, .{ "Missing next argument in command, needed {d}", .{argc} }, null);
            };

            const next_arg_start = p.cursor;
            whitesp_pre_next = next_arg_start - (arg_end + ",".len);
        } else {
            arg_end = area_end;
        }

        const right_margin: usize = if (is_last) ")".len else ",".len;

        switch (generic_cmd_data_info) {
            .l0 => p.l0nodes.push(Node.L0{
                .kind = generic_cmd_data[i],
                .span = .{ arg_start, arg_end },
                .contains_l1 = true,
            }),
            .l1 => p.l1nodes.push(Node.L1{
                .kind = generic_cmd_data[i],
                .span = .{ arg_start, arg_end },
                .margin = .{ left_margin, right_margin },
            }),
            .custom_l0 => {
                const cmd_id = generic_cmd_data;
                p.l0nodes.push(Node.L0{
                    .kind = .blk_custom_cmd_arg,
                    .span = .{ arg_start, arg_end },
                    .contains_l1 = true,
                    .custom_command_id_arg = .{ cmd_id, i },
                });
            },
            .custom_l1 => {
                const cmd_id = generic_cmd_data;
                p.l1nodes.push(Node.L1{
                    .kind = .inl_custom_cmd_arg,
                    .span = .{ arg_start, arg_end },
                    .margin = .{ left_margin, right_margin },
                    .custom_command_id_arg = .{ cmd_id, i },
                });
            },
        }

        if (!is_last) {
            arg_start = p.cursor;
            left_margin = whitesp_pre_next;
        }
    }
}
