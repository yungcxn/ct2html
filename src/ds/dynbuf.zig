const std = @import("std");
const crash = @import("../ErrorReporter.zig").crash;

pub fn DynBuf(T: type) type {
    return struct {
        alloc: std.mem.Allocator,
        buf: ?[]T,
        head: usize = 0,
        cap: usize,

        pub fn init(alloc: std.mem.Allocator, start_cap: usize) DynBuf(T) {
            if (start_cap == 0) crash(error.StartCapZeroNotAllowed);
            return DynBuf(T){
                .alloc = alloc,
                .buf = alloc.alloc(T, start_cap) catch crash(error.OOM),
                .cap = start_cap,
            };
        }

        pub fn alloc_init(alloc: std.mem.Allocator, start_cap: usize) *DynBuf(T) {
            const dynbuf = alloc.create(DynBuf(T)) catch crash(error.OOM);
            dynbuf.* = DynBuf(T).init(alloc, start_cap);
            return dynbuf;
        }

        pub fn init_from_slice(alloc: std.mem.Allocator, buf: []T) DynBuf(T) {
            return DynBuf(T){
                .alloc = alloc,
                .buf = buf,
                .head = buf.len,
                .cap = buf.len,
            };
        }

        pub fn alloc_init_from_slice(alloc: std.mem.Allocator, buf: []T) *DynBuf(T) {
            const dynbuf = alloc.create(DynBuf(T)) catch crash(error.OOM);
            dynbuf.* = DynBuf(T).init_from_slice(alloc, buf);
            return dynbuf;
        }

        pub fn deinit(self: *DynBuf(T)) void {
            self.alloc.free(self.buf orelse return);
        }

        pub fn destroy(self: *DynBuf(T)) void {
            self.deinit();
            self.alloc.destroy(self);
        }

        fn grow(self: *DynBuf(T)) void {
            const new_cap = self.cap * 2;
            self.buf = self.alloc.realloc(self.buf.?, new_cap) catch return crash(error.OOM);
            self.cap = new_cap;
        }

        pub fn push(self: *DynBuf(T), value: T) void {
            if (self.head == self.cap) {
                self.grow();
            }

            self.buf.?[self.head] = value;
            self.head += 1;
        }

        pub fn append(self: *DynBuf(T), slice: []const T) void {
            while (self.head + slice.len > self.cap) {
                self.grow();
            }

            @memcpy(self.buf.?[self.head .. self.head + slice.len], slice);
            self.head += slice.len;
        }

        pub fn slice_view(self: DynBuf(T)) []T {
            return self.buf.?[0..self.head];
        }

        pub fn to_owned_slice(self: *DynBuf(T)) []T {
            const trimmed = self.alloc.realloc(self.buf.?, self.head) catch return crash(error.OOM);
            self.buf = null;
            return trimmed;
        }

        pub fn copy(self: *DynBuf(T)) DynBuf(T) {
            const new_buf = self.alloc.alloc(T, self.head) catch return crash(error.OOM);
            @memcpy(new_buf, self.buf.?[0..self.head]);
            return DynBuf(T){
                .alloc = self.alloc,
                .buf = new_buf,
                .head = self.head,
                .cap = self.head,
            };
        }

        // `alloc` passed extra since `self` might be proxied here
        pub fn alloc_copy(self: *DynBuf(T)) *DynBuf(T) {
            const new_dynbuf = self.alloc.create(DynBuf(T)) catch return crash(error.OOM);
            new_dynbuf.* = self.copy();
            return new_dynbuf;
        }
    };
}
