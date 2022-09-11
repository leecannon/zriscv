const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const args = @import("args");
const lib = @import("lib.zig");
const Interactive = @import("Interactive.zig");

pub const is_debug_or_test = builtin.is_test or builtin.mode == .Debug;

const execution_options: lib.ExecutionOptions = .{};

pub fn main() if (is_debug_or_test) anyerror!u8 else u8 {
    const main_z = lib.traceNamed(@src(), "main");
    // this causes the frame to start with our main instead of `std.start`
    lib.traceFrameMark();

    var gpa = if (is_debug_or_test) std.heap.GeneralPurposeAllocator(.{}){} else {};

    defer {
        if (is_debug_or_test) _ = gpa.deinit();
        main_z.end();
    }

    const gpa_allocator = if (is_debug_or_test) gpa.allocator() else std.heap.c_allocator;
    var tracy_allocator = if (build_options.trace) lib.tracyAllocator(gpa_allocator) else {};
    const allocator: std.mem.Allocator = if (build_options.trace) tracy_allocator.allocator() else gpa_allocator;

    const stderr = std.io.getStdErr().writer();

    const options = parseArguments(allocator, stderr);
    defer if (is_debug_or_test) options.deinit();

    const riscof_mode = if (options.verb.? == .system) options.verb.?.system.signature != null else false;

    const executable = lib.Executable.load(
        allocator,
        stderr,
        options.positionals[0], // `parseArguments` ensures a single positional is given
        riscof_mode,
    ) catch |err| {
        if (is_debug_or_test) return err;
        return 1;
    };
    defer if (is_debug_or_test) executable.unload(allocator);

    // `parseArguments` ensures a verb was given
    _ = switch (options.verb.?) {
        .user => |user_mode_options| userMode(
            allocator,
            executable,
            user_mode_options,
            stderr,
        ),
        .system => |system_mode_options| systemMode(
            allocator,
            executable,
            system_mode_options,
            stderr,
        ),
    } catch |err| {
        if (is_debug_or_test) return err;
        return 1;
    };

    return 0;
}

fn systemMode(
    allocator: std.mem.Allocator,
    executable: lib.Executable,
    system_mode_options: SystemModeOptions,
    stderr: anytype,
) !void {
    const z = lib.traceNamed(@src(), "system mode");
    defer z.end();

    if (system_mode_options.signature) |sig| {
        std.debug.print("{s}\n", .{sig});
    }

    if (system_mode_options.interactive and system_mode_options.harts > 1) {
        stderr.writeAll("ERROR: interactive mode is not supported with multiple harts\n") catch unreachable;
        return error.InteractiveDoesNotSupportMultipleHarts;
    }

    if (system_mode_options.harts == 0) {
        stderr.writeAll("ERROR: non-zero number of harts required\n") catch unreachable;
        return error.ZeroHartsRequested;
    }

    // TODO: Support multiple harts
    if (system_mode_options.harts > 1) {
        @panic("UNIMPLEMENTED: multiple harts"); // TODO: multiple harts
    }

    const machine = lib.SystemMachine.create(
        allocator,
        system_mode_options.memory * 1024 * 1024, // convert from MiB to bytes
        executable,
        system_mode_options.harts,
    ) catch |err| switch (err) {
        error.OutOfBoundsWrite => |e| {
            stderr.writeAll("ERROR: insufficent memory provided to load executable file\n") catch unreachable;
            return e;
        },
        else => |e| {
            stderr.print("ERROR: failed to create machine: {s}\n", .{@errorName(err)}) catch unreachable;
            return e;
        },
    };
    defer if (is_debug_or_test) machine.destroy();

    if (system_mode_options.interactive) {
        return interactiveSystemMode(allocator, machine, stderr);
    }

    // TODO: Support multiple harts
    while (true) {
        lib.step(.system, &machine.harts[0], if (build_options.output) stderr else {}, execution_options, true) catch |err| {
            stderr.print("execution error: {s}\n", .{@errorName(err)}) catch unreachable;
            return err;
        };
    }
}

