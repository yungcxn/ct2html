// metaprogramming helpers...

const std = @import("std");

pub fn force_tup(maybe_tuple: anytype) switch (@typeInfo(@TypeOf(maybe_tuple))) {
    .@"struct" => @TypeOf(maybe_tuple),
    else => @Tuple(&.{@TypeOf(maybe_tuple)}),
} {
    return switch (@typeInfo(@TypeOf(maybe_tuple))) {
        .@"struct" => maybe_tuple,
        else => .{maybe_tuple},
    };
}
