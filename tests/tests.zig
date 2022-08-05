const std = @import("std");
const zriscv = @import("zriscv");

const TestContext = struct {
    file_path: []const u8,
    the_error: ?anyerror = null,
    reset_event: *std.Thread.ResetEvent,
};

fn runTest(file_path: []const u8) !void {
    var reset_event = try std.testing.allocator.create(std.Thread.ResetEvent);
    defer std.testing.allocator.destroy(reset_event);

    try reset_event.init();
    defer reset_event.deinit();

    var context = TestContext{ .file_path = file_path, .reset_event = reset_event };

    var runner_thread = try std.Thread.spawn(.{}, executeTest, .{&context});

    if (reset_event.timedWait(std.time.ns_per_s * 2) == .timed_out) {
        runner_thread.detach();
        return error.TestTimedOut;
    }

    defer runner_thread.join();

    if (context.the_error) |err| return err;
}

fn executeTest(context: *TestContext) !void {
    defer context.reset_event.set();

    const file_contents = blk: {
        var file = try std.fs.cwd().openFile(context.file_path, .{});
        defer file.close();

        break :blk try file.readToEndAlloc(std.testing.allocator, std.math.maxInt(usize));
    };
    defer std.testing.allocator.free(file_contents);

    // TODO: Run until error.
    //       How will we know if it is successful?
    @panic("unimplemented");
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