fn interactiveSystemMode(allocator: std.mem.Allocator, machine: *lib.SystemMachine, stderr: anytype) !void {
    const z = lib.traceNamed(@src(), "interactive system mode");
    defer z.end();

    std.debug.assert(machine.harts.len == 1);

    const hart: *lib.SystemHart = &machine.harts[0];

    const stdout = std.io.getStdOut().writer();

    var timer = std.time.Timer.start() catch |err| {
        stderr.print("ERROR: failed to start timer: {s}\n", .{@errorName(err)}) catch unreachable;
        return err;
    };

    const interactive = try Interactive.init(allocator, machine.executable.file_path);
    defer if (is_debug_or_test) interactive.deinit();

    var opt_break_point: ?u64 = null;

    while (interactive.getInput(stdout, stderr)) |input| {
        const user_input_z = lib.traceNamed(@src(), "action user input");
        defer user_input_z.end();

        switch (input) {
            .run, .output_run => {
                user_input_z.addText("run");

                const output = input == .output_run;

                timer.reset();

                if (opt_break_point) |break_point| {
                    while (hart.pc != break_point) {
                        if (output) {
                            lib.step(.system, hart, stdout, execution_options, true) catch |err| {
                                stderr.print("execution error: {s}\n", .{@errorName(err)}) catch unreachable;
                                break;
                            };
                        } else {
                            lib.step(.system, hart, {}, execution_options, true) catch |err| {
                                stderr.print("execution error: {s}\n", .{@errorName(err)}) catch unreachable;
                                break;
                            };
                        }
                    } else {
                        stdout.writeAll("hit breakpoint\n") catch unreachable;
                    }
                } else {
                    if (output) {
                        while (true) {
                            lib.step(.system, hart, stdout, execution_options, true) catch |err| {
                                stderr.print("execution error: {s}\n", .{@errorName(err)}) catch unreachable;
                                break;
                            };
                        }
                    } else {
                        while (true) {
                            lib.step(.system, hart, {}, execution_options, true) catch |err| {
                                stderr.print("execution error: {s}\n", .{@errorName(err)}) catch unreachable;
                                break;
                            };
                        }
                    }
                }

                const elapsed = timer.read();
                stdout.print("execution took: {} ({} ns)\n", .{ std.fmt.fmtDuration(elapsed), elapsed }) catch unreachable;
            },
            .step, .output_step => {
                user_input_z.addText("step");

                const output = input == .output_step;

                timer.reset();

                if (output) {
                    lib.step(.system, hart, stdout, execution_options, true) catch |err| {
                        stderr.print("execution error: {s}\n", .{@errorName(err)}) catch unreachable;
                    };
                } else {
                    lib.step(.system, hart, {}, execution_options, true) catch |err| {
                        stderr.print("execution error: {s}\n", .{@errorName(err)}) catch unreachable;
                    };
                }

                const elapsed = timer.read();
                stdout.print("execution took: {} ({} ns)\n", .{ std.fmt.fmtDuration(elapsed), elapsed }) catch unreachable;
            },
            .whatif => {
                user_input_z.addText("whatif");

                lib.step(.system, hart, stdout, execution_options, false) catch |err| {
                    stderr.print("execution error: {s}\n", .{@errorName(err)}) catch unreachable;
                };
            },
            .dump => {
                user_input_z.addText("dump");

                @panic("UNIMPLEMENTED: dump machine state"); // TODO: dump machine state
            },
            .reset => {
                user_input_z.addText("reset");

                machine.reset(true) catch |err| {
                    stderr.print("\nERROR: failed to reset machine state: {s}\n", .{@errorName(err)}) catch unreachable;
                    return err;
                };

                stdout.writeAll("reset machine state\n") catch unreachable;
            },
            .breakpoint => |addr| {
                user_input_z.addText("breakpoint");

                const memory_size = machine.memory.memory.len;
                if (addr >= memory_size) {
                    stderr.print("ERROR: breakpoint 0x{x} overflows memory size 0x{x}\n", .{ addr, memory_size }) catch unreachable;
                    continue;
                }

                stdout.print("set breakpoint to 0x{x}\n", .{addr}) catch unreachable;

                opt_break_point = addr;
            },
        }
    }
}

