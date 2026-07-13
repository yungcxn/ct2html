const std = @import("std");
const Generator = @import("../Generator.zig");
const Node = @import("../../element/Node.zig");
const Rule = @import("../../element/Rule.zig");
const CCEngine = @import("../../internal/CCEngine.zig");
const crash = @import("../../ErrorReporter.zig").crash;

inline fn generic_custom(comptime pre: bool, g: *Generator, node: *anyopaque) Generator.GenError!(if (pre) ?@Vector(2, usize) else void) {
    // is either `blk_custom_cmd_arg` or `inl_custom_cmd_arg`
    const realnode: *Node.L0 = @ptrCast(@alignCast(node));
    const span = realnode.span;

    // assume that nonnull is guaranteed here, since `*_custom_cmd_arg` only gets pushed with that
    const cmd_id, const arg_id = realnode.custom_command_id_arg.?;
    const cmd_info = g.custom_cmd_engine.get_custom_cmd_by_id(cmd_id) orelse {
        crash("Logic error: custom command ID not found.");
    };

    if (pre) {
        g.print(g.textin[cmd_info.pre_spans[arg_id][0]..cmd_info.pre_spans[arg_id][1]]);
    } else {
        g.print(g.textin[cmd_info.post_spans[arg_id][0]..cmd_info.post_spans[arg_id][1]]);
    }

    if (comptime pre) {
        return span.?;
    } else {
        return;
    }
}

pub fn custom_pre(
    g: *Generator,
    node: *anyopaque,
) Generator.GenError!?@Vector(2, usize) {
    return generic_custom(true, g, node);
}

pub fn custom_post(
    g: *Generator,
    node: *anyopaque,
) Generator.GenError!void {
    return generic_custom(false, g, node);
}
