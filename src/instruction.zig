const std = @import("std");
const bitjuggle = @import("bitjuggle");
const lib = @import("lib.zig");

pub const InstructionType = enum {
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
};

pub const Instruction = extern union {
    op: bitjuggle.Bitfield(u32, 0, 2),
    opcode: bitjuggle.Bitfield(u32, 0, 7),
    funct3: bitjuggle.Bitfield(u32, 12, 3),
    funct7: bitjuggle.Bitfield(u32, 25, 7),

    _rd: bitjuggle.Bitfield(u32, 7, 5),
    _rs1: bitjuggle.Bitfield(u32, 15, 5),
    _rs2: bitjuggle.Bitfield(u32, 20, 5),

    i_imm: IImm,

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

    pub inline fn rd(self: Instruction) lib.IntegerRegister {
        return lib.IntegerRegister.getIntegerRegister(self._rd.read());
    }

    pub inline fn rs1(self: Instruction) lib.IntegerRegister {
        return lib.IntegerRegister.getIntegerRegister(self._rs1.read());
    }

    pub inline fn rs2(self: Instruction) lib.IntegerRegister {
        return lib.IntegerRegister.getIntegerRegister(self._rs2.read());
    }

    pub fn decode(instruction: Instruction, comptime unimplemented_is_fatal: bool) !InstructionType {
        const funct3 = instruction.funct3.read();

        switch (instruction.op.read()) {
            // compressed instruction
            0b00 => switch (funct3) {
                else => if (unimplemented_is_fatal) {
                    std.log.err("unimplemented compressed instruction 00/{b:0>3}", .{funct3});
                },
            },
            // compressed instruction
            0b01 => switch (funct3) {
                else => if (unimplemented_is_fatal) {
                    std.log.err("unimplemented compressed instruction 01/{b:0>3}", .{funct3});
                },
            },
            // compressed instruction
            0b10 => switch (funct3) {
                else => if (unimplemented_is_fatal) {
                    std.log.err("unimplemented compressed instruction 10/{b:0>3}", .{funct3});
                },
            },
            // non-compressed instruction
            0b11 => switch (instruction.opcode.read()) {
                // LOAD
                0b0000011 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented LOAD 0000011/{b:0>3}", .{funct3});
                    },
                },
                // STORE
                0b0100011 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented STORE 0100011/{b:0>3}", .{funct3});
                    },
                },
                // MADD
                0b1000011 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented MADD 1000011/{b:0>3}", .{funct3});
                    },
                },
                // BRANCH
                0b1100011 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented BRANCH 1100011/{b:0>3}", .{funct3});
                    },
                },
                // LOAD-FP
                0b0000111 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented LOAD-FP 0000111/{b:0>3}", .{funct3});
                    },
                },
                // STORE-FP
                0b0100111 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented STORE-FP 0100111/{b:0>3}", .{funct3});
                    },
                },
                // MSUB
                0b1000111 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented MSUB 1000111/{b:0>3}", .{funct3});
                    },
                },
                // JALR
                0b1100111 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented JALR 1100111/{b:0>3}", .{funct3});
                    },
                },
                // NMSUB
                0b1001011 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented NMSUB 1001011/{b:0>3}", .{funct3});
                    },
                },
                // MISC-MEM
                0b0001111 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented MISC-MEM 0001111/{b:0>3}", .{funct3});
                    },
                },
                // AMO
                0b0101111 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented MISC-MEM 0101111/{b:0>3}", .{funct3});
                    },
                },
                // NMADD
                0b1001111 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented MISC-MEM 1001111/{b:0>3}", .{funct3});
                    },
                },
                // JAL
                0b1101111 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented MISC-MEM 1101111/{b:0>3}", .{funct3});
                    },
                },
                // OP-IMM
                0b0010011 => switch (funct3) {
                    0b000 => return .ADDI,
                    0b001 => switch (instruction.funct7.read()) {
                        0b0000000 => return .SLLI,
                        else => |funct7| if (unimplemented_is_fatal) {
                            std.log.err("unimplemented OP-IMM 0010011/001/{b:0>7}", .{funct7});
                        },
                    },
                    0b010 => return .SLTI,
                    0b011 => return .SLTIU,
                    0b100 => return .XORI,
                    0b101 => switch (instruction.funct7.read()) {
                        0b0000000 => return .SRLI,
                        0b0100000 => return .SRAI,
                        else => |funct7| if (unimplemented_is_fatal) {
                            std.log.err("unimplemented OP-IMM 0010011/101/{b:0>7}", .{funct7});
                        },
                    },
                    0b110 => return .ORI,
                    0b111 => return .ANDI,
                },
                // OP
                0b0110011 => switch (funct3) {
                    0b000 => switch (instruction.funct7.read()) {
                        0b0000000 => return .ADD,
                        0b0100000 => return .SUB,
                        else => |funct7| if (unimplemented_is_fatal) {
                            std.log.err("unimplemented OP 0110011/000/{b:0>7}", .{funct7});
                        },
                    },
                    0b001 => return .SLL,
                    0b010 => return .SLT,
                    0b011 => return .SLTU,
                    0b100 => return .XOR,
                    0b101 => switch (instruction.funct7.read()) {
                        0b0000000 => return .SRL,
                        0b0100000 => return .SRA,
                        else => |funct7| if (unimplemented_is_fatal) {
                            std.log.err("unimplemented OP 0110011/101/{b:0>7}", .{funct7});
                        },
                    },
                    0b110 => return .OR,
                    0b111 => return .AND,
                },
                // OP-FP
                0b1010011 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented OP-FP 1010011/{b:0>3}", .{funct3});
                    },
                },
                // SYSTEM
                0b1110011 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented SYSTEM 1110011/{b:0>3}", .{funct3});
                    },
                },
                // AUIPC
                0b0010111 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented AUIPC 0010111/{b:0>3}", .{funct3});
                    },
                },
                // LUI
                0b0110111 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented LUI 0110111/{b:0>3}", .{funct3});
                    },
                },
                // OP-V
                0b1010111 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented OP-V 1010111/{b:0>3}", .{funct3});
                    },
                },
                // OP-IMM-32
                0b0011011 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented OP-IMM-32 0011011/{b:0>3}", .{funct3});
                    },
                },
                // OP-32
                0b0111011 => switch (funct3) {
                    else => if (unimplemented_is_fatal) {
                        std.log.err("unimplemented OP-32 0111011/{b:0>3}", .{funct3});
                    },
                },
                else => |opcode| if (unimplemented_is_fatal) {
                    std.log.err("unimplemented opcode {b:0>7}", .{opcode});
                },
            },
        }

        return error.UnimplementedOpcode;
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
