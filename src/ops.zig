const std = @import("std");
pub const Op = union(enum) {
    push: u63,
    plus,
    minus,
    dump,

    pub const Code = std.meta.Tag(@This());
    const Self = @This();

    pub fn display(self: Self, out: anytype) !void {
        switch (self) {
            .push => |x| try out.print("push {d}", .{x}),
            else => {
                const name = @tagName(self);
                try out.writeAll(name);
            },
        }
    }
};
