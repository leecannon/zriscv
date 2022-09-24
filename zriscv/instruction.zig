const std = @import("std");
const bitjuggle = @import("bitjuggle");
const tracy = @import("tracy");
const zriscv = @import("zriscv");

pub const InstructionType = enum {
    Illegal,
    Unimplemented,
    LUI,
    AUIPC,
    JAL,
    JALR,
    BEQ,
    BNE,
    BLT,
    BGE,
    BLTU,
    BGEU,
    LB,
    LH,
    LW,
    LBU,
    LHU,
    SB,
    SH,
    SW,
    ADDI,
    SLTI,
    SLTIU,
    XORI,
    ORI,
    ANDI,
    SLLI,
    SRLI,
    SRAI,
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
    FENCE,
    ECALL,
    EBREAK,
    LWU,
    LD,
    SD,
    ADDIW,
    SLLIW,
    SRLIW,
    SRAIW,
    ADDW,
    SUBW,
    SLLW,
    SRLW,
    SRAW,
    FENCE_I,
    CSRRW,
    CSRRS,
    CSRRC,
    CSRRWI,
    CSRRSI,
    CSRRCI,
    MUL,
    MULH,
    MULHSU,
    MULHU,
    DIV,
    DIVU,
    REM,
    REMU,
    MULW,
    DIVW,
    DIVUW,
    REMW,
    REMUW,
    LR_W,
    SC_W,
    AMOSWAP_W,
    AMOADD_W,
    AMOXOR_W,
    AMOAND_W,
    AMOOR_W,
    AMOMIN_W,
    AMOMAX_W,
    AMOMINU_W,
    AMOMAXU_W,
    LR_D,
    SC_D,
    AMOSWAP_D,
    AMOADD_D,
    AMOXOR_D,
    AMOAND_D,
    AMOOR_D,
    AMOMIN_D,
    AMOMAX_D,
    AMOMINU_D,
    AMOMAXU_D,
    FLW,
    FSW,
    FMADD_S,
    FMSUB_S,
    FNMSUB_S,
    FNMADD_S,
    FADD_S,
    FSUB_S,
    FMUL_S,
    FDIV_S,
    FSQRT_S,
    FSGNJ_S,
    FSGNJN_S,
    FSGNJX_S,
    FMIN_S,
    FMAX_S,
    FCVT_W_S,
    FCVT_WU_S,
    FMV_X_W,
    FEQ_S,
    FLT_S,
    FLE_S,
    FCLASS_S,
    FCVT_S_W,
    FCVT_S_WU,
    FMV_W_X,
    FCVT_L_S,
    FCVT_LU_S,
    FCVT_S_L,
    FCVT_S_LU,
    FLD,
    FSD,
    FMADD_D,
    FMSUB_D,
    FNMSUB_D,
    FNMADD_D,
    FADD_D,
    FSUB_D,
    FMUL_D,
    FDIV_D,
    FSQRT_D,
    FSGNJ_D,
    FSGNJN_D,
    FSGNJX_D,
    FMIN_D,
    FMAX_D,
    FCVT_S_D,
    FCVT_D_S,
    FEQ_D,
    FLT_D,
    FLE_D,
    FCLASS_D,
    FCVT_W_D,
    FCVT_WU_D,
    FCVT_D_W,
    FCVT_D_WU,
    FCVT_L_D,
    FCVT_LU_D,
    FMV_X_D,
    FCVT_D_L,
    FCVT_D_LU,
    FMV_D_X,
    C_ADDI4SPN,
    C_FLD,
    C_LW,
    C_LD,
    C_FSD,
    C_SW,
    C_SD,
    C_NOP,
    C_ADDI,
    C_ADDIW,
    C_LI,
    C_ADDI16SP,
    C_LUI,
    C_SRLI,
    C_SRAI,
    C_ANDI,
    C_SUB,
    C_XOR,
    C_OR,
    C_AND,
    C_SUBW,
    C_ADDW,
    C_J,
    C_BEQZ,
    C_BNEZ,
    C_SLLI,
    C_FLDSP,
    C_LWSP,
    C_LDSP,
    C_JR,
    C_MV,
    C_EBREAK,
    C_JALR,
    C_ADD,
    C_FSDSP,
    C_SWSP,
    C_SDSP,
};

