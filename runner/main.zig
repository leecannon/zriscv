const std = @import("std");
const zriscv = @import("zriscv");
const resource_path: []const u8 = @import("build_options").resource_path;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = &gpa.allocator;

const stdin = std.io.getStdIn();
const stdin_reader = stdin.reader();
const stdout_writer = std.io.getStdOut().writer();

const NoOutputCpu = zriscv.Cpu(.{});
const OutputCpu = zriscv.Cpu(.{ .writer_type = @TypeOf(stdout_writer) });

pub fn main() !void {
    defer _ = gpa.deinit();

    const file_contents = blk: {
        var resource_dir = try std.fs.openDirAbsolute(resource_path, .{});
        defer resource_dir.close();

        var file = try resource_dir.openFile("rv64ui_p_blt.bin", .{});
        defer file.close();

        break :blk try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    };
    defer allocator.free(file_contents);

    var cpu_state = zriscv.CpuState{ .memory = file_contents };

    // set stdin to raw mode
    const previous_terminal_settings = blk: {
        const previous = try std.os.tcgetattr(stdin.handle);
        var current_settings = previous;

        current_settings.lflag &= ~@as(u32, std.os.linux.ICANON);

        try std.os.tcsetattr(stdin.handle, .FLUSH, current_settings);
        break :blk previous;
    };

    defer {
        std.os.tcsetattr(stdin.handle, .FLUSH, previous_terminal_settings) catch {};
        stdout_writer.writeByte('\n') catch {};
    }

    var opt_break_point: ?u64 = null;

    outer: while (true) {
        try stdout_writer.writeAll("> ");

        const input = stdin_reader.readByte() catch return;

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
                \\        q - quit
                \\
            );
            continue;
        }
        if (input == 'b') {
            const hex_str = (try stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize))) orelse return;
            defer allocator.free(hex_str);

            if (std.mem.eql(u8, hex_str, "\n")) {
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
            if (opt_break_point) |break_point| {
                while (cpu_state.pc != break_point) {
                    NoOutputCpu.step(&cpu_state) catch |err| {
                        try stdout_writer.print("error: {s}\n", .{@errorName(err)});
                        continue :outer;
                    };
                }

                try stdout_writer.writeAll("hit breakpoint\n");
            } else {
                while (true) {
                    NoOutputCpu.run(&cpu_state) catch |err| {
                        try stdout_writer.print("error: {s}\n", .{@errorName(err)});
                        continue :outer;
                    };
                }
            }
            continue;
        }
        if (input == 'e') {
            try stdout_writer.writeByte('\n');
            if (opt_break_point) |break_point| {
                while (cpu_state.pc != break_point) {
                    OutputCpu.step(&cpu_state, stdout_writer) catch |err| {
                        try stdout_writer.print("error: {s}\n", .{@errorName(err)});
                        continue :outer;
                    };
                }

                try stdout_writer.writeAll("hit breakpoint\n");
            } else {
                while (true) {
                    OutputCpu.run(&cpu_state, stdout_writer) catch |err| {
                        try stdout_writer.print("error: {s}\n", .{@errorName(err)});
                        continue :outer;
                    };
                }
            }
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
            return;
        }

        try stdout_writer.writeAll("invalid option\n");
    }
}

comptime {
    std.testing.refAllDecls(@This());
}
