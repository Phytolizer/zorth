const std = @import("std");
const Op = @import("Op.zig");
const Keyword = @import("keyword.zig").Keyword;

loc: Op.Location,
value: Value,
expanded_depth: usize = 0,

pub const Value = union(enum) {
    word: []const u8,
    int: u64,
    str: []const u8,
    // for UTF8 support
    character: u21,
    keyword: Keyword,

    pub const Tag = std.meta.Tag(@This());
    pub fn tagReadableName(tag: Tag) []const u8 {
        return switch (tag) {
            .word => "a word",
            .int => "an integer",
            .str => "a string",
            .character => "a character",
            .keyword => "a keyword",
        };
    }
    pub fn humanReadableName(self: @This()) []const u8 {
        return tagReadableName(std.meta.activeTag(self));
    }

    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .word, .str => |w| try writer.print("'{s}'", .{w}),
            .int => |x| try writer.print("'{d}'", .{x}),
            .character => |c| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &buf) catch unreachable;
                try writer.print("'{s}'", .{buf[0..len]});
            },
            .keyword => |k| try writer.print("'{s}'", .{@tagName(k)}),
        }
    }
};
