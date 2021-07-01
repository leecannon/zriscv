const std = @import("std");
const zriscv = @import("zriscv");
const resource_path: []const u8 = @import("build_options").resource_path;

test "rv64ui_p_add" {
    try runTest("rv64ui_p_add.bin");
}

fn runTest(file_name: []const u8) !void {
    var resource_dir = try std.fs.openDirAbsolute(resource_path, .{});
    defer resource_dir.close();

    var file = try resource_dir.openFile(file_name, .{});
    defer file.close();

    const stat = try file.stat();
    try std.testing.expectEqual(@as(usize, 4168), stat.size);
}

comptime {
    std.testing.refAllDecls(@This());
}
