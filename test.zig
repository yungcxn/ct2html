const std = @import("std");
const filex = @import("src/filex.zig");
const main = @import("src/main.zig");
const crash = @import("src/ErrorReporter.zig").crash;
const expectError = std.testing.expectError;

fn test_for_file(filepath: []const u8) main.RunError!void {
    const cwd = filex.open_dir(std.testing.io, null, "test/") catch crash("cwd error");
    defer filex.close_dir(std.testing.io, cwd);

    const in_file = filex.open(std.testing.io, cwd, filepath) catch crash("file open error");

    const text, const opterr = main.run(
        std.heap.smp_allocator,
        std.testing.io,
        cwd,
        in_file,
        false,
        false,
        false,
    );

    if (opterr) |err| {
        std.log.info("{s}", .{text});
        return err;
    }
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

test "more complex css containing test" {
    try test_for_file("5_csstest.ct");
}

test "code block test" {
    try test_for_file("6_code_block.ct");
}
