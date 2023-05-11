const std = @import("std");
const cmd = @import("porth-cmd");
const shift = @import("porth-args").shift;
const driver = @import("porth-driver");
const path_mod = @import("porth-path");

const TestError = error{ SimFail, ComFail, BothFail, TestFail } ||
    std.mem.Allocator.Error ||
    std.ChildProcess.SpawnError ||
    std.fmt.ParseIntError ||
    driver.Error ||
    error{Unseekable};

fn expectedPath(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(
        gpa,
        "{s}.expected.txt",
        .{path_mod.withoutExtension(path)},
    );
}

const Expectation = struct {
    args: []const []const u8,
    returncode: u8,
    in: []const u8,
    output: []const u8,
    err: []const u8,
};

const FieldKind = enum {
    int,
    blob,
    pub fn text(comptime self: @This()) []const u8 {
        return switch (self) {
            .int => "i",
            .blob => "b",
        };
    }
    pub fn Type(comptime self: @This()) type {
        return switch (self) {
            .int => usize,
            .blob => []const u8,
        };
    }
};

fn readField(
    in: std.fs.File.Reader,
    gpa: std.mem.Allocator,
    comptime kind: FieldKind,
    field_name: []const u8,
) !kind.Type() {
    const line = (try in.readUntilDelimiterOrEofAlloc(gpa, '\n', std.math.maxInt(usize))).?;
    const field = try std.fmt.allocPrint(
        gpa,
        ":" ++ comptime kind.text() ++ " {s} ",
        .{field_name},
    );
    if (!std.mem.startsWith(u8, line, field)) {
        std.debug.panic("illegal line '{'}'\n", .{std.zig.fmtEscapes(line)});
    }
    const text = line[field.len..];
    switch (kind) {
        .int => return try std.fmt.parseInt(kind.Type(), text, 10),
        .blob => {
            const length = try std.fmt.parseInt(usize, text, 10);
            const result = try gpa.alloc(u8, length);
            const nread = try in.readAll(result);
            if (nread != length)
                std.debug.panic(
                    "invalid format, expected {d} bytes but got {d}\n",
                    .{ length, nread },
                );
            if (try in.readByte() != '\n') std.debug.panic("missing newline", .{});
            return result;
        },
    }
}

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

    const returncode = @intCast(u8, try readField(in, gpa, .int, "returncode"));
    const argc = try readField(in, gpa, .int, "argc");
    var args = try std.ArrayList([]const u8).initCapacity(gpa, argc);
    for (0..argc) |i| {
        args.appendAssumeCapacity(try readField(
            in,
            gpa,
            .blob,
            try std.fmt.allocPrint(gpa, "arg{d}", .{i}),
        ));
    }
    const stdin = try readField(in, gpa, .blob, "stdin");
    const output = try readField(in, gpa, .blob, "stdout");
    const err = try readField(in, gpa, .blob, "stderr");
    return Expectation{
        .args = try args.toOwnedSlice(),
        .returncode = returncode,
        .in = stdin,
        .output = output,
        .err = err,
    };
}

fn simCmd(folder: []const u8, path: []const u8) [5][]const u8 {
    return [_][]const u8{ "porth", "-I", folder, "sim", path };
}

fn comCmd(folder: []const u8, path: []const u8) [7][]const u8 {
    return [_][]const u8{ "porth", "-I", folder, "com", "-s", "-r", path };
}

