const std = @import("std");
const Keyword = @import("keyword.zig").Keyword;
const Intrinsic = @import("intrinsic.zig").Intrinsic;

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
    push_int: u64,
    push_str: []const u8,

    intrinsic: Intrinsic,

    // Control-flow.
    @"if": ?usize,
    @"else": ?usize,
    @"while",
    do: ?usize,
    end: ?usize,

    pub const Tag = std.meta.Tag(@This());
    const Self = @This();

    pub fn display(self: Self, out: anytype) !void {
        switch (self) {
            .push_int => |x| try out.print("push int {d}", .{x}),
            .push_str => |x| try out.print("push str '{'}'", .{std.zig.fmtEscapes(x)}),

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
            .intrinsic => |i| {
                const name = @tagName(i);
                try out.writeAll(name);
            },
            .@"while" => {
                const name = @tagName(self);
                try out.writeAll(name);
            },
        }
    }
};
