const std = @import("std");

pub const PrivilegeLevel = enum(u2) {
    User = 0,
    Supervisor = 1,
    Machine = 3,

    pub fn getPrivilegeLevel(value: u2) !PrivilegeLevel {
        return std.meta.intToEnum(PrivilegeLevel, value) catch {
            std.log.emerg("invalid privlege mode {b}", .{value});
            return error.InvalidPrivilegeLevel;
        };
    }
};

pub const ContextStatus = enum(u2) {
    Off = 0,
    Initial = 1,
    Clean = 2,
    Dirty = 3,

    pub fn getContextStatus(value: u2) !ContextStatus {
        return std.meta.intToEnum(ContextStatus, value) catch {
            std.log.emerg("invalid context status {b}", .{value});
            return error.InvalidContextStatus;
        };
    }
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
