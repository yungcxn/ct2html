const std = @import("std");
const filex = @import("filex.zig");
const argx = @import("argx.zig");
const Preprocessor = @import("input/Preprocessor.zig");
const Parser = @import("input/Parser.zig");
const Generator = @import("output/Generator.zig");
const ErrorReporter = @import("ErrorReporter.zig");
const crash = ErrorReporter.crash;
const file_report = ErrorReporter.file_report;

// these errors get thrown through the reporting system of `ErrorReporter`

pub const RunError = filex.FileError || Preprocessor.FileWalkError || Parser.ParsingError;

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
};

pub fn main(init: std.process.Init) void {
    const io = init.io;
    const manualloc = init.gpa;
    var arena = std.heap.ArenaAllocator.init(manualloc);
    defer arena.deinit();

    const argslice = init.minimal.args.toSlice(
        arena.allocator(),
    ) catch |err| ErrorReporter.crash(err);

    const args = argx.parse(argdef, argslice);

    run(arena.allocator(), io, args) catch std.process.exit(1);
}

// extra function for tests
pub fn run(
    arenalloc: std.mem.Allocator,
    io: std.Io,
    args: anytype,
) RunError!void {
    ErrorReporter.init_singleton(arenalloc, io, args.htmlerror);

    const cwd_dir = try filex.safeopen_dir(io, null, args.cwd);
    defer filex.safeclose_dir(io, cwd_dir);

    const in_file = try filex.safeopen(io, cwd_dir, args.in);
    // normally closed through preprocessor
    errdefer filex.safeclose(io, in_file);

    const out_file = try filex.safeopen(io, cwd_dir, args.out);
    defer filex.safeclose(io, out_file);

    ErrorReporter.set_out_file(out_file);

    const preprocessed_text: []const u8 = try Preprocessor.preprocess(
        arenalloc,
        io,
        cwd_dir,
        in_file,
    );

    if (args.debug) std.debug.print("Preprocessed text: {s}\n", .{preprocessed_text});

    var parser = Parser.init(
        arenalloc,
        io,
        preprocessed_text,
        out_file,
        args.htmlerror,
    );

    ErrorReporter.set_parser(&parser);

    try parser.build_nodes();

    if (args.debug) parser.debug_print();

    var generator = Generator.init(
        arenalloc,
        io,
        preprocessed_text,
        parser.l0nodes,
        parser.l1nodes,
        out_file,
        args.htmlerror,
    );

    generator.print_out();
}
