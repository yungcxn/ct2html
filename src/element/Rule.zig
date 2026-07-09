const std = @import("std");
const Parser = @import("../input/Parser.zig");
const Generator = @import("../output/Generator.zig");
const Node = @import("Node.zig");
const hack = @import("../hack.zig");
const ErrorReporter = @import("../ErrorReporter.zig");

pub fn DataTable(RuleInfoType: type) type { // RuleInfoType: e.g. L0Def.RuleInfoType
    return struct {
        lookup_table: [256]u8, // must be freed afterwards
        rule_table: []RuleInfoType,

        pub fn init(alloc: std.mem.Allocator, comptime rules: anytype) DataTable(RuleInfoType) {
            // `rules` could have optional type
            const rules_opt = @typeInfo(@typeInfo(@TypeOf(rules)).array.child) == .optional;

            const comptime_rule_table = comptime blk: {
                var list: []const RuleInfoType = &.{};
                for (rules) |rule| {
                    list = list ++ rule.rule_info;
                }

                break :blk list;
            };

            // rules has a certain order. If rules[n] is the rule for '#', lookup_table['#'] = n
            // these 256 bytes are smaller than huge L0 or L1 direct lookup arrays, e.g. direct rules['#']
            var lookup_table = alloc.alloc(u8, 256);
            lookup_table = @splat(0);
            for (rules, 0..) |rule, i| {
                for (rule.triggers) |trigger| {
                    lookup_table[trigger] = i;
                }
            }

            return .{ lookup_table, comptime_rule_table };
        }

        pub fn deinit(self: *DataTable(RuleInfoType), alloc: std.mem.Allocator) void {
            alloc.free(self.lookup);
        }

        pub fn lookup(self: *DataTable(RuleInfoType), int_or_enum_key: anytype) RuleInfoType {
            const int_idx = switch (@typeInfo(@TypeOf(int_or_enum_key))) {
                .int, .comptime_int => int_or_enum_key,
                .@"enum" => @intFromEnum(int_or_enum_key),
                .enum_literal => @compileError("Just enum literal provided, cannot induce backing int."),
                else => @compileError("Type without inducable index int"),
            };
            return self.rule_table[self.lookup_table[int_idx]];
        }
    };
}

pub const L0Def = struct {
    triggers: []const u8, // 0: paragraph
    rule_info: RuleInfo,

    pub const RuleInfo = struct {
        // may parse multiple nodes, due to structuring l0 blocks
        parse: fn (*Parser, usize) Parser.ParsingError!ApplyFinalState,
        pre_node: ?Node.L0Kind = null,
        post_node: ?Node.L0Kind = null,
        l1_rescan: bool = true, // could l1 rules be applied in this block?
    };

    pub const ApplyFinalState = enum(u8) {
        success,
        transitioned,
    };

    pub fn def(comptime triggers: anytype, comptime parse: anytype, comptime pre_node: ?Node.L0Kind, comptime post_node: ?Node.L0Kind, comptime l1_rescan: bool) L0Def {
        return .{
            .triggers = hack.force_u8slice(hack.force_tup(triggers)),
            .rule_info = .{
                .parse = parse,
                .pre_node = pre_node,
                .post_node = post_node,
                .l1_rescan = l1_rescan,
            },
        };
    }
};

// in-block rules, really simple, e.g. bold text
// TODO: l1 in l1
pub const L1Def = struct {
    triggers: []const u8,
    rule_info: RuleInfo,

    pub const RuleInfo = struct { // follows the structure above
        // only parses a single node, which is returned
        // null -> no node parsed
        parse_node: fn (*Parser, usize) Parser.ParsingError!?Node.L1,
    };

    pub fn def(comptime triggers: anytype, comptime parse_node: anytype) L1Def {
        return L1Def{
            .triggers = hack.force_u8slice(hack.force_tup(triggers)),
            .rule_info = .{
                .parse_node = parse_node,
            },
        };
    }
};

// Nodes carry not only the text boundary but for attributes or commands,
// sometimes something more complex is needed, therefore a text returning fn
pub const GenDef = struct {
    trigger: u32, // its the backing int of the `Node` kind enums. yes -- they're globally distinct
    rule_info: RuleInfo,

    pub const RuleInfo = struct { // follows the structure above
        algo: union(enum) {
            text: []const u8,
            prepost: struct { pre: []const u8, post: []const u8 },

            // only for l1:
            print: *const fn (g: *Generator, span: @Vector(2, usize)) Generator.GenError!void,
        },
    };

    pub fn def(comptime kind: anytype, algoval: anytype) GenDef {
        return GenDef{
            .kind = @enumFromInt(kind),
            .rule_info = .{
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
            },
        };
    }
};
