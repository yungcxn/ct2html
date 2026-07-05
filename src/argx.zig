const std = @import("std");
const builtin = @import("builtin");

pub fn Arg(T: type) type {
    return struct {
        T: type = T, // not part of the input value, just carried alongside for convenience
        fieldname: []const u8,
        short_altname: ?u8 = null,
        default: ?T = null,
        desc: []const u8,
    };
}

const example_args = .{
    Arg(u32){
        .fieldname = "number",
        .short_altname = 'n',
        .default = 42,
        .desc = "A number argument",
    },
    Arg([]const u8){
        .fieldname = "input",
        .short_altname = 'i',
        .desc = "Input string",
    },
    Arg(bool){
        .fieldname = "verbose",
        .short_altname = 'v',
        .default = false,
        .desc = "Enable verbose output",
    },
};

fn ArgsType(comptime argdef_tuple: anytype) type {
    const n = argdef_tuple.len;
    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    var attrs: [n]std.builtin.Type.StructField.Attributes = undefined;

    inline for (argdef_tuple, 0..) |argdef, i| {
        names[i] = argdef.fieldname;
        types[i] = switch (@typeInfo(argdef.T)) {
            .optional => @compileError("Optional args not supported, use default value instead"),
            else => argdef.T,
        };
        // default_value_ptr is `?*const anyopaque`, so the typed comptime pointer
        // needs an explicit cast. The value lives in the tuple's comptime memory
        // (or, for required fields, in this comptime-local zero value), so taking
        // its address here is valid. Required fields still get a placeholder
        // default purely so `Args{}` type-checks; actual requiredness is enforced
        // separately at runtime via reqs_satisfied in parse().
        const default_val: argdef.T = argdef.default orelse std.mem.zeroes(argdef.T);
        attrs[i] = .{ .default_value_ptr = @ptrCast(&default_val) };
    }

    return @Struct(.auto, null, &names, &types, &attrs);
}

fn cast(comptime T: type, stringval: []const u8) !T {
    if (T == []const u8) {
        return stringval;
    }
    return switch (@typeInfo(T)) {
        .int => try std.fmt.parseInt(T, stringval, 10),
        .float => try std.fmt.parseFloat(T, stringval),
        .bool => std.mem.eql(u8, stringval, "true") or std.mem.eql(u8, stringval, "1"),
        else => @compileError("Unsupported arg type: " ++ @typeName(T)),
    };
}

fn env_var_name(comptime fieldname: []const u8) [8 + fieldname.len]u8 {
    var buf: [8 + fieldname.len]u8 = undefined;
    @memcpy(buf[0..8], "CT2HTML_");
    for (fieldname, 0..) |c, idx| {
        buf[8 + idx] = std.ascii.toUpper(c);
    }
    return buf;
}

