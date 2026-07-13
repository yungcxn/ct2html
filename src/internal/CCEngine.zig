const std = @import("std");
const DynBuf = @import("../ds/dynbuf.zig").DynBuf;
const Node = @import("../element/Node.zig");
const Rule = @import("../element/Rule.zig");
const Parser = @import("../input/Parser.zig");
const L0SyntaxError = Parser.ParsingError.L0SyntaxError;
const ErrorReporter = @import("../ErrorReporter.zig");
const crash = ErrorReporter.crash;
const par = @import("../input/l0_rules.zig").par;

pub const CustomCommandInfo = struct {
    is_l0: bool,
    id: usize,
    lit_span: @Vector(2, usize),
    argc: usize,
    pre_spans: []@Vector(2, usize), // for each arg, vector is text span
    post_spans: []@Vector(2, usize), // for each arg

    pub fn init(
        alloc: std.mem.Allocator,
        is_l0: bool,
        id: usize,
        lit_span: @Vector(2, usize),
        argc: usize,
    ) CustomCommandInfo {
        return CustomCommandInfo{
            .is_l0 = is_l0,
            .id = id,
            .lit_span = lit_span,
            .argc = argc,
            .pre_spans = alloc.alloc(@Vector(2, usize), argc) catch crash(error.OOM),
            .post_spans = alloc.alloc(@Vector(2, usize), argc) catch crash(error.OOM),
        };
    }

    // we do not need to store an additional alloc pointer for many of `@This()`
    pub fn deinit(self: *CustomCommandInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.pre_spans);
        alloc.free(self.post_spans);
    }
};

// custom commands through attributes, should be for l1 and l0
// since we parsing attributes is the first optional step during parsing, we
//   can generate custom commands for l0 and l1.
// because standard commands also may be complex (through running functions),
//   they get treated differently and are being handled in the `Generator`
//
// and the idx corresponds to the COMMAND-ID (important to grasp their generation)
alloc: std.mem.Allocator,
custom_cmd_table: DynBuf(CustomCommandInfo),

e: *ErrorReporter,
text: []const u8, // preprocessed text to read spans from code defs

pub fn init(alloc: std.mem.Allocator, e: *ErrorReporter, text: []const u8) @This() {
    return @This(){
        .custom_cmd_table = .init(alloc, 10),
        .alloc = alloc,
        .e = e,
        .text = text,
    };
}

pub fn deinit(self: *@This()) void {
    for (self.custom_cmd_table.slice_view()) |*cmd| {
        cmd.deinit(self.alloc);
    }
    self.custom_cmd_table.deinit();
}

pub fn new_custom_command(
    self: *@This(),
    alloc: std.mem.Allocator,
    is_l0: bool,
    lit_span: @Vector(2, usize),
    argc: usize,
) usize { // returns the command id, which gets inserted into the node
    const idx = self.custom_cmd_table.head;
    const cmdinfo = CustomCommandInfo.init(alloc, is_l0, idx, lit_span, argc);
    self.custom_cmd_table.push(cmdinfo);
    return idx;
}

// abuse that `CustomCommandInfo.id` is array idx
pub fn get_custom_cmd_by_id(self: *@This(), id: usize) ?*CustomCommandInfo {
    if (id >= self.custom_cmd_table.head) return null;
    return &self.custom_cmd_table.slice_view()[id];
}

// because of this function, we need `id` encoded in `CustomCommandInfo`
pub fn get_custom_cmd_by_literal(
    self: *@This(),
    is_l0: bool,
    lit_span: @Vector(2, usize),
) ?*CustomCommandInfo {
    const needle = self.text[lit_span[0]..lit_span[1]];
    for (self.custom_cmd_table.slice_view()) |*cmd| {
        if (cmd.is_l0 != is_l0) continue;
        const hay = self.text[cmd.lit_span[0]..cmd.lit_span[1]];
        if (std.mem.eql(u8, hay, needle)) {
            return cmd;
        }
    }
    return null;
}

pub fn alloc_debug_cmd_list(self: *@This(), print_l0s: bool) []const u8 {
    var outbuf = DynBuf(u8).init(self.alloc, 100);
    defer outbuf.deinit();

    var numbuf: [32]u8 = undefined;

    for (self.custom_cmd_table.slice_view()) |*cmd| {
        if (cmd.is_l0 != print_l0s) continue;

        const lit = self.text[cmd.lit_span[0]..cmd.lit_span[1]];

        outbuf.append(lit);
        outbuf.append(" (");
        outbuf.append(if (cmd.is_l0) "l0" else "l1");
        outbuf.append(", argc=");
        outbuf.append(std.fmt.bufPrint(&numbuf, "{d}", .{cmd.argc}) catch crash(error.OOM));
        outbuf.append("), ");
    }

    return outbuf.to_owned_slice();
}

// this function is used in `Attributor.call_hooks` and inserted by `Generator` that holds both.
pub fn new_cmd_def_from_attr(self: *@This(), node: Node.L0) Parser.ParsingError!void {
    // node can be any node as this is a hook func
    if (node.kind == .blkdef or node.kind == .inldef) {
        const is_l0 = node.kind == .blkdef;

        // the nodes content is of the form: <cmdlit>,<pre0>,<post0>,<pre1>,<post1>,...,<preN>,<postN>
        // commas get escaped, so the "pre" and "post" strings need to be escaped
        const cmd_def_span = node.span orelse crash("custom command definition node has no span");
        const cmd_def_text = self.text[cmd_def_span[0]..cmd_def_span[1]];

        var def_cursor: usize = 0;
        // run for literal span
        var last_c: u8 = 0;
        while (def_cursor < cmd_def_text.len) : (def_cursor += 1) {
            const c = cmd_def_text[def_cursor];

            if (c == ',' and last_c != '\\') {
                break;
            }

            last_c = c;
        }
        const comma0: usize = def_cursor;
        const lit_span = @Vector(2, usize){ cmd_def_span[0], cmd_def_span[0] + comma0 };

        // run ones through to count overall unescaped commas for argc
        last_c = 0;
        var prepost_commac: usize = 0;
        while (def_cursor < cmd_def_text.len) : (def_cursor += 1) {
            const c = cmd_def_text[def_cursor];
            if (c == ',' and last_c != '\\') prepost_commac += 1;
            last_c = c;
        }
        const argc = prepost_commac / 2;
        def_cursor = comma0 + 1;

        if (prepost_commac % 2 != 0) {
            return self.e.file_report(
                Parser.ParsingError.CustomCommandDefSyntaxError,
                true,
                "Invalid custom command definition, odd number of commas",
                null,
            );
        }

        const new_cmd_id: usize = self.new_custom_command(self.alloc, is_l0, lit_span, argc);

        // cursor was reset to start of <pre0>
        for (0..prepost_commac) |i| {
            const prepost_start = def_cursor;
            last_c = 0;
            while (def_cursor < cmd_def_text.len) : (def_cursor += 1) {
                const c = cmd_def_text[def_cursor];
                if (c == ',' and last_c != '\\') break;
                last_c = c;
            }
            const prepost_end = def_cursor;

            const prepost_span = @Vector(2, usize){
                cmd_def_span[0] + prepost_start,
                cmd_def_span[0] + prepost_end,
            };

            if (i % 2 == 0) {
                self.get_custom_cmd_by_id(new_cmd_id).?.pre_spans[i / 2] = prepost_span;
            } else {
                self.get_custom_cmd_by_id(new_cmd_id).?.post_spans[i / 2] = prepost_span;
            }

            def_cursor += 1; // skip the comma
        }
    }
}
