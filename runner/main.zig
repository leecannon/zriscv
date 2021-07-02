const std = @import("std");
const zriscv = @import("zriscv");
const resource_path: []const u8 = @import("build_options").resource_path;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = &gpa.allocator;

pub fn main() !void {
    defer _ = gpa.deinit();

    const file_contents = blk: {
        var resource_dir = try std.fs.openDirAbsolute(resource_path, .{});
        defer resource_dir.close();

        var file = try resource_dir.openFile("rv64ui_p_add.bin", .{});
        defer file.close();

        break :blk try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    };
    defer allocator.free(file_contents);

    var cpu = zriscv.Cpu{ .memory = file_contents };
    try cpu.run();
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = switch (level) {
        .emerg => "emergency ",
        .alert => "alert     ",
        .crit => "critical  ",
        .err => "error     ",
        .warn => "warning   ",
        .notice => "notice    ",
        .info => "info      ",
        .debug => "",
    };
    const prefix2 = if (scope == .default) "" else "(" ++ @tagName(scope) ++ "): ";
    const stdout = std.io.getStdOut().writer();
    nosuspend stdout.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
}

comptime {
    std.testing.refAllDecls(@This());
}