pub fn parse(
    comptime argdef_tuple: anytype,
    args: []const []const u8,
    environmap: ?std.process.Environ.Map,
) ArgsType(argdef_tuple) { // null: nothing was parsed due to -h/--help or no args
    const Args = ArgsType(argdef_tuple);
    var final_args: Args = .{};

    if (args.len > 1 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        print_help(argdef_tuple);
        std.process.exit(0);
    }

    var reqs_satisfied: [argdef_tuple.len]enum {
        set,
        unset,
        default,
    } = undefined;
    inline for (argdef_tuple, 0..) |argdef, i| {
        reqs_satisfied[i] = if (argdef.default != null) .default else .unset;
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len <= 1 or arg[0] != '-') {
            std.log.err("Unknown argument: {s}", .{arg});
            std.process.exit(1);
        }

        const dashc: usize = if (arg.len >= 2 and arg[1] == '-') 2 else 1;
        const name = arg[dashc..];

        var matched = false;
        inline for (argdef_tuple, 0..) |argdef, argdef_idx| {
            const found_longname = std.mem.eql(u8, name, argdef.fieldname);
            const found_shortname = name.len == 1 and
                argdef.short_altname != null and
                name[0] == argdef.short_altname.?;

            if (found_longname or found_shortname) {
                matched = true;
                if (argdef.T == bool) {
                    @field(final_args, argdef.fieldname) = true;
                } else {
                    const nextarg = if (i + 1 < args.len) args[i + 1] else null;
                    if (nextarg == null) {
                        std.log.err("Argument {s} expects a value, but none provided", .{arg});
                        std.process.exit(1);
                    }
                    @field(final_args, argdef.fieldname) = cast(argdef.T, nextarg.?) catch {
                        std.log.err("Wrong value for arg {s}: {s}", .{ arg, nextarg.? });
                        std.process.exit(1);
                    };
                    i += 1; // consumed nextarg
                }
                reqs_satisfied[argdef_idx] = .set;
            }
        }

        // environment check
        if (environmap) |env| {
            inline for (argdef_tuple, 0..) |argdef, idx| {
                if (reqs_satisfied[idx] != .set) {
                    const env_name_buf = comptime env_var_name(argdef.fieldname);
                    const env_name: []const u8 = &env_name_buf;
                    if (env.get(env_name)) |env_val| {
                        if (argdef.T == bool) {
                            @field(final_args, argdef.fieldname) = !std.mem.eql(u8, env_val, "false");
                        } else {
                            @field(final_args, argdef.fieldname) = cast(argdef.T, env_val) catch {
                                std.log.err("Wrong value for env var {s}: {s}", .{ env_name, env_val });
                                std.process.exit(1);
                            };
                        }
                        reqs_satisfied[idx] = .set;
                    }
                }
            }
        }

        if (!matched) {
            std.log.err("Unknown argument: {s}", .{arg});
            std.process.exit(1);
        }
    }

    inline for (argdef_tuple, 0..) |argdef, idx| {
        if (reqs_satisfied[idx] != .set and reqs_satisfied[idx] != .default) {
            std.log.err("Missing required argument: --{s}", .{argdef.fieldname});
            std.process.exit(1);
        }
    }

    return final_args;
}

fn typeLabel(comptime T: type) []const u8 {
    if (T == []const u8) return "<string>";
    return switch (@typeInfo(T)) {
        .bool => "",
        .int => "<int>",
        .float => "<float>",
        else => "<value>",
    };
}

pub fn print_help(comptime argdef_tuple: anytype) void {
    const w = std.debug.print;

    w("Usage:\n", .{});
    w("  -h, --help              Show this help message\n", .{});

    comptime var max_width: usize = 0;
    inline for (argdef_tuple) |argdef| {
        comptime var width: usize = 2 + argdef.fieldname.len; // "--fieldname"
        if (argdef.short_altname != null) width += 4; // ", -x"
        const label = comptime typeLabel(argdef.T);
        if (label.len > 0) width += 1 + label.len; // " <type>"
        if (width > max_width) max_width = width;
    }
    const col = max_width + 2;

    inline for (argdef_tuple) |argdef| {
        const label = comptime typeLabel(argdef.T);

        var buf: [256]u8 = undefined;
        var len: usize = 0;

        @memcpy(buf[len..][0..2], "--");
        len += 2;
        @memcpy(buf[len..][0..argdef.fieldname.len], argdef.fieldname);
        len += argdef.fieldname.len;

        if (argdef.short_altname) |sc| {
            buf[len] = ',';
            buf[len + 1] = ' ';
            buf[len + 2] = '-';
            buf[len + 3] = sc;
            len += 4;
        }

        if (label.len > 0) {
            buf[len] = ' ';
            len += 1;
            @memcpy(buf[len..][0..label.len], label);
            len += label.len;
        }

        const flag_str: []const u8 = buf[0..len];
        const pad = if (col > flag_str.len) col - flag_str.len else 1;

        w("  {s}", .{flag_str});
        var pad_left = pad;
        while (pad_left > 0) : (pad_left -= 1) w(" ", .{});
        w("{s}", .{argdef.desc});

        if (argdef.default) |d| {
            switch (@typeInfo(argdef.T)) {
                .bool => w(" (default: {})", .{d}),
                .int => w(" (default: {d})", .{d}),
                .float => w(" (default: {d})", .{d}),
                else => if (argdef.T == []const u8) w(" (default: \"{s}\")", .{d}) else {},
            }
        } else {
            w(" (required)", .{});
        }
        w("\n", .{});
    }
}
