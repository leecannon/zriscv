const std = @import("std");
const zriscv = @import("zriscv");
const resource_path: []const u8 = @import("build_options").resource_path;

test "rv64ui_p_lui" {
    try runTest("rv64ui_p_lui.bin");
}

test "rv64ui_p_auipc" {
    try runTest("rv64ui_p_auipc.bin");
}

test "rv64ui_p_jal" {
    try runTest("rv64ui_p_jal.bin");
}

test "rv64ui_p_jalr" {
    try runTest("rv64ui_p_jalr.bin");
}

test "rv64ui_p_beq" {
    try runTest("rv64ui_p_beq.bin");
}

test "rv64ui_p_bne" {
    try runTest("rv64ui_p_bne.bin");
}

test "rv64ui_p_blt" {
    try runTest("rv64ui_p_blt.bin");
}

test "rv64ui_p_bge" {
    try runTest("rv64ui_p_bge.bin");
}

test "rv64ui_p_bltu" {
    try runTest("rv64ui_p_bltu.bin");
}

test "rv64ui_p_bgeu" {
    try runTest("rv64ui_p_bgeu.bin");
}

test "rv64ui_p_lb" {
    try runTest("rv64ui_p_lb.bin");
}

test "rv64ui_p_lh" {
    try runTest("rv64ui_p_lh.bin");
}

test "rv64ui_p_addi" {
    try runTest("rv64ui_p_addi.bin");
}

test "rv64ui_p_slti" {
    try runTest("rv64ui_p_slti.bin");
}

test "rv64ui_p_sltiu" {
    try runTest("rv64ui_p_sltiu.bin");
}

test "rv64ui_p_xori" {
    try runTest("rv64ui_p_xori.bin");
}

test "rv64ui_p_ori" {
    try runTest("rv64ui_p_ori.bin");
}

test "rv64ui_p_andi" {
    try runTest("rv64ui_p_andi.bin");
}

test "rv64ui_p_slli" {
    try runTest("rv64ui_p_slli.bin");
}

test "rv64ui_p_srli" {
    try runTest("rv64ui_p_srli.bin");
}

test "rv64ui_p_srai" {
    try runTest("rv64ui_p_srai.bin");
}

test "rv64ui_p_add" {
    try runTest("rv64ui_p_add.bin");
}

test "rv64ui_p_sub" {
    try runTest("rv64ui_p_sub.bin");
}

test "rv64ui_p_sll" {
    try runTest("rv64ui_p_sll.bin");
}

test "rv64ui_p_slt" {
    try runTest("rv64ui_p_slt.bin");
}

test "rv64ui_p_sltu" {
    try runTest("rv64ui_p_sltu.bin");
}

test "rv64ui_p_xor" {
    try runTest("rv64ui_p_xor.bin");
}

test "rv64ui_p_srl" {
    try runTest("rv64ui_p_srl.bin");
}

test "rv64ui_p_sra" {
    try runTest("rv64ui_p_sra.bin");
}

test "rv64ui_p_or" {
    try runTest("rv64ui_p_or.bin");
}

test "rv64ui_p_and" {
    try runTest("rv64ui_p_and.bin");
}

test "rv64ui_p_addiw" {
    try runTest("rv64ui_p_addiw.bin");
}

test "rv64ui_p_slliw" {
    try runTest("rv64ui_p_slliw.bin");
}

test "rv64ui_p_srliw" {
    try runTest("rv64ui_p_srliw.bin");
}

test "rv64ui_p_sraiw" {
    try runTest("rv64ui_p_sraiw.bin");
}

test "rv64ui_p_addw" {
    try runTest("rv64ui_p_addw.bin");
}

test "rv64ui_p_subw" {
    try runTest("rv64ui_p_subw.bin");
}

test "rv64ui_p_sllw" {
    try runTest("rv64ui_p_sllw.bin");
}

test "rv64ui_p_srlw" {
    try runTest("rv64ui_p_srlw.bin");
}

test "rv64ui_p_sraw" {
    try runTest("rv64ui_p_sraw.bin");
}

test "rv64mi_p_scall" {
    try runTest("rv64mi_p_scall.bin");
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
        var resource_dir = try std.fs.openDirAbsolute(resource_path, .{});
        defer resource_dir.close();

        var file = try resource_dir.openFile(context.file_name, .{});
        defer file.close();

        break :blk try file.readToEndAlloc(std.testing.allocator, std.math.maxInt(usize));
    };
    defer std.testing.allocator.free(file_contents);

    var cpu_state = zriscv.CpuState{ .memory = file_contents };
    zriscv.Cpu(.{}).run(&cpu_state) catch |err| switch (err) {
        error.ExecutionOutOfBounds => {
            if (cpu_state.x[10] != 0) {
                context.the_error = err;
            }
        },
        else => context.the_error = err,
    };
}

comptime {
    std.testing.refAllDecls(@This());
}
