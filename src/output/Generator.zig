const std = @import("std");
const Generator = @This();
const Node = @import("../input/element/Node.zig");
const rules_html = @import("rules/html.zig");

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
        return .{ .kind = k, .effect = effect };
    }

    kind: Node.Kind,
    effect: Effect,
};

// MetaNodes just carry a kind and a before, so it should suffice to just have a
// single string that we map to the node kind

pub const Error = error{
    OOM,
    ExpectedL0NodeGotL1,
    L0NodeNotFound,
    NoEffectForL0NodeRule,
    ReplaceRuleNotSupportedForL0Node,
    NoMetaRuleForKind,
    L1MarginNotFound,
};

// arena so we destroy all of the strings at once
arena: std.heap.ArenaAllocator,
arenalloc: std.mem.Allocator, // is only for this generator -> exclusively owned
io: std.Io, // for logging and writing to file

textin: []const u8, // borrowed from parser

nodes: []Node,
nodec: usize,

nodecursor: usize = 0,
outf: std.Io.File,

pub fn init(
    arenabase: std.mem.Allocator,
    io: std.Io,
    textin: []const u8,
    nodes: []Node,
    nodec: usize,
    outf: std.Io.File,
) !@This() {
    var new_arena = std.heap.ArenaAllocator.init(arenabase);
    return .{
        .arena = new_arena,
        .arenalloc = new_arena.allocator(),
        .io = io,
        .textin = textin,
        .nodes = nodes,
        .nodec = nodec,
        .outf = outf,
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

fn error_handle(self: *@This(), n: anytype, err: anyerror) noreturn {
    _ = self;
    std.log.err("Generating for node {s}: {s}", .{ n.kind.name(), @errorName(err) });
    return std.process.exit(1);
}

// TODO BUG only doing the first l1 in a l0 block
pub fn print_out(self: *@This()) void {
    while (self.pop_node()) |l0node| {
        if (!l0node.kind.is_l0()) continue;

        const rule: Rule = rules_html.rule_by_kind(l0node.kind) catch
            return self.error_handle(l0node, Error.NoEffectForL0NodeRule);

        const l0textpair = switch (rule.effect) {
            .prepost => |pair| pair,
            .replace => return self.error_handle(l0node, Error.ReplaceRuleNotSupportedForL0Node),
            .ignore => continue,
        };

        self.outf.writeStreamingAll(self.io, l0textpair.pre) catch |err|
            return self.error_handle(l0node, err);

        var lastpos = l0node.textstart;

        l1loop: while (self.peek_node()) |l1node| : (self.nodecursor += 1) {
            if (l1node.kind.is_l0()) break :l1loop;

            const l1_margin = rules_html.l1_margins.get(l1node.kind.L1) orelse
                return self.error_handle(l1node, Error.L1MarginNotFound);

            if (l1node.textstart < lastpos or l1node.textend > l0node.textend) {
                continue :l1loop;
            }

            const pre_cut = l1node.textstart - l1_margin[0];
            self.outf.writeStreamingAll(self.io, self.textin[lastpos..pre_cut]) catch |err|
                return self.error_handle(l1node, err);

            const l1rule = rules_html.rule_by_kind(l1node.kind) catch |err|
                return self.error_handle(l1node, err);

            switch (l1rule.effect) {
                .prepost => |pair| {
                    self.outf.writeStreamingAll(self.io, pair.pre) catch |err|
                        return self.error_handle(l1node, err);
                    self.outf.writeStreamingAll(self.io, self.textin[l1node.textstart..l1node.textend]) catch |err|
                        return self.error_handle(l1node, err);
                    self.outf.writeStreamingAll(self.io, pair.post) catch |err|
                        return self.error_handle(l1node, err);
                },
                .replace => |f| {
                    const replacement = f(self) catch |err|
                        return self.error_handle(l1node, err);
                    self.outf.writeStreamingAll(self.io, replacement) catch |err|
                        return self.error_handle(l1node, err);
                },
                .ignore => {},
            }

            lastpos = l1node.textend + l1_margin[1];
        }

        self.outf.writeStreamingAll(self.io, self.textin[lastpos..l0node.textend]) catch |err|
            return self.error_handle(l0node, err);

        self.outf.writeStreamingAll(self.io, l0textpair.post) catch |err|
            return self.error_handle(l0node, err);
    }
}
