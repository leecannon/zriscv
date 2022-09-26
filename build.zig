const std = @import("std");

const zriscv_version = std.builtin.Version{ .major = 0, .minor = 1, .patch = 1 };

pub fn build(b: *std.build.Builder) !void {
    b.prominent_compile_errors = true;

    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const output = b.option(bool, "output", "output when run in non-interactive system mode") orelse false;
    const dont_panic_on_unimplemented = b.option(bool, "unimp", "*don't* panic on unimplemented instruction execution") orelse false;

    const trace = b.option(bool, "trace", "enable tracy tracing") orelse false;
    const trace_callstack = b.option(bool, "trace-callstack", "enable tracy callstack (does nothing without trace option)") orelse false;

    if (trace) {
        // TODO: For some reason self-hosted and tracy don't get along
        b.use_stage1 = true;
    }

    const options_package = try getOptionsPkg(b, trace, trace_callstack, output, dont_panic_on_unimplemented);

    // zriscv_cli
    {
        const zriscv_cli = b.addExecutable("zriscv", "zriscv_cli/main.zig");
        zriscv_cli.setTarget(target);
        zriscv_cli.setBuildMode(mode);

        setupZriscvCli(zriscv_cli, options_package, trace);
        zriscv_cli.install();

        const run_cmd = zriscv_cli.run();
        run_cmd.expected_exit_code = null;
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the CLI emulator");
        run_step.dependOn(&run_cmd.step);
    }

    // zriscv_gui
    {
        const zriscv_gui = b.addExecutable("gzriscv", "zriscv_gui/main.zig");
        zriscv_gui.setTarget(target);
        zriscv_gui.setBuildMode(mode);
        zriscv_gui.install();
        setupZriscvGui(zriscv_gui, options_package, trace);

        const run_cmd = zriscv_gui.run();
        run_cmd.expected_exit_code = null;
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run_gui", "Run the GUI emulator");
        run_step.dependOn(&run_cmd.step);
    }

    // Tests
    {
        const zriscv_test = b.addTest("zriscv/zriscv.zig");
        zriscv_test.setTarget(target);
        zriscv_test.setBuildMode(mode);
        setupZriscvForTests(zriscv_test, options_package, trace);

        const zriscv_cli_test = b.addTest("zriscv_cli/main.zig");
        zriscv_cli_test.setTarget(target);
        zriscv_cli_test.setBuildMode(mode);
        setupZriscvCli(zriscv_cli_test, options_package, trace);

        const zriscv_gui_test = b.addTest("zriscv_gui/main.zig");
        zriscv_gui_test.setTarget(target);
        zriscv_gui_test.setBuildMode(mode);
        setupZriscvGui(zriscv_gui_test, options_package, trace);

        const test_step = b.step("test", "Run the tests");
        test_step.dependOn(&zriscv_test.step);
        test_step.dependOn(&zriscv_cli_test.step);
        test_step.dependOn(&zriscv_gui_test.step);

        b.default_step = test_step;
    }

    // Riscof
    {
        const build_path = comptime std.fs.path.dirname(@src().file).?;
        const run_riscof_step = b.addSystemCommand(&.{build_path ++ "/riscof/run_tests.sh"});
        run_riscof_step.expected_exit_code = null;
        run_riscof_step.step.dependOn(b.getInstallStep());

        const riscof_step = b.step("riscof", "Run the riscof tests");
        riscof_step.dependOn(&run_riscof_step.step);
    }
}

