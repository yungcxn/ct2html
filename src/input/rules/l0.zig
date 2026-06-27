// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Parser = @import("../Parser.zig");
const ParsingError = Parser.ParsingError;

pub const attr_nodekind_map = std.StaticStringMap(Node.KindLevel0).initComptime(.{
    .{ "style", .AttributeStyle },
    .{ "header", .AttributeHeader },
});

// TODO better, real VTABLE type to write, define nice enum(int) vtable type
// every func that is here registered may leave cursor anywhere
pub const vtable = [_]Parser.Rule{
    .{
        .apply = &par,
    },
    .{ // force paragraph, if first char is some trigger
        .trigger = '\\',
        .apply = &par,
    },
    .{
        .trigger = '#',
        .apply = &heading,
    },
    .{
        .trigger = '-',
        .apply = &dash_items,
        .l0_begin = .UnorderedListBeginMeta,
        .l0_end = .UnorderedListEndMeta,
    },
    .{
        .trigger = '!',
        .apply = &attributes,
        .rescan_for_l1 = false,
        .l0_begin = .AttributeBeginMeta,
        .l0_end = .AttributeEndMeta,
    },
    .{
        .trigger = '1',
        .apply = &num_items,
        .l0_begin = .OrderedListBeginMeta,
        .l0_end = .OrderedListEndMeta,
    },
    .{
        .trigger = '2',
        .apply = &num_items,
        .l0_begin = .OrderedListBeginMeta,
        .l0_end = .OrderedListEndMeta,
    },
    .{
        .trigger = '3',
        .apply = &num_items,
        .l0_begin = .OrderedListBeginMeta,
        .l0_end = .OrderedListEndMeta,
    },
    .{
        .trigger = '4',
        .apply = &num_items,
        .l0_begin = .OrderedListBeginMeta,
        .l0_end = .OrderedListEndMeta,
    },
    .{
        .trigger = '5',
        .apply = &num_items,
        .l0_begin = .OrderedListBeginMeta,
        .l0_end = .OrderedListEndMeta,
    },
    .{
        .trigger = '6',
        .apply = &num_items,
        .l0_begin = .OrderedListBeginMeta,
        .l0_end = .OrderedListEndMeta,
    },
    .{
        .trigger = '7',
        .apply = &num_items,
        .l0_begin = .OrderedListBeginMeta,
        .l0_end = .OrderedListEndMeta,
    },
    .{
        .trigger = '8',
        .apply = &num_items,
        .l0_begin = .OrderedListBeginMeta,
        .l0_end = .OrderedListEndMeta,
    },
    .{
        .trigger = '9',
        .apply = &num_items,
        .l0_begin = .OrderedListBeginMeta,
        .l0_end = .OrderedListEndMeta,
    },
};

const AttributeSyntaxError = error{
    EmptyKey,
    MissingColon,
    SpaceBetweenKeyAndColonNotAllowed,
    MissingValue,
    EmptyAttributeSection,
    UnknownAttributeName,
    AttributeBlockAtInvalidPosition,
};

const OrderedItemsSyntaxError = error{
    NotANumberPreSep,
    NonDigitPreSep,
    LabelRegionNeverEnded,
    NothingAfterSep,
    NumberRegionNeverEnded,
    TextRegionEndedUnexpectedly,
    NonDigitPreSepOnMultiline,
    SpaceInLabelNotAllowed,
    UnindentedLineAfterDashItem,
};

pub const SyntaxError = error{
    EmptyItem,
    NothingAfterHeadingHashtags,
    NewlineInHeading,
    UnsupportedHeadingLevel,
    WrongAttributeFormat,
    UnindentedLineAfterDashItem,
    Unhandled,
} || AttributeSyntaxError || OrderedItemsSyntaxError;

pub fn attributes(p: *Parser, endat: usize) SyntaxError!Parser.Rule.ApplyState {
    // attribute block is only allowed if it is the first node in the document
    // since from it we generate structurally important html tags
    // attribute section has a meta node, and before it a root begin node
    if (p.nodeshead != 2) return SyntaxError.AttributeBlockAtInvalidPosition;

    // we assume we are on '!'
    line: while (p.pop() == '!') {
        _ = p.bounded_skip_whitesp(endat) catch {
            return AttributeSyntaxError.EmptyKey;
        };

        const key_start = p.cursor;

        p.bounded_find(':', endat) catch return AttributeSyntaxError.MissingColon;

        // cursor is on ':', so we check if the keyname is free of whitespace
        if (!p.bounds_freeof_whitesp(key_start, p.cursor)) {
            return AttributeSyntaxError.SpaceBetweenKeyAndColonNotAllowed;
        }

        const attr_kind = attr_nodekind_map.get(
            p.text[key_start..p.cursor],
        ) orelse {
            return AttributeSyntaxError.UnknownAttributeName;
        };

        // cursor is at ':'...
        p.inc();
        // ...now at first char of value

        // advance till value start
        _ = p.bounded_skip_whitesp(endat) catch {
            return AttributeSyntaxError.MissingValue;
        };

        const value_start = p.cursor;

        p.bounded_find('\n', endat) catch |e| {
            if (e == ParsingError.OutOfBounds) {
                // last line, so must accept it
                p.push_l0node(attr_kind, value_start, endat);
                break :line;
            } else {
                return AttributeSyntaxError.MissingValue;
            }
        };

        // cursor is on '\n'
        p.push_l0node(attr_kind, value_start, p.cursor);
    }

    // we check if we even produced anything
    if (p.nodeshead == 2) return AttributeSyntaxError.EmptyAttributeSection;

    return .did_not_transition;
}

