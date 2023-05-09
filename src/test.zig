const std = @import("std");
const cmd = @import("porth-cmd");
const shift = @import("porth-args").shift;
const driver = @import("porth-driver");
const path_mod = @import("porth-path");

const TestError = error{ SimFail, ComFail, BothFail, TestFail } ||
    std.mem.Allocator.Error ||
    std.ChildProcess.SpawnError ||
    driver.Error ||
    error{Unseekable};

fn expectedPath(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(
        gpa,
        "{s}.expected.txt",
        .{path_mod.withoutExtension(path)},
    );
}

fn runTest(gpa: std.mem.Allocator, path: []const u8) TestError!void {
    std.debug.print("[INFO] Testing {s}\n", .{path});
    var sim_out_buf = std.ArrayList(u8).init(gpa);
    defer sim_out_buf.deinit();
    const sim_out = sim_out_buf.writer();
    const stderr = std.io.getStdErr().writer();
    const sim_cmd = [_][]const u8{ "porth", "sim", path };
    std.debug.print("[CMD]", .{});
    cmd.printQuoted(&sim_cmd);
    std.debug.print("\n", .{});
    _ = try driver.run(gpa, &sim_cmd, stderr, sim_out);

    const txt_path = try expectedPath(gpa, path);
    defer gpa.free(txt_path);
    const expected = std.fs.cwd().readFileAlloc(gpa, txt_path, std.math.maxInt(usize)) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.print("File {s} not found. Please record it.\n", .{txt_path});
            return e;
        },
        else => return e,
    };
    defer gpa.free(expected);

    var sim_fail = false;
    if (!std.mem.eql(u8, sim_out_buf.items, expected)) {
        std.debug.print(
            \\[ERROR] Unexpected simulation output
            \\  Expected:
            \\    {s}
            \\  Simulation output:
            \\    {s}
            \\
        , .{ expected, sim_out_buf.items });
        sim_fail = true;
    }
    var com_out_buf = std.ArrayList(u8).init(gpa);
    defer com_out_buf.deinit();
    const com_out = com_out_buf.writer();
    const com_cmd = [_][]const u8{ "porth", "com", "-r", path };
    std.debug.print("[CMD]", .{});
    cmd.printQuoted(&com_cmd);
    std.debug.print("\n", .{});
    _ = try driver.run(gpa, &com_cmd, stderr, com_out);

    if (!std.mem.eql(u8, com_out_buf.items, expected)) {
        std.debug.print(
            \\[ERROR] Unexpected compilation output
            \\  Expected:
            \\    {s}
            \\  Compilation output:
            \\    {s}
            \\
        , .{ expected, com_out_buf.items });
        return if (sim_fail) error.BothFail else error.ComFail;
    }
    if (sim_fail) return error.SimFail;
}

fn record(gpa: std.mem.Allocator, path: []const u8) TestError!void {
    var sim_out_buf = std.ArrayList(u8).init(gpa);
    defer sim_out_buf.deinit();
    const sim_out = sim_out_buf.writer();
    const stderr = std.io.getStdErr().writer();
    const sim_cmd = [_][]const u8{ "porth", "sim", path };
    std.debug.print("[CMD]", .{});
    cmd.printQuoted(&sim_cmd);
    std.debug.print("\n", .{});
    _ = try driver.run(gpa, &sim_cmd, stderr, sim_out);
    const txt_path = try expectedPath(gpa, path);
    defer gpa.free(txt_path);
    std.debug.print("[INFO] Saving output to {s}\n", .{txt_path});
    try std.fs.cwd().writeFile(txt_path, sim_out_buf.items);
}

fn walkTests(
    gpa: std.mem.Allocator,
    folder: []const u8,
    comptime f: fn (std.mem.Allocator, []const u8) TestError!void,
) !void {
    const dir = std.fs.cwd().openIterableDir(folder, .{}) catch |e| {
        std.debug.print("failed to open 'tests': {s}\n", .{@errorName(e)});
        return e;
    };
    var walk = try dir.walk(gpa);
    defer walk.deinit();
    const path = std.fs.path;

    var sim_failed: usize = 0;
    var com_failed: usize = 0;

    while (try walk.next()) |ent|
        if (ent.kind == .File and
            std.mem.eql(u8, path.extension(ent.basename), ".porth"))
        {
            const full_path = try path.join(gpa, &.{ folder, ent.path });
            defer gpa.free(full_path);
            f(gpa, full_path) catch |e| switch (e) {
                error.SimFail => sim_failed += 1,
                error.ComFail => com_failed += 1,
                else => return e,
            };
        };

    if (f == runTest) {
        std.debug.print(
            "Simulation failed: {d}, Compilation failed: {d}\n",
            .{ sim_failed, com_failed },
        );
        if (sim_failed +| com_failed > 0) {
            return error.TestFail;
        }
    }
}

fn usage(writer: anytype, exe_name: []const u8) !void {
    try writer.print(
        \\Usage: {s} [OPTIONS] [SUBCOMMAND]
        \\OPTIONS:
        \\  -f <folder>     Set the folder with tests. (Default ./tests)
        \\SUBCOMMANDS:
        \\  test            Run tests. (Default)
        \\  record          Update the expected output.
        \\  help            Show this help.
        \\
    , .{exe_name});
}

fn run() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 10 }){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var argp = args;

    const exe_name = shift(&argp).?;

    var folder: []const u8 = "tests";
    var subcmd: []const u8 = "test";

    const stderr = std.io.getStdErr().writer();

    while (shift(&argp)) |arg| {
        if (std.mem.eql(u8, arg, "-f")) {
            folder = shift(&argp) orelse {
                usage(stderr, exe_name) catch unreachable;
                std.debug.print("[ERROR] no argument for -f\n", .{});
                return error.Usage;
            };
        } else {
            subcmd = arg;
            break;
        }
    }

    if (std.mem.eql(u8, subcmd, "record"))
        try walkTests(gpa, folder, record)
    else if (std.mem.eql(u8, subcmd, "test"))
        try walkTests(gpa, folder, runTest)
    else if (std.mem.eql(u8, subcmd, "help"))
        try usage(std.io.getStdOut().writer(), exe_name)
    else {
        usage(stderr, exe_name) catch unreachable;
        std.debug.print("[ERROR] unknown subcommand {s}\n", .{subcmd});
        return error.Usage;
    }
}

pub fn main() void {
    run() catch std.process.exit(1);
}
