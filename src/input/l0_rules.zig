// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Parser = @import("Parser.zig");
const Rule = @import("../element/Rule.zig");
const ParsingError = Parser.ParsingError;

// TODO better, real VTABLE type to write, define nice enum(int) vtable type
// every func that is here registered may leave cursor anywhere

// .def TODO
pub const def = [_]Rule.L0{
    .{ .parse = &par },
    .{ .triggers = &.{'?'}, .parse = &nonpar },
    .{ .triggers = &.{'\\'}, .parse = &par },
    .{ .triggers = &.{'#'}, .parse = &heading },
    .{
        .triggers = &.{'-'},
        .parse = &dash_items,
        .pre_node = .unordered_list_begin,
        .post_node = .unordered_list_end,
    },
    .{
        .triggers = &.{ '1', '2', '3', '4', '5', '6', '7', '8', '9' },
        .parse = &num_items,
        .pre_node = .ordered_list_begin,
        .post_node = .ordered_list_end,
    },
    .{
        .triggers = &.{'!'},
        .parse = &attributes,
        .pre_node = .attribute_begin,
        .post_node = .attribute_end,
        .l1_rescan = false,
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

// TODO only doing first
pub fn attributes(p: *Parser, endat: usize) SyntaxError!Rule.L0.ApplyFinalState {
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

        const attr_name = p.text[key_start..p.cursor];
        const attr_kind = std.meta.stringToEnum(
            Node.L0Kind,
            attr_name,
        ) orelse return AttributeSyntaxError.UnknownAttributeName;

        if (!attr_kind.is_attribute()) {
            return AttributeSyntaxError.UnknownAttributeName;
        }

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
                p.push_l0node(.{
                    .kind = attr_kind,
                    .span = .{ value_start, endat },
                    .contains_l1 = false,
                });
                break :line;
            } else {
                return AttributeSyntaxError.MissingValue;
            }
        };

        // cursor is on '\n'
        p.push_l0node(.{
            .kind = attr_kind,
            .span = .{ value_start, p.cursor },
            .contains_l1 = false,
        });

        p.inc(); // cursor is now on the first char of the next line, which could be '!' for next
    }

    // we check if we even produced anything
    if (p.l0nodeshead == 2) return AttributeSyntaxError.EmptyAttributeSection;

    return .success;
}

// read #'s
pub fn heading(p: *Parser, endat: usize) SyntaxError!Rule.L0.ApplyFinalState {
    const hashtagc: usize = p.skipc('#') catch {
        return SyntaxError.NothingAfterHeadingHashtags;
    };
    const kind: Node.L0Kind = switch (hashtagc) {
        1 => .heading1,
        2 => .heading2,
        3 => .heading3,
        4 => .heading4,
        5 => .heading5,
        6 => .heading6,
        else => return SyntaxError.UnsupportedHeadingLevel,
    };

    p.bounded_skip_whitesp(endat) catch {
        return SyntaxError.NothingAfterHeadingHashtags;
    };

    // cursor is now at the first char of the heading text, and stays there
    if (!p.bounds_freeof(p.cursor, endat, '\n')) {
        return SyntaxError.NewlineInHeading;
    }
    p.push_l0node(.{ .kind = kind, .span = .{ p.cursor, endat } });
    return .success;
}

pub fn dash_items(p: *Parser, endat: usize) SyntaxError!Rule.L0.ApplyFinalState {
    outer: while (true) {
        p.inc(); // skip '-'
        _ = p.bounded_skip_whitesp(endat) catch return SyntaxError.EmptyItem;

        // now we're at the item text begin
        const item_textstart = p.cursor;

        while (p.pop()) |c| {
            if (!p.in_bound(endat)) {
                // last node
                p.push_l0node(.{
                    .kind = .dash_item,
                    .span = .{ item_textstart, endat },
                });
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
                    p.push_l0node(.{
                        .kind = .dash_item,
                        .span = .{ item_textstart, p.cursor - 1 },
                    });
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
    return .success;
}

pub fn num_items(p: *Parser, endat: usize) SyntaxError!Rule.L0.ApplyFinalState {
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
            const label_kind: Node.L0Kind = switch (p.peek().?) {
                '.' => .num_dot_item_label,
                ')' => .num_paren_item_label,
                else => unreachable, // since we went for `sep_set`
            };

            p.push_l0node(.{
                .kind = label_kind,
                .span = .{ p.cursor - labelc, p.cursor },
            });
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
                    p.push_l0node(.{
                        .kind = .num_dot_item_text,
                        .span = .{ text_start, endat },
                    });
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
                        p.push_l0node(.{
                            .kind = .num_dot_item_text,
                            .span = .{ text_start, p.cursor - 1 },
                        });
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
    return .success;
}

// default rule
pub fn par(p: *Parser, endat: usize) SyntaxError!Rule.L0.ApplyFinalState {
    const offset: usize = if (p.peek() == '\\') 1 else 0; // this is the "force par" char
    p.push_l0node(.{ .kind = .paragraph, .span = .{ p.cursor + offset, endat } });
    return .success;
}

pub fn nonpar(p: *Parser, endat: usize) SyntaxError!Rule.L0.ApplyFinalState {
    p.push_l0node(.{ .kind = .nonparagraph, .span = .{ p.cursor + 1, endat } });
    return .success;
}
