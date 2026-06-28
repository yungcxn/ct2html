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
    .{ .triggers = null, .apply = &par },
    .{ .triggers = &.{'\\'}, .apply = &par },
    .{ .triggers = &.{'#'}, .apply = &heading },
    .{
        .triggers = &.{'-'},
        .apply = &dash_items,
        .l0_begin = .unordered_list_begin,
        .l0_end = .unordered_list_end,
    },
    .{
        .triggers = &.{ '1', '2', '3', '4', '5', '6', '7', '8', '9' },
        .apply = &num_items,
        .l0_begin = .ordered_list_begin,
        .l0_end = .ordered_list_end,
    },
    .{
        .triggers = &.{'!'},
        .apply = &attributes,
        .l0_begin = .attribute_begin,
        .l0_end = .attribute_end,
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

pub fn attributes(p: *Parser, endat: usize) SyntaxError!Rule.L0.ApplyFinalState {
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

        const attr_kind = std.meta.stringToEnum(
            Node.Kind,
            p.text[key_start..p.cursor],
        ) orelse return AttributeSyntaxError.UnknownAttributeName;

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
                p.push_node(attr_kind, .{ .start = value_start, .end = endat });
                break :line;
            } else {
                return AttributeSyntaxError.MissingValue;
            }
        };

        // cursor is on '\n'
        p.push_node(attr_kind, .{ .start = value_start, .end = p.cursor });
    }

    // we check if we even produced anything
    if (p.nodeshead == 2) return AttributeSyntaxError.EmptyAttributeSection;

    return .success;
}

// read #'s
pub fn heading(p: *Parser, endat: usize) SyntaxError!Rule.L0.ApplyFinalState {
    const hashtagc: usize = p.skipc('#') catch {
        return SyntaxError.NothingAfterHeadingHashtags;
    };
    const kind: Node.Kind = switch (hashtagc) {
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
    p.push_node(kind, .{ .start = p.cursor, .end = endat });
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
                p.push_node(.dash_item, .{ .start = item_textstart, .end = endat });
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
                    p.push_node(.dash_item, .{ .start = item_textstart, .end = p.cursor - 1 });
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
            const label_kind: Node.Kind = switch (p.peek().?) {
                '.' => .num_dot_item_label,
                ')' => .num_paren_item_label,
                else => unreachable, // since we went for `sep_set`
            };

            p.push_node(label_kind, .{ .start = p.cursor - labelc, .end = p.cursor });
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
                    p.push_node(.num_dot_item_text, .{ .start = text_start, .end = endat });
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
                        p.push_node(
                            .num_dot_item_text,
                            .{ .start = text_start, .end = p.cursor - 1 },
                        );
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
    p.push_node(.paragraph, .{ .start = p.cursor, .end = endat });
    return .success;
}
