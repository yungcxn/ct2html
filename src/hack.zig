// metaprogramming helpers...

const std = @import("std");

fn max_enum_val(comptime E: type) comptime_int {
    const info = @typeInfo(E).@"enum";
    var max: comptime_int = info.fields[0].value;
    inline for (info.fields) |field| {
        if (field.value > max) max = field.value;
    }
    return max;
}

pub fn force_u8slice(comptime comptime_vald_tup: anytype) []const u8 {
    var toret: []const u8 = &.{};
    for (comptime_vald_tup) |val| {
        toret = toret ++ .{val};
    }
    return toret;
}

pub fn force_tup(maybe_tuple: anytype) switch (@typeInfo(@TypeOf(maybe_tuple))) {
    .@"struct" => @TypeOf(maybe_tuple),
    else => @Tuple(&.{@TypeOf(maybe_tuple)}),
} {
    return switch (@typeInfo(@TypeOf(maybe_tuple))) {
        .@"struct" => maybe_tuple,
        else => .{maybe_tuple},
    };
}
