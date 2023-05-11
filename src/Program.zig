const std = @import("std");
const Op = @import("Op.zig");

items: []Op,

pub fn init(items: []Op) @This() {
    return .{ .items = items };
}

pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
    for (self.items) |op| {
        gpa.free(op.loc.file_path);
        switch (op.code) {
            .push_str => |s| gpa.free(s),
            else => {},
        }
    }
    gpa.free(self.items);
}
