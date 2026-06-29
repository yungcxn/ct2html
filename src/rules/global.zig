const std = @import("std");
const Parser = @import("../parse/Parser");
const Generator = @import("../output/Generator");

pub const RuleDef = struct {
    pub const SyntaxError = error{};
    pub const GenError = error{};

    pub const ParseState = enum(u8) {
        transitioned_to_p,
        did_not_transition,
        errd,
    };

    pub const GenEffect = union(enum) {
        prepost: struct {
            pre: []const u8,
            post: []const u8,
        },
        replace: *const fn (g: *Generator) GenError![]const u8,

        pub fn xprepost(pre: []const u8, post: []const u8) GenEffect {
            return .{ .prepost = .{ .pre = pre, .post = post } };
        }
        pub fn xreplace(f: *const fn (g: *Generator) GenError![]const u8) GenEffect {
            return .{ .replace = f };
        }

        pub fn eq(self: GenEffect, other: GenEffect) bool {
            return std.mem.eql(u8, @tagName(self), @tagName(other));
        }
    };

    node_level: enum { L0, L1 },
    nodename: []const u8,

    parse_triggers: []const u8,
    parse_fn: fn (p: *Parser, endat: usize) SyntaxError!ParseState,

    l0_contains_l1: ?bool = null, // after l0 rule apply to search if we need to parse l1 nodes
    l0_premeta_nodename: ?[]const u8 = null,
    l0_postmeta_nodename: ?[]const u8 = null,

    l1_margin: ?struct { usize, usize } = null, // left and right margin for l1 node, if any

    // specials
    attrname_nodename_pair: ?struct {
        attrname: []const u8,
        nodename: []const u8,
    } = null,
    cmdname_nodename_pair: ?struct {
        cmdname: []const u8,
        nodename: []const u8,
    } = null,

    gen_effect: ?GenEffect = null,
};
