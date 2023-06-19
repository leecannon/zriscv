const std = @import("std");

// TODO: Re-write this file

const zriscv_version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 1 };

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const output = b.option(bool, "output", "output when run in non-interactive system mode") orelse false;
    const dont_panic_on_unimplemented = b.option(bool, "unimp", "*don't* panic on unimplemented instruction execution") orelse false;

    const trace = b.option(bool, "trace", "enable tracy tracing") orelse false;
    const trace_callstack = b.option(bool, "trace-callstack", "enable tracy callstack (does nothing without trace option)") orelse false;

    const options = try getOptions(b, trace, trace_callstack, output, dont_panic_on_unimplemented);

    _ = b.addModule("args", .{ .source_file = .{ .path = "libraries/zig-args/args.zig" } });
    _ = b.addModule("known_folders", .{ .source_file = .{ .path = "libraries/known-folders/known-folders.zig" } });
    _ = b.addModule("bestline", .{ .source_file = .{ .path = "libraries/bestline/bestline.zig" } });
    _ = b.addModule("tracy", .{ .source_file = .{ .path = "libraries/tracy/tracy.zig" } });
    _ = b.addModule("bitjuggle", .{ .source_file = .{ .path = "libraries/zig-bitjuggle/bitjuggle.zig" } });

    const zriscv_module = b.addModule("zriscv", .{
        .source_file = .{ .path = "zriscv/zriscv.zig" },
        .dependencies = &.{
            .{ .name = "build_options", .module = options.module_options.createModule() },
            .{ .name = "tracy", .module = b.modules.get("tracy").? },
            .{ .name = "bitjuggle", .module = b.modules.get("bitjuggle").? },
        },
    });
    zriscv_module.dependencies.put("zriscv", zriscv_module) catch unreachable;

    // zriscv_cli
    {
        const zriscv_cli = b.addExecutable(.{
            .name = "zriscv",
            .root_source_file = .{ .path = "zriscv_cli/main.zig" },
            .target = target,
            .optimize = optimize,
        });

        setupZriscvCli(b, zriscv_cli, options, zriscv_module, trace);
        b.installArtifact(zriscv_cli);

        const run_cmd = b.addRunArtifact(zriscv_cli);
        run_cmd.has_side_effects = true;
        run_cmd.stdio = .inherit;
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
        b.installArtifact(zriscv_gui);
        setupZriscvGui(b, zriscv_gui, options, zriscv_module, trace);

        const run_cmd = b.addRunArtifact(zriscv_gui);
        run_cmd.has_side_effects = true;
        run_cmd.stdio = .inherit;
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run_gui", "Run the GUI emulator");
        run_step.dependOn(&run_cmd.step);
    }

    // Tests
    // {
    //     const zriscv_test = b.addTest(.{
    //         .root_source_file = .{ .path = "zriscv/zriscv.zig" },
    //         .target = target,
    //         .optimize = optimize,
    //     });
    //     setupZriscvForTests(b, zriscv_test, options, zriscv_module, trace);

    //     const zriscv_cli_test = b.addTest(.{
    //         .root_source_file = .{ .path = "zriscv_cli/main.zig" },
    //         .target = target,
    //         .optimize = optimize,
    //     });
    //     setupZriscvCli(b, zriscv_cli_test, options, zriscv_module, trace);

    //     const zriscv_gui_test = b.addTest(.{
    //         .root_source_file = .{ .path = "zriscv_gui/main.zig" },
    //         .target = target,
    //         .optimize = optimize,
    //     });
    //     setupZriscvGui(b, zriscv_gui_test, options, zriscv_module, trace);

    //     const test_step = b.step("test", "Run the tests");
    //     test_step.dependOn(&zriscv_test.step);
    //     test_step.dependOn(&zriscv_cli_test.step);
    //     test_step.dependOn(&zriscv_gui_test.step);

    //     b.default_step = test_step;
    // }

    // Riscof
    {
        const build_path = comptime std.fs.path.dirname(@src().file).?;
        const run_riscof_step = b.addSystemCommand(&.{build_path ++ "/riscof/run_tests.sh"});
        run_riscof_step.has_side_effects = true;
        run_riscof_step.stdio = .inherit;
        run_riscof_step.step.dependOn(b.getInstallStep());

        const riscof_step = b.step("riscof", "Run the riscof tests");
        riscof_step.dependOn(&run_riscof_step.step);
    }
}

fn setupZriscvCli(
    b: *std.Build,
    exe: *std.Build.CompileStep,
    options: Options,
    zriscv_module: *std.Build.Module,
    trace: bool,
) void {
    exe.addOptions("build_options", options.cli_options);

    exe.addModule("args", b.modules.get("args").?);
    exe.addModule("known_folders", b.modules.get("known_folders").?);
    exe.addModule("bestline", b.modules.get("bestline").?);
    exe.addModule("tracy", b.modules.get("tracy").?);

    exe.addModule("zriscv", zriscv_module);

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

fn setupZriscvGui(
    b: *std.Build,
    exe: *std.Build.CompileStep,
    options: Options,
    zriscv_module: *std.Build.Module,
    trace: bool,
) void {
    exe.addOptions("build_options", options.gui_options);

    exe.addModule("args", b.modules.get("args").?);
    exe.addModule("known_folders", b.modules.get("known_folders").?);
    exe.addModule("bestline", b.modules.get("bestline").?);
    exe.addModule("tracy", b.modules.get("tracy").?);

    exe.addModule("zriscv", zriscv_module);

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

fn setupZriscvForTests(
    b: *std.Build,
    exe: *std.Build.LibExeObjStep,
    options: Options,
    zriscv_module: *std.Build.Module,
    trace: bool,
) void {
    exe.addOptions("build_options", options.module_options);

    exe.addModule("bitjuggle", b.modules.get("bitjuggle").?);
    exe.addModule("tracy", b.modules.get("tracy").?);

    exe.addModule("zriscv", zriscv_module);

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

const Options = struct {
    module_options: *std.Build.OptionsStep = undefined,
    cli_options: *std.Build.OptionsStep = undefined,
    gui_options: *std.Build.OptionsStep = undefined,

    fn addToAll(self: Options, comptime T: type, name: []const u8, value: T) void {
        self.module_options.addOption(T, name, value);
        self.cli_options.addOption(T, name, value);
        self.gui_options.addOption(T, name, value);
    }
};

fn getOptions(
    b: *std.Build,
    trace: bool,
    trace_callstack: bool,
    output: bool,
    dont_panic_on_unimplemented: bool,
) !Options {
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

                const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
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

    const result = Options{
        .module_options = b.addOptions(),
        .cli_options = b.addOptions(),
        .gui_options = b.addOptions(),
    };

    { // module only
        result.module_options.addOption(bool, "dont_panic_on_unimplemented", dont_panic_on_unimplemented);
    }

    { // cli only
        result.cli_options.addOption(bool, "output", output);
        result.cli_options.addOption([:0]const u8, "version", try b.allocator.dupeZ(u8, version));
    }

    { // all
        result.addToAll(bool, "trace", trace);
        result.addToAll(bool, "trace_callstack", trace_callstack);
    }

    return result;
}
