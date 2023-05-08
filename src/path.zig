const std = @import("std");

pub fn withoutExtension(p: []const u8) []const u8 {
    const len = @ptrToInt(std.fs.path.extension(p).ptr) - @ptrToInt(p.ptr);
    return p[0..len];
}
