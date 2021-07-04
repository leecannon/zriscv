const std = @import("std");
const zriscv = @import("zriscv");
const resource_path: []const u8 = @import("build_options").resource_path;

test "rv64ui_p_add" {
    try runTest("rv64ui_p_add.bin");
}

test "rv64ui_p_addi" {
    try runTest("rv64ui_p_addi.bin");
}

const TestContext = struct {
    file_name: []const u8,
    the_error: ?anyerror = null,
    reset_event: *std.Thread.ResetEvent,
};

fn runTest(file_name: []const u8) !void {
    var reset_event = try std.testing.allocator.create(std.Thread.ResetEvent);
    defer std.testing.allocator.destroy(reset_event);

    try reset_event.init();
    defer reset_event.deinit();

    var context = TestContext{ .file_name = file_name, .reset_event = reset_event };

    var runner_thread = try std.Thread.spawn(executeTest, &context);
    defer runner_thread.wait();

    if (reset_event.timedWait(std.time.ns_per_s * 2) == .timed_out) {
        return error.TestTimedOut;
    }

    if (context.the_error) |err| return err;
}

fn executeTest(context: *TestContext) !void {
    defer context.reset_event.set();

    const file_contents = blk: {
        var resource_dir = try std.fs.openDirAbsolute(resource_path, .{});
        defer resource_dir.close();

        var file = try resource_dir.openFile(context.file_name, .{});
        defer file.close();

        break :blk try file.readToEndAlloc(std.testing.allocator, std.math.maxInt(usize));
    };
    defer std.testing.allocator.free(file_contents);

    var cpu = zriscv.Cpu{ .memory = file_contents };
    cpu.run() catch |err| switch (err) {
        error.ExecutionOutOfBounds => {
            if (cpu.x[10] != 0) {
                context.the_error = err;
            }
        },
        else => context.the_error = err,
    };
}

comptime {
    std.testing.refAllDecls(@This());
}
