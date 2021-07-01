const std = @import("std");
const bitjuggle = @import("bitjuggle");
const InstructionType = @import("InstructionType.zig").InstructionType;

pub const Instruction = extern union {
    opcode: bitjuggle.Bitfield(u32, 0, 7),
    funct3: bitjuggle.Bitfield(u32, 12, 3),
    rd: bitjuggle.Bitfield(u32, 7, 5),
    rs1: bitjuggle.Bitfield(u32, 15, 5),

    imm19_12: bitjuggle.Bitfield(u32, 12, 8),
    imm11: bitjuggle.Bitfield(u32, 20, 1),
    imm10_1: bitjuggle.Bitfield(u32, 21, 10),
    imm20: bitjuggle.Bitfield(u32, 31, 1),
    imm11_0: bitjuggle.Bitfield(u32, 0, 12),

    backing: u32,

    pub fn readJImm(self: Instruction) i64 {
        const shift_amount = 11 + 32;

        return @bitCast(
            i64,
            @as(u64, self.imm20.read()) << 20 + shift_amount |
                @as(u64, self.imm19_12.read()) << 12 + shift_amount |
                @as(u64, self.imm11.read()) << 11 + shift_amount |
                @as(u64, self.imm10_1.read()) << 1 + shift_amount,
        ) >> shift_amount;
    }

    pub fn decode(self: Instruction) !InstructionType {
        return switch (self.opcode.read()) {
            0b1101111 => .JAL,
            // SYSTEM
            0b1110011 => switch (self.funct3.read()) {
                0b010 => .CSRRS,
                else => |funct3| {
                    std.log.emerg("unimplemented funct3: SYSTEM/{b:0>3}", .{funct3});
                    return error.UnimplementedOpcode;
                },
            },
            else => |opcode| {
                std.log.emerg("unimplemented opcode: {b:0>7}", .{opcode});
                return error.UnimplementedOpcode;
            },
        };
    }

    comptime {
        std.testing.refAllDecls(@This());
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
