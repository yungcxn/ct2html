const std = @import("std");
const filex = @import("filex.zig");
const argx = @import("argx.zig");
const Preprocessor = @import("input/Preprocessor.zig");
const Parser = @import("input/Parser.zig");
const Rule = @import("element/Rule.zig");
const l0_rules = @import("input/l0_rules.zig");
const l1_rules = @import("input/l1_rules.zig");
const html_rules = @import("output/html_rules.zig");
const Generator = @import("output/Generator.zig");
const ErrorReporter = @import("ErrorReporter.zig");
const crash = ErrorReporter.crash;
const file_report = ErrorReporter.file_report;
const throw = ErrorReporter.throw;
const webserver = @import("webserver.zig");

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
};

pub fn main(init: std.process.Init) void {
    const io = init.io;
    const alloc = init.gpa;

    const argslice = init.minimal.args.toSlice(
        alloc,
    ) catch |err| ErrorReporter.crash(err);
    defer alloc.free(argslice);

    const env_vars = init.minimal.environ.createMap(
        alloc,
    ) catch |err| ErrorReporter.crash(err);
    defer env_vars.deinit();

    const args = argx.parse(argdef, argslice, env_vars);

    const cwd = filex.open_dir(io, null, args.cwd) catch |err| {
        std.log.err("Failed to open cwd directory: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer filex.close_dir(io, cwd);

    const l0_rule_datatable: Rule.DataTable(Rule.L0Def.RuleInfo) = .init(alloc, l0_rules.rule_defs);
    defer l0_rule_datatable.deinit(alloc);
    const l1_rule_datatable: Rule.DataTable(Rule.L1Def.RuleInfo) = .init(alloc, l1_rules.rule_defs);
    defer l1_rule_datatable.deinit(alloc);
    const html_gen_rule_datatable: Rule.DataTable(Rule.GenDef.RuleInfo) = .init(alloc, html_rules.rule_defs);
    defer html_gen_rule_datatable.deinit(alloc);

    if (args.webservermode) {
        webserver.set_resp_body_constructor(&generate_response);
        webserver.run(std.heap.smp_allocator, io, cwd);
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
        errdefer filex.close(io, in_file); // closed in preprocessor

        const out_file = filex.create(io, cwd, args.out) catch |err| {
            std.log.err("Failed to open output file: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
        defer filex.close(io, out_file);

        run(
            alloc,
            io,
            false,
            cwd,
            in_file,
            out_file,
            args.htmlerror,
            args.responsemode,
            args.debug,
        ) catch {}; // error is printed into the output file
    }
}

pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    comptime pass_buf: bool,
    cwd: std.Io.Dir,
    in_file: std.Io.File,
    out_file: ?std.Io.File,
    l0_rule_datatable: Rule.DataTable(Rule.L0Def.RuleInfo),
    l1_rule_datatable: Rule.DataTable(Rule.L1Def.RuleInfo),
    html_gen_rule_datatable: Rule.DataTable(Rule.GenDef.RuleInfo),
    htmlerror: bool,
    responsemode: bool,
    debug: bool,
) if (pass_buf) []const u8 else RunError!void {
    var error_reporter = ErrorReporter.init(alloc, io, htmlerror, responsemode);

    // this allocates the preprocessed text []const u8
    const preprocessed_text: []const u8 = Preprocessor.preprocess(
        alloc,
        io,
        &error_reporter,
        cwd,
        in_file,
    ) catch |filewalkerr| {
        if (error_reporter.err_reported) {
            if (comptime pass_buf) {
                return error_reporter.outbuf.to_slice();
            } else {
                out_file.?.writeStreamingAll(
                    io,
                    error_reporter.outbuf.to_slice(),
                ) catch |err| crash(err);
                return filewalkerr;
            }
        } else crash(error.ThrowWithoutReport);
    };
    defer alloc.free(preprocessed_text);

    if (debug) std.debug.print("Preprocessed text: {s}\n", .{preprocessed_text});

    // this allocates the l0nodes and l1nodes dynbufs only, which get removed
    // when deiniting
    var parser = Parser.init(
        alloc,
        io,
        &error_reporter,
        preprocessed_text,
        l0_rule_datatable,
        l1_rule_datatable,
        htmlerror,
    );
    defer parser.deinit();

    error_reporter.set_parser(&parser);

    parser.build_nodes() catch |parserr| {
        if (error_reporter.err_reported) {
            if (comptime pass_buf) {
                return error_reporter.outbuf.to_slice();
            } else {
                out_file.?.writeStreamingAll(
                    io,
                    error_reporter.outbuf.to_slice(),
                ) catch |err| crash(err);
                return parserr;
            }
        } else crash(error.ThrowWithoutReport);
    };

    if (debug) parser.debug_print();

    // is not defered since only the buffer from the generated HTML file is alloc'd
    var generator = Generator.init(
        alloc,
        io,
        &error_reporter,
        preprocessed_text,
        parser.l0nodes,
        parser.l1nodes,
        html_gen_rule_datatable,
        htmlerror,
        responsemode,
    );

    // `Generator` only allocates the buffer behind `outbuf`
    // Caller owns `outbuf`, and nothing else remains on heap (if `pass_buf`)
    const outbuf = generator.generate_out() catch |generr| {
        if (error_reporter.err_reported) {
            if (comptime pass_buf) {
                return error_reporter.outbuf.to_slice();
            } else {
                out_file.?.writeStreamingAll(
                    io,
                    error_reporter.outbuf.to_slice(),
                ) catch |err| crash(err);
                return generr;
            }
        } else crash(error.ThrowWithoutReport);
    };

    if (comptime pass_buf) {
        return outbuf;
    } else {
        out_file.?.writeStreamingAll(
            io,
            outbuf,
        ) catch |err| crash(err);
        alloc.free(outbuf);
    }
}

fn generate_response(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    path: []const u8,
) error{FileNotFound}![]const u8 {
    std.log.info("requested: {s}", .{path});
    if (!std.mem.endsWith(u8, path, ".ct")) {
        return error.FileNotFound;
    }

    var path2 = path;
    if (path[0] == '/') path2 = path[1..]; // remove leading slash

    const in_file = filex.open(io, cwd, path2) catch return error.FileNotFound;

    // run and build generator.outbuf, but on some user-induced error, throw
    // without exiting to fill the outbuf of the error reporter.
    return run(alloc, io, true, cwd, in_file, null, true, false, false);
}
