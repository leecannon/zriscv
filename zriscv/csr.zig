const std = @import("std");
const bitjuggle = @import("bitjuggle");
const zriscv = @import("zriscv");

pub const Csr = enum(u12) {
    // Cycle counter for RDCYCLE instruction
    cycle = 0xC00,

    /// Hardware thread ID
    mhartid = 0xF14,

    pub fn getCsr(value: u12) !Csr {
        return std.meta.intToEnum(Csr, value) catch {
            std.log.err("invalid csr 0x{X}", .{value});
            return error.InvalidCsr;
        };
    }

    pub fn canRead(self: Csr, privilege_level: zriscv.PrivilegeLevel) bool {
        const csr_value = @enumToInt(self);

        // TODO: Calculate this at comptime
        const lowest_privilege_level = bitjuggle.getBits(csr_value, 8, 2);
        if (@enumToInt(privilege_level) < lowest_privilege_level) return false;

        return true;
    }

    pub fn canWrite(self: Csr, privilege_level: zriscv.PrivilegeLevel) bool {
        const csr_value = @enumToInt(self);

        // TODO: Calculate this at comptime
        const lowest_privilege_level = bitjuggle.getBits(csr_value, 8, 2);
        if (@enumToInt(privilege_level) < lowest_privilege_level) return false;

        return bitjuggle.getBits(csr_value, 10, 2) != @as(u12, 0b11);
    }

    pub fn format(value: Csr, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll(@tagName(value));
    }
};

comptime {
    refAllDeclsRecursive(@This());
}

// This code is from `std.testing.refAllDeclsRecursive` but as it is in the file it can access private decls
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (decl.is_pub) {
            if (@TypeOf(@field(T, decl.name)) == type) {
                switch (@typeInfo(@field(T, decl.name))) {
                    .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name)),
                    else => {},
                }
            }
            _ = @field(T, decl.name);
        }
    }
}
