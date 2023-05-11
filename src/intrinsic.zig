const std = @import("std");

pub const Intrinsic = enum {
    // Simple.
    plus,
    minus,
    mul,
    divmod,

    // Comparison.
    eq,
    gt,
    lt,
    ge,
    le,
    ne,

    // Bitwise.
    shr,
    shl,
    bor,
    band,

    // I/O.
    print,

    // Memory access.
    mem,
    load,
    store,
    load64,
    store64,

    // System calls.
    syscall0,
    syscall1,
    syscall2,
    syscall3,
    syscall4,
    syscall5,
    syscall6,

    // Stack.
    dup,
    swap,
    drop,
    over,

    pub const names = std.ComptimeStringMap(@This(), .{
        .{ "+", .plus },
        .{ "-", .minus },
        .{ "*", .mul },
        .{ "divmod", .divmod },
        .{ "shr", .shr },
        .{ "shl", .shl },
        .{ "bor", .bor },
        .{ "band", .band },
        .{ "print", .print },
        .{ "mem", .mem },
        .{ ",", .load },
        .{ ".", .store },
        .{ ",64", .load64 },
        .{ ".64", .store64 },
        .{ "syscall0", .syscall0 },
        .{ "syscall1", .syscall1 },
        .{ "syscall2", .syscall2 },
        .{ "syscall3", .syscall3 },
        .{ "syscall4", .syscall4 },
        .{ "syscall5", .syscall5 },
        .{ "syscall6", .syscall6 },
        .{ "=", .eq },
        .{ ">", .gt },
        .{ "<", .lt },
        .{ ">=", .ge },
        .{ "<=", .le },
        .{ "!=", .ne },
        .{ "dup", .dup },
        .{ "swap", .swap },
        .{ "drop", .drop },
        .{ "over", .over },
    });
};
