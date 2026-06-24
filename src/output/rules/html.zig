const std = @import("std");
const Generator = @import("../Generator.zig");
const MetaNode = @import("../../input/element/MetaNode.zig");
const Node = @import("../../input/element/Node.zig");

pub const Error = error{};
const GeneratorError = Generator.Error;

pub const r = Generator.Rule.def;
pub const mr = Generator.MetaRule.def;

pub const metarules = [_]Generator.MetaRule{
    mr(.UnorderedItemListOpen, "<ul>"),
    mr(.UnorderedItemListClose, "</ul>"),
    mr(.OrderedItemListOpen, "<ol>"),
    mr(.OrderedItemListClose, "</ol>"),
    mr(.HeadOpen, "<head>"),
    mr(.HeadClose, "</head>"),
    mr(.BodyOpen, "<body>"),
    mr(.BodyClose, "</body>"),
    mr(.FigureOpen, "<figure>"),
    mr(.FigureClose, "</figure>"),
};

pub const rules = [_]Generator.Rule{
    r(.l0(.AttributeStyle), .xprepost("<link rel=\"stylesheet\" href=\"", "\">")),
    r(.l0(.AttributeHeader), .xprepost("<title>", "</title>")),

    r(.l0(.Heading1), .xprepost("<h1>", "</h1>")),
    r(.l0(.Heading2), .xprepost("<h2>", "</h2>")),
    r(.l0(.Heading3), .xprepost("<h3>", "</h3>")),
    r(.l0(.Heading4), .xprepost("<h4>", "</h4>")),
    r(.l0(.Heading5), .xprepost("<h5>", "</h5>")),
    r(.l0(.Heading6), .xprepost("<h6>", "</h6>")),

    r(.l0(.Paragraph), .xprepost("<p>", "</p>")),

    r(.l0(.DashItem), .xprepost("<li>", "</li>")),
    r(.l0(.DashItemSentinel), .xignore()),

    r(.l0(.NumDotItemLabel), .xprepost("<li value=\"", "\">")),
    r(.l0(.NumDotItemText), .xprepost("", "</li>")), // scanned when label
    r(.l0(.NumDotItemSentinel), .xignore()),

    r(.l0(.NumParenItemLabel), .xprepost("<li value=\"", "\">")),
    r(.l0(.NumParenItemText), .xprepost("", "</li>")), // scanned when label
    r(.l0(.NumParenItemSentinel), .xignore()),

    r(.l0(.AlphDotItemLabel), .xprepost("<li value=\"", "\">")),
    r(.l0(.AlphDotItemText), .xprepost("", "</li>")), // scanned when label
    r(.l0(.AlphDotItemSentinel), .xignore()),

    r(.l0(.AlphParenItemLabel), .xprepost("<li value=\"", "\">")),
    r(.l0(.AlphParenItemText), .xprepost("", "</li>")), // scanned when label
    r(.l0(.AlphParenItemSentinel), .xignore()),
    r(.l1(.CommandLink), .xreplace(&command_link)), // since we have two fields, link and text
    r(.l1(.CommandImage), .xprepost("<img src=\"", "\">")),
    r(.l1(.CommandFigCaption), .xprepost("<figcaption>", "</figcaption>")),

    r(.l1(.InlineCode), .xprepost("<code>", "</code>")),

    r(.l1(.Bold), .xprepost("<strong>", "</strong>")),
    r(.l1(.Italic), .xprepost("<em>", "</em>")),
    r(.l1(.BoldItalic), .xprepost("<strong><em>", "</em></strong>")),

    r(.l1(.Strikethrough), .xprepost("<del>", "</del>")),
    r(.l1(.StrikethroughBold), .xprepost("<del><strong>", "</strong></del>")),
    r(.l1(.StrikethroughItalic), .xprepost("<del><em>", "</em></del>")),
    r(.l1(.StrikethroughBoldItalic), .xprepost("<del><strong><em>", "</em></strong></del>")),
};

pub const l1_margins = std.EnumMap(Node.KindLevel1, .{ usize, usize }).init(.{
    .CommandLink = .{ "@link(".len, ")".len },

    .InlineCode = .{ 1, 1 },

    .Bold = .{ 1, 1 },
    .Italic = .{ 2, 2 },
    .BoldItalic = .{ 3, 3 },

    .Strikethrough = .{ 1, 1 },
    .StrikethroughBold = .{ 2, 2 },
    .StrikethroughItalic = .{ 3, 3 },
    .StrikethroughBoldItalic = .{ 4, 4 },
});

pub fn metarule_by_kind(k: MetaNode.Kind) !Generator.MetaRule {
    for (metarules) |rule| {
        if (rule.k.eq(k)) return rule;
    }
    return error.NoMetaRuleForKind;
}

pub fn rule_by_kind(k: Node.Kind) !Generator.Rule {
    for (rules) |rule| {
        if (rule.k.eq(k)) return rule;
    }
    return error.NoRuleForKind;
}

fn command_link(g: *Generator) GeneratorError![]const u8 {
    // CommandLink contains of text with some , in it, try to find it
    const node = g.peek_node() orelse return GeneratorError.L0NodeNotFound;
    const text = g.textin[node.textstart..node.textend];
    if (std.mem.find(u8, text, &.{','})) |comma_index| {
        const link = text[0..comma_index];
        const link_text = text[comma_index + 1 ..];
        return std.fmt.allocPrint(
            g.arenalloc,
            "<a href=\"{s}\">{s}</a>",
            .{ link, link_text },
        ) catch return GeneratorError.OOM;
    } else {
        // only link
        return g.textin[node.textstart..node.textend];
    }
}
