const std = @import("std");
const cmd = @import("porth-cmd");
const driver = @import("porth-driver");

fn runTest(gpa: std.mem.Allocator, path: []const u8) !void {
    std.debug.print("[INFO] Testing {s}\n", .{path});
    var sim_out_buf = std.ArrayList(u8).init(gpa);
    defer sim_out_buf.deinit();
    const sim_out = sim_out_buf.writer();
    const stderr = std.io.getStdErr().writer();
    const sim_cmd = [_][]const u8{ "porth", "sim", path };
    std.debug.print("[CMD]", .{});
    cmd.printQuoted(&sim_cmd);
    std.debug.print("\n", .{});
    try driver.run(gpa, &sim_cmd, stderr, sim_out);
    var com_out_buf = std.ArrayList(u8).init(gpa);
    defer com_out_buf.deinit();
    const com_out = com_out_buf.writer();
    const com_cmd = [_][]const u8{ "porth", "com", "-r", path };
    std.debug.print("[CMD]", .{});
    cmd.printQuoted(&com_cmd);
    std.debug.print("\n", .{});
    try driver.run(gpa, &com_cmd, stderr, com_out);

    if (!std.mem.eql(u8, sim_out_buf.items, com_out_buf.items)) {
        std.debug.print(
            \\[ERROR] Output discrepancy between simulation and compilation
            \\  Simulation output:
            \\    {s}
            \\  Compilation output:
            \\    {s}
            \\
        , .{ sim_out_buf.items, com_out_buf.items });
        return error.TestFail;
    }
    std.debug.print("[INFO] {s} OK\n", .{path});
}

fn run() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 10 }){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();

    const dir = std.fs.cwd().openIterableDir("tests", .{}) catch |e| {
        std.debug.print("failed to open 'tests': {s}\n", .{@errorName(e)});
        return e;
    };
    var walk = try dir.walk(gpa);
    defer walk.deinit();
    const path = std.fs.path;
    while (try walk.next()) |ent|
        if (ent.kind == .File and
            std.mem.eql(u8, path.extension(ent.basename), ".porth"))
        {
            const full_path = try path.join(gpa, &.{ "tests", ent.path });
            defer gpa.free(full_path);
            try runTest(gpa, full_path);
        };
}

pub fn main() void {
    run() catch std.process.exit(1);
}
