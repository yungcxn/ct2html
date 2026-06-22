const std = @import("std");
const Node = @import("../element/Node.zig");
const postparse = @import("../actions/postparse.zig");
const PostParser = @import("../PostParser.zig");
const SemanticError = postparse.SemanticError;

pub const RType = enum(c_uint) {
    BlockStart,
    LineStart,
    Inline,
};

nodetrigger: Node.Kind,
func: fn (*PostParser) SemanticError!void, // usize: idx of the node

pub const rules = [_]@This(){
    .{ .nodetrigger = .{ .L0 = .Item }, .func = postparse.unordered_list_wrap },
};
