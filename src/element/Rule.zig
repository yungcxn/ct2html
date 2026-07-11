const std = @import("std");
const Parser = @import("../input/Parser.zig");
const Generator = @import("../output/Generator.zig");
const Node = @import("Node.zig");
const hack = @import("../hack.zig");
const ErrorReporter = @import("../ErrorReporter.zig");
const crash = ErrorReporter.crash;

pub const L0Def = struct {
    // may parse multiple nodes, due to structuring l0 blocks
    parse: *const fn (*Parser, usize) Parser.ParsingError!ApplyFinalState,
    pre_node: ?Node.L0Kind = null,
    post_node: ?Node.L0Kind = null,
    preserve_cursor: bool = false,

    pub const ApplyFinalState = enum(u8) {
        success,
        transitioned,
    };

    pub fn def(comptime parse: anytype, comptime pre_node: ?Node.L0Kind, comptime post_node: ?Node.L0Kind, comptime preserve_cursor: bool) L0Def {
        return .{
            .parse = parse,
            .pre_node = pre_node,
            .post_node = post_node,
            .preserve_cursor = preserve_cursor,
        };
    }
};

// in-block rules, really simple, e.g. bold text
// TODO: l1 in l1
pub const L1Def = struct {
    parse_node: *const fn (*Parser, usize) Parser.ParsingError!?Node.L1,

    pub fn def(comptime parse_node: anytype) L1Def {
        return L1Def{ .parse_node = parse_node };
    }
};

// Nodes carry not only the text boundary but for attributes or commands,
// sometimes something more complex is needed, therefore a text returning fn
pub const GenDef = struct {
    algo: union(enum) {
        text: []const u8,
        prepost: struct { pre: []const u8, post: []const u8 },

        // only for l1:
        print: *const fn (g: *Generator, span: ?@Vector(2, usize)) Generator.GenError!void,
    },

    pub fn def(algoval: anytype) GenDef {
        return GenDef{
            .algo = switch (@typeInfo(@TypeOf(algoval))) {
                .pointer => |p| switch (@typeInfo(p.child)) {
                    .@"fn" => .{ .print = algoval },
                    .array => .{ .text = algoval },
                    else => @compileError("Invalid algoval type for Gen: " ++
                        @typeName(@TypeOf(algoval))),
                },
                .@"struct" => .{ .prepost = .{
                    .pre = algoval[0],
                    .post = algoval[1],
                } },
                else => @compileError("Invalid algoval type for Gen"),
            },
        };
    }
};
