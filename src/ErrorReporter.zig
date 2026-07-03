const std = @import("std");
const Node = @import("element/Node.zig");
const Parser = @import("input/Parser.zig");
const Generator = @import("Generator").Generator;

var instance: ?@This() = null;

io: std.Io,
parser: ?*Parser = null,
outf: std.Io.File,
htmlmode: bool = false,
prefiled_report: ?Report = null,

pub fn init_singleton(
    io: std.Io,
    parser: *Parser,
    outf: std.Io.File,
    htmlmode: bool,
) void {
    instance = @This(){
        .io = io,
        .parser = parser,
        .outf = outf,
        .htmlmode = htmlmode,
    };
}

const Report = struct {
    const NodeOrKind = union(enum) {
        l0: Node.L0,
        l1: Node.L1,
        l0kind: Node.L0Kind,
        l1kind: Node.L1Kind,
    };

    err_name: []const u8,
    from_text: bool = true,
    texthint: ?[]const u8 = null,
    node_or_kind: ?NodeOrKind = null,

    pub fn kind_name(self: @This()) []const u8 {
        if (self.node_or_kind) |n| {
            return switch (n) {
                .l0 => @tagName(n.l0.kind),
                .l1 => @tagName(n.l1.kind),
                .l0kind => @tagName(n.l0kind),
                .l1kind => @tagName(n.l1kind),
            };
        }
        unreachable;
    }
};

pub fn crash(err: anyerror) noreturn {
    switch (@typeInfo(@TypeOf(err))) {
        .error_set => std.log.err("Unhandled Crash: {s}", .{@errorName(err)}),
        else => std.log.err("Unhandled Crash: {}", .{err}),
    }
    return std.process.exit(1);
}

pub fn file_report(
    err: anyerror,
    from_text: bool,
    texthint: ?[]const u8,
    node_or_kind: anytype,
) void {
    const self = &instance.?;
    self.prefiled_report = Report{
        .err_name = @errorName(err),
        .from_text = from_text,
        .texthint = texthint,
        .node_or_kind = switch (@typeInfo(@TypeOf(node_or_kind))) {
            .@"enum" => switch (@TypeOf(node_or_kind)) {
                Node.L0Kind => .{ .l0kind = node_or_kind },
                Node.L1Kind => .{ .l1kind = node_or_kind },
                else => null,
            },
            .@"struct" => switch (@TypeOf(node_or_kind)) {
                Node.L0 => .{ .l0 = node_or_kind },
                Node.L1 => .{ .l1 = node_or_kind },
                else => null,
            },
            else => null,
        },
    };
}

pub fn throw() noreturn {
    const self = &instance.?;
    if (self.prefiled_report) |r| {
        return self.filed_throw(r);
    } else {
        return self.filed_throw(Report{
            .err_name = "Unknown error",
            .from_text = false,
            .texthint = null,
            .node_or_kind = null,
        });
    }
}

fn filed_throw(self: *@This(), r: Report) noreturn {
    if (self.htmlmode) {
        self.outf.writeStreamingAll(self.io,
            \\\<!DOCTYPE html>\n
            \\\<html>\n
            \\\    <head>\n
            \\\    <meta charset=\"UTF-8\">\n
            \\\    <title>Error</title>\n
            \\\    </head>\n
            \\\    <body>\n
        ) catch |e| crash(e);
    }

    self.printf("Error: {s}", .{r.err_name});

    // 1. if node was passed in report
    if (r.node_or_kind) |_| {
        self.printf("Error at Node `{s}`", .{r.kind_name()});

        const span = switch (r.node_or_kind.?) {
            .l0 => r.node_or_kind.?.l0.span,
            .l1 => r.node_or_kind.?.l1.span,
            else => null,
        };

        if (span) |s| {
            const text = self.parser.?.text[s[0]..s[1]];
            self.printf("[node-context]: {s}", .{text});
        }
    }

    { // 2. if error resulted from text
        const line, const col = self.parser_get_line_col();
        const orig_cursor = self.parser.?.cursor;

        self.printf(
            "At line {d}, column {d}",
            .{ line, col },
        );

        const line_bounds = self.parser_find_line_bounds();

        {
            const line_text = self.parser.?.text[line_bounds[0]..line_bounds[1]];
            self.printf("[context]: {s}", .{line_text});
        }

        const pos = orig_cursor - line_bounds[0];
        self.parser.?.cursor = line_bounds[0];

        {
            var pos_marker: [256]u8 = @splat(0);
            @memset(pos_marker[0..pos], ' ');
            pos_marker[pos] = '^';
            self.printf("           {s}\n", .{pos_marker});
        }
    }

    // 3. text hint passage
    if (r.texthint) |hint| self.printf("Hint: {s}", .{hint});

    if (self.htmlmode) {
        self.outf.writeStreamingAll(self.io,
            \\\    </body>\n
            \\\</html>\n
        ) catch |err| crash(err);
    }

    return std.process.exit(1);
}

fn println(self: *@This(), text: []const u8) void {
    if (!self.htmlmode) {
        self.outf.writeStreamingAll(self.io, text) catch |e| crash(e);
    } else {
        self.outf.writeStreamingAll(self.io, "<p><code style=\"white-space: pre;\">") catch |e| crash(e);
        self.outf.writeStreamingAll(self.io, text) catch |e| crash(e);
        self.outf.writeStreamingAll(self.io, "</code></p>") catch |e| crash(e);
    }
    self.outf.writeStreamingAll(self.io, "\n") catch |e| crash(e);
}

fn printf(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch |e| crash(e);
    self.println(text);
}

// returns pos of last newline1 and next newline-1
fn parser_find_line_bounds(self: @This()) @Vector(2, usize) {
    const cursor_save = self.parser.?.cursor;
    defer self.parser.?.cursor = cursor_save;

    // we expect to hit EOF, and since this is a generator function,
    // we return null on end instead of propagating the error
    var rbound_available = true;
    self.parser.?.skip_whitesp() catch {
        rbound_available = false;
    };

    while (self.parser.?.cursor > 0) {
        self.parser.?.dec();
        if (self.parser.?.peek().? == '\n') {
            self.parser.?.cursor += 1;
            break;
        }
    }
    const lbound = self.parser.?.cursor;

    var rbound: usize = undefined;
    if (rbound_available) {
        while (self.parser.?.pop()) |c| {
            if (c == '\n') {
                rbound = self.parser.?.cursor - 1;
                return .{ lbound, rbound };
            }
        }
    }

    rbound = self.parser.?.text.len;
    return .{ lbound, rbound };
}

fn parser_get_line_col(self: @This()) @Vector(2, usize) {
    var line: usize = 1;
    var col: usize = 1;
    for (self.parser.?.text[0..self.parser.?.cursor]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ line, col };
}
