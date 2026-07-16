const std = @import("std");
const filex = @import("../filex.zig");
const DynBuf = @import("../ds/dynbuf.zig").DynBuf;
const Stack = @import("../ds/stack.zig").Stack;
const ByteStream = @import("../ds/ByteStream.zig");
const ErrorReporter = @import("../ErrorReporter.zig");
const crash = @import("../ErrorReporter.zig").crash;

const Cmd = enum { none, import, deferimport };

const DeferredImport = struct {
    file: std.Io.File,
    path: []const u8,
};

const DeferQueue = struct {
    items: Stack(DeferredImport),
    next: usize = 0,
};

pub fn preprocess(
    alloc: std.mem.Allocator,
    io: std.Io,
    e: *ErrorReporter,
    cwd: std.Io.Dir,
    file0: std.Io.File,
) FileWalkError![]const u8 {
    var fbytes: []u8 = undefined;
    if (file0.handle == std.Io.File.stdin().handle) {
        fbytes = filex.alloc_stdin_bytes(alloc, io, file0);
    } else {
        fbytes = filex.alloc_file_bytes(alloc, io, file0);
    }
    defer alloc.free(fbytes);
    var dynbuf = DynBuf(u8).init(alloc, fbytes.len * 2);
    errdefer dynbuf.deinit();

    try walk_and_merge(alloc, io, e, &dynbuf, cwd, file0, fbytes);

    return dynbuf.to_owned_slice();
}

pub const FileWalkError = error{
    InvalidFileExtension,
    NoImportArg,
    ImportCycle,
} || filex.FileError;

fn walk_and_merge(
    alloc: std.mem.Allocator,
    io: std.Io,
    e: *ErrorReporter,
    dynbuf: *DynBuf(u8),
    cwd: std.Io.Dir,
    file0: std.Io.File,
    fbytes: []const u8,
) FileWalkError!void {
    var sbuf_stack = Stack(ByteStream).init(alloc, 4);
    defer sbuf_stack.deinit();
    sbuf_stack.push(.init(fbytes));

    var file_stack = Stack(std.Io.File).init(alloc, 4);
    defer file_stack.deinit();
    file_stack.push(file0);

    var defer_stack = Stack(DeferQueue).init(alloc, 4);
    defer defer_stack.deinit();
    defer_stack.push(.{ .items = Stack(DeferredImport).init(alloc, 2) });

    var depth: usize = 1;

    errdefer {
        while (defer_stack.pop()) |dq_val| {
            var dq = dq_val;
            const items = dq.items.slice_view() orelse &[_]DeferredImport{};
            for (items[dq.next..]) |di| filex.close(io, di.file);
            dq.items.deinit();
        }
        while (depth > 1) : (depth -= 1) {
            if (file_stack.pop()) |file| filex.close(io, file);
            if (sbuf_stack.pop()) |sbuf| alloc.free(sbuf.buf);
        }
        _ = file_stack.pop();
        _ = sbuf_stack.pop();
    }

    while (sbuf_stack.peek_addr()) |sbuf| {
        const start_cursor = sbuf.cursor;
        const pre_at_span = sbuf.take_exc('@') orelse {
            dynbuf.append(sbuf.buf[start_cursor..sbuf.cursor]);

            const dq = defer_stack.peek_addr().?;
            const items = dq.items.slice_view() orelse &[_]DeferredImport{};
            if (dq.next < items.len) {
                const di = items[dq.next];
                dq.next += 1;

                const newfilebuf = filex.alloc_file_bytes(alloc, io, di.file);
                sbuf_stack.push(.init(newfilebuf));
                file_stack.push(di.file);
                defer_stack.push(.{ .items = Stack(DeferredImport).init(alloc, 2) });
                depth += 1;
                continue;
            }

            depth -= 1;
            if (sbuf_stack.pop()) |sb| {
                if (depth >= 1) alloc.free(sb.buf);
            }
            if (file_stack.pop()) |file| {
                if (depth >= 1) filex.close(io, file);
            }
            if (defer_stack.pop()) |finished| {
                var fq = finished;
                fq.items.deinit();
            }
            continue;
        };

        const post_at_cursor = sbuf.cursor;
        if (pre_at_span.len > 0 and pre_at_span[pre_at_span.len - 1] == '\\') {
            dynbuf.append(pre_at_span);
            dynbuf.push('@');
            continue;
        }

        const cmd: Cmd = blk: {
            const cmd_span = sbuf.take_exc('(') orelse break :blk .none;
            if (std.mem.eql(u8, cmd_span, "import")) break :blk .import;
            if (std.mem.eql(u8, cmd_span, "deferimport")) break :blk .deferimport;
            break :blk .none;
        };

        if (cmd == .none) {
            sbuf.cursor = post_at_cursor;
            dynbuf.append(pre_at_span);
            dynbuf.push('@');
            continue;
        }

        const arg_span = sbuf.take_exc(')') orelse {
            return e.file_report(FileWalkError.NoImportArg, false, "No enclosing ')'", null);
        };

        dynbuf.append(pre_at_span);

        const newfile_path: []const u8 = arg_span;
        if (!std.mem.endsWith(u8, newfile_path, ".ct")) {
            return e.file_report(
                FileWalkError.InvalidFileExtension,
                false,
                .{ "Import file must have .ct extension: {s}", .{newfile_path} },
                null,
            );
        }
        const newfile = filex.open(io, cwd, newfile_path) catch |err| {
            return e.file_report(err, false, .{ "Failed to open import file: {s}", .{newfile_path} }, null);
        };

        for (file_stack.slice_view().?) |file| {
            if (file.handle != std.Io.File.stdin().handle) {
                const stat_a = newfile.stat(io) catch |err| return crash(err);
                const stat_b = file.stat(io) catch |err| return crash(err);
                if (stat_a.inode == stat_b.inode) {
                    return e.file_report(
                        FileWalkError.ImportCycle,
                        false,
                        .{ "Import cycle detected: {s}", .{newfile_path} },
                        null,
                    );
                }
            }
        }

        if (cmd == .deferimport) {
            defer_stack.peek_addr().?.items.push(.{ .file = newfile, .path = newfile_path });
            continue;
        }

        const newfilebuf = filex.alloc_file_bytes(alloc, io, newfile);
        sbuf_stack.push(.init(newfilebuf));
        file_stack.push(newfile);
        defer_stack.push(.{ .items = Stack(DeferredImport).init(alloc, 2) });
        depth += 1;
    }
}
