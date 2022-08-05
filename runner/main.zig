const std = @import("std");
const zriscv = @import("zriscv");
const args = @import("args");

pub fn main() !u8 {
    const stdin = std.io.getStdIn();
    const stdin_reader = stdin.reader();
    const stdout_writer = std.io.getStdOut().writer();
    const stderr_writer = std.io.getStdErr().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const options = args.parseForCurrentProcess(struct {
        help: bool = false,

        pub const shorthands = .{
            .h = "help",
        };
    }, allocator, .print) catch return 1;
    defer options.deinit();

    if (options.options.help) {
        try stdout_writer.writeAll(
            \\Usage: riscv [option] FILE
            \\
            \\Interpret FILE as a riscv program and execute it.
            \\
            \\      --help     display this help and exit
            \\
        );
        return 0;
    }

    const file_path = blk: {
        if (options.positionals.len < 1) {
            try stderr_writer.writeAll("no file path provided\n");
            return 1;
        }
        if (options.positionals.len > 1) {
            try stderr_writer.writeAll("multiple files are not supported\n");
            return 1;
        }

        break :blk options.positionals[0];
    };

    const file_contents = blk: {
        var file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try stderr_writer.print("file not found: {s}\n", .{file_path});
                return 1;
            },
            else => |e| return e,
        };
        defer file.close();

        break :blk try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    };
    defer allocator.free(file_contents);

    const previous_terminal_settings = try std.os.tcgetattr(stdin.handle);
    try setRawMode(previous_terminal_settings, stdin.handle);
    defer {
        std.os.tcsetattr(stdin.handle, .FLUSH, previous_terminal_settings) catch {};
        stdout_writer.writeByte('\n') catch {};
    }

    var opt_break_point: ?u64 = null;

    while (true) {
        try stdout_writer.writeAll("> ");

        const input = stdin_reader.readByte() catch return 0;

        switch (input) {
            '?', 'h', '\n' => try stdout_writer.writeAll(
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
            ),
            '0' => {
                // TODO: reset cpu
                @panic("unimplemented");
            },
            'b' => {
                // disable raw mode to enable user to enter hex string
                std.os.tcsetattr(stdin.handle, .FLUSH, previous_terminal_settings) catch {};
                defer setRawMode(previous_terminal_settings, stdin.handle) catch {};

                const hex_str = (try stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize))) orelse return 1;
                defer allocator.free(hex_str);

                if (std.mem.eql(u8, hex_str, "")) {
                    opt_break_point = null;
                    try stdout_writer.writeAll("cleared breakpoint\n");
                    continue;
                }

                const addr = std.fmt.parseUnsigned(u64, hex_str, 16) catch |err| {
                    try stdout_writer.print("unable to parse '{s}' as hex: {s}\n", .{ hex_str, @errorName(err) });
                    continue;
                };

                // TODO: Check if breakpoint exceeds CPU memory

                try stdout_writer.print("set breakpoint to 0x{x}\n", .{addr});

                opt_break_point = addr;
            },
            'r' => {
                try stdout_writer.writeByte('\n');

                const timer = try std.time.Timer.start();

                if (opt_break_point) |break_point| {
                    _ = break_point;
                    // TODO: Run until breakpoint is hit
                    @panic("unimplemented");
                } else {
                    // TODO: Run until error
                    @panic("unimplemented");
                }

                const elapsed = timer.read();
                try stdout_writer.print("execution took: {} ({} ns)\n", .{ std.fmt.fmtDuration(elapsed), elapsed });
            },
            'e' => {
                try stdout_writer.writeByte('\n');

                const timer = try std.time.Timer.start();

                if (opt_break_point) |break_point| {
                    _ = break_point;
                    // TODO: Run until breakpoint is hit
                    @panic("unimplemented");
                } else {
                    // TODO: Run until error
                    @panic("unimplemented");
                }

                const elapsed = timer.read();
                try stdout_writer.print("execution took: {} ({} ns)\n", .{ std.fmt.fmtDuration(elapsed), elapsed });
            },
            'n' => {
                try stdout_writer.writeByte('\n');
                // TODO: single step
                @panic("unimplemented");
            },
            's' => {
                try stdout_writer.writeByte('\n');
                // TODO: single step
                @panic("unimplemented");
            },
            'd' => {
                try stdout_writer.writeByte('\n');
                // TODO: dump cpu state
                @panic("unimplemented");
            },
            'q' => return 0,
            else => try stdout_writer.writeAll("invalid option\n"),
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
