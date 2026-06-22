const std = @import("std");
const Parser = @import("../Parser.zig");
const parse = @import("../actions/parse.zig");
const SyntaxError = parse.SyntaxError;

pub const RType = enum(c_uint) {
    BlockStart = 0b001,
    LineStart = 0b011,
    Inline = 0b111,
};

trigger: ?u8 = null,
func: fn (*Parser, usize) SyntaxError!void,
ruletype: RType = RType.Inline,

pub const rules = [_]@This(){
    .{ .func = parse.par, .ruletype = RType.BlockStart },
    .{ .trigger = '#', .func = parse.h1, .ruletype = RType.BlockStart },
    .{ .trigger = '-', .func = parse.items, .ruletype = RType.BlockStart },
    .{ .trigger = '!', .func = parse.attribute, .ruletype = RType.LineStart },
};

// without default rule
pub fn rules_by_ruletype(
    comptime ruletype: RType,
) []const @This() {
    const rt_int = @intFromEnum(ruletype);
    comptime var rs: []const @This() = &.{};
    inline for (rules) |rule| {
        if (rule.trigger != null and (@intFromEnum(rule.ruletype) & rt_int) != 0) {
            rs = rs ++ &[_]@This(){rule};
        }
    }
    return rs;
}

pub fn default_rule_by_ruletype(
    comptime ruletype: RType,
) ?@This() {
    const rt_int = @intFromEnum(ruletype);
    inline for (rules) |rule| {
        if (rule.trigger == null and (@intFromEnum(rule.ruletype) & rt_int) != 0) {
            return rule;
        }
    }
    return null;
}
