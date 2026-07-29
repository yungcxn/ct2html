const std = @import("std");
const Node = @import("../element/Node.zig");
const Rule = @import("../element/Rule.zig");
const ErrorReporter = @import("../ErrorReporter.zig");
const DynBuf = @import("../ds/dynbuf.zig").DynBuf;
const Stack = @import("../ds/stack.zig").Stack;
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

outbuf: *DynBuf(u8),

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
        .outbuf = DynBuf(u8).alloc_init(alloc, textin.len * 2),
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
pub fn generate_out(self: *@This()) GenError!*DynBuf(u8) {
    errdefer self.outbuf.destroy();
    if (self.responsemode) {
        self.outbuf.append("Content-Type: text/html; charset=UTF-8\r\n\r\n");
    }

    const Frame = struct {
        node_idx: ?usize,
        idx: usize,
        end: usize,
        toprint: usize,
        esc_mode: EscMode,
        span_end: usize,
    };

    var stack = Stack(Frame).init(self.alloc, 8);
    defer stack.deinit();

    for (self.l0nodes.slice_view()) |l0node| {
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

        var toprint0: ?usize = if (l0span) |s| s[0] else null;

        if (toprint0 != null and l0node.l1childhead != null and l0node.l1child0 != null) {
            const l1nodes_slice = self.l1nodes.slice_view();

            stack.push(Frame{
                .node_idx = null,
                .idx = l0node.l1child0.?,
                .end = l0node.l1childhead.?,
                .toprint = toprint0.?,
                .esc_mode = l0_ri.esc_mode,
                .span_end = l0span.?[1],
            });

            while (stack.pop()) |frame_val| {
                var frame = frame_val;

                if (frame.idx >= frame.end) {
                    if (frame.node_idx) |ni| {
                        self.print(frame.esc_mode, self.textin[frame.toprint..frame.span_end]);

                        const node = l1nodes_slice[ni];
                        const ri = gen_rules.datatable.lookup(
                            @intFromEnum(node.kind),
                        ) orelse return ErrorReporter.crash(GenError.NoL1RuleForKind);

                        switch (ri.post_alg) {
                            .constant => |post| self.print_bs_esc(post),
                            .complex => |f| try f(self, @ptrCast(@constCast(&node))),
                        }

                        if (stack.peek_addr()) |parent| {
                            parent.toprint = node.span[1] + node.margin[1];
                        }
                    } else {
                        toprint0 = frame.toprint;
                    }
                    continue;
                }

                const child_idx = frame.idx;
                frame.idx += 1;
                const child = l1nodes_slice[child_idx];

                self.print(frame.esc_mode, self.textin[frame.toprint .. child.span[0] - child.margin[0]]);

                const child_ri = gen_rules.datatable.lookup(
                    @intFromEnum(child.kind),
                ) orelse return ErrorReporter.crash(GenError.NoL1RuleForKind);

                var child_span: ?@Vector(2, usize) = child.span;
                switch (child_ri.pre_alg) {
                    .constant => |pre| self.print_bs_esc(pre),
                    .complex => |f| {
                        child_span = try f(self, @ptrCast(@constCast(&child)));
                    },
                }

                if (child.l1_containable and child_span != null and child.l1child0 != null and child.l1childhead != null) {
                    stack.push(frame);
                    stack.push(Frame{
                        .node_idx = child_idx,
                        .idx = child.l1child0.?,
                        .end = child.l1childhead.?,
                        .toprint = child_span.?[0],
                        .esc_mode = child_ri.esc_mode,
                        .span_end = child_span.?[1],
                    });
                } else {
                    if (child_span) |cs| self.print(child_ri.esc_mode, self.textin[cs[0]..cs[1]]);
                    switch (child_ri.post_alg) {
                        .constant => |post| self.print_bs_esc(post),
                        .complex => |f| try f(self, @ptrCast(@constCast(&child))),
                    }
                    frame.toprint = child.span[1] + child.margin[1];
                    stack.push(frame);
                }
            }
        }

        if (toprint0 != null) {
            self.print(l0_ri.esc_mode, self.textin[toprint0.?..l0span.?[1]]);
        }

        switch (l0_ri.post_alg) {
            .constant => |post| self.print_bs_esc(post),
            .complex => |f| try f(self, @ptrCast(@constCast(&l0node))),
        }
    }

    return self.outbuf;
}
