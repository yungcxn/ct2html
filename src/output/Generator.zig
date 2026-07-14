const std = @import("std");
const Node = @import("../element/Node.zig");
const Rule = @import("../element/Rule.zig");
const ErrorReporter = @import("../ErrorReporter.zig");
const DynBuf = @import("../ds/dynbuf.zig").DynBuf;
const gen_rules = @import("gen_rules.zig");
const Attributor = @import("../internal/Attributor.zig");
const CCEngine = @import("../internal/CCEngine.zig");
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
custom_cmd_engine: *CCEngine, // for command engine to run commands and get their output

textin: []const u8, // borrowed from parser

l0nodes: DynBuf(Node.L0),
l1nodes: DynBuf(Node.L1),

outbuf: DynBuf(u8),

// generation specific variables
sidenote_count: usize = 0,

// user options from `main`
htmlerror: bool = false, // if true, we print the error as HTML instead of plain text
responsemode: bool = false, // if true, we print the response header for HTML

pub fn init(
    alloc: std.mem.Allocator,
    io: std.Io,
    e: *ErrorReporter,
    attributor: *Attributor,
    custom_cmd_engine: *CCEngine,
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
        .custom_cmd_engine = custom_cmd_engine,
        .textin = textin,
        .l0nodes = l0nodes,
        .l1nodes = l1nodes,
        .htmlerror = htmlerror,
        .responsemode = responsemode,
        .outbuf = DynBuf(u8).init(alloc, textin.len * 2),
    };
}

pub const EscMode = enum { bs_esc, html_esc, all_esc, direct };

/// Unified print: escaping behavior is selected at comptime via `mode`,
/// so each call site gets a specialized, branch-free version of this
/// function just like the original hand-written ones.
pub inline fn print(self: *@This(), mode: EscMode, text: []const u8) void {
    if (mode == .direct) {
        self.print_direct(text);
        return;
    }

    var i: usize = 0;
    var toprint0_at: usize = 0;
    while (i < text.len) {
        const c = text[i];

        if ((mode == .bs_esc or mode == .all_esc) and c == '\\' and i + 1 < text.len) {
            self.print_direct(text[toprint0_at..i]);
            i += 1; // skip the backslash
            if (mode == .all_esc) {
                // escaped char printed as-is immediately (never html-escaped)
                self.print_direct(text[i .. i + 1]);
                i += 1;
                toprint0_at = i;
            } else {
                // bs_esc: leave escaped char for the next flush
                toprint0_at = i;
                i += 1;
            }
            continue;
        }

        if (mode == .html_esc or mode == .all_esc) {
            switch (c) {
                '<' => {
                    self.print_direct(text[toprint0_at..i]);
                    toprint0_at = i + 1;
                    self.print_direct("&lt;");
                },
                '>' => {
                    self.print_direct(text[toprint0_at..i]);
                    toprint0_at = i + 1;
                    self.print_direct("&gt;");
                },
                '&' => {
                    self.print_direct(text[toprint0_at..i]);
                    toprint0_at = i + 1;
                    self.print_direct("&amp;");
                },
                '"' => {
                    self.print_direct(text[toprint0_at..i]);
                    toprint0_at = i + 1;
                    self.print_direct("&quot;");
                },
                else => {},
            }
        }
        i += 1;
    }
    if (toprint0_at < text.len) self.print_direct(text[toprint0_at..]);
}

pub inline fn print_direct(self: *@This(), text: []const u8) void {
    self.outbuf.append(text);
}

pub inline fn print_bs_esc(self: *@This(), text: []const u8) void {
    self.print(.bs_esc, text);
}

pub inline fn print_html_esc(self: *@This(), text: []const u8) void {
    self.print(.html_esc, text);
}

pub inline fn print_all_esc(self: *@This(), text: []const u8) void {
    self.print(.all_esc, text);
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

        const l0_ri = gen_rules.datatable.lookup(
            @intFromEnum(l0node.kind),
        ) orelse return ErrorReporter.crash(GenError.L0NodeNotFound);

        switch (l0_ri.pre_alg) {
            .constant => |pre| self.print_bs_esc(pre),
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
                self.print(l0_ri.esc_mode, self.textin[toprint0.? .. l1node.span[0] - l1node.margin[0]]);

                const l1_ri = gen_rules.datatable.lookup(
                    @intFromEnum(l1node.kind),
                ) orelse return ErrorReporter.crash(GenError.NoL1RuleForKind);

                var l1_inner_span: ?@Vector(2, usize) = l1node.span;

                switch (l1_ri.pre_alg) {
                    .constant => |pre| self.print_bs_esc(pre),
                    .complex => |f| {
                        l1_inner_span = try f(self, @ptrCast(@constCast(&l1node)));
                    },
                }

                if (l1_inner_span != null) self.print(l1_ri.esc_mode, self.textin[l1_inner_span.?[0]..l1_inner_span.?[1]]);

                switch (l1_ri.post_alg) {
                    .constant => |post| self.print_bs_esc(post),
                    .complex => |f| try f(self, @ptrCast(@constCast(&l1node))),
                }

                toprint0 = l1node.span[1] + l1node.margin[1];
            }
        }

        // we assume here that this is the last print, which needs to be
        // from the last l1 node's end -- up until the end of the l0 node
        if (toprint0 != null) {
            self.print(l0_ri.esc_mode, self.textin[toprint0.?..l0span.?[1]]);
        }

        // post action
        switch (l0_ri.post_alg) {
            .constant => |post| self.print_bs_esc(post),
            .complex => |f| try f(self, @ptrCast(@constCast(&l0node))),
        }
    }

    return self.outbuf.to_owned_slice();
}
