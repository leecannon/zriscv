const std = @import("std");
const bitjuggle = @import("bitjuggle");
const lib = @import("lib.zig");

// Order of the instruction types loosely follows RV32/64G Instruction Set Listings from the RISC-V Unprivledged ISA
pub const InstructionType = enum {
    // LUI
    LUI,

    // BRANCH
    BEQ,
    BNE,
    BLT,
    BGE,
    BLTU,
    BGEU,

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

    _rd: bitjuggle.Bitfield(u32, 7, 5),
    _rs1: bitjuggle.Bitfield(u32, 15, 5),
    _rs2: bitjuggle.Bitfield(u32, 20, 5),

    i_imm: IImm,
    s_imm: SImm,
    b_imm: BImm,
    u_imm: UImm,
    compressed_jump_target: CompressedJumpTarget,

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

    pub inline fn rd(self: Instruction) lib.IntegerRegister {
        return lib.IntegerRegister.getIntegerRegister(self._rd.read());
    }

    pub inline fn rs1(self: Instruction) lib.IntegerRegister {
        return lib.IntegerRegister.getIntegerRegister(self._rs1.read());
    }

    pub inline fn rs2(self: Instruction) lib.IntegerRegister {
        return lib.IntegerRegister.getIntegerRegister(self._rs2.read());
    }

    pub const DecodeError = error{
        IllegalInstruction,
        UnimplementedInstruction,
    };

    pub fn decode(instruction: Instruction) DecodeError!InstructionType {
        const z = lib.traceNamed(@src(), "instruction decode");
        defer z.end();

        const compressed_funct3 = instruction.compressed_funct3.read();
        const funct3 = instruction.non_compressed_funct3.read();

        return switch (instruction.op.read()) {
            // compressed instruction
            0b00 => switch (compressed_funct3) {
                0b000 => if (instruction.compressed_backing.low == 0) error.IllegalInstruction else InstructionType.C_ADDI4SPN,
                else => error.UnimplementedInstruction,
            },
            // compressed instruction
            0b01 => switch (compressed_funct3) {
                0b101 => InstructionType.C_J,
                else => error.UnimplementedInstruction,
            },
            // compressed instruction
            0b10 => switch (compressed_funct3) {
                else => error.UnimplementedInstruction,
            },
            // non-compressed instruction
            0b11 => switch (instruction.opcode.read()) {
                // LOAD
                0b0000011 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // STORE
                0b0100011 => switch (funct3) {
                    0b000 => InstructionType.SB,
                    0b001 => InstructionType.SH,
                    0b010 => InstructionType.SW,
                    0b011 => InstructionType.SD,
                    else => error.UnimplementedInstruction,
                },
                // MADD
                0b1000011 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // BRANCH
                0b1100011 => switch (funct3) {
                    0b000 => InstructionType.BEQ,
                    0b001 => InstructionType.BNE,
                    0b100 => InstructionType.BLT,
                    0b101 => InstructionType.BGE,
                    0b110 => InstructionType.BLTU,
                    0b111 => InstructionType.BGEU,
                    else => error.UnimplementedInstruction,
                },
                // LOAD-FP
                0b0000111 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // STORE-FP
                0b0100111 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // MSUB
                0b1000111 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // JALR
                0b1100111 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // NMSUB
                0b1001011 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // MISC-MEM
                0b0001111 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // AMO
                0b0101111 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // NMADD
                0b1001111 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // JAL
                0b1101111 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // OP-IMM
                0b0010011 => switch (funct3) {
                    0b000 => InstructionType.ADDI,
                    0b001 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.SLLI,
                        else => error.UnimplementedInstruction,
                    },
                    0b010 => InstructionType.SLTI,
                    0b011 => InstructionType.SLTIU,
                    0b100 => InstructionType.XORI,
                    0b101 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.SRLI,
                        0b0100000 => InstructionType.SRAI,
                        else => error.UnimplementedInstruction,
                    },
                    0b110 => InstructionType.ORI,
                    0b111 => InstructionType.ANDI,
                },
                // OP
                0b0110011 => switch (funct3) {
                    0b000 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.ADD,
                        0b0100000 => InstructionType.SUB,
                        else => error.UnimplementedInstruction,
                    },
                    0b001 => InstructionType.SLL,
                    0b010 => InstructionType.SLT,
                    0b011 => InstructionType.SLTU,
                    0b100 => InstructionType.XOR,
                    0b101 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.SRL,
                        0b0100000 => InstructionType.SRA,
                        else => error.UnimplementedInstruction,
                    },
                    0b110 => InstructionType.OR,
                    0b111 => InstructionType.AND,
                },
                // OP-FP
                0b1010011 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // SYSTEM
                0b1110011 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // AUIPC
                0b0010111 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // LUI
                0b0110111 => InstructionType.LUI,
                // OP-V
                0b1010111 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // OP-IMM-32
                0b0011011 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                // OP-32
                0b0111011 => switch (funct3) {
                    else => error.UnimplementedInstruction,
                },
                0b1111111 => blk: {
                    if (instruction.full_backing == ~@as(u32, 0)) break :blk error.IllegalInstruction;

                    break :blk error.UnimplementedInstruction;
                },
                else => error.UnimplementedInstruction,
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
