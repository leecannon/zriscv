const std = @import("std");
const exports = @import("deps.zig").exports;
const pkgs = @import("deps.zig").pkgs;

pub const zriscv_pkg = std.build.Pkg{
    .name = "zriscv",
    .path = .{ .path = "lib/index.zig" },
    .dependencies = &.{pkgs.bitjuggle},
};

pub fn build(b: *std.build.Builder) void {
    if (@hasField(std.build.Builder, "prominent_compile_errors")) b.prominent_compile_errors = true;

    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    // Runner
    {
        const runner = b.addExecutable("zriscv", "runner/main.zig");
        runner.setTarget(target);
        runner.setBuildMode(mode);
        runner.addPackage(zriscv_pkg);
        pkgs.addAllTo(runner);
        runner.install();

        const run_cmd = runner.run();
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    // Tests
    {
        const test_exe = b.addTest("tests/tests.zig");
        test_exe.setBuildMode(mode);
        test_exe.addPackage(zriscv_pkg);
        test_exe.addBuildOption([]const u8, "resource_path", b.pathFromRoot("tests/resources"));

        const runner_test = b.addTest("runner/main.zig");
        runner_test.setBuildMode(mode);
        runner_test.addPackage(zriscv_pkg);
        pkgs.addAllTo(runner_test);

        const zriscv_test = b.addTest("lib/index.zig");
        zriscv_test.setBuildMode(mode);
        pkgs.addAllTo(zriscv_test);

        const test_step = b.step("test", "Run the tests");
        test_step.dependOn(&test_exe.step);
        test_step.dependOn(&runner_test.step);
        test_step.dependOn(&zriscv_test.step);
    }
}
