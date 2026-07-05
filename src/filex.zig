// helpers for current overcomplicated file handling code in zig

const std = @import("std");
const DynBuf = @import("ds/dynbuf.zig").DynBuf;
const crash = @import("ErrorReporter.zig").crash;
const file_report = @import("ErrorReporter.zig").file_report;

const max_file_size = 50 * 1024 * 1024;

pub const FileError = error{
    FileNotFound,
    InvalidFileExtension,
    NotADir,
};

pub fn open_dir(io: std.Io, cwd: ?std.Io.Dir, path: []const u8) FileError!std.Io.Dir {
    if (cwd == null and std.mem.eql(u8, path, ".")) {
        return std.Io.Dir.cwd();
    }

    var dir: std.Io.Dir = undefined;
    if (cwd) |non_default_cwd| {
        dir = non_default_cwd;
    } else {
        dir = std.Io.Dir.cwd();
    }

    return dir.openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return FileError.FileNotFound,
        error.NotDir => return FileError.NotADir,
        else => return crash(err),
    };
}

pub fn open(io: std.Io, cwd: ?std.Io.Dir, path: []const u8) FileError!std.Io.File {
    if (std.mem.eql(u8, path, "stdin")) {
        return std.Io.File.stdin();
    } else if (std.mem.eql(u8, path, "stdout")) {
        return std.Io.File.stdout();
    }

    // this is important for security reasons
    if (!std.mem.endsWith(u8, path, ".ct")) {
        return FileError.InvalidFileExtension;
    }

    var dir = std.Io.Dir.cwd();
    if (cwd) |non_default_cwd| dir = non_default_cwd;

    return dir.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return FileError.FileNotFound,
        else => return crash(err),
    };
}

pub fn close(io: std.Io, file: std.Io.File) void {
    if (file.handle == std.Io.File.stdin().handle or file.handle == std.Io.File.stdout().handle) {
        return;
    }
    file.close(io);
}

pub fn close_dir(io: std.Io, dir: std.Io.Dir) void {
    if (dir.handle == std.Io.Dir.cwd().handle) {
        return;
    }
    dir.close(io);
}

pub fn alloc_stdin_bytes(
    alloc: std.mem.Allocator,
    io: std.Io,
    stdin: std.Io.File,
) []u8 {
    var reader_buf: [4096]u8 = undefined;
    var freader = stdin.reader(io, &reader_buf);
    var dynbuf = DynBuf(u8).init(alloc, 4096);
    errdefer dynbuf.deinit();

    while (true) {
        const n = freader.interface.readSliceShort(&reader_buf) catch |err| crash(err);
        dynbuf.append(reader_buf[0..n]);
        if (n < reader_buf.len) break; // short read = EOF / CTRL-D
    }

    return dynbuf.to_slice();
}

pub fn alloc_file_bytes(
    alloc: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
) []u8 {
    var reader_buf: [4096]u8 = undefined;
    var freader = file.reader(io, &reader_buf);
    const reader: *std.Io.Reader = &freader.interface;
    const result = reader.allocRemaining(
        alloc,
        std.Io.Limit.limited(max_file_size),
    ) catch |err| crash(err);
    return result;
}
