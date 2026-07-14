// here, the helper funcs for the `Parser` are defined

const std = @import("std");
const Node = @import("../element/Node.zig");
const Parser = @import("Parser.zig");
const Rule = @import("../element/Rule.zig");
const ErrorReporter = @import("../ErrorReporter.zig");
const hack = @import("../hack.zig");
const allcmd_rules = @import("special/allcmd_rules.zig");

const L0SyntaxError = Parser.ParsingError.L0SyntaxError;
const file_report = @import("../ErrorReporter.zig").file_report;
const crash = @import("../ErrorReporter.zig").crash;

pub const datatable = hack.StructByteMap(.{
    .{ .{0}, Rule.L0Def.def(&par, null, null, false) },
    .{ .{'\\'}, Rule.L0Def.def(&par, null, null, false) },
    .{ .{'?'}, Rule.L0Def.def(&nonpar, null, null, false) },
    .{ .{'#'}, Rule.L0Def.def(&heading, null, null, false) },
    .{ .{'`'}, Rule.L0Def.def(&code_block, null, null, true) },
    .{ .{'>'}, Rule.L0Def.def(&block_quote, null, null, false) },
    .{ .{'-'}, Rule.L0Def.def(&dash_items, .unordered_list_begin, .unordered_list_end, false) },

    .{ .{
        '1',
        '2',
        '3',
        '4',
        '5',
        '6',
        '7',
        '8',
        '9',
    }, Rule.L0Def.def(&num_items, .ordered_list_begin, .ordered_list_end, false) },

    .{ .{'@'}, Rule.L0Def.def(&allcmd_rules.l0_parse_block_command, null, null, false) },

    // this is special: head_anchor gets released, but attributes not. then later at generation,
    //   throught the attribute handler, some get written into it
    .{ .{'!'}, Rule.L0Def.def(&attributes, .head_anchor, null, false) },
}).init();

