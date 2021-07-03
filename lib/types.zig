const std = @import("std");

pub const PrivilegeLevel = enum(u2) {
    User = 0,
    Supervisor = 1,
    Machine = 3,
};

pub const VectorMode = enum(u2) {
    direct,
    vectored,

    pub fn getVectorMode(value: u2) !VectorMode {
        return std.meta.intToEnum(VectorMode, value) catch {
            std.log.emerg("invalid vector mode {b}", .{value});
            return error.InvalidVectorMode;
        };
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
