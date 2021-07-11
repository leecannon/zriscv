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
    /// jumpa and link register
    JALR,
    /// branch equal
    BEQ,
    /// branch not equal
    BNE,
    /// branch less than - signed
    BLT,
    /// branch greater equal - signed
    BGE,
    /// branch less than - unsigned
    BLTU,
    /// branch greater equal - unsigned
    BGEU,
    /// load 8 bits - sign extended
    LB,
    /// load 16 bits - sign extended
    LH,
    /// load 32 bits - sign extended
    LW,
    /// load 8 bits - zero extended
    LBU,
    /// load 16 bits - zero extended
    LHU,
    /// add immediate
    ADDI,
    /// set less than immediate - signed
    SLTI,
    /// set less than immediate - unsigned
    SLTIU,
    /// xor immediate
    XORI,
    /// or immediate
    ORI,
    /// and immediate
    ANDI,
    /// logical left shift
    SLLI,
    /// logical right shift
    SRLI,
    /// arithmetic right shift
    SRAI,
    /// add
    ADD,
    /// sub
    SUB,
    /// shift logical left
    SLL,
    /// set less than - signed
    SLT,
    /// set less than - unsigned
    SLTU,
    /// exclusive or
    XOR,
    /// shift right logical
    SRL,
    /// shift right arithmetic
    SRA,
    /// or
    OR,
    /// and
    AND,
    /// memory fence
    FENCE,
    /// environment call
    ECALL,
    /// environment break
    EBREAK,

    // 64I

    /// add immediate - 32 bit
    ADDIW,
    /// logical left shift - 32 bit
    SLLIW,
    /// logical right shift - 32 bit
    SRLIW,
    /// arithmetic right shift - 32 bit
    SRAIW,
    /// add - 32 bit
    ADDW,
    /// sub - 32 bit
    SUBW,
    /// shift logical left - 32 bit
    SLLW,
    /// shift right logical - 32 bit
    SRLW,
    /// shift right arithmetic - 32 bit
    SRAW,

    // Zicsr

    // atomic read/write csr
    CSRRW,
    /// atomic read and set bits in csr
    CSRRS,
    /// atomic read and clear bits in csr
    CSRRC,
    /// atomic read/write csr - immediate
    CSRRWI,

    // Privilege
    MRET,
};

