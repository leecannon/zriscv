const std = @import("std");
const zriscv = @import("zriscv");
const args = @import("args");
const builtin = @import("builtin");

pub const is_debug_or_test = builtin.is_test or builtin.mode == .Debug;

pub fn main() if (is_debug_or_test) anyerror!u8 else u8 {
    const stderr = std.io.getStdErr().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const options = args.parseForCurrentProcess(struct {
        help: bool = false,
        interactive: bool = false,
        memory: usize = 20,

        pub const shorthands = .{
            .i = "interactive",
            .h = "help",
            .m = "memory",
        };
    }, allocator, .print) catch return 1;
    defer options.deinit();

    if (options.options.help) {
        std.io.getStdOut().writeAll(
            \\Usage: riscv [option] FILE
            \\
            \\Interpret FILE as a riscv program and execute it.
            \\
            \\      -i, --interactive      enter an interactive repl
            \\      -m, --memory [number]  the amount of memory to make available to the emulated machine (MiB)      
            \\      -h, --help             display this help and exit
            \\
        ) catch |err| {
            stderr.print("failed to write to stdout: {s}\n", .{@errorName(err)}) catch {};
            if (is_debug_or_test) return err;
            return 1;
        };
        return 0;
    }

    const file_path = blk: {
        if (options.positionals.len < 1) {
            stderr.writeAll("no file path provided\n") catch {};
            return 1;
        }
        if (options.positionals.len > 1) {
            stderr.writeAll("multiple files are not supported\n") catch {};
            return 1;
        }

        break :blk options.positionals[0];
    };

    const memory_description: []const zriscv.MemoryDescriptor = blk: {
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                stderr.print("file not found: {s}\n", .{file_path}) catch {};
                return 1;
            },
            else => |e| {
                stderr.print("failed to open file '{s}': {s}\n", .{ file_path, @errorName(e) }) catch {};
                if (is_debug_or_test) return e;
                return 1;
            },
        };
        defer file.close();

        const stat = file.stat() catch |err| {
            stderr.print("failed to stat file '{s}': {s}\n", .{ file_path, @errorName(err) }) catch {};
            if (is_debug_or_test) return err;
            return 1;
        };

        const ptr = std.os.mmap(
            null,
            stat.size,
            std.os.PROT.READ,
            std.os.MAP.PRIVATE,
            file.handle,
            0,
        ) catch |err| {
            stderr.print("failed to map file '{s}': {s}\n", .{ file_path, @errorName(err) }) catch {};
            if (is_debug_or_test) return err;
            return 1;
        };

        const description = try allocator.alloc(zriscv.MemoryDescriptor, 1);
        description[0] = .{
            .start_address = 0,
            .memory = ptr[0..stat.size],
        };

        break :blk description;
    };
    defer allocator.free(memory_description);

    const memory_size = options.options.memory * 1024;

    // TODO: Parse file as Elf and produce `[]const zriscv.MemoryDescriptor` to describe the sections

    if (options.options.interactive) {
        repl(allocator, memory_size, memory_description) catch |err| {
            if (is_debug_or_test) return err;
            return 1;
        };
        return 0;
    }

    const machine = zriscv.Machine.create(
        allocator,
        memory_size,
        memory_description,
        1,
    ) catch |err| switch (err) {
        error.NonZeroNumberOfHartsRequired => unreachable, // we pass 1
        error.OutOfBoundsWrite => |e| {
            stderr.writeAll("error: insufficent memory provided to load elf file\n") catch {};
            if (is_debug_or_test) return e;
            return 1;
        },
        else => |e| {
            if (is_debug_or_test) return e;
            return 1;
        },
    };
    defer machine.destory();

    while (true) {
        // TODO: Support multiple harts
        // TODO: Someway to exit loop without an error, as it is every execution "fails".
        zriscv.engine.run(&machine.harts[0], {}) catch |err| {
            stderr.print("error: {s}\n", .{@errorName(err)}) catch {};
            if (is_debug_or_test) return err;
            return 1;
        };
    }
}

