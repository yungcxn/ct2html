const std = @import("std");
const argx = @import("src/argx.zig");
const main = @import("src/main.zig");
const expectError = std.testing.expectError;

fn test_for_file(filepath: []const u8) main.RunError!void {
    std.debug.print("Testing file: {s}\n", .{filepath});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arenalloc = arena.allocator();

    const argslice: []const []const u8 = &.{ "ct2html", "-i", filepath, "-c", "test" };
    const args = argx.parse(@import("src/main.zig").argdef, argslice);

    try main.run(arenalloc, std.testing.io, args);
}

test "normal file" {
    try test_for_file("0_correct.ct");
}

test "circular import" {
    try expectError(
        main.RunError.ImportCycle,
        test_for_file("1_import_cycle.ct"),
    );
}

test "not found import" {
    try expectError(
        main.RunError.FileNotFound,
        test_for_file("2_not_found.ct"),
    );
}

test "not a .ct file" {
    try expectError(
        main.RunError.InvalidFileExtension,
        test_for_file("3_import_not_ct.ct"),
    );
}

test "chain importing with a dead end" {
    try expectError(
        main.RunError.FileNotFound,
        test_for_file("4_chain_import_not_found.ct"),
    );
}
