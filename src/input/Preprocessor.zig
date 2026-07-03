const std = @import("std");
const filex = @import("../filex.zig");

// @import("file") as long as there's no \ before @
// if \, then command parsing skips it regardless, not adjustment needed

pub fn walk_and_merge(
    arenalloc: std.mem.Allocator,
    io: std.Io,
    in_file: std.Io.File,
) ![]const u8 {
    // TODO!
    return filex.alloc_filetext(arenalloc, io, in_file);
}
