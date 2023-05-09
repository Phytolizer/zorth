const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mem_capacity = b.option(
        usize,
        "mem_capacity",
        "Maximum memory for Porth programs, default 640KiB",
    ) orelse 640 * 1024;
    const str_capacity = b.option(
        usize,
        "str_capacity",
        "Maximum memory for Porth string literals, default 640KiB",
    ) orelse 640 * 1024;
    const opts = b.addOptions();
    opts.addOption(usize, "mem_capacity", mem_capacity);
    opts.addOption(usize, "str_capacity", str_capacity);
    const opts_mod = opts.createModule();

    const cmd = b.addModule("porth-cmd", .{
        .source_file = .{ .path = "src/cmd.zig" },
    });
    const args_mod = b.addModule("porth-args", .{
        .source_file = .{ .path = "src/args.zig" },
    });
    const path_mod = b.addModule("porth-path", .{
        .source_file = .{ .path = "src/path.zig" },
    });
    const porth_driver = b.addModule("porth-driver", .{
        .source_file = .{ .path = "src/driver.zig" },
        .dependencies = &.{
            .{ .name = "porth-cmd", .module = cmd },
            .{ .name = "porth-args", .module = args_mod },
            .{ .name = "porth-path", .module = path_mod },
            .{ .name = "opts", .module = opts_mod },
        },
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
    test_exe.addModule("porth-args", args_mod);
    test_exe.addModule("porth-path", path_mod);
    // update regular exe with tests to ensure i don't get them out of sync
    test_exe.step.dependOn(b.getInstallStep());

    const test_run_cmd = b.addRunArtifact(test_exe);
    if (b.args) |args| {
        test_run_cmd.addArgs(args);
    }

    const test_run_step = b.step("test", "Run the tests");
    test_run_step.dependOn(&test_run_cmd.step);
}
