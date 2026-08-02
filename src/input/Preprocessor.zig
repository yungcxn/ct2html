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
) FileWalkError!*DynBuf(u8) {
    var fbytes: []u8 = undefined;
    if (file0.handle == std.Io.File.stdin().handle) {
        fbytes = filex.alloc_stdin_bytes(alloc, io, file0);
    } else {
        fbytes = filex.alloc_file_bytes(alloc, io, file0);
    }
    defer alloc.free(fbytes);
    var dynbuf = DynBuf(u8).alloc_init(alloc, fbytes.len * 2);
    errdefer dynbuf.destroy();

    try walk_and_merge(alloc, io, e, dynbuf, cwd, file0, fbytes);

    return dynbuf;
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

    var file_stack = Stack(?std.Io.File).init(alloc, 4);
    defer file_stack.deinit();
    file_stack.push(file0);

    var defer_stack = Stack(DeferQueue).init(alloc, 4);
    defer defer_stack.deinit();
    defer_stack.push(.{ .items = Stack(DeferredImport).init(alloc, 2) });

    var var_map = std.StringHashMap(?[]const u8).init(alloc);
    defer var_map.deinit();

    var depth: usize = 1;

    errdefer {
        while (defer_stack.pop()) |dq_val| {
            var dq = dq_val;
            const items = dq.items.slice_view() orelse &[_]DeferredImport{};
            for (items[dq.next..]) |di| filex.close(io, di.file);
            dq.items.deinit();
        }
        while (depth > 1) : (depth -= 1) {
            const sb = sbuf_stack.pop();
            if (file_stack.pop()) |file| {
                if (file) |f| {
                    filex.close(io, f);
                    if (sb) |s| alloc.free(s.buf);
                }
            }
        }
        _ = file_stack.pop();
        _ = sbuf_stack.pop();
    }

    while (sbuf_stack.peek_addr()) |sbuf| {
        const start_cursor = sbuf.cursor;
        const delim, const pre_trigger_span = sbuf.take_any_exc(&[_]u8{ '@', '$' }) orelse {
            // this stream is finished! clean up

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
            const sb = sbuf_stack.pop();
            if (file_stack.pop()) |maybe_file| {
                if (maybe_file) |f| {
                    if (depth >= 1) {
                        filex.close(io, f);
                        if (sb) |s| alloc.free(s.buf);
                    }
                }
                // maybe_file == null => var-expansion frame; buf is borrowed, never freed
            }

            if (defer_stack.pop()) |finished| {
                var fq = finished;
                fq.items.deinit();
            }
            continue;
        };

        const post_trigger_cursor = sbuf.cursor;
        if (pre_trigger_span.len > 0 and pre_trigger_span[pre_trigger_span.len - 1] == '\\') {
            dynbuf.append(pre_trigger_span);
            dynbuf.push(delim);
            continue;
        }

        if (delim == '@') {
            // TODO OWN FUNC!
            const cmd: Cmd = blk: {
                const cmd_span = sbuf.take_exc('(') orelse break :blk .none;
                if (std.mem.eql(u8, cmd_span, "import")) break :blk .import;
                if (std.mem.eql(u8, cmd_span, "deferimport")) break :blk .deferimport;
                break :blk .none;
            };

            if (cmd == .none) {
                sbuf.cursor = post_trigger_cursor;
                dynbuf.append(pre_trigger_span);
                dynbuf.push('@');
                continue;
            }

            const arg_span = sbuf.take_exc(')') orelse {
                return e.file_report(FileWalkError.NoImportArg, false, "No enclosing ')'", null);
            };

            dynbuf.append(pre_trigger_span);

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
                return e.file_report(
                    err,
                    false,
                    .{ "Failed to open import file: {s}", .{newfile_path} },
                    null,
                );
            };

            for (file_stack.slice_view().?) |optfile| if (optfile) |file| {
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
            };

            if (cmd == .deferimport) {
                defer_stack.peek_addr().?.items.push(.{ .file = newfile, .path = newfile_path });
                continue;
            }

            const newfilebuf = filex.alloc_file_bytes(alloc, io, newfile);
            sbuf_stack.push(.init(newfilebuf));
            file_stack.push(newfile);
            defer_stack.push(.{ .items = Stack(DeferredImport).init(alloc, 2) });
            depth += 1;
        } else if (delim == '$') {
            const sep, const macro_span = sbuf.take_any_exc(&[_]u8{ '=', ';' }) orelse {
                return e.file_report(FileWalkError.NoImportArg, false, "No enclosing '=' or ';'", null);
            };

            dynbuf.append(pre_trigger_span);

            if (sep == '=') {
                // var def
                const var_name = macro_span;
                const var_val = stream_take_var_end_exc(sbuf) orelse {
                    return e.file_report(
                        FileWalkError.NoImportArg,
                        false,
                        "No enclosing ';' for var def",
                        null,
                    );
                };

                var_map.put(var_name, var_val) catch crash(error.OOM);
                continue;
            } else if (sep == ';') {
                // var expr
                if (var_map.get(macro_span)) |foundval| {
                    if (foundval) |val| {
                        // we could append `val` now to the dynbuf, but it is treated as text
                        //   that is from another file, still open for evaluation of inner vars
                        sbuf_stack.push(.init(val));
                        file_stack.push(null);
                        defer_stack.push(.{ .items = Stack(DeferredImport).init(alloc, 2) });
                        depth += 1;
                    } else {
                        // since form of $xxx=; is allowed to undef, just proceed
                        continue;
                    }
                }
            } else unreachable;
        } else unreachable;
    }
}

// it takes e.g. '$' and ';' and skips all ';' that has a preset '$', then takes ';'
// - also skips escaped chars ('\\')
fn stream_take_var_end_exc(self: *ByteStream) ?[]const u8 {
    const start = self.cursor;
    var depth: usize = 0;
    while (self.cursor < self.buf.len) : (self.cursor += 1) {
        const c = self.buf[self.cursor];
        switch (c) {
            '\\' => {
                self.cursor += 1; // skip next char
            },
            '$' => {
                depth += 1;
            },
            ';' => {
                if (depth == 0) {
                    const result = self.buf[start..self.cursor];
                    self.cursor += 1; // skip semicolon
                    return result;
                } else {
                    depth -= 1;
                }
            },
            else => {},
        }
    }
    return null;
}
