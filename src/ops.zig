const std = @import("std");
pub const Op = union(enum) {
    push: u63,
    // Simple.
    plus,
    minus,
    equal,

    // I/O.
    dump,

    // Control-flow.
    @"if": ?usize,
    @"else": ?usize,
    end,

    // Stack.
    dup,

    pub const Code = std.meta.Tag(@This());
    const Self = @This();

    pub fn display(self: Self, out: anytype) !void {
        switch (self) {
            .push => |x| try out.print("push {d}", .{x}),
            .@"if", .@"else" => |maybe_targ| {
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

    pub fn hasCode(self: Self, code: Code) bool {
        return std.meta.activeTag(self) == code;
    }
};
