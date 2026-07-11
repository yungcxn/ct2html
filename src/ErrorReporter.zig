const std = @import("std");
const Node = @import("element/Node.zig");
const Parser = @import("input/Parser.zig");
const DynBuf = @import("ds/dynbuf.zig").DynBuf;

alloc: std.mem.Allocator,
io: std.Io,
err_reported: bool = false,
outbuf: DynBuf(u8),
parser: ?*Parser = null,
htmlmode: bool = false,
responsemode: bool = false,

pub fn init(
    alloc: std.mem.Allocator,
    io: std.Io,
    htmlmode: bool,
    responsemode: bool,
) @This() {
    return @This(){
        .alloc = alloc,
        .io = io,
        .outbuf = DynBuf(u8).init(alloc, 100),
        .htmlmode = htmlmode,
        .responsemode = responsemode,
    };
}

pub fn deinit(self: *@This()) void {
    self.outbuf.deinit();
}

pub fn set_parser(self: *@This(), parser: *Parser) void {
    self.parser = parser;
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

// while testing, this should NOT be executed! it is for non-user induced errors
pub fn crash(err: anytype) noreturn {
    std.log.err("-- UNHANDLED CRASH --", .{});
    switch (@typeInfo(@TypeOf(err))) {
        .@"struct" => std.log.err(err[0], err[1]),
        .error_set => std.log.err("{s}", .{@errorName(err)}),
        else => std.log.err("{s}", .{err}),
    }
    return std.process.exit(1);
}

// this runs before any user induced error
pub fn file_report(
    self: *@This(),
    err: anytype,
    from_text: bool,
    texthint: anytype,
    node_or_kind: anytype, // TODO kann das weg?!
) @TypeOf(err) {
    self.err_reported = true;
    const report = Report{
        .err_name = @errorName(err),
        .from_text = from_text,
        .texthint = std.fmt.allocPrint(
            self.alloc,
            if (@typeInfo(@TypeOf(texthint)) == .@"struct") texthint[0] else "{s}",
            if (@typeInfo(@TypeOf(texthint)) == .@"struct") texthint[1] else .{texthint},
        ) catch return crash(error.OOM),
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

    self.build_report(report);
    self.alloc.free(report.texthint.?); // due to `allocPrint` above

    return err;
}

fn build_report(self: *@This(), r: Report) void {
    if (self.responsemode) {
        self.outbuf.append("Content-Type: text/html; charset=UTF-8\r\n\r\n");
    }

    if (self.htmlmode) {
        self.outbuf.append(
            \\<!DOCTYPE html>
            \\<html>
            \\    <head>
            \\    <meta charset=\"UTF-8\">
            \\    <title>Error</title>
            \\    </head>
            \\    <body>
        );
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

    if (r.from_text) { // 2. if error resulted from text
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
        self.outbuf.append(
            \\    </body>
            \\</html>
        );
    }
}

fn println(self: *@This(), text: []const u8) void {
    if (!self.htmlmode) {
        self.outbuf.append(text);
    } else {
        self.outbuf.append("<p><code style=\"white-space: pre;\">");
        self.outbuf.append(text);
        self.outbuf.append("</code></p>");
    }
    self.outbuf.append("\n");
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
