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

    for (program) |op| {
        switch (op) {
            .push => |x| {
                try stack.append(x);
            },
            .plus => {
                binaryOp(&stack, math.add);
            },
            .minus => {
                binaryOp(&stack, math.sub);
            },
            .equal => {
                binaryOp(&stack, math.equal);
            },
            .dump => {
                const x = stack.pop();
                stderr.print("{d}\n", .{x}) catch unreachable;
            },
        }
    }
}
