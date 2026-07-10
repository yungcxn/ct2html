const std = @import("std");
const filex = @import("filex.zig");
const Io = std.Io;
const net = std.Io.net;
const http = std.http;
const crash = @import("ErrorReporter.zig").crash;

const headers = [_]http.Header{
    .{ .name = "Content-Type", .value = "text/html; charset=UTF-8" },
    .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    .{ .name = "Cache-Control", .value = "no-store" },
};

const listen_addr = "127.0.0.1";
const listen_port: u16 = 8080;

const Responder = fn (
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    path: []const u8,
    cache: *filex.Cache,
) error{FileNotFound}![]const u8;

pub fn run(
    comptime responder: Responder,
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    cache: *filex.Cache,
) void {
    const addr = net.IpAddress.parseIp4(listen_addr, listen_port) catch |err| crash(err);
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| crash(err);
    defer server.deinit(io);
    std.log.info("listening on http://{s}:{d}", .{ listen_addr, listen_port });

    Dispatcher(responder).start(alloc, io, &server, cwd, cache);
}

fn Dispatcher(comptime responder: Responder) type {
    return struct {
        pub fn start(alloc: std.mem.Allocator, io: std.Io, server: *std.Io.net.Server, cwd: std.Io.Dir, cache: *filex.Cache) void {
            var group: std.Io.Group = .init;
            defer group.cancel(io);

            while (true) {
                const stream = server.accept(io) catch |err| {
                    std.log.err("accept failed: {s}", .{@errorName(err)});
                    continue;
                };
                group.concurrent(io, handle_conn, .{ io, alloc, cwd, stream, cache }) catch |err| {
                    std.log.err("failed to spawn handler: {s}", .{@errorName(err)});
                    stream.close(io);
                };
            }
        }

        fn handle_conn(io: Io, alloc: std.mem.Allocator, cwd: std.Io.Dir, stream: net.Stream, cache: *filex.Cache) void {
            defer stream.close(io);

            var read_buf: [8 * 1024]u8 = undefined;
            var write_buf: [8 * 1024]u8 = undefined;
            var reader = stream.reader(io, &read_buf);
            var writer = stream.writer(io, &write_buf);

            var srv = http.Server.init(&reader.interface, &writer.interface);

            while (true) {
                var req = srv.receiveHead() catch |err| switch (err) {
                    error.HttpConnectionClosing => return,
                    else => {
                        std.log.debug("receiveHead error: {s}", .{@errorName(err)});
                        return;
                    },
                };

                handle_req(alloc, io, cwd, &req, cache) catch |err| {
                    std.log.err("handle_req error: {s}", .{@errorName(err)});
                    return;
                };

                if (!req.head.keep_alive) return;
            }
        }

        fn handle_req(
            alloc: std.mem.Allocator,
            io: std.Io,
            cwd: std.Io.Dir,
            req: *http.Server.Request,
            cache: *filex.Cache,
        ) !void {
            if (req.head.method != .GET) {
                try req.respond("", .{ .status = .method_not_allowed, .extra_headers = &headers });
                return;
            }

            const path = req.head.target;
            const response_body = responder(alloc, io, cwd, path, cache) catch |err| switch (err) {
                error.FileNotFound => {
                    try req.respond(
                        "File not found",
                        .{ .status = .not_found, .extra_headers = &headers },
                    );
                    return;
                },
            };
            defer alloc.free(response_body);

            try req.respond(response_body, .{ .status = .ok, .extra_headers = &headers });
        }
    };
}
