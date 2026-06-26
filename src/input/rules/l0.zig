// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Parser = @import("../Parser.zig");
const ParsingError = Parser.ParsingError;

pub const attr_nodekind_map = std.StaticStringMap(Node.KindLevel0).initComptime(.{
    .{ "style", .AttributeStyle },
    .{ "header", .AttributeHeader },
});

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

    .{
        .trigger = 'a',
        .apply = &alph_items,
        .l0_begin = .OrderedListBeginMeta,
        .l0_end = .OrderedListEndMeta,
    },

    .{
        .trigger = 'A',
        .apply = &alph_items,
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
    EmptyItem,
    NothingAfterHeadingHashtags,
    NewlineInHeading,
    UnsupportedHeadingLevel,
    WrongAttributeFormat,
    UnindentedLineAfterDashItem,
    AttributeBlockNotAtStart,
    UnknownAttributeName,
} || AttributeSyntaxError || OrderedItemsSyntaxError;

pub fn attributes(p: *Parser, endat: usize) SyntaxError!Parser.Rule.ApplyState {
    // attribute block is only allowed if it is the first node in the document
    // since from it we generate structurally important html tags
    // attribute section has a meta node, and before it a root begin node
    if (p.nodeshead != 2) return SyntaxError.AttributeBlockNotAtStart;

    // we assume we are on '!', so we move back
    p.dec();
    line: while (p.pop() == '!') {
        _ = p.bounded_skip_whitesp(endat) catch {
            return AttributeSyntaxError.EmptyKey;
        };
        // cursor is on first char of key
        const key_start = p.cursor;

        _ = p.bounded(p.skip(':', true), endat) catch {
            return AttributeSyntaxError.MissingColon;
        };

        if (std.mem.containsAtLeast(u8, p.text[key_start..p.cursor], 0, &.{ ' ', '\t' })) {
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

        _ = p.bounded(p.skip('\n', true), endat) catch |e| {
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
    const hashtagc: usize = p.skip('#', false) catch {
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
    _ = p.bounded(p.skip_whitesp(), endat) catch {
        return SyntaxError.NothingAfterHeadingHashtags;
    };
    // cursor is now at the first char of the heading text, and stays there
    if (!p.bound_free_of(endat, '\n')) return SyntaxError.NewlineInHeading;
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
                    // the next line has a new item, so we end on cursor
                    // with cursor being on c0_l1
                    p.dec(); // back to '\n'
                    p.push_l0node(.DashItem, item_textstart, p.cursor);
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

// this is special; cursor may be on different letters, e.g. '1' or 'a'
fn ordered_items(
    p: *Parser,
    comptime isdigit: bool,
    sep: u8,
    itemlabelkind: Node.KindLevel0,
    itemtextkind: Node.KindLevel0,
    endat: usize,
) SyntaxError!Parser.Rule.ApplyState {
    // outer: while (true) {
    //     const label_first = p.cursor;

    //     { // label
    //         while (true) : (p.cursor += 1) {
    //             const c = p.text[p.cursor];
    //             if (c == sep) break; // successful break

    //             if (isdigit and !std.ascii.isDigit(c))
    //                 return OrderedItemsSyntaxError.NonDigitPreSep;

    //             if (!isdigit and !std.ascii.isAlphabetic(c))
    //                 return OrderedItemsSyntaxError.NonAlphaPreSep;

    //             if (p.cursor >= endat)
    //                 return OrderedItemsSyntaxError.LabelRegionNeverEnded;
    //         }
    //         // we are on '.', so we can skip it and the following whitespace
    //         const label_last = p.cursor - 1;

    //         // now we have a valid number pre dot, so we push the node
    //         p.push_l0node(itemlabelkind, label_first, label_last + 1);
    //     }

    //     { // text
    //         p.cursor += 1;

    //         _ = p.bounded_skip_whitesp(endat) catch {
    //             return OrderedItemsSyntaxError.NothingAfterSep;
    //         };

    //         // now cursor is at first text letter
    //         const text_start = p.cursor;
    //         while (p.pop()) |c| {
    //             if (p.cursor >= endat) { // last item, done
    //                 p.push_l0node(itemtextkind, text_start, endat);
    //                 break :outer;
    //             }

    //             const peeked: u8 = p.peek().?; // safe, checked before this
    //             if (c == '\n') {
    //                 // continue if space or tab, else check if its valid label
    //                 if (peeked == ' ' or peeked == '\t') continue;
    //                 if (isdigit and !std.ascii.isDigit(peeked))
    //                     return OrderedItemsSyntaxError.NonDigitPreSepOnMultiline;

    //                 if (!isdigit and !std.ascii.isAlphabetic(peeked))
    //                     return OrderedItemsSyntaxError.NonAlphaPreSepOnMultiline;

    //                 p.push_l0node(itemtextkind, text_start, p.cursor - 1);
    //                 continue :outer;
    //             }
    //         }
    //     }
    //     return OrderedItemsSyntaxError.TextRegionEndedUnexpectedly;
    // }
    // return .did_not_transition;
}

pub fn num_items(p: *Parser, endat: usize) SyntaxError!Parser.Rule.ApplyState {
    // the rule is: digit(s), then either '.' or ')', if anything wrong -> par
    // const c_safe = p.cursor;
    // var c = p.text[p.cursor];
    // while (true) : (p.cursor += 1) {
    //     if (c == '.' or c == ')') {
    //         p.cursor = c_safe;
    //         return ordered_items(
    //             p,
    //             true,
    //             c,
    //             if (c == '.') .NumDotItemLabel else .NumParenItemLabel,
    //             if (c == '.') .NumDotItemText else .NumParenItemText,
    //             endat,
    //         );
    //     }
    //     if (!std.ascii.isDigit(c)) break;
    //     c = p.peek() orelse break;
    // }
    // p.cursor = c_safe;
    // return par(p, endat);
}

pub fn alph_items(p: *Parser, endat: usize) SyntaxError!Parser.Rule.ApplyState {
    // the rule is: one alph, then either '.' or ')', if anything wrong -> par
    // const c_safe = p.cursor;
    // blk: {
    //     const first = p.pop() orelse break :blk;
    //     if (!std.ascii.isAlphabetic(first)) break :blk;
    //     const sep = p.pop() orelse break :blk;
    //     if (sep != '.' and sep != ')') break :blk;

    //     p.cursor = c_safe;
    //     return ordered_items(
    //         p,
    //         false,
    //         sep,
    //         if (sep == '.') .AlphDotItemLabel else .AlphParenItemLabel,
    //         if (sep == '.') .AlphDotItemText else .AlphParenItemText,
    //         endat,
    //     );
    // }

    // p.cursor = c_safe;
    // _ = par(p, endat) catch |err| {
    //     p.error_handle(err);
    //     return .errd;
    // };
    // return .transitioned_to_p;
}

// default rule
pub fn par(p: *Parser, endat: usize) SyntaxError!Parser.Rule.ApplyState {
    p.push_l0node(.Paragraph, p.cursor, endat);
    return .did_not_transition;
}
