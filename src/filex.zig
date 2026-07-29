// helpers for current overcomplicated file handling code in zig

const std = @import("std");
const DynBuf = @import("ds/dynbuf.zig").DynBuf;
const crash = @import("ErrorReporter.zig").crash;
const file_report = @import("ErrorReporter.zig").file_report;

const max_file_size = 50 * 1024 * 1024;
const max_path_len = 500;

pub const FileError = error{
    FileNotFound,
    NotADir,
};

// Note on `Cache`: when imported files get changed, they do not get recognized until root-file changes
pub const Cache = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    cache_dir: std.Io.Dir,
    abscwd_path: []const u8,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, cache_dir: std.Io.Dir, abscwd_path: []const u8) @This() {
        return @This(){
            .alloc = alloc,
            .io = io,
            .cache_dir = cache_dir,
            .abscwd_path = abscwd_path,
        };
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }

    pub fn try_owned_cacheload(
        self: *@This(),
        file: std.Io.File,
        realpath: []const u8,
    ) ?*DynBuf(u8) {
        const abspathbuf = std.fs.path.join(self.alloc, &.{ self.abscwd_path, realpath }) catch |e| crash(e);
        defer self.alloc.free(abspathbuf);

        const cachefile: std.Io.File, var new: bool = self.get_cachefile(abspathbuf);
        defer cachefile.close(self.io);
        if ((cachefile.length(self.io) catch |e| crash(e)) == 0) new = true;

        if (new) return null;

        // here, we have a cachefile, that is not `new` -> it has content, that could be old
        const file_modns = (file.stat(self.io) catch |e| crash(e)).mtime.nanoseconds;
        const cachefile_modns = (cachefile.stat(self.io) catch |e| crash(e)).mtime.nanoseconds;
        if (file_modns >= cachefile_modns) { // file has newer content -> cache is obsolete
            return null;
        }

        // under the 2 assumptions of 1. being not `new` and 2. being newer than the cached file...
        return DynBuf(u8).alloc_init_from_slice(self.alloc, alloc_file_bytes(
            self.alloc,
            self.io,
            cachefile,
        ));
    }

    pub fn force_store(self: *@This(), towrite: []const u8, realpath: []const u8) void {
        const abspathbuf = std.fs.path.join(self.alloc, &.{ self.abscwd_path, realpath }) catch |e| crash(e);
        defer self.alloc.free(abspathbuf);

        to_cache_fname(abspathbuf);

        const cachefile = self.cache_dir.createFile(self.io, abspathbuf, .{}) catch |err| crash(err);
        defer cachefile.close(self.io);

        cachefile.writeStreamingAll(self.io, towrite) catch |err| crash(err);
    }

    fn get_cachefile(self: *@This(), abspathbuf: []u8) struct { std.Io.File, bool } {
        to_cache_fname(abspathbuf);
        return .{ self.cache_dir.openFile(self.io, abspathbuf, .{}) catch return .{
            self.cache_dir.createFile(self.io, abspathbuf, .{}) catch |err| crash(err), true,
        }, false };
    }

    fn to_cache_fname(abspathbuf: []u8) void {
        for (abspathbuf) |*item| {
            if (item.* == '/') item.* = '.';
        }

        abspathbuf[0] = '~';
    }
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

pub fn create(io: std.Io, cwd: ?std.Io.Dir, path: []const u8) FileError!std.Io.File {
    if (std.mem.eql(u8, path, "stdin")) {
        return std.Io.File.stdin();
    } else if (std.mem.eql(u8, path, "stdout")) {
        return std.Io.File.stdout();
    }

    var dir: std.Io.Dir = undefined;
    if (cwd) |non_default_cwd| {
        dir = non_default_cwd;
    } else {
        dir = std.Io.Dir.cwd();
    }

    return dir.createFile(io, path, .{}) catch |err| crash(err);
}

pub fn create_dir(io: std.Io, cwd: ?std.Io.Dir, path: []const u8) FileError!std.Io.Dir {
    var dir: std.Io.Dir = undefined;
    if (cwd) |non_default_cwd| {
        dir = non_default_cwd;
    } else {
        dir = std.Io.Dir.cwd();
    }

    return dir.createDirPathOpen(io, path, .{}) catch |err| crash(err);
}

pub fn open(io: std.Io, cwd: ?std.Io.Dir, path: []const u8) FileError!std.Io.File {
    if (std.mem.eql(u8, path, "stdin")) {
        return std.Io.File.stdin();
    } else if (std.mem.eql(u8, path, "stdout")) {
        return std.Io.File.stdout();
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

    return dynbuf.to_owned_slice();
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
