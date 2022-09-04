const std = @import("std");
const bitjuggle = @import("bitjuggle");
const lib = @import("lib.zig");

// Order of the instruction types loosely follows RV32/64G Instruction Set Listings from the RISC-V Unprivledged ISA
pub const InstructionType = enum {
    Illegal,
    Unimplemented,

    // LUI
    LUI,

    // AUIPC
    AUIPC,

    // JAL
    JAL,

    // JALR
    JALR,

    // BRANCH
    BEQ,
    BNE,
    BLT,
    BGE,
    BLTU,
    BGEU,

    // LOAD
    LB,
    LH,
    LW,
    LD,
    LBU,
    LHU,
    LWU,

    // STORE
    SB,
    SH,
    SW,
    SD,

    // OP-IMM
    ADDI,
    SLTI,
    SLTIU,
    XORI,
    ORI,
    ANDI,
    SLLI,
    SRLI,
    SRAI,

    // OP
    ADD,
    SUB,
    SLL,
    SLT,
    SLTU,
    XOR,
    SRL,
    SRA,
    OR,
    AND,

    // OP-IMM-32
    ADDIW,
    SLLIW,
    SRLIW,
    SRAIW,

    // SYSTEM
    ECALL,
    EBREAK,
    CSRRW,
    CSRRS,
    CSRRC,
    CSRRWI,
    CSRRSI,
    CSRRCI,

    // Compressed - Quadrant 0
    C_ADDI4SPN,

    // Compressed - Quadrant 1
    C_J,
};

