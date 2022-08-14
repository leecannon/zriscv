const std = @import("std");
const args = @import("args");
const builtin = @import("builtin");

const engine = @import("engine.zig");
const Memory = @import("Memory.zig");
const Machine = @import("Machine.zig");

pub const is_debug_or_test = builtin.is_test or builtin.mode == .Debug;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() if (is_debug_or_test) anyerror!u8 else u8 {
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    const options = parseArguments(allocator, stdout, stderr);
    defer options.deinit();

    const executable = Executable.load(
        allocator,
        stderr,
        options.positionals[0], // `parseArguments` ensures a single positional is given
        options.options.format,
    );
    defer executable.unload(allocator);

    // `parseArguments` ensures a verb was given
    switch (options.verb.?) {
        .user => @panic("UNIMPLEMENTED"), // TODO: Implement user mode
        .system => @panic("UNIMPLEMENTED"), // TODO: Implement system mode
    }

    return 0;
}

// OLD
fn repl(allocator: std.mem.Allocator, memory_size: usize, memory_description: []const Memory.Descriptor) !void {
    const raw_stdin = std.io.getStdIn();
    const stdin = raw_stdin.reader();
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

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

    const machine = Machine.create(
        allocator,
        memory_size,
        memory_description,
        1, // TODO: Support multiple harts
    ) catch |err| switch (err) {
        error.NonZeroNumberOfHartsRequired => unreachable, // we pass 1
        error.OutOfBoundsWrite => |e| {
            stderr.writeAll("ERROR: insufficent memory provided to load elf file\n") catch unreachable;
            if (is_debug_or_test) return e;
            return 1;
        },
        else => |e| {
            if (is_debug_or_test) return e;
            return 1;
        },
    };
    defer machine.destory();

    var timer = std.time.Timer.start() catch |err| {
        stderr.print("ERROR: failed to start timer: {s}\n", .{@errorName(err)}) catch unreachable;
        return err;
    };

    var opt_break_point: ?u64 = null;

    while (true) {
        stdout.writeAll("> ") catch unreachable;

        const input = stdin.readByte() catch |err| {
            stderr.print("ERROR: failed to read from stdin: {s}\n", .{@errorName(err)}) catch unreachable;
            return err;
        };

        switch (input) {
            '?', 'h', '\n' => stdout.writeAll(
                \\help:
                \\ ?|h|'\n' - this help menu
                \\        r - run without output (this will not stop unless a breakpoint is hit, or an error)
                \\        e - run with output (this will not stop unless a breakpoint is hit, or an error)
                \\  b[addr] - set breakpoint, [addr] must be in hex, blank [addr] clears the breakpoint 
                \\        s - single step with output
                \\        n - single step without output
                \\        d - dump machine state
                \\        0 - reset machine
                \\        q - quit
                \\
            ) catch unreachable,
            '0' => {
                machine.reset(memory_description) catch |err| {
                    stderr.print("ERROR: failed to reset machine state: {s}\n", .{@errorName(err)}) catch unreachable;
                    return err;
                };

                stdout.writeAll("\nreset machine state\n") catch unreachable;
            },
            'b' => {
                // disable raw mode to enable user to enter hex string
                std.os.tcsetattr(raw_stdin.handle, .FLUSH, previous_terminal_settings) catch |err| {
                    stderr.print("ERROR: failed to restore termios settings: {s}\n", .{@errorName(err)}) catch unreachable;
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

                // TODO: Check if breakpoint exceeds CPU memory

                stdout.print("set breakpoint to 0x{x}\n", .{addr}) catch unreachable;

                opt_break_point = addr;
            },
            'r', 'e' => {
                // TODO: Support multiple harts

                const output = input == 'e';

                stdout.writeByte('\n') catch unreachable;

                timer.reset();

                if (opt_break_point) |break_point| {
                    while (machine.harts[0].pc != break_point) {
                        if (output) {
                            engine.step(&machine.harts[0], stdout) catch |err| {
                                stdout.print("error: {s}\n", .{@errorName(err)}) catch unreachable;
                                break;
                            };
                        } else {
                            engine.step(&machine.harts[0], {}) catch |err| {
                                stdout.print("error: {s}\n", .{@errorName(err)}) catch unreachable;
                                break;
                            };
                        }
                    } else {
                        stdout.writeAll("hit breakpoint\n") catch unreachable;
                    }
                } else {
                    if (output) {
                        engine.run(&machine.harts[0], stdout) catch |err| {
                            stdout.print("error: {s}\n", .{@errorName(err)}) catch unreachable;
                            break;
                        };
                    } else {
                        engine.run(&machine.harts[0], {}) catch |err| {
                            stdout.print("error: {s}\n", .{@errorName(err)}) catch unreachable;
                            break;
                        };
                    }
                }

                const elapsed = timer.read();
                stdout.print("execution took: {} ({} ns)\n", .{ std.fmt.fmtDuration(elapsed), elapsed }) catch unreachable;
            },
            's', 'n' => {
                // TODO: Support multiple harts

                const output = input == 's';

                stdout.writeByte('\n') catch unreachable;

                timer.reset();

                if (output) {
                    engine.step(&machine.harts[0], stdout) catch |err| {
                        stdout.print("error: {s}\n", .{@errorName(err)}) catch unreachable;
                    };
                } else {
                    engine.step(&machine.harts[0], {}) catch |err| {
                        stdout.print("error: {s}\n", .{@errorName(err)}) catch unreachable;
                    };
                }

                const elapsed = timer.read();
                stdout.print("execution took: {} ({} ns)\n", .{ std.fmt.fmtDuration(elapsed), elapsed }) catch unreachable;
            },
            'd' => {
                stdout.writeByte('\n') catch unreachable;
                @panic("unimplemented"); // TODO: dump machine state
            },
            'q' => return,
            else => {
                stdout.writeAll("\ninvalid option\n") catch unreachable;
            },
        }
    }
}

// OLD
fn setRawMode(previous: std.os.termios, handle: std.os.fd_t) !void {
    var current_settings = previous;

    current_settings.lflag &= ~@as(u32, std.os.linux.ICANON);

    try std.os.tcsetattr(handle, .FLUSH, current_settings);
}

const Executable = struct {
    contents: []align(std.mem.page_size) const u8,
    memory_description: []const Memory.Descriptor,

    pub fn load(
        allocator: std.mem.Allocator,
        stderr: anytype,
        file_path: []const u8,
        opt_format: ?ExecutableFormat,
    ) Executable {
        const contents: []align(std.mem.page_size) u8 = blk: {
            const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                switch (err) {
                    error.FileNotFound => stderr.print(
                        "ERROR: file not found: {s}\n",
                        .{file_path},
                    ) catch unreachable,
                    else => |e| stderr.print(
                        "ERROR: failed to open file '{s}': {s}\n",
                        .{ file_path, @errorName(e) },
                    ) catch unreachable,
                }

                std.process.exit(1);
            };
            defer file.close();

            const stat = file.stat() catch |err| {
                stderr.print(
                    "ERROR: failed to stat file '{s}': {s}\n",
                    .{ file_path, @errorName(err) },
                ) catch unreachable;
                std.process.exit(1);
            };

            const ptr = std.os.mmap(
                null,
                stat.size,
                std.os.PROT.READ,
                std.os.MAP.PRIVATE,
                file.handle,
                0,
            ) catch |err| {
                stderr.print(
                    "ERROR: failed to map file '{s}': {s}\n",
                    .{ file_path, @errorName(err) },
                ) catch unreachable;
                std.process.exit(1);
            };

            break :blk ptr[0..stat.size];
        };

        const format = if (opt_format) |f| f else @panic("UNIMPLEMENTED"); // TODO: Autodetect file format

        const memory_description: []const Memory.Descriptor = switch (format) {
            .flat => blk: {
                const description = allocator.alloc(Memory.Descriptor, 1) catch {
                    stderr.writeAll("ERROR: failed to allocate memory\n") catch unreachable;
                    std.process.exit(1);
                };
                description[0] = .{
                    .start_address = 0,
                    .memory = contents,
                };
                break :blk description;
            },
            .elf => @panic("UNIMPLEMENTED"), // TODO: Add ELF parsing
        };

        return Executable{
            .contents = contents,
            .memory_description = memory_description,
        };
    }

    pub fn unload(self: Executable, allocator: std.mem.Allocator) void {
        allocator.free(self.memory_description);
        std.os.munmap(self.contents);
    }
};

