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
    const IndexIntType: type = switch (@typeInfo(IndexType)) {
        .@"enum" => |e| e.tag_type,
        else => IndexType,
    };
    var max: IndexIntType = 0;
    inline for (pair_array) |pair| {
        const idx, _ = pair;
        const int_idx: IndexIntType = switch (@typeInfo(@TypeOf(idx))) {
            .@"enum" => @intFromEnum(idx),
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
            .@"enum" => @intFromEnum(idx),
            .enum_literal => @intFromEnum(@as(IndexType, idx)),
            else => idx,
        };

        arr[int_idx] = val;
    }
    return arr;
}

test "typed desig init" {
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

// now without type hinting

pub fn DesigInitType(
    comptime pair_array: anytype,
) type {
    const IndexType: type = switch (@typeInfo(@TypeOf(pair_array[0][0]))) {
        .int, .comptime_int, .@"enum" => @TypeOf(pair_array[0][0]),
        .enum_literal => @compileError("Cannot induce type from just enum literal for first pair."),
        else => @compileError("No index through your provided type possible."),
    };

    var ValueType = @TypeOf(pair_array[0][1]);

    // strings need to be handled differently. "..." defaults to @TypeOf("..") = *const [n:0]u8
    //   but if we would need to force n here, `typed_desig_init` should be used. For flexibility,
    //   we need to default the type to a const slice, and the compiler will cast "..." of different
    //   sizes just fine.
    const value_type_info = @typeInfo(ValueType);
    if (value_type_info == .pointer) {
        const ptr_info = value_type_info.pointer;
        const ptr_child_info = @typeInfo(ptr_info.child);
        if (ptr_child_info == .array and ptr_child_info.array.child == u8 and ptr_child_info.array.sentinel() != null and ptr_child_info.array.sentinel() == 0) {
            ValueType = []const u8;
        }
    }

    return TypedDesigInitType(IndexType, ValueType, pair_array);
}

pub fn desig_init(
    comptime def_value: anytype, // could be a noop func
    comptime pair_array: anytype,
) DesigInitType(pair_array) {
    const ArrType = DesigInitType(pair_array);

    var arr: ArrType = undefined;
    for (&arr) |*x| {
        x.* = def_value;
    }

    for (pair_array) |pair| {
        const idx, const val = pair;

        const int_idx = switch (@typeInfo(@TypeOf(idx))) {
            .@"enum" => @intFromEnum(idx),
            // through `DesigInitType` we asserted that `pair_array[0][0]` is an enum val
            .enum_literal => @intFromEnum(@as(@TypeOf(pair_array[0][0]), idx)),
            else => idx,
        };

        arr[int_idx] = val;
    }

    return arr;
}

test "desig init" {
    const my_arr = comptime desig_init("", .{
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

    const vtable = comptime desig_init(struct {
        pub fn noop(_: usize, _: usize) usize {
            return 0;
        }
    }.noop, .{
        .{ OpCode.Add, struct {
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

pub fn AutoDesigInitType(comptime pair_array: anytype) type {
    const IndexIntType = @TypeOf(pair_array[0][0]);

    switch (@typeInfo(IndexIntType)) {
        .int, .comptime_int => {},
        else => @compileError("Use `typed_desig_init`, since untyped only supports numeric indices"),
    }

    var ValueType = @TypeOf(pair_array[0][1]);
    const value_type_info = @typeInfo(ValueType);
    if (value_type_info == .pointer) {
        const ptr_info = value_type_info.pointer;
        const ptr_child_info = @typeInfo(ptr_info.child);
        if (ptr_child_info == .array and ptr_child_info.array.child == u8 and ptr_child_info.array.sentinel() != null and ptr_child_info.array.sentinel() == 0) {
            ValueType = []const u8;
        }
    }

    const RealisedValueType = switch (@typeInfo(ValueType)) {
        .int, .comptime_int, .float, .comptime_float, .optional, .@"fn" => ValueType,
        // this opt wrapping for non trivial types is working better than `std.mem.zeroes`, due to
        // standard string literals as slices not being correctly set. they would be left undefined.
        .pointer, .array, .@"struct", .@"enum", .@"union", .vector => ?ValueType,
        else => @compileError("Unsupported value type " ++ @typeName(ValueType)),
    };

    return TypedDesigInitType(IndexIntType, RealisedValueType, pair_array);
}

// also one without a def value. We are forced to provide a default valued func for function tables
pub fn auto_desig_init(
    comptime pair_array: anytype,
) AutoDesigInitType(pair_array) {
    // this is either optional, and int, a float, or a func
    const ArrValueType = @typeInfo(AutoDesigInitType(pair_array)).array.child;

    // since we can not currently construct our own noop func:
    if (@typeInfo(@TypeOf(ArrValueType)) == .@"fn") {
        @compileError("For function-valued designated init, use `desig_init` with default val.");
    }

    return desig_init(switch (@typeInfo(ArrValueType)) {
        .int, .comptime_int, .float, .comptime_float => @as(ArrValueType, 0),
        .optional => null,
        else => @compileError("Some type assertion on `ArrValueType` failed, it's " ++ @typeName(ArrValueType)),
    }, pair_array);
}

test "auto desig init" {
    const my_arr = comptime auto_desig_init(.{
        .{ 0, "hi" },
        .{ 2, "hey" },
    });

    try std.testing.expectEqual(my_arr[0].?, "hi");
    try std.testing.expectEqual(my_arr[1], null);
    try std.testing.expectEqual(my_arr[2].?, "hey");
    try std.testing.expectEqual(my_arr.len, 3);
}
