// helpers for current overcomplicated file handling code in zig

const std = @import("std");

pub fn safeopen(io: std.Io, path: []const u8) std.Io.File {
    if (std.mem.eql(u8, path, "stdin")) {
        return std.Io.File.stdin();
    } else if (std.mem.eql(u8, path, "stdout")) {
        return std.Io.File.stdout();
    }

    return std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        std.log.err("Failed to open file {s}: {s}", .{ path, @errorName(err) });
        std.process.exit(1);
    };
}

pub fn close(io: std.Io, file: std.Io.File) void {
    if (file.handle == std.Io.File.stdin().handle or file.handle == std.Io.File.stdout().handle) {
        return;
    }
    file.close(io);
}

pub fn alloc_filetext(
    alloc: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
) ![]u8 {
    var buf: [4096]u8 = undefined;
    var freader = file.reader(io, &buf);

    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(alloc);

    while (true) {
        const n = try freader.interface.readSliceShort(&buf);
        try list.appendSlice(alloc, buf[0..n]);
        if (n < buf.len) break; // short read = EOF / CTRL-D
    }

    return list.toOwnedSlice(alloc);
}
