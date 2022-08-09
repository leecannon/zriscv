const std = @import("std");
const lib = @import("lib.zig");

const Hart = @This();

hart_id: usize,
machine: *lib.Machine,

pc: usize = 0,
x: [32]u64 = [_]u64{0} ** 32,

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
