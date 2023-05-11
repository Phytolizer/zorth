const std = @import("std");
const Op = @import("Op.zig");
const sim = @import("sim.zig");
const com = @import("com.zig");
const cmd = @import("porth-cmd");
const shift = @import("porth-args").shift;
const path_mod = @import("porth-path");
const parse = @import("parse.zig");

fn usage(out: anytype, program: []const u8) void {
    out.print(
        \\Usage: {s} [OPTIONS] <SUBCOMMAND> [ARGS]
        \\OPTIONS:
        \\  -I <path>               Add to the include search path
        \\  -E <expansion-limit>    Set the expansion limit for include/macro (default {d})
        \\SUBCOMMANDS:
        \\  sim <file>              Simulate the program
        \\  com [OPTIONS] <file>    Compile the program
        \\  OPTIONS:
        \\    -r                    Run program after compilation
        \\    -o <file|dir>         Set the output path
        \\    -s                    Silent mode; don't print log messages
        \\  help                    Show this help
        \\
    , .{ program, @import("opts").expansion_limit }) catch {};
}

pub const Error = error{Usage} ||
    parse.Error ||
    std.fmt.ParseIntError ||
    std.fs.File.WriteError ||
    std.ChildProcess.SpawnError ||
    cmd.CallError;

const builtin_include_paths = &[_][]const u8{
    ".",
    std.fmt.comptimePrint(".{c}std", .{std.fs.path.sep}),
};

pub fn run(
    gpa: std.mem.Allocator,
    args: []const []const u8,
    stdin: anytype,
    stderr: anytype,
    stdout: anytype,
) Error!u8 {
    var argp = args;
    const program_name = shift(&argp) orelse unreachable;

    var include_paths = try std.ArrayList([]const u8).initCapacity(gpa, builtin_include_paths.len);
    defer include_paths.deinit();
    include_paths.appendSliceAssumeCapacity(builtin_include_paths);

    var expansion_limit = @import("opts").expansion_limit;
    var subcommand_arg: ?[]const u8 = null;
    while (shift(&argp)) |arg| {
        if (std.mem.eql(u8, arg, "-I")) {
            const path = shift(&argp) orelse {
                usage(stderr, program_name);
                stderr.print("[ERROR] no argument provided for -I\n", .{}) catch unreachable;
                return error.Usage;
            };
            try include_paths.append(path);
        } else if (std.mem.eql(u8, arg, "-E")) {
            const new_limit = shift(&argp) orelse {
                usage(stderr, program_name);
                stderr.print("[ERROR] no argument provided for -E\n", .{}) catch unreachable;
                return error.Usage;
            };
            expansion_limit = try std.fmt.parseInt(usize, new_limit, 10);
        } else {
            subcommand_arg = arg;
            break;
        }
    }

    const subcommand = subcommand_arg orelse {
        usage(stderr, program_name);
        stderr.print("[ERROR] no subcommand provided\n", .{}) catch unreachable;
        return error.Usage;
    };

    if (std.mem.eql(u8, subcommand, "sim")) {
        const file_path = shift(&argp) orelse {
            usage(stderr, program_name);
            stderr.print("[ERROR] no input file\n", .{}) catch unreachable;
            return error.Usage;
        };
        const program = try parse.loadProgramFromFile(
            gpa,
            file_path,
            include_paths.items,
            expansion_limit,
            stderr,
        );
        defer program.deinit(gpa);
        const porth_args = try gpa.alloc([]const u8, argp.len + 1);
        defer gpa.free(porth_args);
        porth_args[0] = program_name;
        std.mem.copy([]const u8, porth_args[1..], argp);
        defer gpa.free(porth_args);
        try sim.simulateProgram(
            gpa,
            program.items,
            porth_args,
            stdin,
            stderr,
            stdout,
        );
    } else if (std.mem.eql(u8, subcommand, "com")) {
        var run_flag = false;
        var silent_flag = false;
        var file_path_arg: ?[]const u8 = null;
        var out_path_arg: ?[]const u8 = null;
        while (shift(&argp)) |arg| {
            if (std.mem.eql(u8, arg, "-r")) {
                run_flag = true;
            } else if (std.mem.eql(u8, arg, "-s")) {
                silent_flag = true;
            } else if (std.mem.eql(u8, arg, "-o")) {
                out_path_arg = shift(&argp) orelse {
                    usage(stderr, program_name);
                    stderr.print("[ERROR] no argument to -o\n", .{}) catch unreachable;
                    return error.Usage;
                };
            } else {
                file_path_arg = arg;
                break;
            }
        }
        const file_path = file_path_arg orelse {
            usage(stderr, program_name);
            stderr.print("[ERROR] no input file\n", .{}) catch unreachable;
            return error.Usage;
        };
        const program = try parse.loadProgramFromFile(
            gpa,
            file_path,
            include_paths.items,
            expansion_limit,
            stderr,
        );
        defer program.deinit(gpa);
        const path = std.fs.path;
        var basename_alloc = false;
        const basename = if (out_path_arg) |op| blk: {
            const is_dir = if (std.fs.cwd().statFile(op)) |st|
                st.kind == .Directory
            else |_|
                false;
            if (is_dir) {
                const name = path.stem(file_path);
                const dir = path.dirname(op) orelse ".";
                basename_alloc = true;
                break :blk try std.fmt.allocPrint(
                    gpa,
                    "{s}{c}{s}",
                    .{ dir, path.sep, name },
                );
            }
            break :blk path_mod.withoutExtension(op);
        } else path_mod.withoutExtension(file_path);
        defer if (basename_alloc) gpa.free(basename);
        const asm_path = try std.fmt.allocPrint(gpa, "{s}.asm", .{basename});
        defer gpa.free(asm_path);
        if (!silent_flag)
            stderr.print("[INFO] Generating {s}\n", .{asm_path}) catch unreachable;
        try com.compileProgram(gpa, program.items, asm_path);
        try cmd.callCmd(gpa, &.{ "nasm", "-felf64", asm_path }, .{ .silent = silent_flag });
        const obj_path = try std.fmt.allocPrint(gpa, "{s}.o", .{basename});
        defer gpa.free(obj_path);
        try cmd.callCmd(gpa, &.{ "ld", "-o", basename, obj_path }, .{ .silent = silent_flag });
        if (run_flag) {
            const relpath = try path.join(gpa, &.{ ".", basename });
            defer gpa.free(relpath);
            const run_args = try std.mem.concat(gpa, []const u8, &.{ &.{relpath}, argp });
            defer gpa.free(run_args);
            return try cmd.captureCmd(
                gpa,
                run_args,
                stdout,
                .{ .stdin = stdin, .silent = silent_flag },
            );
        }
    } else if (std.mem.eql(u8, subcommand, "help")) {
        usage(stdout, program_name);
    } else {
        usage(stderr, program_name);
        stderr.print("[ERROR] unknown subcommand {s}\n", .{subcommand}) catch unreachable;
        return error.Usage;
    }
    return 0;
}
