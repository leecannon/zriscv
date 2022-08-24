const std = @import("std");

const zriscv_version = std.builtin.Version{ .major = 0, .minor = 0, .patch = 2 };

pub fn build(b: *std.build.Builder) !void {
    b.prominent_compile_errors = true;

    // TODO: Check if this is still needed, was hitting issue when using tracy
    b.use_stage1 = true;

    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const trace = b.option(bool, "trace", "enable tracy tracing") orelse false;
    const trace_callstack = b.option(bool, "trace-callstack", "enable tracy callstack (does nothing without trace option)") orelse false;

    const options_step = try getOptionsStep(b, trace, trace_callstack);

    // Exe
    {
        const zriscv = b.addExecutable("zriscv", "src/main.zig");
        zriscv.setTarget(target);
        zriscv.setBuildMode(mode);
        zriscv.addOptions("build_options", options_step);
        zriscv.addPackage(args_pkg);
        zriscv.addPackage(bitjuggle_pkg);

        // We use the c allocator in debug modes
        if (mode != .Debug) zriscv.linkLibC();

        if (trace) {
            includeTracy(zriscv);
        }

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
        zriscv_test_exe.addOptions("build_options", options_step);
        zriscv_test_exe.addPackage(args_pkg);
        zriscv_test_exe.addPackage(bitjuggle_pkg);

        const test_step = b.step("test", "Run the tests");
        test_step.dependOn(&zriscv_test_exe.step);

        b.default_step = test_step;
    }
}

fn getOptionsStep(b: *std.build.Builder, trace: bool, trace_callstack: bool) !*std.build.OptionsStep {
    const options = b.addOptions();

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

    return options;
}

fn includeTracy(exe: *std.build.LibExeObjStep) void {
    exe.linkLibC();
    exe.linkLibCpp();
    exe.addIncludeDir("external/tracy/public");

    const tracy_c_flags: []const []const u8 = if (exe.target.isWindows() and exe.target.getAbi() == .gnu)
        &.{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined", "-D_WIN32_WINNT=0x601" }
    else
        &.{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined" };

    exe.addCSourceFile("external/tracy/public/TracyClient.cpp", tracy_c_flags);

    if (exe.target.isWindows()) {
        exe.linkSystemLibrary("Advapi32");
        exe.linkSystemLibrary("User32");
        exe.linkSystemLibrary("Ws2_32");
        exe.linkSystemLibrary("DbgHelp");
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
