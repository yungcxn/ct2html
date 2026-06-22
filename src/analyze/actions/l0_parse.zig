// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Parser = @import("../Parser.zig");
const ParsingError = Parser.ParsingError;

const AttributeSyntaxError = error{
    MissingBang,
    EmptyKey,
    MissingSpaceBetweenBangAndKey,
    MissingColon,
    MissingValue,
};

pub const SyntaxError = error{
    NewlineInHeading,
    TooSmallHeadingLevel,
    WrongAttributeFormat,
} || AttributeSyntaxError;

fn spush_node(p: *Parser, k: Node.KindLevel0, textstart: usize, textend: usize) void {
    p.push_node(.{
        .kind = .{ .L0 = k },
        .textstart = textstart,
        .textend = textend,
    });
}

pub fn attributes(p: *Parser, endat: usize) SyntaxError!void {
    var i = p.cursor;
    var line_end = i;
    while (i < endat) : (i = line_end + 1) {
        line_end = i;
        while (line_end < endat and p.text[line_end] != '\n') : (line_end += 1) {}

        if (i >= line_end) break;

        if (p.text[i] != '!') return SyntaxError.MissingBang;

        i += 1;
        if (i >= line_end) return SyntaxError.EmptyKey;

        if (p.text[i] == ' ' or p.text[i] == '\t')
            return SyntaxError.MissingSpaceBetweenBangAndKey;

        const key_start = i;
        var found_colon = false;
        var key_end = key_start;

        while (i < line_end) : (i += 1) {
            const c = p.text[i];
            if (c == ':') {
                key_end = i;
                found_colon = true;
                break;
            }
            if (c == ' ' or c == '\t') {
                key_end = i;
                break;
            }
        }

        if (!found_colon and i >= line_end)
            return SyntaxError.MissingColon;

        i += 1; // skip ':'
        if (i >= line_end) return SyntaxError.MissingValue;

        while (i < line_end and (p.text[i] == ' ' or p.text[i] == '\t')) : (i += 1) {}

        const value_start = i;

        spush_node(p, .AttributeKey, key_start, key_end);
        spush_node(p, .AttributeValue, value_start, line_end);
    }
    p.cursor = endat;
}

// read #'s
pub fn heading(p: *Parser, endat: usize) SyntaxError!void {
    var hashtagc: usize = 0;
    while (p.advance()) |c| {
        if (c != '#') break;
        hashtagc += 1;
    }

    const kind: Node.KindLevel0 = switch (hashtagc) {
        1 => .Heading1,
        2 => .Heading2,
        3 => .Heading3,
        4 => .Heading4,
        5 => .Heading5,
        6 => .Heading6,
        else => return SyntaxError.TooSmallHeadingLevel,
    };

    if (p.cursor < endat) _ = p.skip_whitesp();
    const start = p.cursor;
    while (p.cursor < endat) : (p.cursor += 1) {
        if (p.text[p.cursor] == '\n') return SyntaxError.NewlineInHeading;
    }

    spush_node(p, kind, start, endat);
}

pub fn items(p: *Parser, endat: usize) SyntaxError!void {
    outer: while (true) {
        // skip '-'
        p.cursor += 1;
        if (p.cursor < endat) _ = p.skip_whitesp();

        p.cursor = @min(p.cursor, endat);
        const start = p.cursor;

        while (p.advance()) |c| {
            if (p.cursor >= endat) {
                spush_node(p, .Item, start, endat);
                break :outer;
            }

            if (c == '\n' and p.peek() == '-') {
                spush_node(p, .Item, start, p.cursor - 1);

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

    spush_node(p, .Paragraph, start, endat);
}
