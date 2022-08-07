const std = @import("std");
const zriscv = @import("zriscv");
const args = @import("args");
const builtin = @import("builtin");

pub const is_debug_or_test = builtin.is_test or builtin.mode == .Debug;

const MainErrors = error{} ||
    ReplErrors ||
    std.mem.Allocator.Error ||
    std.fs.File.OpenError ||
    std.fs.File.WriteError ||
    std.os.MMapError;

pub fn main() if (is_debug_or_test) MainErrors!u8 else u8 {
    const stderr_writer = std.io.getStdErr().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const options = args.parseForCurrentProcess(struct {
        help: bool = false,
        interactive: bool = false,

        pub const shorthands = .{
            .i = "interactive",
            .h = "help",
        };
    }, allocator, .print) catch return 1;
    defer options.deinit();

    if (options.options.help) {
        std.io.getStdOut().writeAll(
            \\Usage: riscv [option] FILE
            \\
            \\Interpret FILE as a riscv program and execute it.
            \\
            \\      -i, --interactive   enter an interactive repl
            \\      -h, --help          display this help and exit
            \\
        ) catch |err| {
            stderr_writer.print("failed to write to stdout: {s}\n", .{@errorName(err)}) catch {};

            if (is_debug_or_test) return err;
            return 1;
        };
        return 0;
    }

    const file_path = blk: {
        if (options.positionals.len < 1) {
            stderr_writer.writeAll("no file path provided\n") catch {};
            return 1;
        }
        if (options.positionals.len > 1) {
            stderr_writer.writeAll("multiple files are not supported\n") catch {};
            return 1;
        }

        break :blk options.positionals[0];
    };

    const file_contents = blk: {
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                stderr_writer.print("file not found: {s}\n", .{file_path}) catch {};
                return 1;
            },
            else => |e| {
                stderr_writer.print("failed to open file '{s}': {s}\n", .{ file_path, @errorName(e) }) catch {};

                if (is_debug_or_test) return e;
                return 1;
            },
        };
        defer file.close();

        const stat = file.stat() catch |err| {
            stderr_writer.print("failed to stat file '{s}': {s}\n", .{ file_path, @errorName(err) }) catch {};

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
            stderr_writer.print("failed to map file '{s}': {s}\n", .{ file_path, @errorName(err) }) catch {};

            if (is_debug_or_test) return err;
            return 1;
        };

        break :blk ptr[0..stat.size];
    };

    if (options.options.interactive) {
        repl(file_contents) catch |err| {
            if (is_debug_or_test) return err;
            return 1;
        };
        return 0;
    }

    @panic("unimplemented"); // TODO: Run without output, until error.
}

const ReplErrors = error{
    EndOfStream,
    StreamTooLong,
} ||
    std.fs.File.ReadError ||
    std.fs.File.WriteError ||
    std.os.TermiosGetError ||
    std.time.Timer.Error ||
    std.os.TermiosSetError;

