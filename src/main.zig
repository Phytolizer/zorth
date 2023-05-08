const std = @import("std");
const Op = @import("ops.zig").Op;
const simulateProgram = @import("sim.zig").simulateProgram;
const compileProgram = @import("com.zig").compileProgram;
const cmd = @import("cmd.zig");

fn usage() void {
    std.debug.print(
        \\Usage: porth <SUBCOMMAND> [ARGS]
        \\SUBCOMMANDS:
        \\  sim             Simulate the program
        \\  com             Compile the program
        \\
    , .{});
}

fn run() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len == 1) {
        usage();
        std.debug.print("ERROR: no subcommand provided\n", .{});
        return error.Usage;
    }

    const subcommand = args[1];

    const program = [_]Op{
        .{ .push = 34 },
        .{ .push = 35 },
        .plus,
        .dump,
        .{ .push = 500 },
        .{ .push = 80 },
        .minus,
        .dump,
    };

    if (std.mem.eql(u8, subcommand, "sim")) {
        try simulateProgram(gpa, &program);
    } else if (std.mem.eql(u8, subcommand, "com")) {
        try compileProgram(&program, "output.asm");
        try cmd.callCmd(gpa, &.{ "nasm", "-felf64", "output.asm" });
        try cmd.callCmd(gpa, &.{ "ld", "-o", "output", "output.o" });
    } else {
        usage();
        std.debug.print("ERROR: unknown subcommand {s}\n", .{subcommand});
        return error.Usage;
    }
}

pub fn main() void {
    run() catch std.process.exit(1);
}
