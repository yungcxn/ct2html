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
//
// and the idx corresponds to the COMMAND-ID (important to grasp their generation)
custom_cmd_table: DynBuf(CustomCommandInfo),
alloc: std.mem.Allocator,

pub fn init(alloc: std.mem.Allocator) @This() {
    return @This(){
        .custom_cmd_table = .init(alloc, 0),
    };
}

pub fn deinit(self: *@This()) void {
    for (self.custom_cmd_table.slice_view()) |cmd| {
        cmd.deinit(self.alloc);
    }
    self.custom_cmd_table.deinit(self.alloc);
}

pub fn new_custom_command(
    self: *@This(),
    alloc: std.mem.Allocator,
    literal: []const u8,
    argc: usize,
) !usize { // returns the command id, which gets inserted into the node
    const idx = self.custom_cmd_table.len;
    const cmdinfo = CustomCommandInfo.init(alloc, literal, argc);
    try self.custom_cmd_table.append(cmdinfo);
    return idx;
}

pub const CustomCommandInfo = struct {
    literal: []const u8,
    argc: usize,
    pres: [][]u8, // for each arg
    posts: [][]u8, // for each arg

    pub fn init(
        alloc: std.mem.Allocator,
        literal: []const u8,
        argc: usize,
    ) CustomCommandInfo {
        return CustomCommandInfo{
            .literal = literal,
            .argc = argc,
            .pres = alloc.alloc([]u8, argc) catch crash(error.OOM),
            .posts = alloc.alloc([]u8, argc) catch crash(error.OOM),
        };
    }

    // we own the pres and posts due to the preprocessed text to be free'd early
    pub fn set_pre_post(
        self: *CustomCommandInfo,
        alloc: std.mem.Allocator,
        arg_idx: usize,
        pre: []const u8,
        post: []const u8,
    ) !void {
        if (arg_idx >= self.argc) {
            return error.InvalidArgument;
        }
        self.pres[arg_idx] = alloc.dupe(u8, pre) catch crash(error.OOM);
        self.posts[arg_idx] = alloc.dupe(u8, post) catch crash(error.OOM);
    }

    // we do not need to store an additional alloc pointer for many of `@This()`
    pub fn deinit(self: *CustomCommandInfo, alloc: std.mem.Allocator) void {
        for (self.argc) |i| {
            alloc.free(self.pres[i]);
            alloc.free(self.posts[i]);
        }
        alloc.free(self.pres);
        alloc.free(self.posts);
    }
};

// here we construct the `commandlit_argtable`, through l1 `inl_cmd_<literal>_*`
//                                           OR through l0 `blk_cmd_<literal>_*`
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

    // TODO NEXT: orelse: try to parse custom command
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

// [L1 RULE]
// here, we abuse the fact that we could return null, so it seems that we generated nothing,
//   but we took advantage of p being available to push the arg nodes "under the hood".
pub fn l1_parse_inline_command(p: *Parser, endat: usize) Parser.ParsingError!usize {
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
    // TODO NEXT: orelse: try to parse custom command
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

fn generic_parse_command_args(
    p: *Parser,
    cmd_name: []const u8,
    cmd_args: anytype, // []Node.L0Kind or []Node.L1Kind
    argareac: usize,
) Parser.ParsingError!usize {
    const n = cmd_args.len;
    if (n == 0) crash("Unsupported number of command arguments");

    const is_l0 = comptime @typeInfo(@TypeOf(cmd_args)).pointer.child == Node.L0Kind;
    const is_l1 = comptime @typeInfo(@TypeOf(cmd_args)).pointer.child == Node.L1Kind;
    if (!is_l0 and !is_l1) @compileError("cmd_args must be []Node.L0Kind or []Node.L1Kind");

    const area_end = p.cursor + argareac;
    const prefix_len = "@".len + cmd_name.len + "(".len;

    var arg_start = p.cursor;
    var left_margin: usize = prefix_len; // only the very first arg gets the "@name(" prefix

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const is_last = (i == n - 1);
        var arg_end: usize = undefined;
        var whitesp_pre_next: usize = 0;

        if (!is_last) {
            // only look for a comma if we still expect another argument after this one.
            // any comma inside the *last* argument's span is just text and is never searched for.
            const argc = p.bounded_findc(',', area_end) catch {
                return p.e.file_report(error.CommandSyntaxError, true, "Missing comma in command arguments", null);
            };
            if (argc == 0) {
                return p.e.file_report(error.CommandSyntaxError, true, "Missing argument in command", null);
            }
            arg_end = arg_start + argc;

            p.inc(); // step past the comma

            p.bounded_skip_whitesp(area_end) catch {
                return p.e.file_report(error.CommandSyntaxError, true, "Missing next argument in command", null);
            };

            const next_arg_start = p.cursor;
            whitesp_pre_next = next_arg_start - (arg_end + ",".len);
        } else {
            arg_end = area_end;
        }

        const right_margin: usize = if (is_last) ")".len else ",".len;

        if (is_l0) {
            p.l0nodes.push(Node.L0{
                .kind = cmd_args[i],
                .span = .{ arg_start, arg_end },
                .contains_l1 = true,
            });
        } else {
            p.l1nodes.push(Node.L1{
                .kind = cmd_args[i],
                .span = .{ arg_start, arg_end },
                .margin = .{ left_margin, right_margin },
            });
        }

        if (!is_last) {
            arg_start = p.cursor;
            left_margin = whitesp_pre_next;
        }
    }

    return n;
}
