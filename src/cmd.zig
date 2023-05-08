const std = @import("std");

pub fn callCmd(gpa: std.mem.Allocator, cmd: []const []const u8) !void {
    std.debug.print(">", .{});
    for (cmd) |arg| {
        std.debug.print(" \"{}\"", .{std.zig.fmtEscapes(arg)});
    }
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
