// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Parser = @import("../Parser.zig");
const ParsingError = Parser.ParsingError;

pub const SyntaxError = error{
    NewlineInHeading,
};

// read #
pub fn h1(p: *Parser, endat: usize) SyntaxError!void {
    const cursor_after_trigger = p.cursor + 1;
    var scan = cursor_after_trigger;
    while (scan < endat) : (scan += 1) {
        if (p.text[scan] == '\n') return SyntaxError.NewlineInHeading;
    }
    p.cursor = cursor_after_trigger;

    p.push_node(.{
        .kind = .{ .L0 = .Heading1 },
        .textstart = cursor_after_trigger,
        .textend = endat,
    });
}

pub fn items(p: *Parser, endat: usize) SyntaxError!void {
    outer: while (true) {
        // skip '-'
        p.cursor += 1;

        if (p.cursor < endat)
            _ = p.skip_whitesp();

        p.cursor = @min(p.cursor, endat);
        const start = p.cursor;

        while (p.advance()) |c| {
            if (p.cursor >= endat) {
                p.push_node(.{
                    .kind = .{ .L0 = .Item },
                    .textstart = start,
                    .textend = endat,
                });
                break :outer;
            }

            if (c == '\n' and p.peek() == '-') {
                p.push_node(.{
                    .kind = .{ .L0 = .Item },
                    .textstart = start,
                    .textend = p.cursor - 1, // exclude '\n'
                });

                // p.cursor is already on the '-'
                continue :outer;
            }
        }
    }
}

// default rule
pub fn par(p: *Parser, endat: usize) SyntaxError!void {
    const start = p.cursor;
    p.cursor = endat;

    p.push_node(.{
        .kind = .{ .L0 = .Paragraph },
        .textstart = start,
        .textend = endat,
    });
}
