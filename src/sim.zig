const std = @import("std");
const Op = @import("Op.zig");
const math = @import("math.zig");

fn binaryOp(
    stack: *std.ArrayList(u64),
    comptime op: fn (comptime T: type, x: u64, y: u64) u64,
) void {
    const b = stack.pop();
    const a = stack.pop();
    stack.appendAssumeCapacity(op(u64, a, b));
}

pub fn simulateProgram(
    gpa: std.mem.Allocator,
    program: []const Op,
    args: []const []const u8,
    stdin: anytype,
    stderr: anytype,
    stdout: anytype,
) !void {
    var stack = std.ArrayList(u64).init(gpa);
    defer stack.deinit();
    const opts = @import("opts");
    const nul_padding = 1; // ASCII NUL terminator
    var mem = try gpa.alloc(u8, opts.mem_capacity + opts.str_capacity + nul_padding);
    defer gpa.free(mem);
    @memset(mem, 0);

    const builtin_fds = .{
        stdin,
        stdout,
        stderr,
    };

    var fds = std.AutoArrayHashMap(usize, std.fs.File).init(gpa);
    defer {
        for (fds.values()) |f|
            f.close();
        fds.deinit();
    }

    var str_offsets = std.AutoArrayHashMap(usize, usize).init(gpa);
    defer str_offsets.deinit();
    var str_size: usize = nul_padding;

    try stack.append(0);
    var args_it = std.mem.reverseIterator(args);
    while (args_it.next()) |arg| {
        std.mem.copy(u8, mem[str_size .. str_size + arg.len], arg);
        mem[str_size + arg.len] = 0;
        try stack.append(str_size);
        str_size += arg.len + 1;
        if (str_size >= opts.str_capacity + nul_padding)
            std.debug.panic(
                "string buffer overflow by {d} bytes",
                .{str_size - opts.str_capacity - nul_padding},
            );
    }
    try stack.append(@intCast(u64, args.len));

    var ip: usize = 0;
    while (ip < program.len) {
        const op = &program[ip];
        switch (op.code) {
            .push_int => |x| {
                try stack.append(x);
                ip += 1;
            },
            .push_str => |x| {
                const s = x;
                try stack.append(@intCast(u64, s.len));
                const addr = str_offsets.get(ip) orelse blk: {
                    const addr = str_size;
                    try str_offsets.put(ip, str_size);
                    for (s, mem[str_size .. str_size + s.len]) |src, *dst|
                        dst.* = src;
                    str_size += s.len;
                    if (str_size >= opts.str_capacity + nul_padding)
                        std.debug.panic(
                            "string buffer overflow by {d} bytes",
                            .{str_size - opts.str_capacity - nul_padding},
                        );
                    break :blk addr;
                };
                try stack.append(@intCast(u64, addr));
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
            .intrinsic => |intrinsic| switch (intrinsic) {
                .plus => {
                    binaryOp(&stack, math.add);
                    ip += 1;
                },
                .minus => {
                    binaryOp(&stack, math.sub);
                    ip += 1;
                },
                .mul => {
                    binaryOp(&stack, math.mul);
                    ip += 1;
                },
                .divmod => {
                    const b = stack.pop();
                    const a = stack.pop();
                    stack.appendAssumeCapacity(math.div(@TypeOf(a), a, b));
                    stack.appendAssumeCapacity(math.mod(@TypeOf(a), a, b));
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
                .print => {
                    const x = stack.pop();
                    try builtin_fds.@"1".print("{d}\n", .{x});
                    ip += 1;
                },
                .mem => {
                    try stack.append(opts.str_capacity);
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
                .load64 => {
                    const addr = stack.pop();
                    const bytes = mem[@intCast(usize, addr)..];
                    const value = std.mem.readIntSliceLittle(u64, bytes);
                    try stack.append(value);
                    ip += 1;
                },
                .store64 => {
                    const value = stack.pop();
                    const addr = stack.pop();
                    const bytes = mem[@intCast(usize, addr)..];
                    std.mem.writeIntLittle(u64, bytes[0..8], value);
                    ip += 1;
                },
                .syscall2,
                .syscall4,
                .syscall5,
                .syscall6,
                => std.debug.panic("UNIMPLEMENTED", .{}),
                .syscall0 => {
                    const syscall_number = stack.pop();
                    switch (syscall_number) {
                        39 => {
                            // getpid
                            try stack.append(@intCast(u64, std.os.linux.getpid()));
                        },
                        else => std.debug.panic("unknown syscall number {d}", .{syscall_number}),
                    }
                    ip += 1;
                },
                .syscall1 => {
                    const syscall_number = stack.pop();
                    const arg1 = stack.pop();
                    switch (syscall_number) {
                        60 => {
                            // exit
                            std.process.exit(@truncate(u8, arg1));
                        },
                        else => std.debug.panic("unknown syscall number {d}", .{syscall_number}),
                    }
                    ip += 1;
                },
                .syscall3 => {
                    const syscall_number = stack.pop();
                    const arg1 = stack.pop();
                    const arg2 = stack.pop();
                    const arg3 = stack.pop();
                    switch (syscall_number) {
                        0 => {
                            // read
                            const fd = @intCast(usize, arg1);
                            const buf = @intCast(usize, arg2);
                            const count = @intCast(usize, arg3);
                            const s = mem[buf .. buf + count];
                            const nread = switch (fd) {
                                0 => try builtin_fds.@"0".readAll(s),
                                else => blk: {
                                    const f = fds.get(fd) orelse
                                        std.debug.panic("unknown file descriptor {d}", .{fd});
                                    break :blk try f.reader().readAll(s);
                                },
                            };
                            try stack.append(@intCast(u64, nread));
                        },
                        1 => {
                            // write
                            const fd = @intCast(usize, arg1);
                            const buf = @intCast(usize, arg2);
                            const count = @intCast(usize, arg3);
                            const s = mem[buf .. buf + count];
                            switch (fd) {
                                1 => try builtin_fds.@"1".writeAll(s),
                                2 => try builtin_fds.@"2".writeAll(s),
                                else => {
                                    const f = fds.get(fd) orelse
                                        std.debug.panic("unknown file descriptor {d}", .{fd});
                                    try f.writer().writeAll(s);
                                },
                            }
                            try stack.append(arg3);
                        },
                        else => std.debug.panic("unknown syscall number {d}", .{syscall_number}),
                    }
                    ip += 1;
                },
                .dup => {
                    const x = stack.pop();
                    try stack.appendSlice(&.{ x, x });
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
            },
        }
    }
}
