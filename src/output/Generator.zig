const std = @import("std");
const Node = @import("../element/Node.zig");
const html_rules = @import("html_rules.zig");
const Rule = @import("../element/Rule.zig");

pub const Error = error{
    OOM,
    ExpectedL0NodeGotL1,
    L0NodeNotFound,
    NoL0RuleForKind,
    NoL1RuleForKind,
    UnsupportedL0RuleAlgo,
};

// arena so we destroy all of the strings at once
arena: std.heap.ArenaAllocator,
arenalloc: std.mem.Allocator, // is only for this generator -> exclusively owned
io: std.Io, // for logging and writing to file

textin: []const u8, // borrowed from parser

nodes: []Node,
nodec: usize,

nodecursor: usize = 0,
outf: std.Io.File, // TODO staging mem buf

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
    std.log.err("Generating for node {s}: {s}", .{ @tagName(n.kind), @errorName(err) });
    return std.process.exit(1);
}

// TODO beautify out by indenting
// TODO io_uring?
pub fn print_out(self: *@This()) void {
    while (self.pop_node()) |l0node| {
        if (!l0node.kind.is_l0()) continue;

        var l0rule: ?Rule.Gen = null;
        for (html_rules.def) |r| {
            if (r.kind == l0node.kind) {
                l0rule = r;
                break;
            }
        }

        if (l0rule == null) {
            return self.error_handle(l0node, Error.NoL0RuleForKind);
        }

        const l0pretext = switch (l0rule.?.algo) {
            .prepost => |pair| pair.pre,
            .text => |text| text,
            else => return self.error_handle(
                l0node,
                Error.UnsupportedL0RuleAlgo,
            ),
        };

        self.outf.writeStreamingAll(
            self.io,
            l0pretext,
        ) catch |err| return self.error_handle(l0node, err);

        // if the l0 node does not contain text, e.g. a section begin node,
        // that is just used for semantic segregation of text blocks, it is
        // not able to contain l1 nodes, since it does not contain text
        if (l0node.span == null) continue;

        var lastpos = l0node.span.?.start;

        l1loop: while (self.peek_node()) |l1node| : (self.nodecursor += 1) {
            if (l1node.kind.is_l0()) break :l1loop;

            const l1_margin = l1node.kind.l1_margin();
            std.log.debug("l1_margin: {d}, {d}", .{ l1_margin[0], l1_margin[1] });

            if (l1node.span.?.start < lastpos or l1node.span.?.end > l0node.span.?.end) {
                continue :l1loop;
            }

            const pre_cut = l1node.span.?.start - l1_margin[0];
            self.outf.writeStreamingAll(
                self.io,
                self.textin[lastpos..pre_cut],
            ) catch |err| return self.error_handle(l1node, err);

            var l1rule: ?Rule.Gen = null;
            for (html_rules.def) |r| {
                if (r.kind == l1node.kind) {
                    l1rule = r;
                    break;
                }
            }
            if (l1rule == null) return self.error_handle(l1node, Error.NoL1RuleForKind);

            switch (l1rule.?.algo) {
                .text => |text| {
                    self.outf.writeStreamingAll(self.io, text) catch |err|
                        return self.error_handle(l1node, err);
                },
                .prepost => |pair| {
                    self.outf.writeStreamingAll(
                        self.io,
                        pair.pre,
                    ) catch |err| return self.error_handle(l1node, err);
                    self.outf.writeStreamingAll(
                        self.io,
                        self.textin[l1node.span.?.start..l1node.span.?.end],
                    ) catch |err| return self.error_handle(l1node, err);
                    self.outf.writeStreamingAll(
                        self.io,
                        pair.post,
                    ) catch |err| return self.error_handle(l1node, err);
                },
                .replace => |f| {
                    self.outf.writeStreamingAll(
                        self.io,
                        f(self) catch |err| return self.error_handle(
                            l1node,
                            err,
                        ),
                    ) catch |err| return self.error_handle(l1node, err);
                },
            }

            lastpos = l1node.span.?.end + l1_margin[1];
        }

        self.outf.writeStreamingAll(self.io, self.textin[lastpos..l0node.span.?.end]) catch |err|
            return self.error_handle(l0node, err);

        const l0posttext = switch (l0rule.?.algo) {
            .prepost => |pair| pair.post,
            .text => "", // no post text for single text l0 rule
            else => return self.error_handle(l0node, Error.UnsupportedL0RuleAlgo),
        };
        self.outf.writeStreamingAll(self.io, l0posttext) catch |err|
            return self.error_handle(l0node, err);
    }
}