fn setupZriscvCli(exe: *std.build.LibExeObjStep, options_package: std.build.Pkg, trace: bool) void {
    exe.addPackage(options_package);
    exe.addPackage(args_pkg);
    exe.addPackage(known_folders_pkg);
    exe.addPackage(bestline_pkg);
    exe.addPackage(tracy_pkg);
    exe.addPackage(getZriscvPkg(options_package));

    exe.linkLibC();

    exe.addIncludePath("libraries/bestline/bestline");
    exe.addCSourceFile("libraries/bestline/bestline/bestline.c", &.{});

    if (trace) {
        exe.linkLibCpp();
        exe.addIncludePath("libraries/tracy/tracy/public");

        const tracy_c_flags: []const []const u8 = if (exe.target.isWindows() and exe.target.getAbi() == .gnu)
            &.{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined", "-D_WIN32_WINNT=0x601" }
        else
            &.{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined" };

        exe.addCSourceFile("libraries/tracy/tracy/public/TracyClient.cpp", tracy_c_flags);

        if (exe.target.isWindows()) {
            exe.linkSystemLibrary("Advapi32");
            exe.linkSystemLibrary("User32");
            exe.linkSystemLibrary("Ws2_32");
            exe.linkSystemLibrary("DbgHelp");
        }
    }
}

fn setupZriscvGui(exe: *std.build.LibExeObjStep, options_package: std.build.Pkg, trace: bool) void {
    exe.addPackage(options_package);
    exe.addPackage(args_pkg);
    exe.addPackage(known_folders_pkg);
    exe.addPackage(tracy_pkg);
    exe.addPackage(getZriscvPkg(options_package));

    exe.linkLibC();

    if (trace) {
        exe.linkLibCpp();
        exe.addIncludePath("libraries/tracy/tracy/public");

        const tracy_c_flags: []const []const u8 = if (exe.target.isWindows() and exe.target.getAbi() == .gnu)
            &.{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined", "-D_WIN32_WINNT=0x601" }
        else
            &.{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined" };

        exe.addCSourceFile("libraries/tracy/tracy/public/TracyClient.cpp", tracy_c_flags);

        if (exe.target.isWindows()) {
            exe.linkSystemLibrary("Advapi32");
            exe.linkSystemLibrary("User32");
            exe.linkSystemLibrary("Ws2_32");
            exe.linkSystemLibrary("DbgHelp");
        }
    }
}

fn setupZriscvForTests(exe: *std.build.LibExeObjStep, options_package: std.build.Pkg, trace: bool) void {
    exe.addPackage(options_package);
    exe.addPackage(bitjuggle_pkg);
    exe.addPackage(tracy_pkg);
    exe.addPackage(getZriscvPkg(options_package));

    exe.linkLibC();

    if (trace) {
        exe.linkLibCpp();
        exe.addIncludePath("libraries/tracy/tracy/public");

        const tracy_c_flags: []const []const u8 = if (exe.target.isWindows() and exe.target.getAbi() == .gnu)
            &.{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined", "-D_WIN32_WINNT=0x601" }
        else
            &.{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined" };

        exe.addCSourceFile("libraries/tracy/tracy/public/TracyClient.cpp", tracy_c_flags);

        if (exe.target.isWindows()) {
            exe.linkSystemLibrary("Advapi32");
            exe.linkSystemLibrary("User32");
            exe.linkSystemLibrary("Ws2_32");
            exe.linkSystemLibrary("DbgHelp");
        }
    }
}

fn getOptionsPkg(b: *std.build.Builder, trace: bool, trace_callstack: bool, output: bool, dont_panic_on_unimplemented: bool) !std.build.Pkg {
    const options = b.addOptions();

    options.addOption(bool, "dont_panic_on_unimplemented", dont_panic_on_unimplemented);
    options.addOption(bool, "output", output);
    options.addOption(bool, "trace", trace);
    options.addOption(bool, "trace_callstack", trace_callstack);

    const version = v: {
        const version_string = b.fmt(
            "{d}.{d}.{d}",
            .{ zriscv_version.major, zriscv_version.minor, zriscv_version.patch },
        );

        var code: u8 = undefined;
        const git_describe_untrimmed = b.execAllowFail(&[_][]const u8{
            "git", "-C", b.build_root, "describe", "--match", "*.*.*", "--tags",
        }, &code, .Ignore) catch {
            break :v version_string;
        };
        const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");

        switch (std.mem.count(u8, git_describe, "-")) {
            0 => {
                // Tagged release version (e.g. 0.8.0).
                if (!std.mem.eql(u8, git_describe, version_string)) {
                    std.debug.print(
                        "zriscv version '{s}' does not match Git tag '{s}'\n",
                        .{ version_string, git_describe },
                    );
                    std.process.exit(1);
                }
                break :v version_string;
            },
            2 => {
                // Untagged development build (e.g. 0.8.0-684-gbbe2cca1a).
                var it = std.mem.split(u8, git_describe, "-");
                const tagged_ancestor = it.next() orelse unreachable;
                const commit_height = it.next() orelse unreachable;
                const commit_id = it.next() orelse unreachable;

                const ancestor_ver = try std.builtin.Version.parse(tagged_ancestor);
                if (zriscv_version.order(ancestor_ver) != .gt) {
                    std.debug.print(
                        "zriscv version '{}' must be greater than tagged ancestor '{}'\n",
                        .{ zriscv_version, ancestor_ver },
                    );
                    std.process.exit(1);
                }

                // Check that the commit hash is prefixed with a 'g' (a Git convention).
                if (commit_id.len < 1 or commit_id[0] != 'g') {
                    std.debug.print("unexpected `git describe` output: {s}\n", .{git_describe});
                    break :v version_string;
                }

                // The version is reformatted in accordance with the https://semver.org specification.
                break :v b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
            },
            else => {
                std.debug.print("unexpected `git describe` output: {s}\n", .{git_describe});
                break :v version_string;
            },
        }
    };
    options.addOption([:0]const u8, "version", try b.allocator.dupeZ(u8, version));

    return options.getPackage("build_options");
}

fn getZriscvPkg(options_package: std.build.Pkg) std.build.Pkg {
    const static = struct {
        var zriscv_pkg_deps_init: bool = false;
        var zriscv_pkg_deps = [_]std.build.Pkg{
            undefined, // options
            mostly_empty_zriscv_pkg,
            bitjuggle_pkg,
            tracy_pkg,
        };

        const mostly_empty_zriscv_pkg: std.build.Pkg = .{
            .name = "zriscv",
            .source = .{ .path = "zriscv/zriscv.zig" },
        };
    };

    if (!static.zriscv_pkg_deps_init) {
        static.zriscv_pkg_deps[0] = options_package;
        static.zriscv_pkg_deps_init = true;
    }

    return .{
        .name = "zriscv",
        .source = .{ .path = "zriscv/zriscv.zig" },
        .dependencies = &static.zriscv_pkg_deps,
    };
}

const args_pkg: std.build.Pkg = .{
    .name = "args",
    .source = .{ .path = "libraries/zig-args/args.zig" },
};

const bestline_pkg: std.build.Pkg = .{
    .name = "bestline",
    .source = .{ .path = "libraries/bestline/bestline.zig" },
};

const bitjuggle_pkg: std.build.Pkg = .{
    .name = "bitjuggle",
    .source = .{ .path = "libraries/zig-bitjuggle/bitjuggle.zig" },
};

const known_folders_pkg: std.build.Pkg = .{
    .name = "known_folders",
    .source = .{ .path = "libraries/known-folders/known-folders.zig" },
};

const tracy_pkg: std.build.Pkg = .{
    .name = "tracy",
    .source = .{ .path = "libraries/tracy/tracy.zig" },
};
