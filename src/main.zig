const std = @import("std");
const Op = @import("ops.zig").Op;
const sim = @import("sim.zig");
const com = @import("com.zig");
const cmd = @import("cmd.zig");
const parse = @import("parse.zig");

fn usage(out: anytype, program: []const u8) void {
    out.print(
        \\Usage: {s} <SUBCOMMAND> [ARGS]
        \\SUBCOMMANDS:
        \\  sim <file>              Simulate the program
        \\  com [OPTIONS] <file>    Compile the program
        \\  OPTIONS:
        \\    -r                    Run program after compilation
        \\    -o <file|dir>         Set the output path
        \\  help                    Show this help
        \\
    , .{program}) catch {};
}

fn shift(args: *[]const []const u8) ?[]const u8 {
    if (args.len == 0) return null;

    const result = args.*[0];
    args.* = args.*[1..];
    return result;
}

fn run() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var argp = args;
    const program_name = shift(&argp) orelse unreachable;

    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    const subcommand = shift(&argp) orelse {
        usage(stderr, program_name);
        std.debug.print("ERROR: no subcommand provided\n", .{});
        return error.Usage;
    };

    if (std.mem.eql(u8, subcommand, "sim")) {
        const file_path = shift(&argp) orelse {
            usage(stderr, program_name);
            std.debug.print("ERROR: no input file\n", .{});
            return error.Usage;
        };
        const program = try parse.loadProgramFromFile(gpa, file_path);
        defer gpa.free(program);
        try sim.simulateProgram(gpa, program);
    } else if (std.mem.eql(u8, subcommand, "com")) {
        var run_flag = false;
        var file_path_arg: ?[]const u8 = null;
        var out_path_arg: ?[]const u8 = null;
        while (shift(&argp)) |arg| {
            if (std.mem.eql(u8, arg, "-r")) {
                run_flag = true;
            } else if (std.mem.eql(u8, arg, "-o")) {
                out_path_arg = shift(&argp) orelse {
                    usage(stderr, program_name);
                    std.debug.print("ERROR: no argument to -o\n", .{});
                    return error.Usage;
                };
            } else {
                file_path_arg = arg;
                break;
            }
        }
        const file_path = file_path_arg orelse {
            usage(stderr, program_name);
            std.debug.print("ERROR: no input file\n", .{});
            return error.Usage;
        };
        const program = try parse.loadProgramFromFile(gpa, file_path);
        defer gpa.free(program);
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
            const basename_len = @ptrToInt(path.extension(op).ptr) - @ptrToInt(op.ptr);
            break :blk op[0..basename_len];
        } else blk: {
            const basename_len = @ptrToInt(path.extension(file_path).ptr) - @ptrToInt(file_path.ptr);
            break :blk file_path[0..basename_len];
        };
        defer if (basename_alloc) gpa.free(basename);
        const asm_path = try std.fmt.allocPrint(gpa, "{s}.asm", .{basename});
        defer gpa.free(asm_path);
        std.debug.print("[INFO] Generating {s}\n", .{asm_path});
        try com.compileProgram(program, asm_path);
        try cmd.callCmd(gpa, &.{ "nasm", "-felf64", asm_path });
        const obj_path = try std.fmt.allocPrint(gpa, "{s}.o", .{basename});
        defer gpa.free(obj_path);
        try cmd.callCmd(gpa, &.{ "ld", "-o", basename, obj_path });
        if (run_flag) {
            const relpath = try path.join(gpa, &.{ ".", basename });
            defer gpa.free(relpath);
            try cmd.callCmd(gpa, &.{relpath});
        }
    } else if (std.mem.eql(u8, subcommand, "help")) {
        usage(stdout, program_name);
    } else {
        usage(stderr, program_name);
        std.debug.print("ERROR: unknown subcommand {s}\n", .{subcommand});
        return error.Usage;
    }
}

pub fn main() void {
    run() catch std.process.exit(1);
}
