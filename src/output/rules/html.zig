const Generator = @import("../Generator.zig");
const MetaNode = @import("../../input/element/MetaNode.zig");
const Node = @import("../../input/element/Node.zig");

pub const r = Generator.Rule.def;
pub const mr = Generator.MetaRule.def;

pub fn metarule_by_kind(k: MetaNode.Kind) !Generator.MetaRule {
    for (metarules) |rule| {
        if (rule.k.eq(k)) return rule;
    }
    return error.NoMetaRuleForKind;
}

pub const metarules = [_]Generator.MetaRule{
    mr(.UnorderedItemListOpen, "<ul>"),
    mr(.UnorderedItemListClose, "</ul>"),
    mr(.OrderedItemListOpen, "<ol>"),
    mr(.OrderedItemListClose, "</ol>"),
};

pub fn rule_by_kind(k: Node.Kind) !Generator.Rule {
    for (rules) |rule| {
        if (rule.k.eq(k)) return rule;
    }
    return error.NoRuleForKind;
}

pub const rules = [_]Generator.Rule{
    r(.l0(.AttributeKey), .xreplace(&attribute_kv)),
    r(.l0(.AttributeValue), .xignore()), // scanned when key

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

    r(.l1(.CommandKey), .xreplace(&command_kv)),
    r(.l1(.CommandValue), .xignore()), // scanned when key

    r(.l1(.InlineCode), .xreplace(&inline_code)),

    r(.l1(.Bold), .xprepost("<strong>", "</strong>")),
    r(.l1(.Italic), .xprepost("<em>", "</em>")),
    r(.l1(.BoldItalic), .xprepost("<strong><em>", "</em></strong>")),

    r(.l1(.Strikethrough), .xprepost("<del>", "</del>")),
    r(.l1(.StrikethroughBold), .xprepost("<del><strong>", "</strong></del>")),
    r(.l1(.StrikethroughItalic), .xprepost("<del><em>", "</em></del>")),
    r(.l1(.StrikethroughBoldItalic), .xprepost("<del><strong><em>", "</em></strong></del>")),
};

fn noop(g: Generator) Generator.Rule.Effect {
    _ = g;
    return .vanish();
}

fn attribute_kv(g: *Generator) []const u8 {
    _ = g; // TODO
}

fn command_kv(g: *Generator) []const u8 {
    _ = g; // TODO
}

fn inline_code(g: *Generator) []const u8 {
    _ = g; // TODO
}
