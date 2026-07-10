const std = @import("std");
const Node = @import("../element/Node.zig");
const Rule = @import("../element/Rule.zig");
const ErrorReporter = @import("../ErrorReporter.zig");
const DynBuf = @import("../ds/dynbuf.zig").DynBuf;
const html_rules = @import("html_rules.zig");

pub const GenError = error{
    OOM,
    L0NodeNotFound,
    NoL1RuleForKind,
    UnsupportedL0RuleAlgo,
    UnnecessaryNodePresented,
};

io: std.Io, // for logging and writing to file
e: *ErrorReporter,

textin: []const u8, // borrowed from parser

l0nodes: DynBuf(Node.L0),
l1nodes: DynBuf(Node.L1),

outbuf: DynBuf(u8),

htmlerror: bool = false, // if true, we print the error as HTML instead of plain text
responsemode: bool = false, // if true, we print the response header for HTML

pub fn init(
    alloc: std.mem.Allocator,
    io: std.Io,
    e: *ErrorReporter,
    textin: []const u8,
    l0nodes: DynBuf(Node.L0),
    l1nodes: DynBuf(Node.L1),
    htmlerror: bool,
    responsemode: bool,
) @This() {
    return .{
        .io = io,
        .e = e,
        .textin = textin,
        .l0nodes = l0nodes,
        .l1nodes = l1nodes,
        .htmlerror = htmlerror,
        .responsemode = responsemode,
        .outbuf = DynBuf(u8).init(alloc, textin.len * 2),
    };
}

pub inline fn print(self: *@This(), text: []const u8) void {
    self.outbuf.append(text);
}

pub inline fn print_span(self: *@This(), textstart: usize, textend: usize) void {
    self.print(self.textin[textstart..textend]);
}

// TODO beautify out by indenting
pub fn generate_out(self: *@This()) GenError![]const u8 {
    errdefer self.outbuf.deinit();
    if (self.responsemode) {
        self.outbuf.append("Content-Type: text/html; charset=UTF-8\r\n\r\n");
    }

    for (self.l0nodes.slice_view()) |l0node| {
        const l0_ri = html_rules.datatable.lookup(
            @intFromEnum(l0node.kind),
        ) orelse return ErrorReporter.crash(GenError.L0NodeNotFound);

        const l0pretext = switch (l0_ri.algo) {
            .prepost => |pair| pair.pre,
            .text => |text| text,
            else => @panic("Replace-Rule not supported for L0"),
        };
        self.print(l0pretext);

        defer {
            const l0posttext = switch (l0_ri.algo) {
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

        for (self.l1nodes.slice_view()[l0node.l1child0.?..l0node.l1childhead.?]) |l1node| {
            self.print_span(toprint0, l1node.span[0] - l1node.margin[0]);

            const l1_ri = html_rules.datatable.lookup(
                @intFromEnum(l1node.kind),
            ) orelse return ErrorReporter.crash(GenError.NoL1RuleForKind);

            switch (l1_ri.algo) {
                .text => |text| {
                    self.print(text);
                },
                .prepost => |pair| {
                    self.print(pair.pre);
                    self.print_span(l1node.span[0], l1node.span[1]);
                    self.print(pair.post);
                },
                .print => |f| {
                    try f(self, l1node.span);
                },
            }

            toprint0 = l1node.span[1] + l1node.margin[1];
        }
    }

    return self.outbuf.to_owned_slice();
}
