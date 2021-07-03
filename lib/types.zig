const std = @import("std");

pub const PrivilegeLevel = enum(u2) {
    User = 0,
    Supervisor = 1,
    Machine = 3,
};

pub const VectorMode = enum(u2) {
    Direct,
    Vectored,

    pub fn getVectorMode(value: u2) !VectorMode {
        return std.meta.intToEnum(VectorMode, value) catch {
            std.log.emerg("invalid vector mode {b}", .{value});
            return error.InvalidVectorMode;
        };
    }
};

pub const AddressTranslationMode = enum(u4) {
    Bare = 0,
    Sv39 = 8,
    Sv48 = 9,

    pub fn getAddressTranslationMode(value: u4) !AddressTranslationMode {
        return std.meta.intToEnum(AddressTranslationMode, value) catch {
            std.log.emerg("invalid address translation mode {b}", .{value});
            return error.InvalidAddressTranslationMode;
        };
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
