const std = @import("std");
const crash = @import("../ErrorReporter.zig").crash;

pub fn DynBuf(T: type) type {
    return struct {
        alloc: std.mem.Allocator,
        buf: []T,
        head: usize = 0,
        cap: usize,

        pub fn init(alloc: std.mem.Allocator, start_cap: usize) !DynBuf(T) {
            if (start_cap == 0) return error.Cap0NotAllowed;

            return DynBuf(T){
                .alloc = alloc,
                .buf = try alloc.alloc(T, start_cap),
                .cap = start_cap,
            };
        }

        pub fn deinit(self: *DynBuf(T)) void {
            self.alloc.free(self.buf);
        }

        fn grow(self: *DynBuf(T)) void {
            const new_cap = self.cap * 2;
            self.buf = self.alloc.realloc(self.buf, new_cap) catch return crash(error.OOM);
            self.cap = new_cap;
        }

        pub fn push(self: *DynBuf(T), value: T) void {
            if (self.head == self.cap) {
                self.grow();
            }

            self.buf[self.head] = value;
            self.head += 1;
        }

        pub fn append(self: *DynBuf(T), slice: []const T) void {
            while (self.head + slice.len > self.cap) {
                self.grow();
            }

            @memcpy(self.buf[self.head .. self.head + slice.len], slice);
            self.head += slice.len;
        }

        pub fn to_slice(self: DynBuf(T)) []T {
            return self.buf[0..self.head];
        }
    };
}