fn runTest(
    gpa: std.mem.Allocator,
    folder: []const u8,
    path: []const u8,
    _: void,
) TestError!void {
    std.debug.print("[INFO] Testing {s}\n", .{path});

    const expected_path = try expectedPath(gpa, path);
    const expected = try readExpected(gpa, expected_path);

    var sim_out_buf = std.ArrayList(u8).init(gpa);
    const sim_out = sim_out_buf.writer();
    var sim_err_buf = std.ArrayList(u8).init(gpa);
    const sim_err = sim_err_buf.writer();
    const sim_cmd = simCmd(folder, try gpa.dupe(u8, path));
    std.debug.print("[CMD]", .{});
    cmd.printQuoted(&sim_cmd);
    std.debug.print("\n", .{});
    var sim_in = std.io.fixedBufferStream(expected.in);
    const sim_code = driver.run(
        gpa,
        &sim_cmd,
        sim_in.reader(),
        sim_err,
        sim_out,
    ) catch 1;

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
    const com_out = com_out_buf.writer();
    var com_err_buf = std.ArrayList(u8).init(gpa);
    const com_err = com_err_buf.writer();
    const com_cmd = comCmd(folder, path);
    std.debug.print("[CMD]", .{});
    cmd.printQuoted(&com_cmd);
    std.debug.print("\n", .{});
    var com_in = std.io.fixedBufferStream(expected.in);
    const com_code = driver.run(gpa, &com_cmd, com_in.reader(), com_err, com_out) catch 1;

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

fn writeField(
    out: anytype,
    comptime kind: FieldKind,
    field_name: []const u8,
    value: kind.Type(),
) !void {
    switch (kind) {
        .int => try out.print(":i {s} {d}\n", .{ field_name, value }),
        .blob => try out.print(":b {s} {d}\n{s}\n", .{ field_name, value.len, value }),
    }
}

fn writeExpected(gpa: std.mem.Allocator, path: []const u8, expected: Expectation) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    const out = file.writer();

    try writeField(out, .int, "returncode", expected.returncode);
    try writeField(out, .int, "argc", expected.args.len);
    for (expected.args, 0..) |arg, i| {
        try writeField(
            out,
            .blob,
            try std.fmt.allocPrint(gpa, "arg{d}", .{i}),
            arg,
        );
    }
    try writeField(out, .blob, "stdin", expected.in);
    try writeField(out, .blob, "stdout", expected.output);
    try writeField(out, .blob, "stderr", expected.err);
}

const RecordOpts = struct {
    mode: Mode,
    args: []const []const u8 = &.{},
    in: []const u8 = "",

    pub const Mode = enum { sim, com };
};

fn record(
    gpa: std.mem.Allocator,
    folder: []const u8,
    path: []const u8,
    opts: RecordOpts,
) TestError!void {
    var out_buf = std.ArrayList(u8).init(gpa);
    const out = out_buf.writer();
    var err_buf = std.ArrayList(u8).init(gpa);
    const err = err_buf.writer();
    const run_cmd = switch (opts.mode) {
        .sim => blk: {
            const base = simCmd(folder, try gpa.dupe(u8, path));
            break :blk try std.mem.concat(
                gpa,
                []const u8,
                &[_][]const []const u8{ &base, opts.args },
            );
        },
        .com => blk: {
            const base = comCmd(folder, try gpa.dupe(u8, path));
            break :blk try std.mem.concat(
                gpa,
                []const u8,
                &[_][]const []const u8{ &base, opts.args },
            );
        },
    };
    std.debug.print("[CMD]", .{});
    cmd.printQuoted(run_cmd);
    std.debug.print("\n", .{});
    var stdin = std.io.fixedBufferStream(opts.in);
    const code = driver.run(
        gpa,
        run_cmd,
        stdin.reader(),
        err,
        out,
    ) catch 1;
    const expected_path = try expectedPath(gpa, path);
    std.debug.print("[INFO] Saving output to {s}\n", .{expected_path});
    try writeExpected(gpa, expected_path, .{
        .args = opts.args,
        .returncode = code,
        .in = &.{},
        .output = out_buf.items,
        .err = err_buf.items,
    });
}

fn walkTests(
    gpa: std.mem.Allocator,
    folder: []const u8,
    arg: anytype,
    comptime f: fn (std.mem.Allocator, []const u8, []const u8, @TypeOf(arg)) TestError!void,
) !void {
    const dir = std.fs.cwd().openIterableDir(folder, .{}) catch |e| {
        std.debug.print("failed to open 'tests': {s}\n", .{@errorName(e)});
        return e;
    };
    var walk = try dir.walk(gpa);
    const path = std.fs.path;

    var sim_failed: usize = 0;
    var com_failed: usize = 0;

    while (try walk.next()) |ent|
        if (ent.kind == .File and
            std.mem.eql(u8, path.extension(ent.basename), ".porth"))
        {
            const full_path = try path.join(gpa, &.{ folder, ent.path });
            f(gpa, folder, full_path, arg) catch |e| switch (e) {
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

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    if (std.mem.eql(u8, subcmd, "record")) {
        var mode = RecordOpts.Mode.sim;
        while (shift(&argp)) |arg| {
            if (std.mem.eql(u8, arg, "-com")) {
                mode = .com;
            } else {
                usage(stderr, exe_name) catch unreachable;
                std.debug.print("[ERROR] unknown flag '{s}'\n", .{arg});
                return error.usage;
            }
        }
        try walkTests(arena.allocator(), folder, RecordOpts{ .mode = mode }, record);
    } else if (std.mem.eql(u8, subcmd, "test"))
        try walkTests(arena.allocator(), folder, {}, runTest)
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
