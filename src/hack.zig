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

pub fn from_enum_literal(comptime EnumType: type, el: @EnumLiteral()) ?EnumType {
    comptime {
        @setEvalBranchQuota(10_000);
    }

    inline for (std.meta.fields(EnumType)) |f| {
        if (std.mem.eql(u8, @tagName(el), f.name)) {
            return @enumFromInt(f.value);
        }
    }
    return null;
}