fn userMode(
    allocator: std.mem.Allocator,
    executable: lib.Executable,
    user_mode_options: UserModeOptions,
    stderr: anytype,
) !void {
    const z = lib.traceNamed(@src(), "user mode");
    defer z.end();

    _ = allocator;
    _ = executable;
    _ = user_mode_options;
    _ = stderr;
    @panic("UNIMPLEMENTED: user mode"); // TODO: user mode
}

/// This function parses the arguments from the user.
/// It performs the below additional functionality:
///     - Prints any errors during parsing
///     - Handles the help option
///     - Handles the version option
///     - Validates that a verb has been given
///     - Validates that a single file path has been given
fn parseArguments(
    allocator: std.mem.Allocator,
    stderr: anytype,
) args.ParseArgsResult(SharedArguments, ModeOptions) {
    const z = lib.traceNamed(@src(), "parse arguments");
    defer z.end();

    const options = args.parseWithVerbForCurrentProcess(
        SharedArguments,
        ModeOptions,
        allocator,
        .print,
    ) catch {
        std.process.exit(1);
    };

    if (options.options.help) {
        std.io.getStdOut().writeAll(usage) catch unreachable;
        std.process.exit(0);
    }

    if (options.options.version) {
        std.io.getStdOut().writeAll("zriscv " ++ build_options.version ++ "\n") catch unreachable;
        std.process.exit(0);
    }

    if (options.verb == null) {
        stderr.writeAll("ERROR: no execution mode given\n") catch unreachable;
        std.process.exit(1);
    }

    if (options.positionals.len < 1) {
        stderr.writeAll("ERROR: no file path provided\n") catch unreachable;
        std.process.exit(1);
    }

    if (options.positionals.len > 1) {
        stderr.writeAll("ERROR: multiple files are not supported\n") catch unreachable;
        std.process.exit(1);
    }

    return options;
}

const usage =
    \\usage: riscv [standard options] MODE [mode specific options] FILE
    \\
    \\Load FILE and execute is as a riscv program in either system or user mode.
    \\
    \\Modes:
    \\    user   - will run the executable as a userspace program, translating syscalls to and from the host
    \\    system - will run the executable as a system/kernel program
    \\
    \\Standard options:
    \\    -h, --help                 display this help and exit
    \\    -v, --version              display the version information and exit
    \\
    \\System mode options:
    \\    -i, --interactive          run in a interactive repl mode, only supported with a single hart
    \\
    \\    -m, --memory=[MEMORY]      the amount of memory to make available to the emulated machine (MiB), defaults to 20MiB
    \\
    \\    --harts=[HARTS]            the number of harts the system has, defaults to 1, must be greater than zero
    \\
    \\    --signature=[PATH]         runs the emulator in riscof test mode and writes out the signature to [PATH]
    \\
;

const ModeOptions = union(lib.Mode) {
    user: UserModeOptions,
    system: SystemModeOptions,
};

const SharedArguments = struct {
    help: bool = false,
    version: bool = false,

    pub const shorthands = .{
        .h = "help",
        .v = "version",
    };
};

const UserModeOptions = struct {};

const SystemModeOptions = struct {
    /// memory size in MiB, defaults to 20MiB
    memory: usize = 20,
    harts: usize = 1,
    interactive: bool = false,
    signature: ?[]const u8 = null,

    pub const shorthands = .{
        .m = "memory",
        .i = "interactive",
    };
};

comptime {
    refAllDeclsRecursive(@This());
}

// This code is from `std.testing.refAllDeclsRecursive` but as it is in the file it can access private decls
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (decl.is_pub) {
            if (@TypeOf(@field(T, decl.name)) == type) {
                switch (@typeInfo(@field(T, decl.name))) {
                    .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name)),
                    else => {},
                }
            }
            _ = @field(T, decl.name);
        }
    }
}
