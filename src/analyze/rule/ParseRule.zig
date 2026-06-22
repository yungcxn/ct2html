const std = @import("std");
const Parser = @import("../Parser.zig");
const l0_parse = @import("../actions/l0_parse.zig");
const l1_parse = @import("../actions/l1_parse.zig");

const L0SyntaxError = l0_parse.SyntaxError;
const L1SyntaxError = l1_parse.SyntaxError;

pub const SyntaxError = L0SyntaxError || L1SyntaxError;

trigger: ?u8 = null,
func: fn (*Parser, usize) SyntaxError!void,

pub const l0_rules = [_]@This(){
    .{
        .func = l0_parse.par, // default
    },
    .{ .trigger = '#', .func = l0_parse.heading },
    .{ .trigger = '-', .func = l0_parse.items },
    .{ .trigger = '!', .func = l0_parse.attributes },
};

pub const l1_rules = [_]@This(){
    // .{ .trigger = '*', .func = l1_parse.bold },
    // .{ .trigger = '_', .func = l1_parse.italic },
    // .{ .trigger = '@', .func = l1_parse.command },
};