/// This function parses the arguments from the user.
/// It performs the below additional functionality:
///     - Prints any errors during parsing
///     - Handles the help option
///     - Validates that a verb has been given
///     - Validates that a single file path has been given
fn parseArguments(
    allocator: std.mem.Allocator,
    stdout: anytype,
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
        stdout.writeAll(usage) catch unreachable;
        std.process.exit(0);
    }

    if (options.verb == null) {
        stderr.writeAll("ERROR: no execution mode given\n\n") catch unreachable;
        stdout.writeAll(usage) catch unreachable;
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
    \\      -f, --format=FORMAT        the format of the executable file; if not provided will attempt to autodetect
    \\                                   Supported Values:
    \\                                     flat
    \\                                     elf
    \\
    \\      --start-address=ADDRESS    will be used as the execution start address; if not provided:
    \\                                   flat files will start at address 0
    \\                                   elf file will start at the start address specifed in the file
    \\
    \\      -h, --help                 display this help and exit
    \\
    \\SYSTEM mode options:
    \\      -m, --memory=[number]      the amount of memory to make available to the emulated machine (MiB), defaults to 20MiB 
    \\
;

const ModeOptions = union(enum) {
    user: UserModeOptions,
    system: SystemModeOptions,
};

const SharedArguments = struct {
    help: bool = false,
    // TODO: Change default to null once autodetect is implemented
    /// `null` means autodetect
    format: ?ExecutableFormat = .flat,
    @"start-address": ?u64 = null,

    pub const shorthands = .{
        .h = "help",
        .f = "format",
    };
};

const ExecutableFormat = enum {
    flat,
    elf,
};

const UserModeOptions = struct {};

const SystemModeOptions = struct {
    memory: usize = 20,

    pub const shorthands = .{
        .m = "memory",
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
