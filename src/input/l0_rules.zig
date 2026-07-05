// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Parser = @import("Parser.zig");
const Rule = @import("../element/Rule.zig");
const ErrorReporter = @import("../ErrorReporter.zig");

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
            return p.e.file_report(error.L0SyntaxError, true, "Empty attribute key", null);
        };

        const key_start = p.cursor;

        p.bounded_find(':', endat) catch {
            return p.e.file_report(error.L0SyntaxError, true, "Missing colon in attribute", null);
        };

        // cursor is on ':', so we check if the keyname is free of whitespace
        if (!p.bounds_freeof_whitesp(key_start, p.cursor)) {
            return p.e.file_report(error.L0SyntaxError, true, "Space between key and colon not allowed", null);
        }

        const attr_name = p.text[key_start..p.cursor];
        const attr_kind = std.meta.stringToEnum(Node.L0Kind, attr_name) orelse {
            return p.e.file_report(error.L0SyntaxError, true, "Unknown attribute name", null);
        };
        if (!attr_kind.is_attribute()) {
            return p.e.file_report(error.L0SyntaxError, true, "Invalid attribute name", null);
        }

        // cursor is at ':'...
        p.inc();
        // ...now at first char of value

        // advance till value start
        p.bounded_skip_whitesp(endat) catch {
            return p.e.file_report(error.L0SyntaxError, true, "Missing value in attribute", attr_kind);
        };

        const value_start = p.cursor;

        p.bounded_find('\n', endat) catch |err| {
            if (err == Parser.ParsingError.OutOfBounds) {
                // last line, so must accept it
                p.l0nodes.push(.{
                    .kind = attr_kind,
                    .span = .{ value_start, endat },
                    .contains_l1 = false,
                });
                break :line;
            } else {
                return p.e.file_report(error.L0SyntaxError, true, "Missing value in attribute", attr_kind);
            }
        };

        // cursor is on '\n'
        p.l0nodes.push(.{
            .kind = attr_kind,
            .span = .{ value_start, p.cursor },
            .contains_l1 = false,
        });

        p.inc(); // cursor is now on the first char of the next line, which could be '!' for next
    }

    // we check if we even produced anything
    if (p.l0nodes.head == 2) {
        return p.e.file_report(error.L0SyntaxError, true, "Empty attribute section", null);
    }

    return .success;
}

// read #'s
pub fn heading(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0.ApplyFinalState {
    const hashtagc: usize = p.skipc('#') catch {
        return p.e.file_report(error.L0SyntaxError, true, "Nothing after heading hashtags", null);
    };

    const kind: Node.L0Kind = switch (hashtagc) {
        1 => .heading1,
        2 => .heading2,
        3 => .heading3,
        4 => .heading4,
        5 => .heading5,
        6 => .heading6,
        else => {
            return p.e.file_report(error.L0SyntaxError, true, "Too many heading hashtags", null);
        },
    };

    p.bounded_skip_whitesp(endat) catch {
        return p.e.file_report(error.L0SyntaxError, true, "Nothing after heading hashtags", null);
    };

    // cursor is now at the first char of the heading text, and stays there
    if (!p.bounds_freeof(p.cursor, endat, '\n')) {
        return p.e.file_report(error.L0SyntaxError, true, "Newline in heading", kind);
    }

    // cursor is now at the first char of the heading text, and stays there
    if (!p.bounds_freeof(p.cursor, endat, '\n')) {
        return p.e.file_report(error.L0SyntaxError, true, "Newline in heading", kind);
    }

    p.l0nodes.push(.{ .kind = kind, .span = .{ p.cursor, endat } });
    return .success;
}

pub fn dash_items(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0.ApplyFinalState {
    outer: while (true) {
        p.inc(); // skip '-'
        p.bounded_skip_whitesp(endat) catch {
            return p.e.file_report(error.L0SyntaxError, true, "Empty item", Node.L0Kind.dash_item);
        };

        // now we're at the item text begin
        const item_textstart = p.cursor;

        while (p.pop()) |c| {
            if (!p.in_bound(endat)) {
                // last node
                p.l0nodes.push(.{
                    .kind = .dash_item,
                    .span = .{ item_textstart, endat },
                });

                break :outer;
            }

            if (c != '\n') continue;

            switch (p.peek() orelse {
                return p.e.file_report(error.L0SyntaxError, true, "Empty item", Node.L0Kind.dash_item);
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
                    });

                    continue :outer;
                },
                else => {
                    // in this case we forbid something like this:
                    // \\- this-is-some\n
                    // \\unindented-text
                    return p.e.file_report(error.L0SyntaxError, true, "Unindented line after dash item", Node.L0Kind.dash_item);
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
                return p.e.file_report(error.L0SyntaxError, true, "Not a number before separator", Node.L0Kind.num_dot_item_label);
            };
            //cursor is on sep

            if (!p.bounds_freeof_whitesp(p.cursor - labelc, p.cursor)) {
                return p.e.file_report(error.L0SyntaxError, true, "Space in label not allowed", Node.L0Kind.num_dot_item_label);
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
            });

            p.inc();
        }

        // second: the text, and we start with cursor on sep +1
        {
            p.bounded_skip_whitesp(endat) catch {
                return p.e.file_report(error.L0SyntaxError, true, "Nothing after separator", Node.L0Kind.num_dot_item_text);
            };

            const text_start = p.cursor;

            while (p.pop()) |c| {
                if (!p.in_bound(endat)) {
                    // last node
                    p.l0nodes.push(.{
                        .kind = .num_dot_item_text,
                        .span = .{ text_start, endat },
                    });

                    break :outer;
                }

                if (c != '\n') continue;

                switch (p.peek() orelse {
                    return p.e.file_report(error.L0SyntaxError, true, "Nothing after separator", Node.L0Kind.num_dot_item_text);
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
                        });

                        continue :outer;
                    },
                    else => {
                        // in this case we forbid something like this:
                        // \\1. this-is-some\n
                        // \\unindented-text
                        return p.e.file_report(error.L0SyntaxError, true, "Unindented line after number item", Node.L0Kind.num_dot_item_text);
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
    p.l0nodes.push(.{ .kind = .paragraph, .span = .{ p.cursor + offset, endat } });

    return .success;
}

pub fn nonpar(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0.ApplyFinalState {
    p.l0nodes.push(.{ .kind = .nonparagraph, .span = .{ p.cursor + 1, endat } });

    return .success;
}
