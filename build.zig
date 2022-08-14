const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    b.prominent_compile_errors = true;

    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    // Exe
    {
        const zriscv = b.addExecutable("zriscv", "src/main.zig");
        zriscv.setTarget(target);
        zriscv.setBuildMode(mode);
        zriscv.addPackage(args_pkg);
        zriscv.addPackage(bitjuggle_pkg);
        zriscv.install();

        const run_cmd = zriscv.run();
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
        const zriscv_test_exe = b.addTest("src/main.zig");
        zriscv_test_exe.setBuildMode(mode);
        zriscv_test_exe.addPackage(args_pkg);
        zriscv_test_exe.addPackage(bitjuggle_pkg);

        const test_step = b.step("test", "Run the tests");
        test_step.dependOn(&zriscv_test_exe.step);

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
