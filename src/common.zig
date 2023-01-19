const std = @import("std");

pub fn runCmd(a: std.mem.Allocator, argv: []const []const u8, options: anytype) !u8 {
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
    const fail_ok = if (@hasField(@TypeOf(options), "fail_ok")) options.fail_ok else false;
    const was_ok = switch (result) {
        .Exited => |code| if (fail_ok)
            // early return
            return code
        else
            code == 0,
        else => false,
    };
    if (!was_ok) {
        std.log.err("command {s} exited with error", .{argv[0]});
        return error.Cmd;
    }
    return 0;
}
