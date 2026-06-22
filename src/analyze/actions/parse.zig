// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Parser = @import("../Parser.zig");
const ParsingError = Parser.ParsingError;

const AttributeSyntaxError = error{
    EmptyKey,
    MissingSpaceBetweenBangAndKey,
    MissingColon,
    MissingValue,
};

pub const SyntaxError = error{
    NewlineInHeading,
    WrongAttributeFormat,
} || AttributeSyntaxError;

pub fn attribute(p: *Parser, endat: usize) SyntaxError!void {
    // we require the cursor to be at '!'
    // the attribute is of format `!key<s?>:<s?>value<s?>\n` with endat at the '\n'
    p.cursor += 1; // skip '!'
    if (p.cursor >= endat) return SyntaxError.EmptyKey;
    if (p.at_whitesp()) return SyntaxError.MissingSpaceBetweenBangAndKey;
    if (!p.skip_whitesp_until(endat)) return SyntaxError.EmptyKey;
    const key_start = p.cursor;
    var key_end = key_start + 1;
    while (p.cursor < endat) : (p.cursor += 1) {
        const c = p.text[p.cursor];
        if (c == ':') {
            key_end = p.cursor;
            break;
        }
        if (c == ' ' or c == '\t') {
            key_end = p.cursor;
            _ = p.skip_whitesp();
            if (p.cursor >= endat or p.text[p.cursor] != ':') {
                return SyntaxError.MissingColon;
            }
            break;
        }
    }

    p.cursor += 1; // now at :, skip
    if (p.cursor >= endat) return SyntaxError.MissingValue;
    if (!p.skip_whitesp_until(endat)) return SyntaxError.MissingValue;
    const value_start = p.cursor;
    const value_end = endat;

    p.push_node(.{
        .kind = .{ .L0 = .AttributeKey },
        .textstart = key_start,
        .textend = key_end,
    });
    p.push_node(.{
        .kind = .{ .L0 = .AttributeValue },
        .textstart = value_start,
        .textend = value_end,
    });
    p.cursor = endat; // nothing else should be eval'd here
}

// read #
pub fn h1(p: *Parser, endat: usize) SyntaxError!void {
    p.cursor += 1;
    if (p.cursor < endat) _ = p.skip_whitesp();
    const start = p.cursor;
    while (p.cursor < endat) : (p.cursor += 1) {
        if (p.text[p.cursor] == '\n') return SyntaxError.NewlineInHeading;
    }

    p.push_node(.{
        .kind = .{ .L0 = .Heading1 },
        .textstart = start,
        .textend = p.cursor,
    });
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
