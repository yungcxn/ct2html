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

pub fn TypedDesigInitType(
    comptime IndexType: type,
    comptime ValueType: type,
    comptime pair_array: anytype,
) type {
    // const RealisedValueType = switch (@typeInfo(ValueType)) {
    //     .int, .comptime_int, .float, .comptime_float, .optional, .@"fn" => ValueType,
    //     .pointer, .array, .@"struct", .@"enum", .@"union", .vector => ?ValueType,
    //     else => @compileError("Unsupported value type " ++ @typeName(ValueType)),
    // };

    const IndexIntType: type = switch (@typeInfo(IndexType)) {
        .@"enum" => |e| e.tag_type,
        else => IndexType,
    };
    var max: IndexIntType = 0;
    inline for (pair_array) |pair| {
        const idx, _ = pair;
        const int_idx: IndexIntType = switch (@typeInfo(@TypeOf(idx))) {
            .enum_literal => @intFromEnum(@as(IndexType, idx)),
            else => idx,
        };
        max = @max(int_idx, max);
    }
    return [max + 1]ValueType;
}

pub fn typed_desig_init(
    comptime IndexType: type,
    comptime ValueType: type,
    comptime def_value: anytype, // could be a noop func
    comptime pair_array: anytype,
) TypedDesigInitType(IndexType, ValueType, pair_array) {
    const ArrType = TypedDesigInitType(IndexType, ValueType, pair_array);

    var arr: ArrType = undefined;
    for (&arr) |*x| {
        x.* = def_value;
    }

    const IndexIntType: type = switch (@typeInfo(IndexType)) {
        .@"enum" => |e| e.tag_type,
        else => IndexType,
    };

    for (pair_array) |pair| {
        const idx, const val = pair;

        const int_idx: IndexIntType = switch (@typeInfo(@TypeOf(idx))) {
            .enum_literal => @intFromEnum(@as(IndexType, idx)),
            else => idx,
        };

        arr[int_idx] = val;
    }
    return arr;
}

test "desig init" {
    const my_arr = comptime typed_desig_init(u8, []const u8, "", .{
        .{ 0, "hi" },
        .{ 2, "hey" },
    });

    try std.testing.expectEqual(my_arr[0], "hi");
    try std.testing.expectEqual(my_arr[1], "");
    try std.testing.expectEqual(my_arr[2], "hey");
    try std.testing.expectEqual(my_arr.len, 3);

    const OpCode = enum(u8) {
        Add = 0b01,
        Sub = 0b10,
    };

    const vtable = comptime typed_desig_init(OpCode, fn (usize, usize) usize, struct {
        pub fn noop(_: usize, _: usize) usize {
            return 0;
        }
    }.noop, .{
        .{ .Add, struct {
            pub fn f(a: usize, b: usize) usize {
                return a + b;
            }
        }.f },
        .{ .Sub, struct {
            pub fn f(a: usize, b: usize) usize {
                return a - b;
            }
        }.f },
    });

    try std.testing.expectEqual(vtable[@intFromEnum(OpCode.Add)](5, 4), 9);
    try std.testing.expectEqual(vtable[@intFromEnum(OpCode.Sub)](5, 4), 1);
}
