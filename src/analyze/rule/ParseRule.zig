const std = @import("std");
const Parser = @import("../Parser.zig");
const l0_parse = @import("../actions/l0_parse.zig");
const l1_parse = @import("../actions/l1_parse.zig");

const L0SyntaxError = l0_parse.SyntaxError;
const L1SyntaxError = l1_parse.SyntaxError;

pub const SyntaxError = L0SyntaxError || L1SyntaxError;

trigger: ?u8 = null,
func: fn (*Parser, usize) SyntaxError!void,
rescan_for_l1: bool = true, // could l1 rules be applied in this rule block?, not for l1 rules

// every func that is here registered is not required to have the cursor on some position afterwards
pub const l0_rules = [_]@This(){
    .{
        .func = l0_parse.par, // default
    },
    .{ .trigger = '#', .func = l0_parse.heading },
    .{ .trigger = '-', .func = l0_parse.items },
    .{ .trigger = '!', .func = l0_parse.attributes, .rescan_for_l1 = false },
};

// every func here IS required to have the cursor moved on some non-to-scan position afterwards
pub const l1_rules = [_]@This(){
    .{ .trigger = '*', .func = l1_parse.bold_italic_both },
    .{ .trigger = '_', .func = l1_parse.st_stb_sti_all }, // strikethrough, bold, italic, all
    .{ .trigger = '`', .func = l1_parse.inline_code },
    // .{ .trigger = '@', .func = l1_parse.command },
};
