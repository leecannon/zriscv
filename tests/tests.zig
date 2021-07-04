const std = @import("std");
const zriscv = @import("zriscv");
const resource_path: []const u8 = @import("build_options").resource_path;

test "rv64ui_p_add" {
    try runTest("rv64ui_p_add.bin");
}

fn runTest(file_name: []const u8) !void {
    const file_contents = blk: {
        var resource_dir = try std.fs.openDirAbsolute(resource_path, .{});
        defer resource_dir.close();

        var file = try resource_dir.openFile(file_name, .{});
        defer file.close();

        break :blk try file.readToEndAlloc(std.testing.allocator, std.math.maxInt(usize));
    };
    defer std.testing.allocator.free(file_contents);

    var cpu = zriscv.Cpu{ .memory = file_contents };
    cpu.run() catch |err| switch (err) {
        error.ExecutionOutOfBounds => if (cpu.x[10] != 0) return err,
        else => return err,
    };
}

comptime {
    std.testing.refAllDecls(@This());
}
