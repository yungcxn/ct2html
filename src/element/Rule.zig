const std = @import("std");
const Parser = @import("../input/Parser.zig");
const Generator = @import("../output/Generator.zig");
const Node = @import("Node.zig");
const L0SyntaxError = @import("../input/l0_rules.zig").SyntaxError;
const L1SyntaxError = @import("../input/l1_rules.zig").SyntaxError;
const GeneratorError = Generator.Error;
const hack = @import("../hack.zig");

pub const L0 = struct {
    triggers: ?[]const u8 = null, // null: e.g. paragraph
    // may parse multiple nodes, due to structuring l0 blocks
    parse: *const fn (*Parser, usize) L0SyntaxError!ApplyFinalState,
    pre_node: ?Node.L0Kind = null,
    post_node: ?Node.L0Kind = null,
    l1_rescan: bool = true, // could l1 rules be applied in this block?

    pub const ApplyFinalState = enum(u8) {
        success,
        transitioned,
    };

    pub fn in_triggers(self: @This(), c: u8) bool {
        const t = self.triggers orelse return false;
        for (t) |trigger| {
            if (c == trigger) return true;
        }
        return false;
    }

    // TODO def
};

// in-block rules, really simple, e.g. bold text
pub const L1 = struct {
    triggers: []const u8,
    // only parses a single node, which is returned
    parse_node: *const fn (*Parser, usize) L1SyntaxError!Node.L1,

    pub fn in_triggers(self: @This(), c: u8) bool {
        for (self.triggers) |trigger| {
            if (c == trigger) return true;
        }
        return false;
    }

    // TODO def
};

// Nodes carry not only the text boundary but for attributes or commands,
// sometimes something more complex is needed, therefore a text returning fn
pub const Gen = struct {
    kind: union(enum) {
        l0: Node.L0Kind,
        l1: Node.L1Kind,
    },

    algo: union(enum) {
        text: []const u8,
        prepost: struct { pre: []const u8, post: []const u8 },

        // only for l1:
        replace: *const fn (g: *Generator) GeneratorError![]const u8,
    },

    pub fn def(comptime kind: @EnumLiteral(), algoval: anytype) Gen {
        const l0_enum = hack.from_enum_literal(Node.L0Kind, kind);
        const l1_enum = hack.from_enum_literal(Node.L1Kind, kind);

        if (l0_enum == null and l1_enum == null) {
            @compileError("Invalid kind for Gen: " ++ @typeName(@TypeOf(kind)));
        }

        return Gen{
            .kind = if (l0_enum == null)
                .{ .l1 = l1_enum.? }
            else
                .{ .l0 = l0_enum.? },

            .algo = switch (@typeInfo(@TypeOf(algoval))) {
                .pointer => |p| switch (@typeInfo(p.child)) {
                    .@"fn" => .{ .replace = algoval },
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
