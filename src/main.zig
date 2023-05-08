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
        \\  com <file>              Compile the program
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
        const file_path = shift(&argp) orelse {
            usage(stderr, program_name);
            std.debug.print("ERROR: no input file\n", .{});
            return error.Usage;
        };
        const program = try parse.loadProgramFromFile(gpa, file_path);
        defer gpa.free(program);
        const path = std.fs.path;
        const basename_len = @ptrToInt(path.extension(file_path).ptr) - @ptrToInt(file_path.ptr);
        const basename = file_path[0..basename_len];
        const asm_path = try std.fmt.allocPrint(gpa, "{s}.asm", .{basename});
        defer gpa.free(asm_path);
        try com.compileProgram(program, asm_path);
        try cmd.callCmd(gpa, &.{ "nasm", "-felf64", asm_path });
        const obj_path = try std.fmt.allocPrint(gpa, "{s}.o", .{basename});
        defer gpa.free(obj_path);
        try cmd.callCmd(gpa, &.{ "ld", "-o", basename, obj_path });
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
