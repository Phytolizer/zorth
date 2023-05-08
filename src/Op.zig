const std = @import("std");

loc: Location,
code: Code,

pub fn init(loc: Location, code: Code) @This() {
    return .{ .loc = loc, .code = code };
}

pub const Location = struct {
    file_path: []const u8,
    row: usize,
    col: usize,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}:{d}:{d}", .{ self.file_path, self.row, self.col });
    }
};

pub const Code = union(enum) {
    push: u63,
    // Simple.
    plus,
    minus,
    mod,
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

    // System calls.
    syscall0,
    syscall1,
    syscall2,
    syscall3,
    syscall4,
    syscall5,
    syscall6,

    // Control-flow.
    @"if": ?usize,
    @"else": ?usize,
    @"while",
    do: ?usize,
    end: ?usize,

    // Stack.
    dup,
    dup2,
    swap,
    drop,
    over,

    pub const Tag = std.meta.Tag(@This());
    const Self = @This();

    pub fn display(self: Self, out: anytype) !void {
        switch (self) {
            .push => |x| try out.print("push {d}", .{x}),

            .@"if",
            .@"else",
            .do,
            .end,
            => |maybe_targ| {
                const name = @tagName(self);
                try out.writeAll(name);
                if (maybe_targ) |targ| {
                    try out.print(" -> #{d}", .{targ});
                } else {
                    try out.writeAll(" -> NOTHING!!!");
                }
            },

            else => {
                const name = @tagName(self);
                try out.writeAll(name);
            },
        }
    }

    pub fn hasCode(self: Self, code: Tag) bool {
        return std.meta.activeTag(self) == code;
    }
};
