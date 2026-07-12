const std = @import("std");
const Node = @import("../element/Node.zig");
const Rule = @import("../element/Rule.zig");
const ErrorReporter = @import("../ErrorReporter.zig");
const DynBuf = @import("../ds/dynbuf.zig").DynBuf;
const html_rules = @import("html_rules.zig");
const Attributor = @import("../internal/Attributor.zig");
const crash = ErrorReporter.crash;

pub const GenError = error{
    OOM,
    L0NodeNotFound,
    NoL1RuleForKind,
    UnsupportedL0RuleAlgo,
    UnnecessaryNodePresented,
    InvalidL1Format,
};

alloc: std.mem.Allocator, // for rule functions to alloc and dealloc, not directly for @This()
io: std.Io, // for logging and writing to file
e: *ErrorReporter,
attributor: *Attributor,

textin: []const u8, // borrowed from parser

l0nodes: DynBuf(Node.L0),
l1nodes: DynBuf(Node.L1),

outbuf: DynBuf(u8),
stop_escaping: bool = false, // if true, we print ALL backslashes

htmlerror: bool = false, // if true, we print the error as HTML instead of plain text
responsemode: bool = false, // if true, we print the response header for HTML

pub fn init(
    alloc: std.mem.Allocator,
    io: std.Io,
    e: *ErrorReporter,
    attributor: *Attributor,
    textin: []const u8,
    l0nodes: DynBuf(Node.L0),
    l1nodes: DynBuf(Node.L1),
    htmlerror: bool,
    responsemode: bool,
) @This() {
    return .{
        .alloc = alloc,
        .io = io,
        .e = e,
        .attributor = attributor,
        .textin = textin,
        .l0nodes = l0nodes,
        .l1nodes = l1nodes,
        .htmlerror = htmlerror,
        .responsemode = responsemode,
        .outbuf = DynBuf(u8).init(alloc, textin.len * 2),
    };
}

// - nothing enters the final html file wihout going through this function
pub inline fn print(self: *@This(), text: []const u8) void {
    if (self.stop_escaping) {
        self.outbuf.append(text);
    } else {
        var i: usize = 0;
        var toprint0_at: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == '\\' and i + 1 < text.len) {
                self.outbuf.append(text[toprint0_at..i]);
                i += 1; // skip the backslash
                // text[i] is now the escaped char, leave it for the next flush
                toprint0_at = i;
                i += 1; // skip the escaped char itself, since it was printed
                continue;
            }
            i += 1;
        }
        if (toprint0_at < text.len) {
            self.outbuf.append(text[toprint0_at..]);
        }
    }
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
        // not containing a span means, that there can not be any l1 nodes
        // -> we continue and run the defered print of post text
        var l0span: ?@Vector(2, usize) = l0node.span;

        const l0_ri = html_rules.datatable.lookup(
            @intFromEnum(l0node.kind),
        ) orelse return ErrorReporter.crash(GenError.L0NodeNotFound);

        self.stop_escaping = l0_ri.stop_escaping;

        switch (l0_ri.pre_alg) {
            .constant => |pre| self.print(pre),
            .complex => |f| {
                l0span = try f(self, @ptrCast(@constCast(&l0node)));
            },
        }

        // this variable tracks the next unprinted, to-be-printed text idx
        var toprint0: ?usize = if (l0span) |s| s[0] else null;

        // not having l1 nodes here means, that l1 nodes were possible but none
        // were encountered; defered print the rest of the l0 node's text, the
        // post text and continue to the next l0
        if (toprint0 != null and l0node.l1childhead != null and l0node.l1child0 != null) {
            for (self.l1nodes.slice_view()[l0node.l1child0.?..l0node.l1childhead.?]) |l1node| {
                self.print_span(toprint0.?, l1node.span[0] - l1node.margin[0]);

                const l1_ri = html_rules.datatable.lookup(
                    @intFromEnum(l1node.kind),
                ) orelse return ErrorReporter.crash(GenError.NoL1RuleForKind);

                self.stop_escaping = l1_ri.stop_escaping;

                var l1_inner_span: ?@Vector(2, usize) = l1node.span;

                switch (l1_ri.pre_alg) {
                    .constant => |pre| self.print(pre),
                    .complex => |f| {
                        l1_inner_span = try f(self, @ptrCast(@constCast(&l1node)));
                    },
                }

                if (l1_inner_span != null) self.print_span(l1_inner_span.?[0], l1_inner_span.?[1]); // TODO

                switch (l1_ri.post_alg) {
                    .constant => |post| self.print(post),
                    .complex => |f| try f(self, @ptrCast(@constCast(&l1node))),
                }

                toprint0 = l1node.span[1] + l1node.margin[1];
            }
        }

        self.stop_escaping = l0_ri.stop_escaping;

        // we assume here that this is the last print, which needs to be
        // from the last l1 node's end -- up until the end of the l0 node
        if (toprint0 != null) {
            self.print_span(toprint0.?, l0span.?[1]);
        }

        // post action
        switch (l0_ri.post_alg) {
            .constant => |post| self.print(post),
            .complex => |f| try f(self, @ptrCast(@constCast(&l0node))),
        }
    }

    return self.outbuf.to_owned_slice();
}
