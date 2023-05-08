const std = @import("std");
const mem_ext = @import("mem_ext.zig");

inline fn isSafeUnixChar(c: u8) bool {
    return switch (c) {
        '%',
        '+',
        '-',
        '.',
        '/',
        '_',
        ':',
        '=',
        '@',
        '0'...'9',
        'A'...'Z',
        'a'...'z',
        => true,
        else => false,
    };
}

const safe_unix_chars = blk: {
    comptime var result: []const u8 = "";
    for (0..128) |c| if (isSafeUnixChar(c)) {
        result = result ++ &[_]u8{c};
    };
    break :blk result;
};

fn printQuoted(cmd: []const []const u8) void {
    var buf = std.io.bufferedWriter(std.io.getStdErr().writer());
    defer buf.flush() catch unreachable;
    const out = buf.writer();
    for (cmd) |arg| {
        out.writeByte(' ') catch unreachable;
        if (arg.len == 0) {
            out.writeAll("''") catch unreachable;
        } else if (mem_ext.indexOfNone(u8, arg, safe_unix_chars) == null) {
            out.print("{s}", .{arg}) catch unreachable;
        } else {
            out.writeByte('\'') catch unreachable;
            for (arg) |c| {
                if (c == '\'') {
                    out.writeAll("'\"'\"'") catch unreachable;
                } else {
                    out.writeByte(c) catch unreachable;
                }
            }
            out.writeByte('\'') catch unreachable;
        }
    }
}

pub fn callCmd(gpa: std.mem.Allocator, cmd: []const []const u8) !void {
    std.debug.print("[CMD]", .{});
    printQuoted(cmd);
    std.debug.print("\n", .{});

    var proc = std.ChildProcess.init(cmd, gpa);
    const term = try proc.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("ERROR: failed with code {d}\n", .{code});
            return error.BadExit;
        },
        else => {
            std.debug.print("ERROR: crashed\n", .{});
            return error.Crash;
        },
    }
}
