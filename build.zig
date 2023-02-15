const std = @import("std");

const zriscv_version = std.builtin.Version{ .major = 0, .minor = 1, .patch = 1 };

pub fn build(b: *std.Build) !void {
    b.prominent_compile_errors = true;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const output = b.option(bool, "output", "output when run in non-interactive system mode") orelse false;
    const dont_panic_on_unimplemented = b.option(bool, "unimp", "*don't* panic on unimplemented instruction execution") orelse false;

    const trace = b.option(bool, "trace", "enable tracy tracing") orelse false;
    const trace_callstack = b.option(bool, "trace-callstack", "enable tracy callstack (does nothing without trace option)") orelse false;

    const options_package = try getOptionsPkg(b, trace, trace_callstack, output, dont_panic_on_unimplemented);

    // zriscv_cli
    {
        const zriscv_cli = b.addExecutable(.{
            .name = "zriscv",
            .root_source_file = .{ .path = "zriscv_cli/main.zig" },
            .target = target,
            .optimize = optimize,
        });

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
        const zriscv_gui = b.addExecutable(.{
            .name = "gzriscv",
            .root_source_file = .{ .path = "zriscv_gui/main.zig" },
            .target = target,
            .optimize = optimize,
        });
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
        const zriscv_test = b.addTest(.{
            .root_source_file = .{ .path = "zriscv/zriscv.zig" },
            .target = target,
            .optimize = optimize,
        });
        setupZriscvForTests(zriscv_test, options_package, trace);

        const zriscv_cli_test = b.addTest(.{
            .root_source_file = .{ .path = "zriscv_cli/main.zig" },
            .target = target,
            .optimize = optimize,
        });
        setupZriscvCli(zriscv_cli_test, options_package, trace);

        const zriscv_gui_test = b.addTest(.{
            .root_source_file = .{ .path = "zriscv_gui/main.zig" },
            .target = target,
            .optimize = optimize,
        });
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

fn setupZriscvCli(exe: *std.Build.CompileStep, options_package: *std.Build.OptionsStep, trace: bool) void {
    exe.addOptions("build_options", options_package);
    exe.addAnonymousModule("args", .{ .source_file = .{ .path = "libraries/zig-args/args.zig" } });
    exe.addAnonymousModule("known_folders", .{ .source_file = .{ .path = "libraries/known-folders/known-folders.zig" } });
    exe.addAnonymousModule("bestline", .{ .source_file = .{ .path = "libraries/bestline/bestline.zig" } });
    exe.addAnonymousModule("tracy", .{ .source_file = .{ .path = "libraries/tracy/tracy.zig" } });

    exe.addModule("zriscv", getZriscvModule(exe.builder, options_package));

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

fn setupZriscvGui(exe: *std.Build.CompileStep, options_package: *std.Build.OptionsStep, trace: bool) void {
    exe.addOptions("build_options", options_package);
    exe.addAnonymousModule("args", .{ .source_file = .{ .path = "libraries/zig-args/args.zig" } });
    exe.addAnonymousModule("known_folders", .{ .source_file = .{ .path = "libraries/known-folders/known-folders.zig" } });
    exe.addAnonymousModule("bestline", .{ .source_file = .{ .path = "libraries/bestline/bestline.zig" } });
    exe.addAnonymousModule("tracy", .{ .source_file = .{ .path = "libraries/tracy/tracy.zig" } });

    exe.addModule("zriscv", getZriscvModule(exe.builder, options_package));

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

fn setupZriscvForTests(exe: *std.Build.LibExeObjStep, options_package: *std.Build.OptionsStep, trace: bool) void {
    exe.addOptions("build_options", options_package);
    exe.addAnonymousModule("tracy", .{ .source_file = .{ .path = "libraries/tracy/tracy.zig" } });
    exe.addAnonymousModule("bitjuggle", .{ .source_file = .{ .path = "libraries/zig-bitjuggle/bitjuggle.zig" } });

    exe.addModule("zriscv", getZriscvModule(exe.builder, options_package));

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

fn getOptionsPkg(
    b: *std.Build,
    trace: bool,
    trace_callstack: bool,
    output: bool,
    dont_panic_on_unimplemented: bool,
) !*std.Build.OptionsStep {
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
            "git", "-C", b.build_root.path.?, "describe", "--match", "*.*.*", "--tags",
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

fn getZriscvModule(b: *std.Build, options_package: *std.Build.OptionsStep) *std.Build.Module {
    const static = struct {
        var module: ?*std.Build.Module = null;
    };

    if (static.module) |module| return module;

    const recursive_module = b.createModule(.{
        .source_file = .{ .path = "zriscv/zriscv.zig" },
    });

    static.module = b.createModule(.{
        .source_file = .{ .path = "zriscv/zriscv.zig" },
        .dependencies = &.{
            .{ .name = "build_options", .module = options_package.createModule() },
            .{ .name = "zriscv", .module = recursive_module },
            .{ .name = "tracy", .module = b.createModule(.{ .source_file = .{ .path = "libraries/tracy/tracy.zig" } }) },
            .{ .name = "bitjuggle", .module = b.createModule(.{ .source_file = .{ .path = "libraries/zig-bitjuggle/bitjuggle.zig" } }) },
        },
    });

    return static.module.?;
}
