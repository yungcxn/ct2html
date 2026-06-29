const std = @import("std");
const Node = @import("../element/Node.zig");
const html_rules = @import("html_rules.zig");
const Rule = @import("../element/Rule.zig");

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

l0nodes: []Node,
l0nodec: usize,

l1nodes: []Node,
l1nodec: usize,

outf: std.Io.File, // TODO staging mem buf

pub fn init(
    arenabase: std.mem.Allocator,
    io: std.Io,
    textin: []const u8,
    l0nodes: []Node,
    l0nodec: usize,
    l1nodes: []Node,
    l1nodec: usize,
    outf: std.Io.File,
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
    };
}

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
}

// better error handle
fn error_handle(self: *@This(), err: anyerror) noreturn {
    _ = self;
    std.log.err("Generating for node {s}", .{@errorName(err)});
    return std.process.exit(1);
}

inline fn print(self: *@This(), text: []const u8) void {
    self.outf.writeStreamingAll(
        self.io,
        text,
    ) catch |err| return self.error_handle(err);
}

inline fn print_span(self: *@This(), textstart: usize, textend: usize) void {
    self.print(self.textin[textstart..textend]);
}

// TODO beautify out by indenting
// TODO io_uring?
pub fn print_out(self: *@This()) void {
    for (self.l0nodes[0..self.l0nodec]) |l0node| {
        if (!l0node.kind.is_l0()) unreachable; // TODO IMPOSSIBLE

        var l0rule: ?Rule.Gen = null;
        for (html_rules.def) |r| {
            if (r.kind == l0node.kind) {
                l0rule = r;
                break;
            }
        }

        if (l0rule == null) {
            return self.error_handle(Error.UnnecessaryNodePresented);
        }

        const l0pretext = switch (l0rule.?.algo) {
            .prepost => |pair| pair.pre,
            .text => |text| text,
            else => unreachable, // TODO
        };
        self.print(l0pretext);

        defer {
            const l0posttext = switch (l0rule.?.algo) {
                .prepost => |pair| pair.post,
                .text => "", // no post text for single text l0 rule
                else => unreachable, // TODO
            };
            self.print(l0posttext);
        }

        // not containing a span means, that there can not be any l1 nodes
        // -> we continue and run the defered print of post text
        const l0span = l0node.span orelse continue;
        // this variable tracks the next unprinted, to-be-printed text idx
        var toprint0 = l0span.start;

        defer {
            // we assume here that this is the last print, which needs to be
            // from the last l1 node's end -- up until the end of the l0 node
            self.print_span(toprint0, l0span.end);
        }
        // not having l1 nodes here means, that l1 nodes were possible but none
        // were encountered; defered print the rest of the l0 node's text, the
        // post text and continue to the next l0
        if (l0node.l1childc == 0 or l0node.l1child0 == null) continue;

        for (self.l1nodes[l0node.l1child0.? .. l0node.l1child0.? + l0node.l1childc]) |l1node| {
            if (!l1node.kind.is_l1()) unreachable; // TODO IMPOSSIBLE
            const l1margin = l1node.kind.l1_margin();
            const l1span = l1node.span.?; // TODO never empty l1 node!!

            self.print_span(toprint0, l1span.start - l1margin[0]);

            var l1rule: ?Rule.Gen = null;
            for (html_rules.def) |r| {
                if (r.kind == l1node.kind) {
                    l1rule = r;
                    break;
                }
            }
            if (l1rule == null) return self.error_handle(Error.NoL1RuleForKind);

            switch (l1rule.?.algo) {
                .text => |text| {
                    self.print(text);
                },
                .prepost => |pair| {
                    self.print(pair.pre);
                    self.print_span(l1span.start, l1span.end);
                    self.print(pair.post);
                },
                .replace => |f| {
                    self.print(f(self) catch |err| return self.error_handle(err));
                },
            }

            toprint0 = l1span.end + l1margin[1];
        }
    }
}
