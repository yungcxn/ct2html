const std = @import("std");
const filex = @import("filex.zig");
const argx = @import("argx.zig");
const Preprocessor = @import("input/Preprocessor.zig");
const Parser = @import("input/Parser.zig");
const Rule = @import("element/Rule.zig");
const l0_rules = @import("input/l0_rules.zig");
const l1_rules = @import("input/l1_rules.zig");
const gen_rules = @import("output/gen_rules.zig");
const Generator = @import("output/Generator.zig");
const ErrorReporter = @import("ErrorReporter.zig");
const crash = ErrorReporter.crash;
const file_report = ErrorReporter.file_report;
const throw = ErrorReporter.throw;
const webserver = @import("webserver.zig");
const Attributor = @import("internal/Attributor.zig");
const CCEngine = @import("internal/CCEngine.zig");
const DynBuf = @import("ds/dynbuf.zig").DynBuf;

// these errors get thrown through the reporting system of `ErrorReporter`

pub const RunError = filex.FileError || Preprocessor.FileWalkError || Parser.ParsingError || Generator.GenError;

pub const argdef = .{
    argx.Arg([]const u8){
        .fieldname = "in",
        .short_altname = 'i',
        .default = "stdin",
        .desc = "Input file path",
    },
    argx.Arg([]const u8){
        .fieldname = "out",
        .short_altname = 'o',
        .default = "stdout",
        .desc = "Whether to write output to file",
    },
    argx.Arg([]const u8){
        .fieldname = "cwd",
        .short_altname = 'c',
        .desc = "Current working directory",
        .default = ".",
    },
    argx.Arg(bool){
        .fieldname = "debug",
        .short_altname = 'd',
        .default = false,
        .desc = "Print debug information",
    },
    argx.Arg(bool){
        .fieldname = "htmlerror",
        .default = false,
        .desc = "Print the error as HTML instead of plain text",
    },
    argx.Arg(bool){
        .fieldname = "responsemode",
        .short_altname = 'r',
        .default = false,
        .desc = "Prints HTML response headers aswell",
    },
    argx.Arg(bool){
        .fieldname = "webservermode",
        .short_altname = 'w',
        .default = false,
        .desc = "Runs in web server mode (on 127.0.0.1:8080)",
    },
    argx.Arg(bool){
        .fieldname = "cleantmp", // TODO FIX NOT WORKING
        .default = false,
        .desc = "Cleans the temp-folder for file caching at start (/tmp/ct2html/)",
    },
};

inline fn print_elapsed(io: std.Io, start: std.Io.Timestamp, comptime fmt: []const u8) void {
    const end = std.Io.Clock.now(.awake, io);
    const duration = start.durationTo(end);
    const ns: i96 = duration.toNanoseconds();
    const ms: f128 = @as(f128, @floatFromInt(ns)) / 1_000_000.0;
    std.log.info(fmt, .{ms});
}

