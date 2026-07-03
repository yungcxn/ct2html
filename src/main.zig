const std = @import("std");
const filex = @import("filex.zig");
const argx = @import("argx.zig");
const Preprocessor = @import("input/Preprocessor.zig");
const Parser = @import("input/Parser.zig");
const Generator = @import("output/Generator.zig");
const ErrorReporter = @import("ErrorReporter.zig");

var manualloc: std.mem.Allocator = undefined;
var arena: std.heap.ArenaAllocator = undefined;
var io: std.Io = undefined;

const argdef = .{
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
    io = init.io;
    manualloc = init.gpa;
    arena = std.heap.ArenaAllocator.init(manualloc);
    defer arena.deinit();

    const argslice = init.minimal.args.toSlice(
        arena.allocator(),
    ) catch |err| ErrorReporter.crash(err);

    const args = argx.parse(argdef, argslice);

    const in_file = filex.safeopen(io, args.in);
    defer filex.close(io, in_file);

    const out_file = filex.safeopen(io, args.out);
    defer filex.close(io, out_file);

    // const text: []u8 = filex.alloc_filetext(
    //     arena.allocator(),
    //     io,
    //     in_file,
    // ) catch |err| ErrorReporter.crash(err);

    const preprocessed_text: []const u8 = Preprocessor.walk_and_merge(
        arena.allocator(),
        io,
        in_file,
    ) catch |err| ErrorReporter.crash(err);

    var parser = Parser.init(
        arena.allocator(),
        io,
        preprocessed_text,
        out_file,
        args.htmlerror,
    ) catch |err| ErrorReporter.crash(err);

    ErrorReporter.init_singleton(io, &parser, out_file, args.htmlerror);

    parser.build_nodes();
    if (args.debug) parser.debug_print();

    var generator = Generator.init(
        arena.allocator(),
        io,
        preprocessed_text,
        parser.l0nodes,
        parser.l1nodes,
        out_file,
        args.htmlerror,
    ) catch |err| ErrorReporter.crash(err);
    defer generator.deinit();

    generator.print_out();
}
