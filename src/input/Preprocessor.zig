const std = @import("std");
const filex = @import("../filex.zig");
const DynBuf = @import("../ds/dynbuf.zig").DynBuf;
const Stack = @import("../ds/stack.zig").Stack;
const crash = @import("../ErrorReporter.zig").crash;

pub const CursoredBuf = struct {
    buf: []const u8,
    cursor: usize,

    pub fn init(buf: []const u8) CursoredBuf {
        return CursoredBuf{
            .buf = buf,
            .cursor = 0,
        };
    }

    pub fn pop(self: *CursoredBuf) ?u8 {
        if (self.cursor >= self.buf.len) return null;
        defer self.cursor += 1;
        return self.buf[self.cursor];
    }

    pub fn peek(self: *CursoredBuf) ?u8 {
        if (self.cursor >= self.buf.len) return null;
        return self.buf[self.cursor];
    }

    // on null, self.cursor is at end (exc) of buffer
    pub fn take_exc(self: *CursoredBuf, delim: u8) ?[]const u8 {
        const start = self.cursor;
        while (self.cursor < self.buf.len) : (self.cursor += 1) {
            if (self.buf[self.cursor] == delim) {
                const result = self.buf[start..self.cursor];
                self.cursor += 1; // skip delim
                return result;
            }
        }
        return null;
    }
};

// @import("file") as long as there's no \ before @
// if \, then command parsing skips it regardless, not adjustment needed

// recursive, since we do not have a huge chain of imports, so stack remains small
pub fn preprocess(
    arenalloc: std.mem.Allocator,
    io: std.Io,
    file0: std.Io.File,
) ![]const u8 {
    var fbytes: []u8 = undefined;
    if (file0.handle == std.Io.File.stdin().handle) {
        fbytes = try filex.alloc_stdin_bytes(arenalloc, io, file0);
    } else {
        fbytes = try filex.alloc_file_bytes(arenalloc, io, file0);
    }
    var dynbuf = try DynBuf(u8).init(arenalloc, fbytes.len * 2);
    walk_and_merge(arenalloc, io, &dynbuf, file0, fbytes);
    // `fbytes` is the `file0` buffer, which is freed in `walk_and_merge`

    // we could postpone, but no need to keep all files twice in memory
    // since the reader ops copy the file contents in `dynbuf`
    return dynbuf.to_slice();
}

fn walk_and_merge(
    alloc: std.mem.Allocator,
    io: std.Io,
    dynbuf: *DynBuf(u8),
    file0: std.Io.File,
    fbytes: []const u8,
) void {
    // null: file without reader, meaning `stdin`
    var cbuf_stack = Stack(CursoredBuf).init(alloc, 4) catch return crash(error.OOM);
    defer cbuf_stack.deinit();
    cbuf_stack.push(.init(fbytes)) catch return crash(error.OOM);

    // null: file without need to be cyclic checked or closed, meaning `stdin`
    var file_stack = Stack(std.Io.File).init(alloc, 4) catch return crash(error.OOM);
    defer file_stack.deinit();
    file_stack.push(file0) catch return crash(error.OOM);

    while (cbuf_stack.peek_addr()) |cbuf| {
        const start_cursor = cbuf.cursor;
        const pre_at_span = cbuf.take_exc('@') orelse {
            dynbuf.append(cbuf.buf[start_cursor..cbuf.cursor]) catch return crash(error.OOM);
            alloc.free(cbuf.buf);
            _ = cbuf_stack.pop();
            if (file_stack.pop()) |file| {
                if (file.handle != std.Io.File.stdin().handle) file.close(io);
            }
            continue; // reading file is done; next
        };

        const post_at_cursor = cbuf.cursor;
        if (pre_at_span.len > 0 and pre_at_span[pre_at_span.len - 1] == '\\') {
            dynbuf.append(pre_at_span) catch return crash(error.OOM);
            dynbuf.push('@') catch return crash(error.OOM);
            continue;
        }

        const is_import = blk: {
            const cmd_span = cbuf.take_exc('(') orelse break :blk false;
            break :blk std.mem.eql(u8, cmd_span, "import");
        };

        if (!is_import) { // same as above
            // undo the command lookahead so we don't lose data after '@'
            cbuf.cursor = post_at_cursor;
            dynbuf.append(pre_at_span) catch return crash(error.OOM);
            dynbuf.push('@') catch return crash(error.OOM);
            continue;
        }

        const arg_span = cbuf.take_exc(')') orelse return crash("No closing '(' for @import-call");
        dynbuf.append(pre_at_span) catch return crash(error.OOM);

        const newfile_path: []const u8 = arg_span;
        const newfile = std.Io.Dir.cwd().openFile(io, newfile_path, .{}) catch {
            crash(.{ "Unable to open file: {s}", .{newfile_path} });
        }; // closed later

        // if newfile is in stack, we build a cycle, throw error
        // unwrapped since we currently peek into `file_stack` which guarantees atleast one elem
        for (file_stack.to_slice().?) |file| {
            if (file.handle != std.Io.File.stdin().handle) {
                const stat_a = newfile.stat(io) catch |e| return crash(e);
                const stat_b = file.stat(io) catch |e| return crash(e);
                if (stat_a.inode == stat_b.inode) {
                    // cycle
                    return crash(.{ "Cycle for file: {s}", .{newfile_path} });
                }
            }
        }

        // push newfile on stack and "schreite den berg hinauf :D"
        const newfilebuf = filex.alloc_file_bytes(alloc, io, newfile) catch return crash(error.OOM);
        cbuf_stack.push(.init(newfilebuf)) catch return crash(error.OOM);
        file_stack.push(newfile) catch return crash(error.OOM);
    }
}