pub fn main(init: std.process.Init) void {
    const io = init.io;
    const alloc = init.gpa;

    const start = std.Io.Clock.now(.awake, io);

    const argslice = init.minimal.args.toSlice(
        alloc,
    ) catch |err| ErrorReporter.crash(err);
    defer alloc.free(argslice);

    var env_vars = init.minimal.environ.createMap(
        alloc,
    ) catch |err| ErrorReporter.crash(err);
    defer env_vars.deinit();

    const args = argx.parse(argdef, argslice, env_vars);

    const cwd = filex.open_dir(io, null, args.cwd) catch |err| {
        std.log.err("Failed to open cwd directory: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer filex.close_dir(io, cwd);

    const tmp = filex.create_dir(io, null, "/tmp/ct2html/") catch |err| {
        std.log.err("Failed to open/create tmp directory: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer filex.close_dir(io, tmp);

    if (args.cleantmp) {
        var it = tmp.iterate();
        while (it.next(io) catch |err| crash(err)) |entry| {
            switch (entry.kind) {
                .directory => tmp.deleteTree(io, entry.name) catch |err| crash(err),
                else => tmp.deleteFile(io, entry.name) catch |err| crash(err),
            }
            std.log.info("Deleted from cache: {s}", .{entry.name});
        }
    }

    const abscwd_path = cwd.realPathFileAlloc(io, ".", alloc) catch |err| crash(err);
    defer alloc.free(abscwd_path);

    var cache = filex.Cache.init(alloc, io, tmp, abscwd_path);
    defer cache.deinit();

    if (args.webservermode) {
        webserver.run(gen_response, alloc, io, cwd, &cache);
    } else {
        if (!std.mem.eql(u8, args.in, "stdin") and !std.mem.endsWith(u8, args.in, ".ct")) {
            std.log.err("Input file must have .ct extension", .{});
            std.process.exit(1);
        }

        if (!std.mem.eql(u8, args.out, "stdout") and !std.mem.endsWith(u8, args.out, ".html")) {
            std.log.err("Output file must have .html extension", .{});
            std.process.exit(1);
        }

        const in_file = filex.open(io, cwd, args.in) catch |err| {
            std.log.err("Failed to open input file: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
        defer filex.close(io, in_file); // closed in preprocessor

        const out_file = filex.create(io, cwd, args.out) catch |err| {
            std.log.err("Failed to open output file: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
        defer filex.close(io, out_file);

        if (in_file.handle != std.Io.File.stdin().handle) {
            const opt_cachecontent = cache.try_owned_cacheload(in_file, args.in);
            if (opt_cachecontent) |cachecontent| {
                std.log.info("Cache hit for: {s}", .{args.in});

                out_file.writeStreamingAll(
                    io,
                    cachecontent.slice_view(),
                ) catch return crash(error.OOM);

                cachecontent.destroy();
                print_elapsed(io, start, "Cached run took: {} ms");
                return;
            }
        }

        const outdynbuf, const run_err = run(alloc, io, cwd, in_file, args.htmlerror, args.responsemode, args.debug);
        defer outdynbuf.destroy();

        if (run_err == null and in_file.handle != std.Io.File.stdin().handle) {
            cache.force_store(outdynbuf.slice_view(), args.in);
            std.log.info("Stored cache for: {s}", .{args.in});
        }

        out_file.writeStreamingAll(io, outdynbuf.slice_view()) catch return crash(error.OOM);
        print_elapsed(io, start, "Full run took: {} ms");
    }
}

// the error is returned optionally for testing purposes.
pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    in_file: std.Io.File,
    htmlerror: bool,
    responsemode: bool,
    debug: bool,
) struct { *DynBuf(u8), ?RunError } {
    var error_reporter = ErrorReporter.init(alloc, io, htmlerror, responsemode);
    defer error_reporter.deinit();

    const preprocessed_text: *DynBuf(u8) = Preprocessor.preprocess(
        alloc,
        io,
        &error_reporter,
        cwd,
        in_file,
    ) catch |err| {
        if (error_reporter.err_reported) {
            return .{ error_reporter.outbuf.alloc_copy(), err };
        } else {
            crash(error.ThrowWithoutReport);
        }
    };
    defer preprocessed_text.destroy();

    if (debug) std.log.debug("[[PREPROCESSOR DEBUG]]:\n{s}\n", .{preprocessed_text.slice_view()});

    var custom_cmd_engine = CCEngine.init(alloc, &error_reporter, preprocessed_text.slice_view());
    defer custom_cmd_engine.deinit();

    var attributor = Attributor.init(alloc, &custom_cmd_engine);
    defer attributor.deinit();

    // this allocates the l0nodes and l1nodes dynbufs only, which get removed
    // when deiniting
    var parser = Parser.init(
        alloc,
        io,
        &error_reporter,
        &attributor,
        &custom_cmd_engine,
        preprocessed_text.slice_view(),
        htmlerror,
    );
    defer parser.deinit();

    error_reporter.set_parser(&parser);

    parser.build_nodes() catch |err| if (error_reporter.err_reported) {
        return .{ error_reporter.outbuf.alloc_copy(), err };
    } else {
        crash(error.ThrowWithoutReport);
    };

    if (debug) {
        std.log.debug("[[PARSER DEBUG]]:", .{});
        parser.debug_print();
        std.log.debug("[[PARSER CUSTOM COMMANDS]]:", .{});

        const debugstr = parser.custom_cmd_engine.alloc_debug_cmd_list(true);
        std.log.debug("{s}", .{debugstr});
        alloc.free(debugstr);

        const debugstr2 = parser.custom_cmd_engine.alloc_debug_cmd_list(false);
        std.log.debug("{s}", .{debugstr2});
        alloc.free(debugstr2);

        std.log.debug("[[PARSER DEBUG END]]", .{});
    }

    // is not defered since only the buffer from the generated HTML file is alloc'd
    var generator = Generator.init(
        alloc,
        io,
        &error_reporter,
        &attributor,
        &custom_cmd_engine,
        preprocessed_text.slice_view(),
        parser.l0nodes,
        parser.l1nodes,
        htmlerror,
        responsemode,
    );

    // `Generator` only allocates the buffer behind `outbuf`
    const outdynbuf = generator.generate_out() catch |err| if (error_reporter.err_reported) {
        return .{ error_reporter.outbuf.alloc_copy(), err };
    } else {
        crash(error.ThrowWithoutReport);
    };

    return .{ outdynbuf, null };
}

fn gen_response(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    path: []const u8,
    cache: *filex.Cache,
) error{FileNotFound}!*DynBuf(u8) {
    const start = std.Io.Clock.now(.awake, io);

    std.log.info("requested: {s}", .{path});
    if (!std.mem.endsWith(u8, path, ".ct")) {
        return error.FileNotFound;
    }

    var path2 = path;
    if (path[0] == '/') path2 = path[1..]; // remove leading slash

    const in_file = filex.open(io, cwd, path2) catch return error.FileNotFound;
    defer in_file.close(io);

    if (cache.try_owned_cacheload(in_file, path2)) |dynbuf| {
        std.log.info("Cache hit for: {s}", .{path2});
        print_elapsed(io, start, "Cached run took: {} ms");
        return dynbuf;
    } else {
        const outdynbuf, const run_err = run(alloc, io, cwd, in_file, true, false, false);
        if (run_err == null) {
            cache.force_store(outdynbuf.slice_view(), path2);
            std.log.info("Stored cache for: {s}", .{path2});
        }
        print_elapsed(io, start, "Full run took: {} ms");
        return outdynbuf;
    }
}
