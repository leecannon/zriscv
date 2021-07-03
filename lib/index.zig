const std = @import("std");

pub const Cpu = @import("Cpu.zig");

comptime {
    std.testing.refAllDecls(@This());
}