fn repl(allocator: std.mem.Allocator, memory_size: usize, memory_description: []const zriscv.MemoryDescriptor) !void {
    const raw_stdin = std.io.getStdIn();
    const stdin = raw_stdin.reader();
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const previous_terminal_settings = std.os.tcgetattr(raw_stdin.handle) catch |err| {
        stderr.print("failed to capture termios settings: {s}\n", .{@errorName(err)}) catch {};
        return err;
    };
    setRawMode(previous_terminal_settings, raw_stdin.handle) catch |err| {
        stderr.print("failed to set raw console mode: {s}\n", .{@errorName(err)}) catch {};
        return err;
    };
    defer {
        std.os.tcsetattr(raw_stdin.handle, .FLUSH, previous_terminal_settings) catch |err| {
            stderr.print("failed to restore termios settings: {s}\n", .{@errorName(err)}) catch {};
        };
        stdout.writeByte('\n') catch {};
    }

    const machine = zriscv.Machine.create(
        allocator,
        memory_size,
        memory_description,
        1, // TODO: Support multiple harts
    ) catch |err| switch (err) {
        error.NonZeroNumberOfHartsRequired => unreachable, // we pass 1
        error.OutOfBoundsWrite => |e| {
            stderr.writeAll("error: insufficent memory provided to load elf file\n") catch {};
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
        stderr.print("failed to start timer: {s}\n", .{@errorName(err)}) catch {};
        return err;
    };

    var opt_break_point: ?u64 = null;

    while (true) {
        stdout.writeAll("> ") catch |err| {
            stderr.print("failed to write to stdout: {s}\n", .{@errorName(err)}) catch {};
            return err;
        };

        const input = stdin.readByte() catch |err| {
            stderr.print("failed to read from stdin: {s}\n", .{@errorName(err)}) catch {};
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
            ) catch |err| {
                stderr.print("failed to write to stdout: {s}\n", .{@errorName(err)}) catch {};
                return err;
            },
            '0' => {
                machine.reset(memory_description) catch |err| {
                    stderr.print("failed to reset machine state: {s}\n", .{@errorName(err)}) catch {};
                    return err;
                };

                stdout.writeAll("\nreset machine state\n") catch |err| {
                    stderr.print("failed to write to stdout: {s}\n", .{@errorName(err)}) catch {};
                    return err;
                };
            },
            'b' => {
                // disable raw mode to enable user to enter hex string
                std.os.tcsetattr(raw_stdin.handle, .FLUSH, previous_terminal_settings) catch |err| {
                    stderr.print("failed to restore termios settings: {s}\n", .{@errorName(err)}) catch {};
                    return err;
                };
                defer setRawMode(previous_terminal_settings, raw_stdin.handle) catch |err| {
                    stderr.print("failed to set raw console mode: {s}\n", .{@errorName(err)}) catch {};
                };

                var hex_buffer: [86]u8 = undefined;

                const hex_str: []const u8 = stdin.readUntilDelimiterOrEof(&hex_buffer, '\n') catch |err| {
                    stderr.print("failed to read from stdin: {s}\n", .{@errorName(err)}) catch {};
                    return err;
                } orelse "";

                if (hex_str.len == 0) {
                    opt_break_point = null;
                    stdout.writeAll("cleared breakpoint\n") catch |err| {
                        stderr.print("failed to write to stdout: {s}\n", .{@errorName(err)}) catch {};
                        return err;
                    };
                    continue;
                }

                const addr = std.fmt.parseUnsigned(u64, hex_str, 16) catch |err| {
                    stderr.print("unable to parse '{s}' as hex: {s}\n", .{ hex_str, @errorName(err) }) catch {};
                    continue;
                };

                // TODO: Check if breakpoint exceeds CPU memory

                stdout.print("set breakpoint to 0x{x}\n", .{addr}) catch |err| {
                    stderr.print("failed to write to stdout: {s}\n", .{@errorName(err)}) catch {};
                    return err;
                };

                opt_break_point = addr;
            },
            'r', 'e' => {
                // TODO: Support multiple harts

                const output = input == 'e';

                stdout.writeByte('\n') catch |err| {
                    stderr.print("failed to write to stdout: {s}\n", .{@errorName(err)}) catch {};
                    return err;
                };

                timer.reset();

                if (opt_break_point) |break_point| {
                    while (machine.harts[0].pc != break_point) {
                        if (output) {
                            zriscv.engine.step(&machine.harts[0], stdout) catch |err| {
                                stdout.print("error: {s}\n", .{@errorName(err)}) catch |e| {
                                    stderr.print("failed to write to stdout: {s}\n", .{@errorName(e)}) catch {};
                                    return e;
                                };
                                break;
                            };
                        } else {
                            zriscv.engine.step(&machine.harts[0], {}) catch |err| {
                                stdout.print("error: {s}\n", .{@errorName(err)}) catch |e| {
                                    stderr.print("failed to write to stdout: {s}\n", .{@errorName(e)}) catch {};
                                    return e;
                                };
                                break;
                            };
                        }
                    } else {
                        stdout.writeAll("hit breakpoint\n") catch |err| {
                            stderr.print("failed to write to stdout: {s}\n", .{@errorName(err)}) catch {};
                            return err;
                        };
                    }
                } else {
                    if (output) {
                        zriscv.engine.run(&machine.harts[0], stdout) catch |err| {
                            stdout.print("error: {s}\n", .{@errorName(err)}) catch |e| {
                                stderr.print("failed to write to stdout: {s}\n", .{@errorName(e)}) catch {};
                                return e;
                            };
                            break;
                        };
                    } else {
                        zriscv.engine.run(&machine.harts[0], {}) catch |err| {
                            stdout.print("error: {s}\n", .{@errorName(err)}) catch |e| {
                                stderr.print("failed to write to stdout: {s}\n", .{@errorName(e)}) catch {};
                                return e;
                            };
                            break;
                        };
                    }
                }

                const elapsed = timer.read();
                stdout.print("execution took: {} ({} ns)\n", .{ std.fmt.fmtDuration(elapsed), elapsed }) catch |err| {
                    stderr.print("failed to write to stdout: {s}\n", .{@errorName(err)}) catch {};
                    return err;
                };
            },
            's', 'n' => {
                // TODO: Support multiple harts

                const output = input == 's';

                stdout.writeByte('\n') catch |err| {
                    stderr.print("failed to write to stdout: {s}\n", .{@errorName(err)}) catch {};
                    return err;
                };

                timer.reset();

                if (output) {
                    zriscv.engine.step(&machine.harts[0], stdout) catch |err| {
                        stdout.print("error: {s}\n", .{@errorName(err)}) catch |e| {
                            stderr.print("failed to write to stdout: {s}\n", .{@errorName(e)}) catch {};
                            return e;
                        };
                    };
                } else {
                    zriscv.engine.step(&machine.harts[0], {}) catch |err| {
                        stdout.print("error: {s}\n", .{@errorName(err)}) catch |e| {
                            stderr.print("failed to write to stdout: {s}\n", .{@errorName(e)}) catch {};
                            return e;
                        };
                    };
                }

                const elapsed = timer.read();
                stdout.print("execution took: {} ({} ns)\n", .{ std.fmt.fmtDuration(elapsed), elapsed }) catch |err| {
                    stderr.print("failed to write to stdout: {s}\n", .{@errorName(err)}) catch {};
                    return err;
                };
            },
            'd' => {
                stdout.writeByte('\n') catch |err| {
                    stderr.print("failed to write to stdout: {s}\n", .{@errorName(err)}) catch {};
                    return err;
                };
                @panic("unimplemented"); // TODO: dump machine state
            },
            'q' => return,
            else => {
                stdout.writeAll("\ninvalid option\n") catch |err| {
                    stderr.print("failed to write to stdout: {s}\n", .{@errorName(err)}) catch {};
                    return err;
                };
            },
        }
    }
}

fn setRawMode(previous: std.os.termios, handle: std.os.fd_t) !void {
    var current_settings = previous;

    current_settings.lflag &= ~@as(u32, std.os.linux.ICANON);

    try std.os.tcsetattr(handle, .FLUSH, current_settings);
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
