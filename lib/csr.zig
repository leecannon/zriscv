const std = @import("std");
const bitjuggle = @import("bitjuggle");
usingnamespace @import("types.zig");

pub const Csr = enum(u12) {
    /// Hardware thread ID
    mhartid = 0xF14,
    /// Machine trap-handler base address
    mtvec = 0x305,

    pub fn getCsr(value: u12) !Csr {
        return std.meta.intToEnum(Csr, value) catch {
            std.log.emerg("invalid csr 0x{X}", .{value});
            return error.InvalidCsr;
        };
    }

    pub fn canRead(self: Csr, privilege_level: PrivilegeLevel) bool {
        const csr_value = @enumToInt(self);

        const lowest_privilege_level = bitjuggle.getBits(csr_value, 8, 2);
        if (@enumToInt(privilege_level) < lowest_privilege_level) return false;

        return true;
    }

    pub fn canWrite(self: Csr, privilege_level: PrivilegeLevel) bool {
        const csr_value = @enumToInt(self);

        const lowest_privilege_level = bitjuggle.getBits(csr_value, 8, 2);
        if (@enumToInt(privilege_level) < lowest_privilege_level) return false;

        return bitjuggle.getBits(csr_value, 10, 2) != @as(u12, 0b11);
    }
};

pub const Mtvec = extern union {
    mode: bitjuggle.Bitfield(u64, 0, 2),
    base: bitjuggle.Bitfield(u64, 2, 62),

    backing: u64,
};

comptime {
    std.testing.refAllDecls(@This());
}
