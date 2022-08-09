const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    b.prominent_compile_errors = true;

    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    // Runner
    {
        const runner = b.addExecutable("zriscv", "runner/main.zig");
        runner.setTarget(target);
        runner.setBuildMode(mode);
        runner.addPackage(args_pkg);
        runner.addPackage(zriscv_pkg);
        runner.install();

        const run_cmd = runner.run();
        run_cmd.expected_exit_code = null;
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the emulator");
        run_step.dependOn(&run_cmd.step);
    }

    // Tests
    {
        const test_exe = b.addTest("tests/tests.zig");
        test_exe.setBuildMode(mode);
        test_exe.addPackage(zriscv_pkg);

        const runner_test = b.addTest("runner/main.zig");
        runner_test.setBuildMode(mode);
        runner_test.addPackage(args_pkg);
        runner_test.addPackage(zriscv_pkg);

        const zriscv_test = b.addTest("lib/lib.zig");
        zriscv_test.setBuildMode(mode);
        zriscv_test.addPackage(bitjuggle_pkg);

        const test_step = b.step("test", "Run the tests");
        test_step.dependOn(&test_exe.step);
        test_step.dependOn(&runner_test.step);
        test_step.dependOn(&zriscv_test.step);

        b.default_step = test_step;
    }
}

const args_pkg: std.build.Pkg = .{
    .name = "args",
    .source = .{ .path = "external/zig-args/args.zig" },
};

const bitjuggle_pkg: std.build.Pkg = .{
    .name = "bitjuggle",
    .source = .{ .path = "external/zig-bitjuggle/bitjuggle.zig" },
};

pub const zriscv_pkg = std.build.Pkg{
    .name = "zriscv",
    .source = .{ .path = "lib/lib.zig" },
    .dependencies = &.{bitjuggle_pkg},
};
