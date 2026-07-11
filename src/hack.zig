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

// @TypeOf(key_val_table[0]) = struct {
//     @"0": []u8,
//     @"1": V,
// };

pub fn StructByteMap(
    comptime key_val_table: anytype,
) type {
    const V = @TypeOf(key_val_table[0][1]);
    const valuec = key_val_table.len;

    return struct {
        lookup_table: [256]u8, // must be freed afterwards
        values: [valuec]V,

        pub fn init() @This() {
            const values: [valuec]V = comptime blk: {
                var list: [valuec]V = undefined;
                for (key_val_table, 0..) |key_val, i| {
                    list[i] = key_val[1];
                }

                break :blk list;
            };

            const lookup_table: [256]u8 = comptime blk: {
                var table: [256]u8 = @splat(0xFF);
                for (key_val_table, 0..) |key_val, i| {
                    for (key_val[0]) |key| {
                        const int_key = if (@typeInfo(@TypeOf(key)) == .@"enum") @intFromEnum(key) else key;
                        if (int_key == 0xFF) {
                            @compileError("Invalid key value 0xFF for StructByteMap");
                        }
                        table[int_key] = i;
                    }
                }

                break :blk table;
            };

            return .{ .lookup_table = lookup_table, .values = values };
        }

        pub fn lookup(self: @This(), key: u8) ?V {
            const idx = self.lookup_table[key];
            if (idx == 0xFF) return null;
            return self.values[idx];
        }
    };
}
