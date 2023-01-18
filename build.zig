const std = @import("std");

const pkgs = [_]std.build.Pkg{
    .{
        .name = "known-folders",
        .source = .{ .path = "deps/known-folders/known-folders.zig" },
    },
};

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zorth", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    for (pkgs) |p| {
        exe.addPackage(p);
    }
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_cmd.expected_exit_code = null;

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
