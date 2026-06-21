const std = @import("std");

io: std.Io = undefined,
arena: *std.heap.ArenaAllocator = undefined,

pub fn print(self: @This(), text: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(self.io, text) catch @panic("Failed to write to stdout");
}

pub fn printf(self: @This(), comptime fmt: []const u8, args: anytype) void {
    self.print(std.fmt.allocPrint(self.arena.allocator(), fmt, args) catch @panic("Failed to format string"));
}
