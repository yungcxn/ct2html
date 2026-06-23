// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Parser = @import("../Parser.zig");
const ParsingError = Parser.ParsingError;

// every func that is here registered is not required to have the cursor on some position afterwards
pub const rules = [_]Parser.Rule{
    .{
        .func = par, // default
    },
    .{ .trigger = '\\', .func = par }, // force paragraph, if first char is some trigger
    .{ .trigger = '#', .func = heading },
    .{ .trigger = '-', .func = dash_items },
    .{ .trigger = '!', .func = attributes, .rescan_for_l1 = false },

    .{ .trigger = '1', .func = num_items },
    .{ .trigger = '2', .func = num_items },
    .{ .trigger = '3', .func = num_items },
    .{ .trigger = '4', .func = num_items },
    .{ .trigger = '5', .func = num_items },
    .{ .trigger = '6', .func = num_items },
    .{ .trigger = '7', .func = num_items },
    .{ .trigger = '8', .func = num_items },
    .{ .trigger = '9', .func = num_items },

    .{ .trigger = 'a', .func = alph_items },
    .{ .trigger = 'A', .func = alph_items },
};

const AttributeSyntaxError = error{
    MissingBang,
    EmptyKey,
    MissingSpaceBetweenBangAndKey,
    MissingColon,
    MissingValue,
};

const OrderedItemsSyntaxError = error{
    NotANumberPreSep,
    NonDigitPreSep,
    NonAlphaPreSep,
    LabelRegionNeverEnded,
    NothingAfterSep,
    NumberRegionNeverEnded,
    TextRegionEndedUnexpectedly,
    NonDigitPreSepOnMultiline,
    NonAlphaPreSepOnMultiline,
};

pub const SyntaxError = error{
    NewlineInHeading,
    TooSmallHeadingLevel,
    WrongAttributeFormat,
    UnindentedLineAfterDashItem,
} || AttributeSyntaxError || OrderedItemsSyntaxError;

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

pub fn dash_items(p: *Parser, endat: usize) SyntaxError!void {
    outer: while (true) {
        // skip '-'
        p.cursor += 1;
        if (p.cursor < endat) _ = p.skip_whitesp();

        p.cursor = @min(p.cursor, endat);
        const start = p.cursor;

        while (p.advance()) |c| {
            if (p.cursor >= endat) {
                spush_node(p, .DashItem, start, endat);
                break :outer;
            }

            if (c == '\n') {
                // we could proceed on ' ' or '\t'
                const c_p = p.peek() orelse 0;
                if (c_p == ' ' or c_p == '\t') continue;

                // we have something unidented on this line, better let it be '-'
                if (c_p != '-') return SyntaxError.UnindentedLineAfterDashItem;

                // we end here on "\n-", with cursor on '-'
                spush_node(p, .DashItem, start, p.cursor - 1);
                continue :outer;
            }
        }
    }
    spush_node(p, .DashItemSentinel, 0, 0);
}

// this is special; cursor may be on 1-9, since we start on first line ->`1. text` or `5. text`
fn ordered_items(
    p: *Parser,
    comptime isdigit: bool,
    sep: u8,
    itemlabelkind: Node.KindLevel0,
    itemtextkind: Node.KindLevel0,
    itemsentinelkind: Node.KindLevel0,
    endat: usize,
) SyntaxError!void {
    outer: while (true) {
        const label_first = p.cursor;

        { // label
            while (true) : (p.cursor += 1) {
                const c = p.text[p.cursor];
                if (c == sep) break; // successful break

                if (isdigit and !std.ascii.isDigit(c))
                    return OrderedItemsSyntaxError.NonDigitPreSep;

                if (!isdigit and !std.ascii.isAlphabetic(c))
                    return OrderedItemsSyntaxError.NonAlphaPreSep;

                if (p.cursor >= endat)
                    return OrderedItemsSyntaxError.LabelRegionNeverEnded;
            }
            // we are on '.', so we can skip it and the following whitespace
            const label_last = p.cursor - 1;

            // now we have a valid number pre dot, so we push the node
            spush_node(p, itemlabelkind, label_first, label_last + 1);
        }

        { // text
            p.cursor += 1;
            if (!p.skip_whitesp())
                return OrderedItemsSyntaxError.NothingAfterSep;

            // now cursor is at first text letter
            const text_start = p.cursor;
            while (p.advance()) |c| {
                if (p.cursor >= endat) { // last item, done
                    spush_node(p, itemtextkind, text_start, endat);
                    break :outer;
                }

                const peeked: u8 = p.peek().?; // safe, checked before this
                if (c == '\n') {
                    // continue if space or tab, else check if its valid label
                    if (peeked == ' ' or peeked == '\t') continue;
                    if (isdigit and !std.ascii.isDigit(peeked))
                        return OrderedItemsSyntaxError.NonDigitPreSepOnMultiline;

                    if (!isdigit and !std.ascii.isAlphabetic(peeked))
                        return OrderedItemsSyntaxError.NonAlphaPreSepOnMultiline;

                    spush_node(p, itemtextkind, text_start, p.cursor - 1);
                    continue :outer;
                }
            }
        }
        return OrderedItemsSyntaxError.TextRegionEndedUnexpectedly;
    }
    spush_node(p, itemsentinelkind, 0, 0);
}

pub fn num_items(p: *Parser, endat: usize) SyntaxError!void {
    // the rule is: digit(s), then either '.' or ')', if anything wrong -> par
    const c_safe = p.cursor;
    var c = p.text[p.cursor];
    while (true) : (p.cursor += 1) {
        if (c == '.' or c == ')') {
            p.cursor = c_safe;
            return ordered_items(
                p,
                true,
                c,
                if (c == '.') .NumDotItemLabel else .NumParenItemLabel,
                if (c == '.') .NumDotItemText else .NumParenItemText,
                if (c == '.') .NumDotItemSentinel else .NumParenItemSentinel,
                endat,
            );
        }
        if (!std.ascii.isDigit(c)) break;
        c = p.peek() orelse break;
    }
    p.cursor = c_safe;
    return par(p, endat);
}

pub fn alph_items(p: *Parser, endat: usize) SyntaxError!void {
    // the rule is: one alph, then either '.' or ')', if anything wrong -> par
    const c_safe = p.cursor;
    blk: {
        const first = p.advance() orelse break :blk;
        if (!std.ascii.isAlphabetic(first)) break :blk;
        const sep = p.advance() orelse break :blk;
        if (sep != '.' and sep != ')') break :blk;

        p.cursor = c_safe;
        return ordered_items(
            p,
            false,
            sep,
            if (sep == '.') .AlphDotItemLabel else .AlphParenItemLabel,
            if (sep == '.') .AlphDotItemText else .AlphParenItemText,
            if (sep == '.') .AlphDotItemSentinel else .AlphParenItemSentinel,
            endat,
        );
    }

    p.cursor = c_safe;
    return par(p, endat);
}

// default rule
pub fn par(p: *Parser, endat: usize) SyntaxError!void {
    const start = p.cursor;
    p.cursor = endat;

    spush_node(p, .Paragraph, start, endat);
}
