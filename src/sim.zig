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
    var mem = try gpa.alloc(u8, @import("opts").mem_capacity);
    defer gpa.free(mem);
    @memset(mem, 0);

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
            .mod => {
                binaryOp(&stack, math.mod);
                ip += 1;
            },
            .eq => {
                binaryOp(&stack, math.eq);
                ip += 1;
            },
            .gt => {
                binaryOp(&stack, math.gt);
                ip += 1;
            },
            .lt => {
                binaryOp(&stack, math.lt);
                ip += 1;
            },
            .ge => {
                binaryOp(&stack, math.ge);
                ip += 1;
            },
            .le => {
                binaryOp(&stack, math.le);
                ip += 1;
            },
            .ne => {
                binaryOp(&stack, math.ne);
                ip += 1;
            },
            .shr => {
                binaryOp(&stack, math.shr);
                ip += 1;
            },
            .shl => {
                binaryOp(&stack, math.shl);
                ip += 1;
            },
            .bor => {
                binaryOp(&stack, math.bor);
                ip += 1;
            },
            .band => {
                binaryOp(&stack, math.band);
                ip += 1;
            },
            .dump => {
                const x = stack.pop();
                try stdout.print("{d}\n", .{x});
                ip += 1;
            },
            .mem => {
                try stack.append(0);
                ip += 1;
            },
            .load => {
                const addr = stack.pop();
                const byte = mem[@intCast(usize, addr)];
                try stack.append(byte);
                ip += 1;
            },
            .store => {
                const value = stack.pop();
                const addr = stack.pop();
                mem[@intCast(usize, addr)] = @truncate(u8, @intCast(usize, value));
                ip += 1;
            },
            .syscall1,
            .syscall2,
            .syscall4,
            .syscall5,
            .syscall6,
            => std.debug.panic("UNIMPLEMENTED", .{}),
            .syscall3 => {
                const syscall_number = stack.pop();
                const arg1 = stack.pop();
                const arg2 = stack.pop();
                const arg3 = stack.pop();
                switch (syscall_number) {
                    1 => {
                        const fd = arg1;
                        const buf = @intCast(usize, arg2);
                        const count = @intCast(usize, arg3);
                        const s = mem[buf .. buf + count];
                        switch (fd) {
                            1 => try stdout.writeAll(s),
                            2 => std.debug.print("{s}", .{s}),
                            else => std.debug.panic("unknown file descriptor {d}", .{fd}),
                        }
                        try stack.append(arg3);
                    },
                    else => std.debug.panic("unknwon syscall number {d}", .{syscall_number}),
                }
                ip += 1;
            },
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
            .dup2 => {
                const b = stack.pop();
                const a = stack.pop();
                try stack.appendSlice(&.{ a, b, a, b });
                ip += 1;
            },
            .swap => {
                const b = stack.pop();
                const a = stack.pop();
                try stack.appendSlice(&.{ b, a });
                ip += 1;
            },
            .drop => {
                _ = stack.pop();
                ip += 1;
            },
            .over => {
                const b = stack.pop();
                const a = stack.pop();
                try stack.appendSlice(&.{ a, b, a });
                ip += 1;
            },
        }
    }
}
