const std = @import("std");
const args = @import("args");
const builtin = @import("builtin");

const Executable = @import("Executable.zig");
const engine = @import("engine.zig");
const Machine = @import("machine.zig").Machine;
const Hart = @import("hart.zig").Hart;

pub const is_debug_or_test = builtin.is_test or builtin.mode == .Debug;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() if (is_debug_or_test) anyerror!u8 else u8 {
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stderr = std.io.getStdErr().writer();

    const options = parseArguments(allocator, stderr);
    defer options.deinit();

    const executable = Executable.load(
        allocator,
        stderr,
        options.positionals[0], // `parseArguments` ensures a single positional is given
    ) catch |err| {
        if (is_debug_or_test) return err;
        return 1;
    };
    defer executable.unload(allocator);

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
    executable: Executable,
    system_mode_options: SystemModeOptions,
    stderr: anytype,
) !void {
    if (system_mode_options.interactive and system_mode_options.harts > 1) {
        stderr.writeAll("ERROR: interactive mode is not supported with multiple harts\n") catch unreachable;
        return error.InteractiveDoesNotSupportMultipleHarts;
    }

    if (system_mode_options.harts == 0) {
        stderr.writeAll("ERROR: non-zero number of harts required\n") catch unreachable;
        return error.ZeroHartsRequested;
    }

    const machine: Machine(.system) = @import("machine.zig").systemMachine(
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
    defer machine.destroy();

    if (system_mode_options.interactive) {
        return interactiveSystemMode(machine, stderr);
    }

    @panic("UNIMPLEMENTED"); // TODO: Non-interactive system mode
}

fn interactiveSystemMode(machine: Machine(.system), stderr: anytype) !void {
    std.debug.assert(machine.getSystem().harts.len == 1);

    const hart: *Hart(.system) = &machine.getSystem().harts[0];

    const raw_stdin = std.io.getStdIn();
    const stdin = raw_stdin.reader();
    const stdout = std.io.getStdOut().writer();

    const previous_terminal_settings = std.os.tcgetattr(raw_stdin.handle) catch |err| {
        stderr.print("ERROR: failed to capture termios settings: {s}\n", .{@errorName(err)}) catch unreachable;
        return err;
    };
    setRawMode(previous_terminal_settings, raw_stdin.handle) catch |err| {
        stderr.print("ERROR: failed to set raw console mode: {s}\n", .{@errorName(err)}) catch unreachable;
        return err;
    };
    defer {
        std.os.tcsetattr(raw_stdin.handle, .FLUSH, previous_terminal_settings) catch |err| {
            stderr.print("ERROR: failed to restore termios settings: {s}\n", .{@errorName(err)}) catch unreachable;
        };
        stdout.writeByte('\n') catch unreachable;
    }

    var timer = std.time.Timer.start() catch |err| {
        stderr.print("ERROR: failed to start timer: {s}\n", .{@errorName(err)}) catch unreachable;
        return err;
    };

    var opt_break_point: ?u64 = null;

    while (true) {
        stdout.writeAll("> ") catch unreachable;

        const input = readCharFromRaw(stdin) catch |err| {
            stderr.print("ERROR: failed to read from stdin: {s}\n", .{@errorName(err)}) catch unreachable;
            return err;
        };

        // const input = stdin.readByte() catch |err| {};

        switch (input) {
            '\n' => stdout.writeAll(interactive_help_menu) catch unreachable,
            '?', 'h' => stdout.writeAll("\n" ++ interactive_help_menu) catch unreachable,
            '0' => {
                machine.reset(true) catch |err| {
                    stderr.print("\nERROR: failed to reset machine state: {s}\n", .{@errorName(err)}) catch unreachable;
                    return err;
                };

                stdout.writeAll("\nreset machine state\n") catch unreachable;
            },
            'b' => {
                // disable raw mode to enable user to enter hex string
                std.os.tcsetattr(raw_stdin.handle, .FLUSH, previous_terminal_settings) catch |err| {
                    stderr.print("\nERROR: failed to restore termios settings: {s}\n", .{@errorName(err)}) catch unreachable;
                    return err;
                };
                defer setRawMode(previous_terminal_settings, raw_stdin.handle) catch |err| {
                    stderr.print("ERROR: failed to set raw console mode: {s}\n", .{@errorName(err)}) catch unreachable;
                };

                var hex_buffer: [86]u8 = undefined;

                const hex_str: []const u8 = stdin.readUntilDelimiterOrEof(&hex_buffer, '\n') catch |err| {
                    stderr.print("ERROR: failed to read from stdin: {s}\n", .{@errorName(err)}) catch unreachable;
                    return err;
                } orelse "";

                if (hex_str.len == 0) {
                    opt_break_point = null;
                    stdout.writeAll("cleared breakpoint\n") catch unreachable;
                    continue;
                }

                const addr = std.fmt.parseUnsigned(u64, hex_str, 16) catch |err| {
                    stderr.print("ERROR: unable to parse '{s}' as hex: {s}\n", .{ hex_str, @errorName(err) }) catch unreachable;
                    continue;
                };

                const memory_size = machine.getSystem().memory.getSystem().memory.len;
                if (addr >= memory_size) {
                    stderr.print("ERROR: breakpoint 0x{x} overflows memory size 0x{x}\n", .{ addr, memory_size }) catch unreachable;
                    continue;
                }

                stdout.print("set breakpoint to 0x{x}\n", .{addr}) catch unreachable;

                opt_break_point = addr;
            },
            'r', 'e' => {
                const output = input == 'e';

                stdout.writeByte('\n') catch unreachable;

                timer.reset();

                if (opt_break_point) |break_point| {
                    while (hart.pc != break_point) {
                        if (output) {
                            engine.step(.system, hart, stdout) catch |err| {
                                stdout.print("error: {s}\n", .{@errorName(err)}) catch unreachable;
                                break;
                            };
                        } else {
                            engine.step(.system, hart, {}) catch |err| {
                                stdout.print("error: {s}\n", .{@errorName(err)}) catch unreachable;
                                break;
                            };
                        }
                    } else {
                        stdout.writeAll("hit breakpoint\n") catch unreachable;
                    }
                } else {
                    if (output) {
                        engine.run(.system, hart, stdout) catch |err| {
                            stdout.print("error: {s}\n", .{@errorName(err)}) catch unreachable;
                            break;
                        };
                    } else {
                        engine.run(.system, hart, {}) catch |err| {
                            stdout.print("error: {s}\n", .{@errorName(err)}) catch unreachable;
                            break;
                        };
                    }
                }

                const elapsed = timer.read();
                stdout.print("execution took: {} ({} ns)\n", .{ std.fmt.fmtDuration(elapsed), elapsed }) catch unreachable;
            },
            's', 'n' => {
                const output = input == 's';

                stdout.writeByte('\n') catch unreachable;

                timer.reset();

                if (output) {
                    engine.step(.system, hart, stdout) catch |err| {
                        stdout.print("error: {s}\n", .{@errorName(err)}) catch unreachable;
                    };
                } else {
                    engine.step(.system, hart, {}) catch |err| {
                        stdout.print("error: {s}\n", .{@errorName(err)}) catch unreachable;
                    };
                }

                const elapsed = timer.read();
                stdout.print("execution took: {} ({} ns)\n", .{ std.fmt.fmtDuration(elapsed), elapsed }) catch unreachable;
            },
            'd' => {
                stdout.writeByte('\n') catch unreachable;
                @panic("UNIMPLEMENTED"); // TODO: dump machine state
            },
            'q' => return,
            0x1b => {
                // escape, arrow keys, etc
                const key = readEscapeCode(raw_stdin) catch |err| {
                    stderr.print("ERROR: failed to read from stdin: {s}\n", .{@errorName(err)}) catch unreachable;
                    return err;
                };

                if (key == .escape) return;

                stdout.writeAll("\ninvalid option\n") catch unreachable;
            },
            else => {
                stdout.writeAll("\ninvalid option\n") catch unreachable;
            },
        }
    }
}

fn readEscapeCode(stdin: std.fs.File) !EscapeKey {
    var seq: [3]u8 = undefined;

    if ((try stdin.read(seq[0..1])) != 1) return .escape;

    if ((try stdin.read(seq[1..2])) != 1) return .escape;

    if (seq[0] == '[') {
        if (seq[1] >= '0' and seq[1] <= '9') {
            if ((try stdin.read(seq[2..3])) != 1) return .escape;

            if (seq[2] == '~') {
                switch (seq[1]) {
                    '5' => return .page_up,
                    '6' => return .page_down,
                    else => {},
                }
            }
        } else {
            switch (seq[1]) {
                'A' => return .up_arrow,
                'B' => return .down_arrow,
                'C' => return .right_arrow,
                'D' => return .left_arrow,
                else => {},
            }
        }
    }

    return .escape;
}

const EscapeKey = union(enum) {
    up_arrow,
    left_arrow,
    right_arrow,
    down_arrow,

    page_up,
    page_down,

    escape,

    key: u8,
};

fn readCharFromRaw(reader: anytype) !u8 {
    while (true) {
        return reader.readByte() catch |err| switch (err) {
            error.EndOfStream => continue,
            else => |e| return e,
        };
    }
}

const interactive_help_menu =
    \\help:
    \\ ?|h|Enter|Esc - this help menu
    \\             r - run without output (this will not stop unless a breakpoint is hit, or an error)
    \\             e - run with output (this will not stop unless a breakpoint is hit, or an error)
    \\       b[addr] - set breakpoint, [addr] must be in hex, blank [addr] clears the breakpoint
    \\             s - single step with output
    \\             n - single step without output
    \\             d - dump machine state
    \\             0 - reset machine
    \\             q - quit
    \\
;

fn setRawMode(previous: std.os.termios, handle: std.os.fd_t) !void {
    var current_settings = previous;

    // Raw mode with no signals and some other stuff disabled
    // https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
    current_settings.iflag &= ~(std.os.linux.IXON | std.os.linux.BRKINT | std.os.linux.INPCK | std.os.linux.ISTRIP);
    current_settings.cflag |= std.os.linux.CS8;
    current_settings.lflag &= ~(std.os.linux.ICANON | std.os.linux.ISIG | std.os.linux.IEXTEN);
    current_settings.cc[std.os.linux.V.MIN] = 0;

    try std.os.tcsetattr(handle, .FLUSH, current_settings);
}

fn userMode(
    allocator: std.mem.Allocator,
    executable: Executable,
    user_mode_options: UserModeOptions,
    stderr: anytype,
) !void {
    _ = allocator;
    _ = executable;
    _ = user_mode_options;
    _ = stderr;
    @panic("UNIMPLEMENTED"); // TODO: Implement user mode
}

/// This function parses the arguments from the user.
/// It performs the below additional functionality:
///     - Prints any errors during parsing
///     - Handles the help option
///     - Validates that a verb has been given
///     - Validates that a single file path has been given
fn parseArguments(
    allocator: std.mem.Allocator,
    stderr: anytype,
) args.ParseArgsResult(SharedArguments, ModeOptions) {
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
    \\
    \\System mode options:
    \\    -i, --interactive          run in a interactive repl mode, only supported with a single hart
    \\
    \\    -m, --memory=[MEMORY]      the amount of memory to make available to the emulated machine (MiB), defaults to 20MiB
    \\
    \\    --harts=[HARTS]            the number of harts the system has, defaults to 1, must be greater than zero
    \\
;

const ModeOptions = union(engine.Mode) {
    user: UserModeOptions,
    system: SystemModeOptions,
};

const SharedArguments = struct {
    help: bool = false,

    pub const shorthands = .{
        .h = "help",
    };
};

const UserModeOptions = struct {};

const SystemModeOptions = struct {
    /// memory size in MiB, defaults to 20MiB
    memory: usize = 20,
    harts: usize = 1,
    interactive: bool = false,

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
