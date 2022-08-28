const std = @import("std");
const zriscv = @import("zriscv");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

const stdin = std.io.getStdIn();
const stdin_reader = stdin.reader();
const stdout_writer = std.io.getStdOut().writer();
const stderr_writer = std.io.getStdErr().writer();

const NoOutputCpu = zriscv.Cpu(.{});
const OutputCpu = zriscv.Cpu(.{ .writer_type = @TypeOf(stdout_writer) });

pub fn main() !u8 {
    defer _ = gpa.deinit();

    const file_path = "sss";

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

    var memory = try allocator.dupe(u8, file_contents);
    defer allocator.free(memory);

    var cpu_state = zriscv.CpuState{ .memory = memory };

    const previous_terminal_settings = try std.os.tcgetattr(stdin.handle);
    try setRawMode(previous_terminal_settings);
    defer {
        std.os.tcsetattr(stdin.handle, .FLUSH, previous_terminal_settings) catch {};
        stdout_writer.writeByte('\n') catch {};
    }

    var opt_break_point: ?u64 = null;

    while (true) {
        try stdout_writer.writeAll("> ");

        const input = stdin_reader.readByte() catch return 0;

        if (input == '?' or input == 'h' or input == '\n') {
            try stdout_writer.writeAll(
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
            );
            continue;
        }
        if (input == '0') {
            const new_memory = try allocator.dupe(u8, file_contents);
            allocator.free(memory);
            memory = new_memory;
            cpu_state = zriscv.CpuState{ .memory = memory };

            try stdout_writer.writeAll("\nstate reset\n");
            continue;
        }
        if (input == 'b') {
            // disable raw mode to enable user to enter hex string
            std.os.tcsetattr(stdin.handle, .FLUSH, previous_terminal_settings) catch {};
            defer setRawMode(previous_terminal_settings) catch {};

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

            if (addr >= cpu_state.memory.len) {
                try stdout_writer.print("breakpoint address 0x{x} exceeds cpu memory\n", .{addr});
                continue;
            }

            try stdout_writer.print("set breakpoint to 0x{x}\n", .{addr});

            opt_break_point = addr;
            continue;
        }
        if (input == 'r') {
            try stdout_writer.writeByte('\n');

            var timer = try std.time.Timer.start();

            if (opt_break_point) |break_point| {
                while (cpu_state.pc != break_point) {
                    NoOutputCpu.step(&cpu_state) catch |err| {
                        try stdout_writer.print("error: {s}\n", .{@errorName(err)});
                        break;
                    };
                } else {
                    try stdout_writer.writeAll("hit breakpoint\n");
                }
            } else {
                while (true) {
                    NoOutputCpu.run(&cpu_state) catch |err| {
                        try stdout_writer.print("error: {s}\n", .{@errorName(err)});
                        break;
                    };
                }
            }

            const elapsed = timer.read();
            try stdout_writer.print("execution took: {} ({} ns)\n", .{ std.fmt.fmtDuration(elapsed), elapsed });
            continue;
        }
        if (input == 'e') {
            try stdout_writer.writeByte('\n');

            var timer = try std.time.Timer.start();

            if (opt_break_point) |break_point| {
                while (cpu_state.pc != break_point) {
                    OutputCpu.step(&cpu_state, stdout_writer) catch |err| {
                        try stdout_writer.print("error: {s}\n", .{@errorName(err)});
                        break;
                    };
                } else {
                    try stdout_writer.writeAll("hit breakpoint\n");
                }
            } else {
                while (true) {
                    OutputCpu.run(&cpu_state, stdout_writer) catch |err| {
                        try stdout_writer.print("error: {s}\n", .{@errorName(err)});
                        break;
                    };
                }
            }

            const elapsed = timer.read();
            try stdout_writer.print("execution took: {} ({} ns)\n", .{ std.fmt.fmtDuration(elapsed), elapsed });
            continue;
        }
        if (input == 'n') {
            try stdout_writer.writeByte('\n');
            NoOutputCpu.step(&cpu_state) catch |err| {
                try stdout_writer.print("error: {s}\n", .{@errorName(err)});
            };
            continue;
        }
        if (input == 's') {
            try stdout_writer.writeByte('\n');
            OutputCpu.step(&cpu_state, stdout_writer) catch |err| {
                try stdout_writer.print("error: {s}\n", .{@errorName(err)});
            };
            continue;
        }
        if (input == 'd') {
            try stdout_writer.writeByte('\n');
            try cpu_state.dump(stdout_writer);
            continue;
        }
        if (input == 'q') {
            return 0;
        }

        try stdout_writer.writeAll("invalid option\n");
    }
}

fn setRawMode(previous: std.os.termios) !void {
    var current_settings = previous;

    current_settings.lflag &= ~@as(u32, std.os.linux.ICANON);

    try std.os.tcsetattr(stdin.handle, .FLUSH, current_settings);
}

comptime {
    std.testing.refAllDecls(@This());
}