fn repl(file_contents: []const u8) ReplErrors!void {
    _ = file_contents;

    const stdin = std.io.getStdIn();
    const stdin_reader = stdin.reader();
    const stdout_writer = std.io.getStdOut().writer();
    const stderr_writer = std.io.getStdErr().writer();

    const previous_terminal_settings = std.os.tcgetattr(stdin.handle) catch |err| {
        try stderr_writer.print("failed to capture termios settings: {s}\n", .{@errorName(err)});
        return err;
    };
    setRawMode(previous_terminal_settings, stdin.handle) catch |err| {
        try stderr_writer.print("failed to set raw console mode: {s}\n", .{@errorName(err)});
        return err;
    };
    defer {
        std.os.tcsetattr(stdin.handle, .FLUSH, previous_terminal_settings) catch |err| {
            stderr_writer.print("failed to restore termios settings: {s}\n", .{@errorName(err)}) catch {};
        };
        stdout_writer.writeByte('\n') catch {};
    }

    var opt_break_point: ?u64 = null;

    while (true) {
        stdout_writer.writeAll("> ") catch |err| {
            try stderr_writer.print("failed to write to stdout: {s}\n", .{@errorName(err)});
            return err;
        };

        const input = stdin_reader.readByte() catch |err| {
            try stderr_writer.print("failed to read from stdin: {s}\n", .{@errorName(err)});
            return err;
        };

        switch (input) {
            '?', 'h', '\n' => stdout_writer.writeAll(
                \\help:
                \\ ?|h|'\n' - this help menu
                \\        r - run without output (this will not stop unless a breakpoint is hit, or an error)
                \\        e - run with output (this will not stop unless a breakpoint is hit, or an error)
                \\  b[addr] - set breakpoint, [addr] must be in hex, blank [addr] clears the breakpoint 
                \\        s - single step with output
                \\        n - single step without output
                \\        d - dump cpu state
                \\        0 - reset cpu
                \\        q - quit
                \\
            ) catch |err| {
                try stderr_writer.print("failed to write to stdout: {s}\n", .{@errorName(err)});
                return err;
            },
            '0' => {
                @panic("unimplemented"); // TODO: reset cpu
            },
            'b' => {
                // disable raw mode to enable user to enter hex string
                std.os.tcsetattr(stdin.handle, .FLUSH, previous_terminal_settings) catch |err| {
                    try stderr_writer.print("failed to restore termios settings: {s}\n", .{@errorName(err)});
                    return err;
                };
                defer setRawMode(previous_terminal_settings, stdin.handle) catch |err| {
                    stderr_writer.print("failed to set raw console mode: {s}\n", .{@errorName(err)}) catch {};
                };

                var hex_buffer: [86]u8 = undefined;

                const hex_str: []const u8 = stdin_reader.readUntilDelimiterOrEof(&hex_buffer, '\n') catch |err| {
                    try stderr_writer.print("failed to read from stdin: {s}\n", .{@errorName(err)});
                    return err;
                } orelse "";

                if (hex_str.len == 0) {
                    opt_break_point = null;
                    stdout_writer.writeAll("cleared breakpoint\n") catch |err| {
                        try stderr_writer.print("failed to write to stdout: {s}\n", .{@errorName(err)});
                        return err;
                    };
                    continue;
                }

                const addr = std.fmt.parseUnsigned(u64, hex_str, 16) catch |err| {
                    try stderr_writer.print("unable to parse '{s}' as hex: {s}\n", .{ hex_str, @errorName(err) });
                    continue;
                };

                // TODO: Check if breakpoint exceeds CPU memory

                stdout_writer.print("set breakpoint to 0x{x}\n", .{addr}) catch |err| {
                    try stderr_writer.print("failed to write to stdout: {s}\n", .{@errorName(err)});
                    return err;
                };

                opt_break_point = addr;
            },
            'r', 'e' => {
                const output = input == 'e';

                stdout_writer.writeByte('\n') catch |err| {
                    try stderr_writer.print("failed to write to stdout: {s}\n", .{@errorName(err)});
                    return err;
                };

                const timer = std.time.Timer.start() catch |err| {
                    try stderr_writer.print("failed to start timer: {s}\n", .{@errorName(err)});
                    return err;
                };

                if (opt_break_point) |break_point| {
                    _ = break_point;
                    if (output) {
                        @panic("unimplemented"); // TODO: Run with output, until breakpoint is hit.
                    } else {
                        @panic("unimplemented"); // TODO: Run without output, until breakpoint is hit.
                    }
                } else {
                    if (output) {
                        @panic("unimplemented"); // TODO: Run with output, until error.
                    } else {
                        @panic("unimplemented"); // TODO: Run without output, until error.
                    }
                }

                const elapsed = timer.read();
                stdout_writer.print("execution took: {} ({} ns)\n", .{ std.fmt.fmtDuration(elapsed), elapsed }) catch |err| {
                    try stderr_writer.print("failed to write to stdout: {s}\n", .{@errorName(err)});
                    return err;
                };
            },
            's', 'n' => {
                const output = input == 's';

                stdout_writer.writeByte('\n') catch |err| {
                    try stderr_writer.print("failed to write to stdout: {s}\n", .{@errorName(err)});
                    return err;
                };

                if (output) {
                    @panic("unimplemented"); // TODO: single step with output
                } else {
                    @panic("unimplemented"); // TODO: single step without output
                }
            },
            'd' => {
                stdout_writer.writeByte('\n') catch |err| {
                    try stderr_writer.print("failed to write to stdout: {s}\n", .{@errorName(err)});
                    return err;
                };
                @panic("unimplemented"); // TODO: dump cpu state
            },
            'q' => return,
            else => {
                stdout_writer.writeAll("\ninvalid option\n") catch |err| {
                    try stderr_writer.print("failed to write to stdout: {s}\n", .{@errorName(err)});
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
