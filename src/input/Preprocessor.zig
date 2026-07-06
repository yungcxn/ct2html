const std = @import("std");
const filex = @import("../filex.zig");
const DynBuf = @import("../ds/dynbuf.zig").DynBuf;
const Stack = @import("../ds/stack.zig").Stack;
const ByteStream = @import("../ds/ByteStream.zig");
const ErrorReporter = @import("../ErrorReporter.zig");
const crash = @import("../ErrorReporter.zig").crash;

// @import("file") as long as there's no \ before @
// if \, then command parsing skips it regardless, not adjustment needed

// this returns an allocated dynbuf slice of the preprocessed text, nothing else
// is to be allocated out of here
pub fn preprocess(
    alloc: std.mem.Allocator,
    io: std.Io,
    e: *ErrorReporter,
    cwd: std.Io.Dir,
    file0: std.Io.File,
) FileWalkError![]const u8 {
    var fbytes: []u8 = undefined;
    // `fbytes` is the `file0` buffer, which is freed in `walk_and_merge`
    if (file0.handle == std.Io.File.stdin().handle) {
        fbytes = filex.alloc_stdin_bytes(alloc, io, file0);
    } else {
        fbytes = filex.alloc_file_bytes(alloc, io, file0);
    }
    var dynbuf = DynBuf(u8).init(alloc, fbytes.len * 2);

    try walk_and_merge(alloc, io, e, &dynbuf, cwd, file0, fbytes);

    // only `try` since we try to propagate the test error when in testmode

    // we could postpone, but no need to keep all files twice in memory
    // since the reader ops copy the file contents in `dynbuf`
    return dynbuf.to_slice();
}

pub const FileWalkError = error{
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
    // null: file without reader, meaning `stdin`
    var sbuf_stack = Stack(ByteStream).init(alloc, 4);
    defer sbuf_stack.deinit();
    sbuf_stack.push(.init(fbytes));

    // null: file without need to be cyclic checked or closed, meaning `stdin`
    var file_stack = Stack(std.Io.File).init(alloc, 4);
    defer file_stack.deinit();
    file_stack.push(file0);

    errdefer {
        while (file_stack.pop()) |file| {
            filex.close(io, file);
        }

        while (sbuf_stack.pop()) |sbuf| {
            alloc.free(sbuf.buf);
        }
    }

    while (sbuf_stack.peek_addr()) |sbuf| {
        const start_cursor = sbuf.cursor;
        const pre_at_span = sbuf.take_exc('@') orelse {
            dynbuf.append(sbuf.buf[start_cursor..sbuf.cursor]);
            alloc.free(sbuf.buf);
            _ = sbuf_stack.pop();
            if (file_stack.pop()) |file| {
                filex.close(io, file);
            }
            continue; // reading file is done; next
        };

        const post_at_cursor = sbuf.cursor;
        if (pre_at_span.len > 0 and pre_at_span[pre_at_span.len - 1] == '\\') {
            dynbuf.append(pre_at_span);
            dynbuf.push('@');
            continue;
        }

        const is_import = blk: {
            const cmd_span = sbuf.take_exc('(') orelse break :blk false;
            break :blk std.mem.eql(u8, cmd_span, "import");
        };

        if (!is_import) { // same as above
            // undo the command lookahead so we don't lose data after '@'
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
        const newfile = filex.open(io, cwd, newfile_path, ".ct") catch |err| {
            return e.file_report(err, false, .{ "Failed to open import file: {s}", .{newfile_path} }, null);
        };

        // if newfile is in stack, we build a cycle, throw error
        // unwrapped since we currently peek into `file_stack` which guarantees atleast one elem
        for (file_stack.to_slice().?) |file| {
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

        // push newfile on stack and "schreite den berg hinauf :D"
        const newfilebuf = filex.alloc_file_bytes(alloc, io, newfile);
        sbuf_stack.push(.init(newfilebuf));
        file_stack.push(newfile);
    }
}
