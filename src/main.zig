const std = @import("std");
const driver = @import("porth-driver");

fn run() !u8 {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 10 }){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    return try driver.run(gpa, args, stderr, stdout);
}

pub fn main() void {
    std.process.exit(run() catch 1);
}
