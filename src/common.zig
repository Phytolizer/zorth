const std = @import("std");

pub fn runCmd(a: std.mem.Allocator, argv: []const []const u8, options: anytype) !void {
    std.debug.print("cmd:", .{});
    for (argv) |arg| {
        std.debug.print(" '{s}'", .{arg});
    }
    std.debug.print("\n", .{});
    const result = run: {
        if (@hasField(@TypeOf(options), "stdout")) {
            const result = try std.ChildProcess.exec(.{
                .allocator = a,
                .argv = argv,
            });
            defer a.free(result.stdout);
            defer a.free(result.stderr);
            try options.stdout.writeAll(result.stdout);
            break :run result.term;
        } else {
            var child = std.ChildProcess.init(argv, a);
            break :run try child.spawnAndWait();
        }
    };
    const was_ok = switch (result) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!was_ok) {
        std.log.err("command {s} exited with error", .{argv[0]});
        return error.Cmd;
    }
}
