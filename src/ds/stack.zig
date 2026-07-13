const std = @import("std");
const crash = @import("../ErrorReporter.zig").crash;

pub fn Stack(T: type) type {
    return struct {
        alloc: std.mem.Allocator,
        buf: []T,
        sp: usize = std.math.maxInt(usize),
        cap: usize,

        pub fn init(alloc: std.mem.Allocator, start_cap: usize) Stack(T) {
            if (start_cap == 0) crash(error.StartCapZeroNotAllowed);
            return Stack(T){
                .alloc = alloc,
                .buf = alloc.alloc(T, start_cap) catch crash(error.OOM),
                .cap = start_cap,
            };
        }

        pub fn deinit(self: *Stack(T)) void {
            self.alloc.free(self.buf);
        }

        fn grow(self: *Stack(T)) void {
            const new_cap = self.cap * 2;
            self.buf = self.alloc.realloc(self.buf, new_cap) catch return crash(error.OOM);
            self.cap = new_cap;
        }

        pub fn empty(self: *Stack(T)) bool {
            return self.sp == std.math.maxInt(usize);
        }

        pub fn push(self: *Stack(T), value: T) void {
            self.sp = self.sp +% 1;
            if (self.sp >= self.cap) self.grow();
            self.buf[self.sp] = value;
        }

        pub fn pop(self: *Stack(T)) ?T {
            if (self.empty()) return null;

            defer self.sp = self.sp -% 1;
            return self.peek();
        }

        pub fn peek(self: *Stack(T)) ?T {
            if (self.empty()) return null;

            return self.buf[self.sp];
        }

        pub fn peek_addr(self: *Stack(T)) ?*T {
            if (self.empty()) return null;

            return &self.buf[self.sp];
        }

        pub fn slice_view(self: *Stack(T)) ?[]T {
            if (self.empty()) return null;

            return self.buf[0 .. self.sp + 1];
        }
    };
}