// read #'s
pub fn heading(p: *Parser, endat: usize) SyntaxError!Parser.Rule.ApplyState {
    const hashtagc: usize = p.skipc('#') catch {
        return SyntaxError.NothingAfterHeadingHashtags;
    };
    const kind: Node.KindLevel0 = switch (hashtagc) {
        1 => .Heading1,
        2 => .Heading2,
        3 => .Heading3,
        4 => .Heading4,
        5 => .Heading5,
        6 => .Heading6,
        else => return SyntaxError.UnsupportedHeadingLevel,
    };

    p.bounded_skip_whitesp(endat) catch {
        return SyntaxError.NothingAfterHeadingHashtags;
    };

    // cursor is now at the first char of the heading text, and stays there
    if (!p.bounds_freeof(p.cursor, endat, '\n')) {
        return SyntaxError.NewlineInHeading;
    }

    p.push_l0node(kind, p.cursor, endat);
    return .did_not_transition;
}

pub fn dash_items(p: *Parser, endat: usize) SyntaxError!Parser.Rule.ApplyState {
    outer: while (true) {
        p.inc(); // skip '-'
        _ = p.bounded_skip_whitesp(endat) catch return SyntaxError.EmptyItem;

        // now we're at the item text begin
        const item_textstart = p.cursor;

        while (p.pop()) |c| {
            if (!p.in_bound(endat)) {
                // last node
                p.push_l0node(.DashItem, item_textstart, endat);
                break :outer;
            }

            if (c != '\n') continue;

            switch (p.peek() orelse return SyntaxError.EmptyItem) {
                ' ', '\t' => {
                    // through this condition, we allow the next line to be
                    // part of this item, if it starts anyhow indented
                    continue;
                },
                '-' => {
                    // the next line has a new item, so we end on cursor-1=\n
                    p.push_l0node(.DashItem, item_textstart, p.cursor - 1);
                    continue :outer;
                },
                else => {
                    // in this case we forbid something like this:
                    // \\\- this-is-some\n
                    // \\\unindented-text
                    return SyntaxError.UnindentedLineAfterDashItem;
                },
            }
        }
    }
    return .did_not_transition;
}

pub fn num_items(
    p: *Parser,
    endat: usize,
) SyntaxError!Parser.Rule.ApplyState {
    const sep_set = .{ '.', ')' };
    outer: while (true) {

        // first: the label, we exit this block on cursor being sep +1
        {
            const labelc = p.bounded_findc(sep_set, endat) catch {
                return OrderedItemsSyntaxError.NotANumberPreSep;
            };
            //cursor is on sep

            if (!p.bounds_freeof_whitesp(p.cursor - labelc, p.cursor)) {
                return OrderedItemsSyntaxError.SpaceInLabelNotAllowed;
            }

            // we are still on the sep, e.g. '.'
            const label_kind: Node.KindLevel0 = switch (p.peek().?) {
                '.' => .NumDotItemLabel,
                ')' => .NumParenItemLabel,
                else => unreachable, // since we went for `sep_set`
            };

            p.push_l0node(label_kind, p.cursor - labelc, p.cursor);

            p.inc();
        }

        // second: the text, and we start with cursor on sep +1
        {
            _ = p.bounded_skip_whitesp(endat) catch {
                return OrderedItemsSyntaxError.NothingAfterSep;
            };

            const text_start = p.cursor;

            while (p.pop()) |c| {
                if (!p.in_bound(endat)) {
                    // last node
                    p.push_l0node(.NumDotItemText, text_start, endat);
                    break :outer;
                }

                if (c != '\n') continue;

                switch (p.peek() orelse return OrderedItemsSyntaxError.NothingAfterSep) {
                    ' ', '\t' => {
                        // through this condition, we allow the next line to be
                        // part of this item, if it starts anyhow indented
                        continue;
                    },
                    '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                        // the next line has a new item, so we end on cursor-1=\n
                        p.push_l0node(.NumDotItemText, text_start, p.cursor - 1);
                        continue :outer;
                    },
                    else => {
                        // in this case we forbid something like this:
                        // \\\1. this-is-some\n
                        // \\\unindented-text
                        return OrderedItemsSyntaxError.UnindentedLineAfterDashItem;
                    },
                }
            }
        }
    }
    return .did_not_transition;
}

// default rule
pub fn par(p: *Parser, endat: usize) SyntaxError!Parser.Rule.ApplyState {
    p.push_l0node(.Paragraph, p.cursor, endat);
    return .did_not_transition;
}
