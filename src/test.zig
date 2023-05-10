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
        "{s}.expected.bin",
        .{path_mod.withoutExtension(path)},
    );
}

const Expectation = struct {
    returncode: u8,
    output: []const u8,
    err: []const u8,

    pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        gpa.free(self.output);
        gpa.free(self.err);
    }
};

fn readExpected(gpa: std.mem.Allocator, path: []const u8) !Expectation {
    const file = std.fs.cwd().openFile(path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.print("File {s} not found. Please record it.\n", .{path});
            return e;
        },
        else => return e,
    };
    defer file.close();
    const in = file.reader();

    const returncode = try in.readByte();
    const output_length = @intCast(usize, try in.readIntLittle(u64));
    const output = try gpa.alloc(u8, output_length);
    const nread = try in.readAll(output);
    if (nread != output_length)
        std.debug.panic(
            "invalid format, expected {d} bytes but got {d}\n",
            .{ output_length, nread },
        );
    const err_length = @intCast(usize, try in.readIntLittle(u64));
    const err = try gpa.alloc(u8, err_length);
    const nread_err = try in.readAll(err);
    if (nread_err != err_length)
        std.debug.panic(
            "invalid format, expected {d} bytes but got {d}\n",
            .{ err_length, nread },
        );
    return Expectation{
        .returncode = returncode,
        .output = output,
        .err = err,
    };
}

fn runTest(gpa: std.mem.Allocator, path: []const u8, _: void) TestError!void {
    std.debug.print("[INFO] Testing {s}\n", .{path});

    const bin_path = try expectedPath(gpa, path);
    defer gpa.free(bin_path);
    const expected = try readExpected(gpa, bin_path);
    defer expected.deinit(gpa);

    var sim_out_buf = std.ArrayList(u8).init(gpa);
    defer sim_out_buf.deinit();
    const sim_out = sim_out_buf.writer();
    var sim_err_buf = std.ArrayList(u8).init(gpa);
    defer sim_err_buf.deinit();
    const sim_err = sim_err_buf.writer();
    const sim_cmd = [_][]const u8{ "porth", "sim", path };
    std.debug.print("[CMD]", .{});
    cmd.printQuoted(&sim_cmd);
    std.debug.print("\n", .{});
    const sim_code = driver.run(gpa, &sim_cmd, sim_err, sim_out) catch 1;

    var sim_fail = false;
    if (!(std.mem.eql(u8, sim_out_buf.items, expected.output) and
        std.mem.eql(u8, sim_err_buf.items, expected.err) and
        sim_code == expected.returncode))
    {
        std.debug.print(
            \\[ERROR] Unexpected simulation output
            \\  Expected:
            \\    return code: {d}
            \\    stdout: {s}
            \\    stderr: {s}
            \\  Simulation output:
            \\    return code: {d}
            \\    stdout: {s}
            \\    stderr: {s}
            \\
        , .{
            expected.returncode,
            expected.output,
            expected.err,
            sim_code,
            sim_out_buf.items,
            sim_err_buf.items,
        });
        sim_fail = true;
    }

    var com_out_buf = std.ArrayList(u8).init(gpa);
    defer com_out_buf.deinit();
    const com_out = com_out_buf.writer();
    var com_err_buf = std.ArrayList(u8).init(gpa);
    defer com_err_buf.deinit();
    const com_err = com_err_buf.writer();
    const com_cmd = [_][]const u8{ "porth", "com", "-s", "-r", path };
    std.debug.print("[CMD]", .{});
    cmd.printQuoted(&com_cmd);
    std.debug.print("\n", .{});
    const com_code = driver.run(gpa, &com_cmd, com_err, com_out) catch 1;

    if (!(std.mem.eql(u8, com_out_buf.items, expected.output) and
        std.mem.eql(u8, com_err_buf.items, expected.err) and
        com_code == expected.returncode))
    {
        std.debug.print(
            \\[ERROR] Unexpected compilation output
            \\  Expected:
            \\    return code: {d}
            \\    stdout: {s}
            \\    stderr: {s}
            \\  compilation output:
            \\    return code: {d}
            \\    stdout: {s}
            \\    stderr: {s}
            \\
        , .{
            expected.returncode,
            expected.output,
            expected.err,
            com_code,
            com_out_buf.items,
            com_err_buf.items,
        });
        return if (sim_fail) error.BothFail else error.ComFail;
    }
    if (sim_fail) return error.SimFail;
}

fn writeExpected(path: []const u8, expected: Expectation) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    const out = file.writer();

    try out.writeByte(expected.returncode);
    try out.writeIntLittle(u64, @intCast(u64, expected.output.len));
    try out.writeAll(expected.output);
    try out.writeIntLittle(u64, @intCast(u64, expected.err.len));
    try out.writeAll(expected.err);
}

const RecordMode = enum { sim, com };

fn record(gpa: std.mem.Allocator, path: []const u8, mode: RecordMode) TestError!void {
    var out_buf = std.ArrayList(u8).init(gpa);
    defer out_buf.deinit();
    const out = out_buf.writer();
    var err_buf = std.ArrayList(u8).init(gpa);
    defer err_buf.deinit();
    const err = err_buf.writer();
    const run_cmd = switch (mode) {
        .sim => &[_][]const u8{ "porth", "sim", path },
        .com => &[_][]const u8{ "porth", "com", "-s", "-r", path },
    };
    std.debug.print("[CMD]", .{});
    cmd.printQuoted(run_cmd);
    std.debug.print("\n", .{});
    const code = driver.run(gpa, run_cmd, err, out) catch 1;
    const bin_path = try expectedPath(gpa, path);
    defer gpa.free(bin_path);
    std.debug.print("[INFO] Saving output to {s}\n", .{bin_path});
    try writeExpected(bin_path, .{
        .returncode = code,
        .output = out_buf.items,
        .err = err_buf.items,
    });
}

fn walkTests(
    gpa: std.mem.Allocator,
    folder: []const u8,
    arg: anytype,
    comptime f: fn (std.mem.Allocator, []const u8, @TypeOf(arg)) TestError!void,
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
            f(gpa, full_path, arg) catch |e| switch (e) {
                error.SimFail => sim_failed += 1,
                error.ComFail => com_failed += 1,
                else => return e,
            };
        };

    if (@TypeOf(f) == @TypeOf(runTest)) {
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
        \\  record [-com]   Update the expected output. (Use compiled mode if `-com`.)
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

    if (std.mem.eql(u8, subcmd, "record")) {
        var mode = RecordMode.sim;
        while (shift(&argp)) |arg| {
            if (std.mem.eql(u8, arg, "-com")) {
                mode = .com;
            } else {
                usage(stderr, exe_name) catch unreachable;
                std.debug.print("[ERROR] unknown flag '{s}'\n", .{arg});
                return error.usage;
            }
        }
        try walkTests(gpa, folder, mode, record);
    } else if (std.mem.eql(u8, subcmd, "test"))
        try walkTests(gpa, folder, {}, runTest)
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
