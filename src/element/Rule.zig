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
    parse_node: *const fn (*Parser, usize) Parser.ParsingError!usize,

    pub fn def(comptime parse_node: anytype) L1Def {
        return L1Def{ .parse_node = parse_node };
    }
};

// Nodes carry not only the text boundary but for attributes or commands,
// sometimes something more complex is needed, therefore a text returning fn
pub const GenDef = struct {
    pre_alg: GenPreAlg, // this has bs_esc by default as escmode
    post_alg: GenPostAlg, // this aswell
    esc_mode: Generator.EscMode = .all_esc,

    const GenPreAlg = union(enum) {
        constant: []const u8,
        complex: GenPreFn,
    };

    const GenPostAlg = union(enum) {
        constant: []const u8,
        complex: GenPostFn,
    };

    const GenPreFn = *const fn (
        g: *Generator,
        node: *anyopaque,
    ) Generator.GenError!?@Vector(2, usize);

    const GenPostFn = *const fn (
        g: *Generator,
        node: *anyopaque,
    ) Generator.GenError!void;

    pub fn def(pre: anytype, post: anytype, esc_mode: Generator.EscMode) GenDef {
        return .{
            .pre_alg = switch (@TypeOf(pre)) {
                GenPreFn => .{ .complex = pre },
                else => .{ .constant = pre },
            },
            .post_alg = switch (@TypeOf(post)) {
                GenPostFn => .{ .complex = post },
                else => .{ .constant = post },
            },
            .esc_mode = esc_mode,
        };
    }
};
