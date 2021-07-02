const std = @import("std");
const bitjuggle = @import("bitjuggle");
const InstructionType = @import("InstructionType.zig").InstructionType;

pub const Instruction = extern union {
    opcode: bitjuggle.Bitfield(u32, 0, 7),
    funct3: bitjuggle.Bitfield(u32, 12, 3),
    rd: bitjuggle.Bitfield(u32, 7, 5),
    rs1: bitjuggle.Bitfield(u32, 15, 5),
    rs2: bitjuggle.Bitfield(u32, 20, 5),
    csr: bitjuggle.Bitfield(u32, 20, 12),

    j_imm: JImm,
    b_imm: BImm,
    i_imm: IImm,
    u_imm: UImm,

    backing: u32,

    pub const UImm = extern union {
        imm31_12: bitjuggle.Bitfield(u32, 12, 19),

        backing: u32,

        pub fn read(self: UImm) i32 {
            return self.imm31_12.read() << 12;
        }
    };

    pub const IImm = extern union {
        imm11_0: bitjuggle.Bitfield(u32, 0, 12),

        backing: u32,

        pub fn read(self: IImm) i64 {
            const shift_amount = 20 + 32;
            return @bitCast(i64, @as(u64, self.imm11_0.read()) << shift_amount) >> shift_amount;
        }
    };

    pub const JImm = extern union {
        imm10_1: bitjuggle.Bitfield(u32, 21, 10),
        imm11: bitjuggle.Bitfield(u32, 20, 1),
        imm19_12: bitjuggle.Bitfield(u32, 12, 8),
        imm20: bitjuggle.Bitfield(u32, 31, 1),

        backing: u32,

        pub fn read(self: JImm) i64 {
            const shift_amount = 11 + 32;

            return @bitCast(
                i64,
                @as(u64, self.imm20.read()) << 20 + shift_amount |
                    @as(u64, self.imm19_12.read()) << 12 + shift_amount |
                    @as(u64, self.imm11.read()) << 11 + shift_amount |
                    @as(u64, self.imm10_1.read()) << 1 + shift_amount,
            ) >> shift_amount;
        }
    };

    pub const BImm = extern union {
        imm4_1: bitjuggle.Bitfield(u32, 8, 4),
        imm10_5: bitjuggle.Bitfield(u32, 25, 6),
        imm11: bitjuggle.Bitfield(u32, 7, 1),
        imm12: bitjuggle.Bitfield(u32, 31, 1),

        backing: u32,

        pub fn read(self: BImm) i64 {
            const shift_amount = 19 + 32;

            return @bitCast(
                i64,
                @as(u64, self.imm12.read()) << 12 + shift_amount |
                    @as(u64, self.imm11.read()) << 11 + shift_amount |
                    @as(u64, self.imm10_5.read()) << 5 + shift_amount |
                    @as(u64, self.imm4_1.read()) << 1 + shift_amount,
            ) >> shift_amount;
        }
    };

    comptime {
        std.testing.refAllDecls(@This());
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
