const std = @import("std");

pub const Cpu = struct {
    registers: [32]u64 = [_]u64{0} ** 32,
    memory: []u8,
};

comptime {
    std.testing.refAllDecls(@This());
}