pub const Instruction = extern union {
    opcode: bitjuggle.Bitfield(u32, 0, 7),
    funct3: bitjuggle.Bitfield(u32, 12, 3),
    funct7: bitjuggle.Bitfield(u32, 25, 7),
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

    pub fn decode(instruction: Instruction, comptime unimplemented_is_fatal: bool) !InstructionType {
        const opcode = instruction.opcode.read();

        return switch (opcode) {
            // LOAD
            0b0000011 => switch (instruction.funct3.read()) {
                0b000 => InstructionType.LB,
                0b001 => InstructionType.LH,
                0b010 => InstructionType.LW,
                0b100 => InstructionType.LBU,
                0b101 => InstructionType.LHU,
                else => |funct3| {
                    if (unimplemented_is_fatal) {
                        std.log.emerg("unimplemented LOAD {b:0>7}/{b:0>3}", .{ opcode, funct3 });
                    }
                    return error.UnimplementedOpcode;
                },
            },
            0b0110111 => InstructionType.LUI,
            0b0010111 => InstructionType.AUIPC,
            0b1101111 => InstructionType.JAL,
            0b1100111 => InstructionType.JALR,
            // BRANCH
            0b1100011 => switch (instruction.funct3.read()) {
                0b000 => InstructionType.BEQ,
                0b001 => InstructionType.BNE,
                0b100 => InstructionType.BLT,
                0b101 => InstructionType.BGE,
                0b110 => InstructionType.BLTU,
                0b111 => InstructionType.BGEU,
                else => |funct3| {
                    if (unimplemented_is_fatal) {
                        std.log.emerg("unimplemented BRANCH {b:0>7}/{b:0>3}", .{ opcode, funct3 });
                    }
                    return error.UnimplementedOpcode;
                },
            },
            // OP-IMM
            0b0010011 => switch (instruction.funct3.read()) {
                0b000 => InstructionType.ADDI,
                0b010 => InstructionType.SLTI,
                0b011 => InstructionType.SLTIU,
                0b001 => InstructionType.SLLI,
                0b100 => InstructionType.XORI,
                0b110 => InstructionType.ORI,
                0b111 => InstructionType.ANDI,
                0b101 => if (instruction.funct7.read() == 0) InstructionType.SRLI else InstructionType.SRAI,
            },
            // OP
            0b0110011 => switch (instruction.funct3.read()) {
                0b000 => if (instruction.funct7.read() == 0) InstructionType.ADD else InstructionType.SUB,
                0b110 => InstructionType.OR,
                0b111 => InstructionType.AND,
                0b001 => InstructionType.SLL,
                0b010 => InstructionType.SLT,
                0b011 => InstructionType.SLTU,
                0b100 => InstructionType.XOR,
                0b101 => if (instruction.funct7.read() == 0) InstructionType.SRL else InstructionType.SRA,
            },
            0b001111 => InstructionType.FENCE,
            // SYSTEM
            0b1110011 => switch (instruction.funct3.read()) {
                0b000 => switch (instruction.funct7.read()) {
                    0b0000000 => InstructionType.ECALL,
                    0b0000001 => InstructionType.EBREAK,
                    0b0011000 => InstructionType.MRET,
                    else => |funct7| {
                        if (unimplemented_is_fatal) {
                            std.log.emerg("unimplemented SYSTEM {b:0>7}/000/{b:0>7}", .{ opcode, funct7 });
                        }
                        return error.UnimplementedOpcode;
                    },
                },
                0b001 => InstructionType.CSRRW,
                0b010 => InstructionType.CSRRS,
                0b011 => InstructionType.CSRRC,
                0b101 => InstructionType.CSRRWI,
                else => |funct3| {
                    if (unimplemented_is_fatal) {
                        std.log.emerg("unimplemented SYSTEM {b:0>7}/{b:0>3}", .{ opcode, funct3 });
                    }
                    return error.UnimplementedOpcode;
                },
            },
            // OP-IMM-32
            0b0011011 => switch (instruction.funct3.read()) {
                0b000 => InstructionType.ADDIW,
                0b001 => InstructionType.SLLIW,
                0b101 => if (instruction.funct7.read() == 0) InstructionType.SRLIW else InstructionType.SRAIW,
                else => |funct3| {
                    if (unimplemented_is_fatal) {
                        std.log.emerg("unimplemented OP-IMM-32 {b:0>7}/{b:0>3}", .{ opcode, funct3 });
                    }
                    return error.UnimplementedOpcode;
                },
            },
            // OP-32
            0b0111011 => switch (instruction.funct3.read()) {
                0b000 => if (instruction.funct7.read() == 0) InstructionType.ADDW else InstructionType.SUBW,
                0b001 => InstructionType.SLLW,
                0b101 => if (instruction.funct7.read() == 0) InstructionType.SRLW else InstructionType.SRAW,
                else => |funct3| {
                    if (unimplemented_is_fatal) {
                        std.log.emerg("unimplemented OP-32 {b:0>7}/{b:0>3}", .{ opcode, funct3 });
                    }
                    return error.UnimplementedOpcode;
                },
            },
            else => {
                if (unimplemented_is_fatal) {
                    std.log.emerg("unimplemented opcode {b:0>7}", .{opcode});
                }
                return error.UnimplementedOpcode;
            },
        };
    }

    pub const ISpecialization = extern union {
        shmt4_0: bitjuggle.Bitfield(u32, 20, 5),
        shmt5: bitjuggle.Bitfield(u32, 25, 1),
        shift_type: bitjuggle.Bitfield(u32, 26, 6),

        backing: u32,

        pub fn smallShift(self: ISpecialization) u5 {
            return @truncate(u5, self.shmt4_0.read());
        }

        pub fn fullShift(self: ISpecialization) u6 {
            return @truncate(u6, @as(u64, self.shmt5.read()) << 5 | self.shmt4_0.read());
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
