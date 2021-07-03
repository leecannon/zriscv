const std = @import("std");
const bitjuggle = @import("bitjuggle");

pub const InstructionType = enum {
    // 32I

    /// load upper immediate
    LUI,
    /// add upper immediate to pc
    AUIPC,
    /// jump and link
    JAL,
    /// branch equal
    BEQ,
    /// branch not equal
    BNE,
    /// branch greater equal
    BGE,
    /// add immediate
    ADDI,
    /// logical left shift
    SLLI,

    // 64I

    /// add immediate - 32 bit
    ADDIW,

    // Zicsr

    // atomic read/write csr
    CSRRW,
    /// atomic read and set bits in csr
    CSRRS,
    /// atomic read/write csr - immediate
    CSRRWI,
};

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

    i_specialization: ISpecialization,

    backing: u32,

    pub const ISpecialization = extern union {
        shmt4_0: bitjuggle.Bitfield(u32, 20, 5),
        shmt5: bitjuggle.Bitfield(u32, 25, 1),
        shift_type: bitjuggle.Bitfield(u32, 26, 6),

        backing: u32,

        pub fn smallShift(self: ISpecialization) u4 {
            return @truncate(u4, self.shmt4_0.read());
        }

        pub fn fullShift(self: ISpecialization) u5 {
            return @truncate(u5, @as(u64, self.shmt5.read()) << 5 | self.shmt4_0.read());
        }
    };

    pub const UImm = extern union {
        imm31_12: bitjuggle.Bitfield(u32, 12, 20),

        backing: u32,

        pub fn read(self: UImm) i64 {
            return @bitCast(
                i64,
                (@as(u64, self.imm31_12.read()) << 12) << 32,
            ) >> 32;
        }
    };

    pub const IImm = extern union {
        imm11_0: bitjuggle.Bitfield(u32, 20, 12),

        backing: u32,

        pub fn read(self: IImm) i64 {
            const shift_amount = 20 + 32;
            return @bitCast(i64, @as(u64, self.imm11_0.read()) << shift_amount) >> shift_amount;
        }
    };

    pub const JImm = extern union {
        imm19_12: bitjuggle.Bitfield(u32, 12, 8),
        imm11: bitjuggle.Bitfield(u32, 20, 1),
        imm10_1: bitjuggle.Bitfield(u32, 21, 10),
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
        imm11: bitjuggle.Bitfield(u32, 7, 1),
        imm4_1: bitjuggle.Bitfield(u32, 8, 4),
        imm10_5: bitjuggle.Bitfield(u32, 25, 6),
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
