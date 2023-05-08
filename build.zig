const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cmd = b.addModule("porth-cmd", .{
        .source_file = .{ .path = "src/cmd.zig" },
    });
    const porth_driver = b.addModule("porth-driver", .{
        .source_file = .{ .path = "src/driver.zig" },
        .dependencies = &.{.{ .name = "porth-cmd", .module = cmd }},
    });

    const exe = b.addExecutable(.{
        .name = "zorth",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("porth-driver", porth_driver);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_exe = b.addExecutable(.{
        .name = "test",
        .root_source_file = .{ .path = "src/test.zig" },
        .target = target,
        .optimize = optimize,
    });
    test_exe.addModule("porth-driver", porth_driver);
    test_exe.addModule("porth-cmd", cmd);

    const test_run_cmd = b.addRunArtifact(test_exe);
    if (b.args) |args| {
        test_run_cmd.addArgs(args);
    }

    const test_run_step = b.step("test", "Run the tests");
    test_run_step.dependOn(&test_run_cmd.step);
}
