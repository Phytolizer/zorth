const std = @import("std");

const Op = union(enum) {
    PUSH: i64,
    PLUS,
    MINUS,
    DUMP,
};
const COUNT_OPS = @typeInfo(Op).Union.fields.len;

var a: std.mem.Allocator = undefined;

const PROGRAM = [_]Op{
    .{ .PUSH = 34 },
    .{ .PUSH = 35 },
    .PLUS,
    .DUMP,
    .{ .PUSH = 500 },
    .{ .PUSH = 80 },
    .MINUS,
    .DUMP,
};

fn notImplemented() noreturn {
    std.log.err("not implemented", .{});
    unreachable;
}

fn pop(stack: anytype) !@typeInfo(@TypeOf(stack.items)).Pointer.child {
    comptime switch (@typeInfo(@TypeOf(stack))) {
        .Pointer => |p| {
            std.debug.assert(p.size == .One);
            std.debug.assert(!p.is_const);
        },
        else => unreachable,
    };
    return stack.popOrNull() orelse return error.StackUnderflow;
}

fn simulateProgram(program: []const Op) !void {
    var stack = std.ArrayList(i64).init(a);
    for (program) |op| {
        switch (op) {
            .PUSH => |x| {
                try stack.append(x);
            },
            .PLUS => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(x + y);
            },
            .MINUS => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(x - y);
            },
            .DUMP => {
                const x = try pop(&stack);
                std.debug.print("{d}\n", .{x});
            },
        }
    }
}

fn compileProgram(program: []const Op) !void {
    _ = program;
}

pub fn main() void {
    run() catch std.process.exit(1);
}

fn usage(program_name: []const u8) void {
    std.debug.print(
        \\Usage: {s} <SUBCOMMAND> [ARGS]
        \\SUBCOMMANDS:
        \\    sim           Simulate the program
        \\    com           Compile the program
        \\
    , .{program_name});
}

fn streq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);

    if (args.len < 2) {
        usage(args[0]);
        std.log.err("no subcommand provided", .{});
        return error.Usage;
    }

    const subcommand = args[1];
    if (streq(subcommand, "sim")) {
        try simulateProgram(&PROGRAM);
    } else if (streq(subcommand, "com")) {
        try compileProgram(&PROGRAM);
    } else {
        usage(args[0]);
        std.log.err("unknown subcommand '{s}'", .{subcommand});
        return error.Usage;
    }
}
