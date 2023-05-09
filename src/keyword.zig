const std = @import("std");

pub const Keyword = enum {
    @"if",
    end,
    @"else",
    @"while",
    do,
    macro,
    include,

    pub const names = std.ComptimeStringMap(@This(), .{
        .{ "if", .@"if" },
        .{ "end", .end },
        .{ "else", .@"else" },
        .{ "while", .@"while" },
        .{ "do", .do },
        .{ "macro", .macro },
        .{ "include", .include },
    });
};
