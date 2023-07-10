const std = @import("std");

pub fn withoutExtension(p: []const u8) []const u8 {
    const len = @intFromPtr(std.fs.path.extension(p).ptr) - @intFromPtr(p.ptr);
    return p[0..len];
}
