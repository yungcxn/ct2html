// helpers for current overcomplicated file handling code in zig

const std = @import("std");
const DynBuf = @import("ds/dynbuf.zig").DynBuf;

const max_file_size = 50 * 1024 * 1024;

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

pub fn alloc_stdin_bytes(
    alloc: std.mem.Allocator,
    io: std.Io,
    stdin: std.Io.File,
) ![]u8 {
    var reader_buf: [4096]u8 = undefined;
    var freader = stdin.reader(io, &reader_buf);
    var dynbuf = try DynBuf(u8).init(alloc, 4096);
    errdefer dynbuf.deinit();

    while (true) {
        const n = try freader.interface.readSliceShort(&reader_buf);
        dynbuf.append(reader_buf[0..n]);
        if (n < reader_buf.len) break; // short read = EOF / CTRL-D
    }

    return dynbuf.to_slice();
}

pub fn alloc_file_bytes(
    alloc: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
) ![]u8 {
    var reader_buf: [4096]u8 = undefined;
    var freader = file.reader(io, &reader_buf);
    const reader: *std.Io.Reader = &freader.interface;
    const result = try reader.allocRemaining(alloc, std.Io.Limit.limited(max_file_size));
    return result;
}
