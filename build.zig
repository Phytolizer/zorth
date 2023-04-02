const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common_mod = std.Build.ModuleDependency{
        .name = "common",
        .module = b.createModule(.{
            .source_file = .{ .path = "src/common.zig" },
        }),
    };
    const known_folders_mod = std.Build.ModuleDependency{
        .name = "known-folders",
        .module = b.createModule(.{
            .source_file = .{ .path = "deps/known-folders/known-folders.zig" },
        }),
    };

    const pkgs = [_]std.Build.ModuleDependency{
        known_folders_mod,
        common_mod,
    };

    const exe = b.addExecutable(.{
        .name = "zorth",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    for (pkgs) |pkg| {
        exe.addModule(pkg.name, pkg.module);
    }
    exe.install();

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.stdio = .{
        .check = std.ArrayList(std.Build.RunStep.StdIo.Check).init(b.allocator),
    };
    run_cmd.has_side_effects = true;
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addExecutable(.{
        .name = "zorth-test",
        .root_source_file = .{ .path = "src/test.zig" },
        .target = target,
        .optimize = optimize,
    });
    tests.addModule(
        "zorth",
        b.createModule(.{
            .source_file = .{ .path = "src/main.zig" },
            .dependencies = &pkgs,
        }),
    );
    tests.addModule(common_mod.name, common_mod.module);
    tests.install();

    const tests_run_cmd = b.addRunArtifact(tests);
    tests_run_cmd.has_side_effects = true;
    tests_run_cmd.stdio = .{
        .check = std.ArrayList(std.Build.RunStep.StdIo.Check).init(b.allocator),
    };
    tests_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        tests_run_cmd.addArgs(args);
    }

    const tests_run_step = b.step("test", "Test the app");
    tests_run_step.dependOn(&tests_run_cmd.step);
}
