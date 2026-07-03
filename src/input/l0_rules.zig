// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Parser = @import("Parser.zig");
const Rule = @import("../element/Rule.zig");

const L0SyntaxError = Parser.ParsingError.L0SyntaxError;
const file_report = @import("../ErrorReporter.zig").file_report;
const crash = @import("../ErrorReporter.zig").crash;

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

pub fn attributes(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0.ApplyFinalState {
    // we assume we are on '!'
    line: while (p.pop() == '!') {
        p.bounded_skip_whitesp(endat) catch {
            file_report(error.L0Attribute, true, "Empty attribute key", null);
            return L0SyntaxError;
        };

        const key_start = p.cursor;

        p.bounded_find(':', endat) catch {
            file_report(error.L0Attribute, true, "Missing colon in attribute", null);
            return L0SyntaxError;
        };

        // cursor is on ':', so we check if the keyname is free of whitespace
        if (!p.bounds_freeof_whitesp(key_start, p.cursor)) {
            file_report(error.L0Attribute, true, "Space between key and colon not allowed", null);
            return L0SyntaxError;
        }

        const attr_name = p.text[key_start..p.cursor];
        const attr_kind = std.meta.stringToEnum(Node.L0Kind, attr_name) orelse {
            file_report(error.L0Attribute, true, "Unknown attribute name", null);
            return L0SyntaxError;
        };
        if (!attr_kind.is_attribute()) {
            file_report(error.L0Attribute, true, "Invalid attribute name", null);
            return L0SyntaxError;
        }

        // cursor is at ':'...
        p.inc();
        // ...now at first char of value

        // advance till value start
        p.bounded_skip_whitesp(endat) catch {
            file_report(error.L0Attribute, true, "Missing value in attribute", attr_kind);
            return L0SyntaxError;
        };

        const value_start = p.cursor;

        p.bounded_find('\n', endat) catch |e| {
            if (e == Parser.ParsingError.OutOfBounds) {
                // last line, so must accept it
                p.l0nodes.push(.{
                    .kind = attr_kind,
                    .span = .{ value_start, endat },
                    .contains_l1 = false,
                }) catch |err| crash(err);
                break :line;
            } else {
                file_report(error.L0Attribute, true, "Missing value in attribute", attr_kind);
                return L0SyntaxError;
            }
        };

        // cursor is on '\n'
        p.l0nodes.push(.{
            .kind = attr_kind,
            .span = .{ value_start, p.cursor },
            .contains_l1 = false,
        }) catch |err| crash(err);

        p.inc(); // cursor is now on the first char of the next line, which could be '!' for next
    }

    // we check if we even produced anything
    if (p.l0nodes.head == 2) {
        file_report(error.L0Attribute, true, "Empty attribute section", null);
        return L0SyntaxError;
    }

    return .success;
}

// read #'s
pub fn heading(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0.ApplyFinalState {
    const hashtagc: usize = p.skipc('#') catch {
        file_report(error.L0Heading, true, "Nothing after heading hashtags", null);
        return L0SyntaxError;
    };

    const kind: Node.L0Kind = switch (hashtagc) {
        1 => .heading1,
        2 => .heading2,
        3 => .heading3,
        4 => .heading4,
        5 => .heading5,
        6 => .heading6,
        else => {
            file_report(error.L0Heading, true, "Too many heading hashtags", null);
            return L0SyntaxError;
        },
    };

    p.bounded_skip_whitesp(endat) catch {
        file_report(error.L0Heading, true, "Nothing after heading hashtags", null);
        return L0SyntaxError;
    };

    // cursor is now at the first char of the heading text, and stays there
    if (!p.bounds_freeof(p.cursor, endat, '\n')) {
        file_report(error.L0Heading, true, "Newline in heading", kind);
        return L0SyntaxError;
    }

    // cursor is now at the first char of the heading text, and stays there
    if (!p.bounds_freeof(p.cursor, endat, '\n')) {
        file_report(error.L0Heading, true, "Newline in heading", kind);
        return L0SyntaxError;
    }

    p.l0nodes.push(.{ .kind = kind, .span = .{ p.cursor, endat } }) catch |err| crash(err);
    return .success;
}

pub fn dash_items(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0.ApplyFinalState {
    outer: while (true) {
        p.inc(); // skip '-'
        p.bounded_skip_whitesp(endat) catch {
            file_report(error.L0DashItem, true, "Empty item", Node.L0Kind.dash_item);
            return L0SyntaxError;
        };

        // now we're at the item text begin
        const item_textstart = p.cursor;

        while (p.pop()) |c| {
            if (!p.in_bound(endat)) {
                // last node
                p.l0nodes.push(.{
                    .kind = .dash_item,
                    .span = .{ item_textstart, endat },
                }) catch |err| crash(err);

                break :outer;
            }

            if (c != '\n') continue;

            switch (p.peek() orelse {
                file_report(error.L0DashItem, true, "Empty item", Node.L0Kind.dash_item);
                return L0SyntaxError;
            }) {
                ' ', '\t' => {
                    // through this condition, we allow the next line to be
                    // part of this item, if it starts anyhow indented
                    continue;
                },
                '-' => {
                    // the next line has a new item, so we end on cursor-1=\n
                    p.l0nodes.push(.{
                        .kind = .dash_item,
                        .span = .{ item_textstart, p.cursor - 1 },
                    }) catch |err| crash(err);

                    continue :outer;
                },
                else => {
                    // in this case we forbid something like this:
                    // \\\- this-is-some\n
                    // \\\unindented-text
                    file_report(error.L0DashItem, true, "Unindented line after dash item", Node.L0Kind.dash_item);
                    return L0SyntaxError;
                },
            }
        }
    }
    return .success;
}

pub fn num_items(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0.ApplyFinalState {
    const sep_set = .{ '.', ')' };
    outer: while (true) {

        // first: the label, we exit this block on cursor being sep +1
        {
            const labelc = p.bounded_findc(sep_set, endat) catch {
                file_report(error.L0NumItem, true, "Not a number before separator", Node.L0Kind.num_dot_item_label);
                return L0SyntaxError;
            };
            //cursor is on sep

            if (!p.bounds_freeof_whitesp(p.cursor - labelc, p.cursor)) {
                file_report(error.L0NumItem, true, "Space in label not allowed", Node.L0Kind.num_dot_item_label);
                return L0SyntaxError;
            }

            // we are still on the sep, e.g. '.'
            const label_kind: Node.L0Kind = switch (p.peek().?) {
                '.' => .num_dot_item_label,
                ')' => .num_paren_item_label,
                else => unreachable, // since we went for `sep_set`
            };

            p.l0nodes.push(.{
                .kind = label_kind,
                .span = .{ p.cursor - labelc, p.cursor },
            }) catch |err| crash(err);

            p.inc();
        }

        // second: the text, and we start with cursor on sep +1
        {
            p.bounded_skip_whitesp(endat) catch {
                file_report(error.L0NumItem, true, "Nothing after separator", Node.L0Kind.num_dot_item_text);
                return L0SyntaxError;
            };

            const text_start = p.cursor;

            while (p.pop()) |c| {
                if (!p.in_bound(endat)) {
                    // last node
                    p.l0nodes.push(.{
                        .kind = .num_dot_item_text,
                        .span = .{ text_start, endat },
                    }) catch |err| crash(err);

                    break :outer;
                }

                if (c != '\n') continue;

                switch (p.peek() orelse {
                    file_report(L0SyntaxError, true, "Nothing after separator", Node.L0Kind.num_dot_item_text);
                    return L0SyntaxError;
                }) {
                    ' ', '\t' => {
                        // through this condition, we allow the next line to be
                        // part of this item, if it starts anyhow indented
                        continue;
                    },
                    '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                        // the next line has a new item, so we end on cursor-1=\n
                        p.l0nodes.push(.{
                            .kind = .num_dot_item_text,
                            .span = .{ text_start, p.cursor - 1 },
                        }) catch |err| crash(err);

                        continue :outer;
                    },
                    else => {
                        // in this case we forbid something like this:
                        // \\\1. this-is-some\n
                        // \\\unindented-text
                        file_report(L0SyntaxError, true, "Unindented line after number item", Node.L0Kind.num_dot_item_text);
                        return L0SyntaxError;
                    },
                }
            }
        }
    }
    return .success;
}

// default rule
pub fn par(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0.ApplyFinalState {
    const offset: usize = if (p.peek() == '\\') 1 else 0; // this is the "force par" char
    p.l0nodes.push(.{ .kind = .paragraph, .span = .{ p.cursor + offset, endat } }) catch |err| crash(err);

    return .success;
}

pub fn nonpar(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0.ApplyFinalState {
    p.l0nodes.push(.{ .kind = .nonparagraph, .span = .{ p.cursor + 1, endat } }) catch |err| crash(err);

    return .success;
}
