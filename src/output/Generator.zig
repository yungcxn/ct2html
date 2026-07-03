const std = @import("std");
const Node = @import("../element/Node.zig");
const html_rules = @import("html_rules.zig");
const Rule = @import("../element/Rule.zig");
const ErrorReporter = @import("../ErrorReporter.zig");

// TODO: caching by saving outfile at /tmp/ct2html/datetimenanoseconds.html (faster than hash)
// TODO: not printing \ out, only if \\ the first vanishes. it should be replaced with some dead char
// TODO: print special non ascii chars correctly...

pub const Error = error{
    OOM,
    L0NodeNotFound,
    NoL1RuleForKind,
    UnsupportedL0RuleAlgo,
    UnnecessaryNodePresented,
};

// arena so we destroy all of the strings at once
arena: std.heap.ArenaAllocator,
arenalloc: std.mem.Allocator, // is only for this generator -> exclusively owned
io: std.Io, // for logging and writing to file

textin: []const u8, // borrowed from parser

l0nodes: []Node.L0,
l0nodec: usize,

l1nodes: []Node.L1,
l1nodec: usize,

outf: std.Io.File, // TODO staging mem buf

htmlerror: bool = false, // if true, we print the error as HTML instead of plain text

pub fn init(
    arenabase: std.mem.Allocator,
    io: std.Io,
    textin: []const u8,
    l0nodes: []Node.L0,
    l0nodec: usize,
    l1nodes: []Node.L1,
    l1nodec: usize,
    outf: std.Io.File,
    htmlerror: bool,
) !@This() {
    var new_arena = std.heap.ArenaAllocator.init(arenabase);
    return .{
        .arena = new_arena,
        .arenalloc = new_arena.allocator(),
        .io = io,
        .textin = textin,
        .l0nodes = l0nodes,
        .l0nodec = l0nodec,
        .l1nodes = l1nodes,
        .l1nodec = l1nodec,
        .outf = outf,
        .htmlerror = htmlerror,
    };
}

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
}

pub inline fn print(self: *@This(), text: []const u8) void {
    self.outf.writeStreamingAll(
        self.io,
        text,
    ) catch |err| return ErrorReporter.crash(err);
}

pub inline fn print_span(self: *@This(), textstart: usize, textend: usize) void {
    self.print(self.textin[textstart..textend]);
}

// TODO beautify out by indenting
// TODO io_uring?
pub fn print_out(self: *@This()) void {
    for (self.l0nodes[0..self.l0nodec]) |l0node| {
        var l0rule: ?Rule.Gen = null;
        for (html_rules.def) |r| {
            if (std.meta.activeTag(r.kind) != .l0) continue;

            if (r.kind.l0 == l0node.kind) {
                l0rule = r;
                break;
            }
        }

        if (l0rule == null) {
            return ErrorReporter.crash(Error.UnnecessaryNodePresented);
        }

        const l0pretext = switch (l0rule.?.algo) {
            .prepost => |pair| pair.pre,
            .text => |text| text,
            else => @panic("Replace-Rule not supported for L0"),
        };
        self.print(l0pretext);

        defer {
            const l0posttext = switch (l0rule.?.algo) {
                .prepost => |pair| pair.post,
                .text => "", // no post text for single text l0 rule
                else => @panic("Replace-Rule not supported for L0"),
            };
            self.print(l0posttext);
        }

        // not containing a span means, that there can not be any l1 nodes
        // -> we continue and run the defered print of post text
        const l0span: @Vector(2, usize) = l0node.span orelse continue;
        // this variable tracks the next unprinted, to-be-printed text idx
        var toprint0 = l0span[0];

        defer {
            // we assume here that this is the last print, which needs to be
            // from the last l1 node's end -- up until the end of the l0 node
            self.print_span(toprint0, l0span[1]);
        }
        // not having l1 nodes here means, that l1 nodes were possible but none
        // were encountered; defered print the rest of the l0 node's text, the
        // post text and continue to the next l0
        if (l0node.l1childhead == null or l0node.l1child0 == null) continue;

        for (self.l1nodes[l0node.l1child0.?..l0node.l1childhead.?]) |l1node| {
            self.print_span(toprint0, l1node.span[0] - l1node.margin[0]);

            var l1rule: ?Rule.Gen = null;
            for (html_rules.def) |r| {
                if (std.meta.activeTag(r.kind) != .l1) continue;

                if (r.kind.l1 == l1node.kind) {
                    l1rule = r;
                    break;
                }
            }
            if (l1rule == null) return ErrorReporter.crash(Error.NoL1RuleForKind);

            switch (l1rule.?.algo) {
                .text => |text| {
                    self.print(text);
                },
                .prepost => |pair| {
                    self.print(pair.pre);
                    self.print_span(l1node.span[0], l1node.span[1]);
                    self.print(pair.post);
                },
                .print => |f| {
                    f(self, l1node.span) catch |err| return ErrorReporter.crash(err);
                },
            }

            toprint0 = l1node.span[1] + l1node.margin[1];
        }
    }
}
