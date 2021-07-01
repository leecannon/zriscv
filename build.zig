const std = @import("std");

const lib_pkg = std.build.Pkg{ .name = "zriscv", .path = .{ .path = "lib/index.zig" } };

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const runner = b.addExecutable("zriscv", "runner/main.zig");
    runner.setTarget(target);
    runner.setBuildMode(mode);
    runner.addPackage(lib_pkg);
    runner.install();

    // TODO: This is temporary
    runner.addBuildOption([]const u8, "resource_path", b.pathFromRoot("tests/resources"));

    const run_cmd = runner.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_exe = b.addTest("tests/tests.zig");
    test_exe.setBuildMode(mode);
    test_exe.addPackage(lib_pkg);
    test_exe.addBuildOption([]const u8, "resource_path", b.pathFromRoot("tests/resources"));

    const runner_test = b.addTest("runner/main.zig");
    runner_test.setBuildMode(mode);
    runner_test.addPackage(lib_pkg);

    // TODO: This is temporary
    runner_test.addBuildOption([]const u8, "resource_path", b.pathFromRoot("tests/resources"));

    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&test_exe.step);
    test_step.dependOn(&runner_test.step);
}
