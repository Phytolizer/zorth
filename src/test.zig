const std = @import("std");
const zorth = @import("zorth");
const common = @import("common.zig");

var a: std.mem.Allocator = undefined;

fn doTest() !void {
    var sim_failed: usize = 0;
    var com_failed: usize = 0;
    var iter_dir = try std.fs.cwd().openIterableDir("tests", .{});
    var w = try iter_dir.walk(a);
    defer w.deinit();
    while (try w.next()) |ent| {
        if (ent.kind == .File and std.mem.endsWith(u8, ent.basename, ".zorth")) {
            const real_path = try iter_dir.dir.realpathAlloc(a, ent.path);
            defer a.free(real_path);
            std.log.info("Testing {s}", .{real_path});
            const without_ext = real_path[0 .. real_path.len - ".zorth".len];
            const txt_path = try std.mem.concat(a, u8, &.{ without_ext, ".txt" });
            defer a.free(txt_path);
            const expected_output = try std.fs.cwd().readFileAlloc(a, txt_path, std.math.maxInt(usize));
            defer a.free(expected_output);
            var sim_output_arr = std.ArrayList(u8).init(a);
            defer sim_output_arr.deinit();
            var sim_output = sim_output_arr.writer();
            _ = try zorth.driver(
                a,
                &.{ "zorth", "sim", real_path },
                sim_output,
                std.io.null_writer,
            );
            var com_output_arr = std.ArrayList(u8).init(a);
            defer com_output_arr.deinit();
            var com_output = com_output_arr.writer();
            _ = try zorth.driver(
                a,
                &.{ "zorth", "com", "-r", real_path },
                com_output,
                std.io.null_writer,
            );
            if (!std.mem.eql(u8, sim_output_arr.items, expected_output)) {
                std.log.err("Unexpected simulation output", .{});
                std.debug.print("Expected:\n{s}\n", .{expected_output});
                std.debug.print("Actual:\n{s}\n", .{sim_output_arr.items});
                sim_failed += 1;
            }
            if (!std.mem.eql(u8, com_output_arr.items, expected_output)) {
                std.log.err("Unexpected compilation output", .{});
                std.debug.print("Expected:\n{s}\n", .{expected_output});
                std.debug.print("Actual:\n{s}\n", .{com_output_arr.items});
                com_failed += 1;
            }
            std.log.info("OK {s}", .{real_path});
        }
    }

    std.debug.print(
        "\nfailures: {d} simulation, {d} compilation\n",
        .{ sim_failed, com_failed },
    );
    if (sim_failed + com_failed > 0) {
        return error.TestFailed;
    } else {
        std.debug.print("All OK\n", .{});
    }
}

fn doRecord() !void {
    var iter_dir = try std.fs.cwd().openIterableDir("tests", .{});
    var w = try iter_dir.walk(a);
    defer w.deinit();
    while (try w.next()) |ent| {
        if (ent.kind == .File and std.mem.endsWith(u8, ent.basename, ".zorth")) {
            const real_path = try iter_dir.dir.realpathAlloc(a, ent.path);
            defer a.free(real_path);
            std.log.info("Recording output of {s}", .{real_path});
            var sim_output_arr = std.ArrayList(u8).init(a);
            defer sim_output_arr.deinit();
            var sim_output = sim_output_arr.writer();
            _ = try zorth.driver(a, &.{ "zorth", "sim", real_path }, sim_output, std.io.null_writer);
            const without_ext = real_path[0 .. real_path.len - ".zorth".len];
            const txt_path = try std.mem.concat(a, u8, &.{ without_ext, ".txt" });
            defer a.free(txt_path);
            std.log.info("Saving output to {s}", .{txt_path});
            const f = try std.fs.createFileAbsolute(txt_path, .{});
            defer f.close();
            try f.writer().writeAll(sim_output_arr.items);
        }
    }
}

fn usage(writer: anytype, program_name: []const u8) !void {
    try writer.print(
        \\Usage: {s} [SUBCOMMAND]
        \\SUBCOMMANDS:
        \\  test            Run the tests (default)
        \\  record          Record expected output for tests
        \\  help            Print this message to stdout
        \\
    , .{program_name});
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    var i: usize = 0;
    const program_name = common.uncons(args, &i);
    if (args.len - i == 0) {
        try doTest();
    } else {
        const subcommand = common.uncons(args, &i);
        if (std.mem.eql(u8, subcommand, "record")) {
            try doRecord();
        } else if (std.mem.eql(u8, subcommand, "test")) {
            try doTest();
        } else if (std.mem.eql(u8, subcommand, "help")) {
            try usage(std.io.getStdOut().writer(), program_name);
        } else {
            try usage(std.io.getStdErr().writer(), program_name);
            std.log.err("unknown subcommand `{s}`", .{subcommand});
            return error.Usage;
        }
    }
}

pub fn main() !void {
    run() catch |e| switch (e) {
        error.Usage, error.TestFailed => std.process.exit(1),
        else => return e,
    };
}