pub const Instruction = extern union {
    op: bitjuggle.Bitfield(u32, 0, 2),
    opcode: bitjuggle.Bitfield(u32, 0, 7),
    non_compressed_funct3: bitjuggle.Bitfield(u32, 12, 3),
    compressed_funct3: bitjuggle.Bitfield(u32, 13, 3),
    funct7: bitjuggle.Bitfield(u32, 25, 7),
    funct7_shift: bitjuggle.Bitfield(u32, 26, 6),
    csr: bitjuggle.Bitfield(u32, 20, 12),

    _rd: bitjuggle.Bitfield(u32, 7, 5),
    _rs1: bitjuggle.Bitfield(u32, 15, 5),
    _rs2: bitjuggle.Bitfield(u32, 20, 5),

    i_imm: IImm,
    s_imm: SImm,
    b_imm: BImm,
    u_imm: UImm,
    j_imm: JImm,

    compressed_jump_target: CompressedJumpTarget,

    i_specialization: ISpecialization,

    compressed_backing: CompressedBacking,
    full_backing: u32,

    pub const CompressedBacking = extern struct {
        low: u16,
        high: u16 = 0,

        comptime {
            std.debug.assert(@sizeOf(CompressedBacking) == @sizeOf(u32));
            std.debug.assert(@bitSizeOf(CompressedBacking) == @bitSizeOf(u32));
        }
    };

    pub const CompressedJumpTarget = extern union {
        imm5: bitjuggle.Bitfield(u32, 2, 1),
        imm3_1: bitjuggle.Bitfield(u32, 3, 3),
        imm7: bitjuggle.Bitfield(u32, 6, 1),
        imm6: bitjuggle.Bitfield(u32, 7, 1),
        imm10: bitjuggle.Bitfield(u32, 8, 1),
        imm9_8: bitjuggle.Bitfield(u32, 9, 2),
        imm4: bitjuggle.Bitfield(u32, 11, 1),
        imm11: bitjuggle.Bitfield(u32, 12, 1),

        backing: u32,

        pub fn read(self: CompressedJumpTarget) i64 {
            const shift_amount = 20 + 32;

            return @bitCast(
                i64,
                (@as(u64, self.imm11.read()) << (11 + shift_amount) |
                    @as(u64, self.imm10.read()) << (10 + shift_amount) |
                    @as(u64, self.imm9_8.read()) << (8 + shift_amount) |
                    @as(u64, self.imm7.read()) << (7 + shift_amount) |
                    @as(u64, self.imm6.read()) << (6 + shift_amount) |
                    @as(u64, self.imm5.read()) << (5 + shift_amount) |
                    @as(u64, self.imm4.read()) << (4 + shift_amount) |
                    @as(u64, self.imm3_1.read()) << (1 + shift_amount)),
            ) >> shift_amount;
        }

        comptime {
            std.debug.assert(@sizeOf(CompressedJumpTarget) == @sizeOf(u32));
            std.debug.assert(@bitSizeOf(CompressedJumpTarget) == @bitSizeOf(u32));
        }
    };

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

    pub const IImm = extern union {
        imm11_0: bitjuggle.Bitfield(u32, 20, 12),

        backing: u32,

        pub fn read(self: IImm) i64 {
            const shift_amount = 20 + 32;
            return @bitCast(i64, @as(u64, self.imm11_0.read()) << shift_amount) >> shift_amount;
        }

        comptime {
            std.debug.assert(@sizeOf(IImm) == @sizeOf(u32));
            std.debug.assert(@bitSizeOf(IImm) == @bitSizeOf(u32));
        }
    };

    pub const SImm = extern union {
        imm4_0: bitjuggle.Bitfield(u32, 7, 5),
        imm11_5: bitjuggle.Bitfield(u32, 25, 7),

        backing: u32,

        pub fn read(self: SImm) i64 {
            const shift_amount = 20 + 32;
            return @bitCast(
                i64,
                @as(u64, self.imm11_5.read()) << (5 + shift_amount) |
                    @as(u64, self.imm4_0.read()) << shift_amount,
            ) >> shift_amount;
        }

        comptime {
            std.debug.assert(@sizeOf(SImm) == @sizeOf(u32));
            std.debug.assert(@bitSizeOf(SImm) == @bitSizeOf(u32));
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
                @as(u64, self.imm12.read()) << (12 + shift_amount) |
                    @as(u64, self.imm11.read()) << (11 + shift_amount) |
                    @as(u64, self.imm10_5.read()) << (5 + shift_amount) |
                    @as(u64, self.imm4_1.read()) << (1 + shift_amount),
            ) >> shift_amount;
        }

        comptime {
            std.debug.assert(@sizeOf(BImm) == @sizeOf(u32));
            std.debug.assert(@bitSizeOf(BImm) == @bitSizeOf(u32));
        }
    };

    pub const UImm = extern union {
        imm31_12: bitjuggle.Bitfield(u32, 12, 20),

        backing: u32,

        pub fn read(self: UImm) i64 {
            return @bitCast(
                i64,
                @as(u64, self.imm31_12.read()) << (12 + 32),
            ) >> 32;
        }

        comptime {
            std.debug.assert(@sizeOf(UImm) == @sizeOf(u32));
            std.debug.assert(@bitSizeOf(UImm) == @bitSizeOf(u32));
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

    pub inline fn rd(self: Instruction) lib.IntegerRegister {
        return lib.IntegerRegister.getIntegerRegister(self._rd.read());
    }

    pub inline fn rs1(self: Instruction) lib.IntegerRegister {
        return lib.IntegerRegister.getIntegerRegister(self._rs1.read());
    }

    pub inline fn rs2(self: Instruction) lib.IntegerRegister {
        return lib.IntegerRegister.getIntegerRegister(self._rs2.read());
    }

    pub fn decode(instruction: Instruction) InstructionType {
        const z = lib.traceNamed(@src(), "instruction decode");
        defer z.end();

        const compressed_funct3 = instruction.compressed_funct3.read();
        const funct3 = instruction.non_compressed_funct3.read();

        return switch (instruction.op.read()) {
            // compressed instruction
            0b00 => switch (compressed_funct3) {
                0b000 => if (instruction.compressed_backing.low == 0) InstructionType.Illegal else InstructionType.C_ADDI4SPN,
                else => InstructionType.Unimplemented,
            },
            // compressed instruction
            0b01 => switch (compressed_funct3) {
                0b101 => InstructionType.C_J,
                else => InstructionType.Unimplemented,
            },
            // compressed instruction
            0b10 => switch (compressed_funct3) {
                else => InstructionType.Unimplemented,
            },
            // non-compressed instruction
            0b11 => switch (instruction.opcode.read()) {
                // LOAD
                0b0000011 => switch (funct3) {
                    0b000 => InstructionType.LB,
                    0b001 => InstructionType.LH,
                    0b010 => InstructionType.LW,
                    0b011 => InstructionType.LD,
                    0b100 => InstructionType.LBU,
                    0b101 => InstructionType.LHU,
                    0b110 => InstructionType.LWU,
                    else => InstructionType.Unimplemented,
                },
                // STORE
                0b0100011 => switch (funct3) {
                    0b000 => InstructionType.SB,
                    0b001 => InstructionType.SH,
                    0b010 => InstructionType.SW,
                    0b011 => InstructionType.SD,
                    else => InstructionType.Unimplemented,
                },
                // MADD
                0b1000011 => switch (funct3) {
                    else => InstructionType.Unimplemented,
                },
                // BRANCH
                0b1100011 => switch (funct3) {
                    0b000 => InstructionType.BEQ,
                    0b001 => InstructionType.BNE,
                    0b100 => InstructionType.BLT,
                    0b101 => InstructionType.BGE,
                    0b110 => InstructionType.BLTU,
                    0b111 => InstructionType.BGEU,
                    else => InstructionType.Unimplemented,
                },
                // LOAD-FP
                0b0000111 => switch (funct3) {
                    else => InstructionType.Unimplemented,
                },
                // STORE-FP
                0b0100111 => switch (funct3) {
                    else => InstructionType.Unimplemented,
                },
                // MSUB
                0b1000111 => switch (funct3) {
                    else => InstructionType.Unimplemented,
                },
                // JALR
                0b1100111 => switch (funct3) {
                    0b000 => InstructionType.JALR,
                    else => InstructionType.Unimplemented,
                },
                // NMSUB
                0b1001011 => switch (funct3) {
                    else => InstructionType.Unimplemented,
                },
                // MISC-MEM
                0b0001111 => switch (funct3) {
                    else => InstructionType.Unimplemented,
                },
                // AMO
                0b0101111 => switch (funct3) {
                    else => InstructionType.Unimplemented,
                },
                // NMADD
                0b1001111 => switch (funct3) {
                    else => InstructionType.Unimplemented,
                },
                // JAL
                0b1101111 => InstructionType.JAL,
                // OP-IMM
                0b0010011 => switch (funct3) {
                    0b000 => InstructionType.ADDI,
                    0b001 => switch (instruction.funct7_shift.read()) {
                        0b000000 => InstructionType.SLLI,
                        else => InstructionType.Unimplemented,
                    },
                    0b010 => InstructionType.SLTI,
                    0b011 => InstructionType.SLTIU,
                    0b100 => InstructionType.XORI,
                    0b101 => switch (instruction.funct7_shift.read()) {
                        0b000000 => InstructionType.SRLI,
                        0b010000 => InstructionType.SRAI,
                        else => InstructionType.Unimplemented,
                    },
                    0b110 => InstructionType.ORI,
                    0b111 => InstructionType.ANDI,
                },
                // OP
                0b0110011 => switch (funct3) {
                    0b000 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.ADD,
                        0b0100000 => InstructionType.SUB,
                        else => InstructionType.Unimplemented,
                    },
                    0b001 => InstructionType.SLL,
                    0b010 => InstructionType.SLT,
                    0b011 => InstructionType.SLTU,
                    0b100 => InstructionType.XOR,
                    0b101 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.SRL,
                        0b0100000 => InstructionType.SRA,
                        else => InstructionType.Unimplemented,
                    },
                    0b110 => InstructionType.OR,
                    0b111 => InstructionType.AND,
                },
                // OP-FP
                0b1010011 => switch (funct3) {
                    else => InstructionType.Unimplemented,
                },
                // SYSTEM
                0b1110011 => switch (funct3) {
                    0b000 => switch (instruction.i_imm.read()) {
                        0b000000000000 => InstructionType.ECALL,
                        0b000000000001 => InstructionType.EBREAK,
                        else => InstructionType.Unimplemented,
                    },
                    0b001 => InstructionType.CSRRW,
                    0b010 => InstructionType.CSRRS,
                    0b011 => InstructionType.CSRRC,
                    0b101 => InstructionType.CSRRWI,
                    0b110 => InstructionType.CSRRSI,
                    0b111 => InstructionType.CSRRCI,
                    else => InstructionType.Unimplemented,
                },
                // AUIPC
                0b0010111 => InstructionType.AUIPC,
                // LUI
                0b0110111 => InstructionType.LUI,
                // OP-V
                0b1010111 => switch (funct3) {
                    else => InstructionType.Unimplemented,
                },
                // OP-IMM-32
                0b0011011 => switch (funct3) {
                    0b000 => InstructionType.ADDIW,
                    0b001 => InstructionType.SLLIW,
                    0b101 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.SRLIW,
                        0b0100000 => InstructionType.SRAIW,
                        else => InstructionType.Unimplemented,
                    },
                    else => InstructionType.Unimplemented,
                },
                // OP-32
                0b0111011 => switch (funct3) {
                    else => InstructionType.Unimplemented,
                },
                0b1111111 => blk: {
                    if (instruction.full_backing == ~@as(u32, 0)) break :blk InstructionType.Illegal;
                    break :blk InstructionType.Unimplemented;
                },
                else => InstructionType.Unimplemented,
            },
        };
    }

    pub fn printUnimplementedInstruction(instruction: Instruction) void {
        const op = instruction.op.read();

        if (op == 0b11) {
            // non-compressed
            const opcode = instruction.opcode.read();
            const funct3 = instruction.non_compressed_funct3.read();
            const funct7 = instruction.funct7.read();
            std.log.err(
                "UNIMPLEMENTED non-compressed instruction: opcode<{b:0>7}>/funct3<{b:0>3}>/funct7<{b:0>7}>",
                .{ opcode, funct3, funct7 },
            );
        } else {
            // compressed
            const compressed_funct3 = instruction.compressed_funct3.read();
            std.log.err(
                "UNIMPLEMENTED compressed instruction: quadrant<{b:0>2}>/funct3<{b:0>3}>",
                .{ op, compressed_funct3 },
            );
        }
    }

    comptime {
        std.debug.assert(@sizeOf(Instruction) == @sizeOf(u32));
        std.debug.assert(@bitSizeOf(Instruction) == @bitSizeOf(u32));
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