fn attributes(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0Def.ApplyFinalState {
    // we assume we are on '!'
    line: while (p.pop() == '!') {
        p.bounded_skip_whitesp(endat) catch {
            return p.e.file_report(L0SyntaxError, true, "Empty attribute key", null);
        };

        const key_start = p.cursor;

        p.bounded_find(':', endat) catch {
            return p.e.file_report(L0SyntaxError, true, "Missing colon in attribute", null);
        };

        // cursor is on ':', so we check if the keyname is free of whitespace
        if (!p.bounds_freeof_whitesp(key_start, p.cursor)) {
            return p.e.file_report(L0SyntaxError, true, "Space between key and colon not allowed", null);
        }

        const attr_name = p.text[key_start..p.cursor];
        const attr_kind = std.meta.stringToEnum(Node.L0Kind, attr_name) orelse {
            return p.e.file_report(L0SyntaxError, true, "Unknown attribute name", null);
        };

        // cursor is at ':'...
        p.inc();
        // ...now at first char of value

        // advance till value start
        p.bounded_skip_whitesp(endat) catch {
            return p.e.file_report(L0SyntaxError, true, "Missing value in attribute", attr_kind);
        };

        const value_start = p.cursor;

        p.bounded_find('\n', endat) catch |err| {
            if (err == Parser.ParsingError.OutOfBounds) {
                // last line, so must accept it
                try p.attributor.push(.{
                    .kind = attr_kind,
                    .span = .{ value_start, endat },
                    .l1_containable = false,
                });
                break :line;
            } else {
                return p.e.file_report(L0SyntaxError, true, "Missing value in attribute", attr_kind);
            }
        };

        // cursor is on '\n'
        try p.attributor.push(.{
            .kind = attr_kind,
            .span = .{ value_start, p.cursor },
            .l1_containable = false,
        });

        p.inc(); // cursor is now on the first char of the next line, which could be '!' for next
    }

    return .success;
}

// read #'s
fn heading(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0Def.ApplyFinalState {
    const hashtagc: usize = p.skipc('#') catch {
        return p.e.file_report(L0SyntaxError, true, "Nothing after heading hashtags", null);
    };

    const kind: Node.L0Kind = switch (hashtagc) {
        1 => .heading1,
        2 => .heading2,
        3 => .heading3,
        4 => .heading4,
        5 => .heading5,
        6 => .heading6,
        else => {
            return p.e.file_report(L0SyntaxError, true, "Too many heading hashtags", null);
        },
    };

    p.bounded_skip_whitesp(endat) catch {
        return p.e.file_report(L0SyntaxError, true, "Nothing after heading hashtags", null);
    };

    // cursor is now at the first char of the heading text, and stays there
    if (!p.bounds_freeof(p.cursor, endat, '\n')) {
        return p.e.file_report(L0SyntaxError, true, "Newline in heading", kind);
    }

    // cursor is now at the first char of the heading text, and stays there
    if (!p.bounds_freeof(p.cursor, endat, '\n')) {
        return p.e.file_report(L0SyntaxError, true, "Newline in heading", kind);
    }

    p.l0nodes.push(.{ .kind = kind, .span = .{ p.cursor, endat }, .l1_containable = false });
    return .success;
}

// since having inline code at the start of a par block is not uncommon,
//   we just pass to a par. if we only have a single backtick and could look
//   for the l1 inline code in the next parser stage.
// we also need to advance past endat, since `code_block` is multi block
fn code_block(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0Def.ApplyFinalState {
    const at_start = p.cursor;
    // cursor is assumed to be on the first backtick, begin counting
    const backtick0_c = p.skipc('`') catch {
        return p.e.file_report(L0SyntaxError, true, "Nothing after first batch of backticks", null);
    };

    if (backtick0_c == 1) { // the fallback that was mentioned above
        p.cursor = at_start;
        _ = par(p, endat) catch |err| return err;
        return .transitioned;
    } else if (backtick0_c != 3) {
        return p.e.file_report(L0SyntaxError, true, "Code block must start with 3 backticks", null);
    }

    const code_block0_at = p.cursor; // cursor is now on the first char after the 3 backticks
    p.find('\n') catch {
        return p.e.file_report(L0SyntaxError, true, "Missing newline after code block meta line", null);
    };

    const code_block_meta_span: @Vector(2, usize) = .{ code_block0_at, p.cursor };

    p.inc(); // skip the newline char

    var code_blockc: usize = 0;
    while (true) {
        code_blockc += p.findc('`') catch {
            return p.e.file_report(L0SyntaxError, true, "Missing closing backticks for code block", null);
        };
        if (p.text[p.cursor - 1] == '\\') {
            code_blockc += 1;
            p.inc();
            continue;
        } else {
            break;
        }
    }

    const code_block_span: @Vector(2, usize) = .{ p.cursor - code_blockc, p.cursor };

    // cursor at first of closing backticks, count them until endat
    var backtick1_c: usize = 0;
    while (p.peek()) |c| {
        if (c == '`') {
            backtick1_c += 1;
        } else {
            break;
        }
        p.inc();
    }

    // there could be still text after the closing batch of backticks

    if (backtick1_c != 3) {
        return p.e.file_report(L0SyntaxError, true, "Code block must end with 3 backticks", null);
    }
    // cursor is on first char after the 3 last backticks, could be only
    // whitespace... skip inline-whitespace until newline or global file endat
    var c_last: u8 = 0;
    var header_start: usize = 0;
    while (p.peek()) |c| : (p.inc()) {
        if (c == '\n' and c_last == '\n') {
            if (header_start != 0) {
                p.l0nodes.push(.{
                    .kind = .code_block_header,
                    .span = .{ header_start, p.cursor - 1 },
                    .l1_containable = true,
                });
            }
            p.inc();
            break;
        } else if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            c_last = c;
            continue;
        } else {
            if (header_start == 0) header_start = p.cursor;
        }
        c_last = c;
    }

    p.l0nodes.push(.{
        .kind = .code_block_meta,
        .span = code_block_meta_span,
        .l1_containable = false,
    });

    p.l0nodes.push(.{
        .kind = .code_block,
        .span = code_block_span,
        .l1_containable = false,
    });

    return .success;
}

fn dash_items(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0Def.ApplyFinalState {
    outer: while (true) {
        p.inc(); // skip '-'
        p.bounded_skip_whitesp(endat) catch {
            return p.e.file_report(L0SyntaxError, true, "Empty item", Node.L0Kind.dash_item);
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
                return p.e.file_report(L0SyntaxError, true, "Empty item", Node.L0Kind.dash_item);
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
                    return p.e.file_report(L0SyntaxError, true, "Unindented line after dash item", Node.L0Kind.dash_item);
                },
            }
        }
    }
    return .success;
}

fn num_items(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0Def.ApplyFinalState {
    const sep_set = .{ '.', ')' };
    outer: while (true) {

        // first: the label, we exit this block on cursor being sep +1
        {
            const labelc = p.bounded_findc(sep_set, endat) catch {
                return p.e.file_report(L0SyntaxError, true, "Not a number before separator", Node.L0Kind.num_dot_item_label);
            };
            //cursor is on sep

            if (!p.bounds_freeof_whitesp(p.cursor - labelc, p.cursor)) {
                return p.e.file_report(L0SyntaxError, true, "Space in label not allowed", Node.L0Kind.num_dot_item_label);
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
                return p.e.file_report(L0SyntaxError, true, "Nothing after separator", Node.L0Kind.num_dot_item_text);
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
                    return p.e.file_report(L0SyntaxError, true, "Nothing after separator", Node.L0Kind.num_dot_item_text);
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
                        return p.e.file_report(L0SyntaxError, true, "Unindented line after number item", Node.L0Kind.num_dot_item_text);
                    },
                }
            }
        }
    }
    return .success;
}

fn block_quote(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0Def.ApplyFinalState {
    const quotec = p.skipc('>') catch {
        return p.e.file_report(L0SyntaxError, true, "Nothing after block quote", Node.L0Kind.quote_block);
    };

    const kind: Node.L0Kind = switch (quotec) {
        1 => .quote_block,
        2 => .bold_quote_block,
        3 => .italic_quote_block,
        4 => .bold_italic_quote_block,
        else => {
            return p.e.file_report(L0SyntaxError, true, "Too many block quote chars", Node.L0Kind.quote_block);
        },
    };

    p.l0nodes.push(.{ .kind = kind, .span = .{ p.cursor, endat } });
    return .success;
}

// default rule
pub fn par(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0Def.ApplyFinalState {
    const offset: usize = if (p.peek() == '\\') 1 else 0; // this is the "force par" char
    p.l0nodes.push(.{ .kind = .paragraph, .span = .{ p.cursor + offset, endat } });

    return .success;
}

fn nonpar(p: *Parser, endat: usize) Parser.ParsingError!Rule.L0Def.ApplyFinalState {
    p.l0nodes.push(.{ .kind = .nonparagraph, .span = .{ p.cursor + 1, endat }, .l1_containable = true });

    return .success;
}
