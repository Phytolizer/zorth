const std = @import("std");
const Op = @import("ops.zig").Op;
const math = @import("math.zig");

fn binaryOp(
    stack: *std.ArrayList(i64),
    comptime op: fn (comptime T: type, x: i64, y: i64) i64,
) void {
    const b = stack.pop();
    const a = stack.pop();
    stack.appendAssumeCapacity(op(i64, a, b));
}

pub fn simulateProgram(gpa: std.mem.Allocator, program: []const Op) !void {
    var stack = std.ArrayList(i64).init(gpa);
    defer stack.deinit();
    var stderr_buf = std.io.bufferedWriter(std.io.getStdErr().writer());
    defer stderr_buf.flush() catch unreachable;
    const stderr = stderr_buf.writer();

    var ip: usize = 0;
    while (ip < program.len) {
        const op = program[ip];
        switch (op) {
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
            .@"if" => |maybe_targ| {
                const targ = maybe_targ.?;
                const x = stack.pop();
                switch (x) {
                    0 => ip = targ,
                    else => ip += 1,
                }
            },
            .end => {
                ip += 1;
            },
            .dump => {
                const x = stack.pop();
                stderr.print("{d}\n", .{x}) catch unreachable;
                ip += 1;
            },
        }
    }
}