pub const Instruction = extern union {
    op: bitjuggle.Bitfield(u32, 0, 2),
    opcode: bitjuggle.Bitfield(u32, 0, 7),
    non_compressed_funct3: bitjuggle.Bitfield(u32, 12, 3),
    compressed_funct3: bitjuggle.Bitfield(u32, 13, 3),
    funct2: bitjuggle.Bitfield(u32, 25, 2),
    funct7: bitjuggle.Bitfield(u32, 25, 7),
    funct7_shift: bitjuggle.Bitfield(u32, 26, 6),
    funct7_shift2: bitjuggle.Bitfield(u32, 27, 5),
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
    compressed_2_6: bitjuggle.Bitfield(u32, 2, 5),
    compressed_10_11: bitjuggle.Bitfield(u32, 10, 2),
    compressed_5_6: bitjuggle.Bitfield(u32, 5, 2),
    compressed_12: bitjuggle.Bitfield(u32, 12, 1),
    compressed_7_11: bitjuggle.Bitfield(u32, 7, 5),

    i_specialization: ISpecialization,

    compressed_backing: CompressedBacking,
    full_backing: u32,

    pub fn decode(instruction: Instruction) InstructionType {
        const z = tracy.traceNamed(@src(), "instruction decode");
        defer z.end();

        const compressed_funct3 = instruction.compressed_funct3.read();
        const funct3 = instruction.non_compressed_funct3.read();

        return switch (instruction.op.read()) {
            // compressed instruction
            0b00 => switch (compressed_funct3) {
                0b000 => if (instruction.compressed_backing.low == 0) InstructionType.Illegal else InstructionType.C_ADDI4SPN,
                0b001 => InstructionType.C_FLD,
                0b010 => InstructionType.C_LW,
                0b011 => InstructionType.C_LD,
                0b101 => InstructionType.C_FSD,
                0b110 => InstructionType.C_SW,
                0b111 => InstructionType.C_SD,
                else => InstructionType.Unimplemented,
            },
            // compressed instruction
            0b01 => switch (compressed_funct3) {
                0b000 => if (instruction._rd.read() == 0) InstructionType.C_NOP else InstructionType.C_ADDI,
                0b001 => InstructionType.C_ADDIW,
                0b010 => InstructionType.C_LI,
                0b011 => switch (instruction._rd.read()) {
                    0 => InstructionType.Unimplemented, // TODO: Should this branch be removed?
                    2 => InstructionType.C_ADDI16SP,
                    else => InstructionType.C_LUI,
                },
                0b100 => switch (instruction.compressed_10_11.read()) {
                    0b00 => InstructionType.C_SRLI,
                    0b01 => InstructionType.C_SRAI,
                    0b10 => InstructionType.C_ANDI,
                    0b11 => switch (instruction.compressed_5_6.read()) {
                        0b00 => if (instruction.compressed_12.read() == 0) InstructionType.C_SUB else InstructionType.C_SUBW,
                        0b01 => if (instruction.compressed_12.read() == 0) InstructionType.C_XOR else InstructionType.C_ADDW,
                        0b10 => if (instruction.compressed_12.read() == 0) InstructionType.C_OR else InstructionType.Unimplemented,
                        0b11 => if (instruction.compressed_12.read() == 0) InstructionType.C_AND else InstructionType.Unimplemented,
                    },
                },
                0b101 => InstructionType.C_J,
                0b110 => InstructionType.C_BEQZ,
                0b111 => InstructionType.C_BNEZ,
            },
            // compressed instruction
            0b10 => switch (compressed_funct3) {
                0b000 => InstructionType.C_SLLI,
                0b001 => InstructionType.C_FLDSP,
                0b010 => InstructionType.C_LWSP,
                0b011 => InstructionType.C_LDSP,
                0b100 => switch (instruction.compressed_12.read()) {
                    0b0 => if (instruction.compressed_2_6.read() == 0) InstructionType.C_JR else InstructionType.C_MV,
                    0b1 => if (instruction.compressed_7_11.read() == 0)
                        InstructionType.C_EBREAK
                    else if (instruction.compressed_2_6.read() == 0)
                        InstructionType.C_JALR
                    else
                        InstructionType.C_ADD,
                },
                0b101 => InstructionType.C_FSDSP,
                0b110 => InstructionType.C_SWSP,
                0b111 => InstructionType.C_SDSP,
            },
            // non-compressed instruction
            0b11 => switch (instruction.opcode.read()) {
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
                0b0100011 => switch (funct3) {
                    0b000 => InstructionType.SB,
                    0b001 => InstructionType.SH,
                    0b010 => InstructionType.SW,
                    0b011 => InstructionType.SD,
                    else => InstructionType.Unimplemented,
                },
                0b1000011 => switch (instruction.funct2.read()) {
                    0b00 => InstructionType.FMADD_S,
                    else => InstructionType.Unimplemented,
                },
                0b1100011 => switch (funct3) {
                    0b000 => InstructionType.BEQ,
                    0b001 => InstructionType.BNE,
                    0b100 => InstructionType.BLT,
                    0b101 => InstructionType.BGE,
                    0b110 => InstructionType.BLTU,
                    0b111 => InstructionType.BGEU,
                    else => InstructionType.Unimplemented,
                },
                0b0000111 => switch (funct3) {
                    0b010 => InstructionType.FLW,
                    else => InstructionType.Unimplemented,
                },
                0b0100111 => switch (funct3) {
                    0b010 => InstructionType.FSW,
                    else => InstructionType.Unimplemented,
                },
                0b1000111 => switch (instruction.funct2.read()) {
                    0b00 => InstructionType.FMSUB_S,
                    else => InstructionType.Unimplemented,
                },
                0b1100111 => switch (funct3) {
                    0b000 => InstructionType.JALR,
                    else => InstructionType.Unimplemented,
                },
                0b1001011 => switch (instruction.funct2.read()) {
                    0b00 => InstructionType.FNMSUB_S,
                    else => InstructionType.Unimplemented,
                },
                0b0001111 => switch (funct3) {
                    0b000 => InstructionType.FENCE,
                    0b001 => InstructionType.FENCE_I,
                    else => InstructionType.Unimplemented,
                },
                0b0101111 => switch (funct3) {
                    0b010 => switch (instruction.funct7_shift2.read()) {
                        0b00010 => InstructionType.LR_W,
                        0b00011 => InstructionType.SC_W,
                        0b00001 => InstructionType.AMOSWAP_W,
                        0b00000 => InstructionType.AMOADD_W,
                        0b00100 => InstructionType.AMOXOR_W,
                        0b01100 => InstructionType.AMOAND_W,
                        0b01000 => InstructionType.AMOOR_W,
                        0b10000 => InstructionType.AMOMIN_W,
                        0b10100 => InstructionType.AMOMAX_W,
                        0b11000 => InstructionType.AMOMINU_W,
                        0b11100 => InstructionType.AMOMAXU_W,
                        else => InstructionType.Unimplemented,
                    },
                    0b011 => switch (instruction.funct7_shift2.read()) {
                        0b00010 => InstructionType.LR_D,
                        0b00011 => InstructionType.SC_D,
                        0b00001 => InstructionType.AMOSWAP_D,
                        0b00000 => InstructionType.AMOADD_D,
                        0b00100 => InstructionType.AMOXOR_D,
                        0b01100 => InstructionType.AMOAND_D,
                        0b01000 => InstructionType.AMOOR_D,
                        0b10000 => InstructionType.AMOMIN_D,
                        0b10100 => InstructionType.AMOMAX_D,
                        0b11000 => InstructionType.AMOMINU_D,
                        0b11100 => InstructionType.AMOMAXU_D,
                        else => InstructionType.Unimplemented,
                    },
                    else => InstructionType.Unimplemented,
                },
                0b1001111 => switch (instruction.funct2.read()) {
                    0b000 => InstructionType.FNMADD_S,
                    else => InstructionType.Unimplemented,
                },
                0b1101111 => InstructionType.JAL,
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
                0b0110011 => switch (funct3) {
                    0b000 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.ADD,
                        0b0100000 => InstructionType.SUB,
                        0b0000001 => InstructionType.MUL,
                        else => InstructionType.Unimplemented,
                    },
                    0b001 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.SLL,
                        0b0000001 => InstructionType.MULH,
                        else => InstructionType.Unimplemented,
                    },
                    0b010 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.SLT,
                        0b0000001 => InstructionType.MULHSU,
                        else => InstructionType.Unimplemented,
                    },
                    0b011 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.SLTU,
                        0b0000001 => InstructionType.MULHU,
                        else => InstructionType.Unimplemented,
                    },
                    0b100 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.XOR,
                        0b0000001 => InstructionType.DIV,
                        else => InstructionType.Unimplemented,
                    },
                    0b101 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.SRL,
                        0b0100000 => InstructionType.SRA,
                        0b0000001 => InstructionType.DIVU,
                        else => InstructionType.Unimplemented,
                    },
                    0b110 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.OR,
                        0b0000001 => InstructionType.REM,
                        else => InstructionType.Unimplemented,
                    },
                    0b111 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.AND,
                        0b0000001 => InstructionType.REMU,
                        else => InstructionType.Unimplemented,
                    },
                },
                0b1010011 => switch (instruction.funct7.read()) {
                    0b0000000 => InstructionType.FADD_S,
                    0b0000001 => InstructionType.FADD_D,
                    0b0000100 => InstructionType.FSUB_S,
                    0b0000101 => InstructionType.FSUB_D,
                    0b0001000 => InstructionType.FMUL_S,
                    0b0001001 => InstructionType.FMUL_D,
                    0b0001100 => InstructionType.FDIV_S,
                    0b0001101 => InstructionType.FDIV_D,
                    0b0101100 => InstructionType.FSQRT_S,
                    0b0101101 => InstructionType.FSQRT_D,
                    0b0010000 => switch (instruction.non_compressed_funct3.read()) {
                        0b000 => InstructionType.FSGNJ_S,
                        0b001 => InstructionType.FSGNJN_S,
                        0b010 => InstructionType.FSGNJX_S,
                        else => InstructionType.Unimplemented,
                    },
                    0b0010001 => switch (instruction.non_compressed_funct3.read()) {
                        0b000 => InstructionType.FSGNJ_D,
                        0b001 => InstructionType.FSGNJN_D,
                        0b010 => InstructionType.FSGNJX_D,
                        else => InstructionType.Unimplemented,
                    },
                    0b0010100 => switch (instruction.non_compressed_funct3.read()) {
                        0b000 => InstructionType.FMIN_S,
                        0b001 => InstructionType.FMAX_S,
                        else => InstructionType.Unimplemented,
                    },
                    0b0010101 => switch (instruction.non_compressed_funct3.read()) {
                        0b000 => InstructionType.FMIN_D,
                        0b001 => InstructionType.FMAX_D,
                        else => InstructionType.Unimplemented,
                    },
                    0b1100000 => switch (instruction._rs2.read()) {
                        0b00000 => InstructionType.FCVT_W_S,
                        0b00001 => InstructionType.FCVT_WU_S,
                        0b00010 => InstructionType.FCVT_L_S,
                        0b00011 => InstructionType.FCVT_LU_S,
                        else => InstructionType.Unimplemented,
                    },
                    0b1100001 => switch (instruction._rs2.read()) {
                        0b00000 => InstructionType.FCVT_W_D,
                        0b00001 => InstructionType.FCVT_WU_D,
                        0b00010 => InstructionType.FCVT_L_D,
                        0b00011 => InstructionType.FCVT_LU_D,
                        else => InstructionType.Unimplemented,
                    },
                    0b1110000 => switch (instruction.non_compressed_funct3.read()) {
                        0b000 => InstructionType.FMV_X_W,
                        0b001 => InstructionType.FCLASS_S,
                        else => InstructionType.Unimplemented,
                    },
                    0b1110001 => switch (instruction.non_compressed_funct3.read()) {
                        0b000 => InstructionType.FMV_X_D,
                        0b001 => InstructionType.FCLASS_D,
                        else => InstructionType.Unimplemented,
                    },
                    0b1010000 => switch (instruction.non_compressed_funct3.read()) {
                        0b010 => InstructionType.FEQ_S,
                        0b001 => InstructionType.FLT_S,
                        0b000 => InstructionType.FLE_S,
                        else => InstructionType.Unimplemented,
                    },
                    0b1010001 => switch (instruction.non_compressed_funct3.read()) {
                        0b010 => InstructionType.FEQ_D,
                        0b001 => InstructionType.FLT_D,
                        0b000 => InstructionType.FLE_D,
                        else => InstructionType.Unimplemented,
                    },
                    0b0100000 => switch (instruction._rs2.read()) {
                        0b00001 => InstructionType.FCVT_S_D,
                        else => InstructionType.Unimplemented,
                    },
                    0b0100001 => switch (instruction._rs2.read()) {
                        0b00000 => InstructionType.FCVT_D_S,
                        else => InstructionType.Unimplemented,
                    },
                    0b1101000 => switch (instruction._rs2.read()) {
                        0b00000 => InstructionType.FCVT_S_W,
                        0b00001 => InstructionType.FCVT_S_WU,
                        0b00010 => InstructionType.FCVT_S_L,
                        0b00011 => InstructionType.FCVT_S_LU,
                        else => InstructionType.Unimplemented,
                    },
                    0b1101001 => switch (instruction._rs2.read()) {
                        0b00000 => InstructionType.FCVT_D_W,
                        0b00001 => InstructionType.FCVT_D_WU,
                        0b00010 => InstructionType.FCVT_D_L,
                        0b00011 => InstructionType.FCVT_D_LU,
                        else => InstructionType.Unimplemented,
                    },
                    0b1111000 => switch (instruction._rs2.read()) {
                        0b00000 => InstructionType.FMV_W_X,
                        else => InstructionType.Unimplemented,
                    },
                    0b1111001 => switch (instruction._rs2.read()) {
                        0b00000 => InstructionType.FMV_D_X,
                        else => InstructionType.Unimplemented,
                    },
                    else => InstructionType.Unimplemented,
                },
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
                0b0010111 => InstructionType.AUIPC,
                0b0110111 => InstructionType.LUI,
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
                0b0111011 => switch (funct3) {
                    0b000 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.ADDW,
                        0b0100000 => InstructionType.SUBW,
                        0b0000001 => InstructionType.MULW,
                        else => InstructionType.Unimplemented,
                    },
                    0b001 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.SLLW,
                        else => InstructionType.Unimplemented,
                    },
                    0b100 => switch (instruction.funct7.read()) {
                        0b0000001 => InstructionType.DIVW,
                        else => InstructionType.Unimplemented,
                    },
                    0b101 => switch (instruction.funct7.read()) {
                        0b0000000 => InstructionType.SRLW,
                        0b0100000 => InstructionType.SRAW,
                        0b0000001 => InstructionType.DIVUW,
                        else => InstructionType.Unimplemented,
                    },
                    0b110 => switch (instruction.funct7.read()) {
                        0b0000001 => InstructionType.REMW,
                        else => InstructionType.Unimplemented,
                    },
                    0b111 => switch (instruction.funct7.read()) {
                        0b0000001 => InstructionType.REMUW,
                        else => InstructionType.Unimplemented,
                    },
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

    pub inline fn rd(self: Instruction) zriscv.IntegerRegister {
        return zriscv.IntegerRegister.getIntegerRegister(self._rd.read());
    }

    pub inline fn rs1(self: Instruction) zriscv.IntegerRegister {
        return zriscv.IntegerRegister.getIntegerRegister(self._rs1.read());
    }

    pub inline fn rs2(self: Instruction) zriscv.IntegerRegister {
        return zriscv.IntegerRegister.getIntegerRegister(self._rs2.read());
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
