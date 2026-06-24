const std = @import("std");
const Generator = @This();
const Node = @import("../input/element/Node.zig");
const MetaNode = @import("../input/element/MetaNode.zig");
const metarules_html = @import("rules/html.zig").metarules;
const html_metarule_by_kind = @import("rules/html.zig").metarule_by_kind;
const rules_html = @import("rules/html.zig").rules;
const html_rule_by_kind = @import("rules/html.zig").rule_by_kind;

pub const Effect = union(enum) {
    prepost: struct {
        pre: []const u8,
        post: []const u8,
    },
    replace: *const fn (g: *Generator) Error![]const u8,
    ignore: void,

    pub fn xprepost(pre: []const u8, post: []const u8) Effect {
        return .{ .prepost = .{ .pre = pre, .post = post } };
    }
    pub fn xreplace(f: *const fn (g: *Generator) Error![]const u8) Effect {
        return .{ .replace = f };
    }
    pub fn xignore() Effect {
        return .{ .ignore = {} };
    }

    pub fn eq(self: Effect, other: Effect) bool {
        return std.mem.eql(u8, @tagName(self), @tagName(other));
    }
};

// Nodes carry not only the text boundary but for attributes or commands,
// sometimes something more complex is needed, therefore a text returning fn
pub const Rule = struct {
    pub fn def(k: Node.Kind, effect: Effect) Rule {
        return .{ .k = k, .effect = effect };
    }

    k: Node.Kind,
    effect: Effect,
};

// MetaNodes just carry a kind and a before, so it should suffice to just have a
// single string that we map to the node kind
pub const MetaRule = struct {
    pub fn def(k: MetaNode.Kind, out: []const u8) MetaRule {
        return .{ .k = k, .out = out };
    }

    k: MetaNode.Kind,
    out: []const u8,
};

pub const Error = error{
    OOM,
    ExpectedL0NodeGotL1,
    L0NodeNotFound,
    NoEffectForL0NodeRule,
    ReplaceRuleNotSupportedForL0Node,
    NoMetaRuleForKind,
};

// arena so we destroy all of the strings at once
arena: std.heap.ArenaAllocator,
arenalloc: std.mem.Allocator, // is only for this generator -> exclusively owned

textin: []const u8, // borrowed from parser

nodes: []Node,
nodec: usize,
mnodes: []MetaNode,
mnodec: usize,

nodecursor: usize = 0,
mnodecursor: usize = 0,
out: std.Io.Writer,

pub fn init(
    arenabase: std.mem.Allocator,
    textin: []const u8,
    nodes: []Node,
    nodec: usize,
    mnodes: []MetaNode,
    mnodec: usize,
    out: std.Io.Writer,
) !@This() {
    var new_arena = std.heap.ArenaAllocator.init(arenabase);
    return .{
        .arena = new_arena,
        .arenalloc = new_arena.allocator(),
        .textin = textin,
        .nodes = nodes,
        .nodec = nodec,
        .mnodes = mnodes,
        .mnodec = mnodec,
        .out = out,
    };
}

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
}

pub fn peek_node(self: *@This()) ?Node {
    if (self.nodecursor >= self.nodec) return null;
    return self.nodes[self.nodecursor];
}

fn pop_node(self: *@This()) ?Node {
    if (self.nodecursor >= self.nodec) return null;
    defer self.nodecursor += 1;
    return self.nodes[self.nodecursor];
}

pub fn peek_mnode(self: *@This()) ?MetaNode {
    if (self.mnodecursor >= self.mnodec) return null;
    return self.mnodes[self.mnodecursor];
}

fn pop_mnode(self: *@This()) ?MetaNode {
    if (self.mnodecursor >= self.mnodec) return null;
    defer self.mnodecursor += 1;
    return self.mnodes[self.mnodecursor];
}

fn push_chunk(self: *@This(), textin_start: usize, textin_end: usize) void {
    push_chunk_new(self, self.textin[textin_start..textin_end]);
}

fn push_chunk_new(self: *@This(), newchunk: []const u8) void {
    if (self.chunksout_head >= self.chunksout.len) {
        const newlen = self.chunksout.len * 2;
        const newchunksout = self.arenalloc.realloc(self.chunksout, newlen) catch {
            std.log.err("OOM for Generator chunks.");
            std.process.exit(1);
        };
        self.chunksout = newchunksout;
    }
    self.chunksout[self.chunksout_head] = newchunk;
    self.chunksout_head += 1;
}

fn error_handle(self: *@This(), n: Node, err: anyerror) noreturn {
    _ = self;
    std.log.err("Generating for node {any}: {s}", .{ n.kind.name(), @errorName(err) });
    return std.process.exit(1);
}

pub fn print_out(self: *@This()) void {
    // TODO mnodes
    while (self.pop_node()) |l0node| {
        if (!l0node.kind.is_l0()) return self.error_handle(l0node, Error.ExpectedL0NodeGotL1);

        const rule: Rule = html_rule_by_kind(l0node.kind) catch return self.error_handle(l0node, Error.NoEffectForL0NodeRule);

        const l0textpair = switch (rule.effect) {
            .prepost => |l0textpair| l0textpair,
            .replace => return self.error_handle(l0node, Error.ReplaceRuleNotSupportedForL0Node),
            .ignore => continue,
        };

        self.out.writeAll(l0textpair.pre) catch |err| return self.error_handle(l0node, err);
        var lastpos = l0node.textstart;

        // a single l1iter must generate text before this and and this node
        // so `lastpos` gets updated to the end of the last l1node
        l1loop: while (self.peek_node()) |l1node| : (self.nodecursor += 1) {
            if (l1node.kind.is_l0()) break :l1loop;

            // *bold*_strike
            // first iter, lastpos->*, first write is *..* -> nothing, nice
            self.out.writeAll(self.textin[lastpos .. l1node.textstart - 1]) catch |err| {
                return self.error_handle(l1node, err);
            };

            const l1rule = html_rule_by_kind(l1node.kind) catch |err| {
                return self.error_handle(l1node, err);
            };
            switch (l1rule.effect) {
                .prepost => |l1textpair| {
                    self.out.writeAll(l1textpair.pre) catch |err| return self.error_handle(l1node, err);
                    self.out.writeAll(self.textin[l1node.textstart..l1node.textend]) catch |err| return self.error_handle(l1node, err);
                    self.out.writeAll(l1textpair.post) catch |err| return self.error_handle(l1node, err);
                },
                .replace => |f| {
                    const replacement = f(self) catch |err| return self.error_handle(l1node, err);
                    self.out.writeAll(replacement) catch |err| return self.error_handle(l1node, err);
                },
                .ignore => {
                    // do nothing, just skip the text
                },
            }

            lastpos = l1node.textend; // which is some exclusive idx, lies in l0
        }

        self.out.writeAll(self.textin[lastpos..l0node.textend]) catch |err| return self.error_handle(l0node, err);
        self.out.writeAll(l0textpair.post) catch |err| return self.error_handle(l0node, err);
    }
}
