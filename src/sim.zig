const std = @import("std");
const Op = @import("Op.zig");
const math = @import("math.zig");

fn binaryOp(
    stack: *std.ArrayList(i64),
    comptime op: fn (comptime T: type, x: i64, y: i64) i64,
) void {
    const b = stack.pop();
    const a = stack.pop();
    stack.appendAssumeCapacity(op(i64, a, b));
}

pub fn simulateProgram(gpa: std.mem.Allocator, program: []const Op, raw_stdout: anytype) !void {
    var stack = std.ArrayList(i64).init(gpa);
    defer stack.deinit();
    var stdout_buf = std.io.bufferedWriter(raw_stdout);
    defer stdout_buf.flush() catch {};
    const stdout = stdout_buf.writer();

    var ip: usize = 0;
    while (ip < program.len) {
        const op = program[ip];
        switch (op.code) {
            .push => |x| {
                try stack.append(x);
                ip += 1;
            },
            .plus => {
                binaryOp(&stack, math.add);
                ip += 1;
            },
            .minus => {
                binaryOp(&stack, math.sub);
                ip += 1;
            },
            .equal => {
                binaryOp(&stack, math.equal);
                ip += 1;
            },
            .gt => {
                binaryOp(&stack, math.gt);
                ip += 1;
            },
            .dump => {
                const x = stack.pop();
                try stdout.print("{d}\n", .{x});
                ip += 1;
            },
            .mem => @panic("UNIMPLEMENTED"),
            .@"if", .do => |maybe_targ| {
                const targ = maybe_targ.?;
                const x = stack.pop();
                switch (x) {
                    0 => ip = targ,
                    else => ip += 1,
                }
            },
            .@"while" => {
                ip += 1;
            },
            .@"else", .end => |maybe_targ| {
                const targ = maybe_targ.?;
                ip = targ;
            },
            .dup => {
                const x = stack.pop();
                try stack.appendSlice(&.{ x, x });
                ip += 1;
            },
        }
    }
}
