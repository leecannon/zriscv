const std = @import("std");
const lib = @import("lib.zig");
const build_options = @import("build_options");

pub const ExecutionOptions = struct {
    unrecognised_instruction_is_fatal: bool = true,
    illegal_instruction_is_fatal: bool = true,
    unrecognised_csr_is_fatal: bool = true,
    ebreak_is_fatal: bool = false,
    execution_out_of_bounds_is_fatal: bool = true,

    /// this option is only taken into account if a writer is given
    always_print_pc: bool = true,
};

/// Execute a single instruction
///
/// Note: `writer` may be void (`{}`) in order to suppress output
pub fn step(
    comptime mode: lib.Mode,
    hart: *lib.Hart(mode),
    writer: anytype,
    riscof_mode: bool,
    comptime options: ExecutionOptions,
    comptime actually_execute: bool,
) !bool {
    const execute_z = lib.traceNamed(@src(), "execute step");
    defer execute_z.end();

    const has_writer = comptime isWriter(@TypeOf(writer));

    const instruction: lib.Instruction = blk: {
        const z = lib.traceNamed(@src(), "instruction read");
        defer z.end();

        break :blk .{
            // try to load 32-bit instruction
            .full_backing = hart.loadMemory(32, hart.pc) catch |err| switch (err) {
                // try to load 16-bit compressed instruction
                error.ExecutionOutOfBounds => {
                    break :blk .{
                        .compressed_backing = .{
                            .low = hart.loadMemory(16, hart.pc) catch |compressed_err| {
                                if (options.execution_out_of_bounds_is_fatal) return error.ExecutionOutOfBounds;

                                switch (compressed_err) {
                                    // TODO: Pass `InstructionAccessFault` once `throw` is implemented
                                    error.ExecutionOutOfBounds => {
                                        try throw(mode, hart, {}, 0, writer, actually_execute);
                                        return true;
                                    },
                                    else => |e| return e,
                                }
                            },
                        },
                    };
                },
                else => |e| return e,
            },
        };
    };

    if (has_writer and options.always_print_pc) {
        try writer.print("pc: {x:0>16}\n", .{hart.pc});
    }

    return try execute(mode, hart, instruction, writer, riscof_mode, options, actually_execute);
}

fn execute(
    comptime mode: lib.Mode,
    hart: *lib.Hart(mode),
    instruction: lib.Instruction,
    writer: anytype,
    riscof_mode: bool,
    comptime options: ExecutionOptions,
    comptime actually_execute: bool,
) !bool {
    const execute_z = lib.traceNamed(@src(), "execute");
    defer execute_z.end();

    defer if (actually_execute) {
        hart.cycle += 1;
    };

    const has_writer = comptime isWriter(@TypeOf(writer));

    switch (instruction.decode()) {
        .Unimplemented => {
            if (options.unrecognised_instruction_is_fatal) {
                instruction.printUnimplementedInstruction();
                return error.UnimplementedInstruction;
            }

            // TODO: Pass `IllegalInstruction` once `throw` is implemented
            try throw(mode, hart, {}, instruction.full_backing, writer, actually_execute);
        },
        .Illegal => {
            if (options.illegal_instruction_is_fatal) return error.IllegalInstruction;

            // TODO: Pass `IllegalInstruction` once `throw` is implemented
            try throw(mode, hart, {}, instruction.full_backing, writer, actually_execute);
        },
        .LUI => {
            const z = lib.traceNamed(@src(), "LUI");
            defer z.end();

            // U-type
            const rd = instruction.rd();

            if (rd != .zero) {
                const imm = instruction.u_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\LUI - dest: {}, value: {}
                        \\  setting {} to {}
                        \\
                    , .{
                        rd,
                        imm,
                        rd,
                        imm,
                    });
                }

                if (actually_execute) {
                    hart.x[@enumToInt(rd)] = @bitCast(u64, imm);
                }
            } else {
                if (has_writer) {
                    const imm = instruction.u_imm.read();

                    try writer.print(
                        \\LUI - dest: {}, value: {}
                        \\  nop
                        \\
                    , .{
                        rd,
                        imm,
                    });
                }
            }

            if (actually_execute) {
                hart.pc += 4;
            }
        },
        .AUIPC => {
            const z = lib.traceNamed(@src(), "AUIPC");
            defer z.end();

            // U-type
            const rd = instruction.rd();

            if (rd != .zero) {
                const imm = instruction.u_imm.read();
                const result = addSignedToUnsignedWrap(hart.pc, imm);

                if (has_writer) {
                    try writer.print(
                        \\AUIPC - dest: {}, offset: 0x{x}
                        \\  setting {} to  ( pc<0x{x}> + 0x{x} ) = 0x{x}
                        \\
                    , .{
                        rd,
                        imm,
                        rd,
                        hart.pc,
                        imm,
                        result,
                    });
                }

                if (actually_execute) {
                    hart.x[@enumToInt(rd)] = result;
                }
            } else {
                if (has_writer) {
                    const imm = instruction.u_imm.read();

                    try writer.print(
                        \\AUIPC - dest: {}, offset: 0x{x}
                        \\  nop
                        \\
                    , .{
                        rd,
                        imm,
                    });
                }
            }

            if (actually_execute) {
                hart.pc += 4;
            }
        },
        .JAL => {
            const z = lib.traceNamed(@src(), "JAL");
            defer z.end();

            // J-type

            const rd = instruction.rd();
            const imm = instruction.j_imm.read();

            const target_address = addSignedToUnsignedWrap(hart.pc, imm);

            if (rd != .zero) {
                const return_address = hart.pc + 4;

                if (has_writer) {
                    try writer.print(
                        \\JAL - dest: {}, offset: 0x{x}
                        \\  setting {} to ( pc<0x{x}> + 0x4 ) = 0x{x}
                        \\  setting pc ( pc<0x{x}> + 0x{x} ) = 0x{x}
                        \\
                    , .{
                        rd,
                        imm,
                        rd,
                        hart.pc,
                        return_address,
                        hart.pc,
                        imm,
                        target_address,
                    });
                }

                if (actually_execute) {
                    hart.x[@enumToInt(rd)] = return_address;
                }
            } else {
                if (has_writer) {
                    try writer.print(
                        \\JAL - dest: {}, offset: 0x{x}
                        \\  setting pc to ( pc<0x{x}> + 0x{x} ) = 0x{x}
                        \\
                    , .{
                        rd,
                        imm,
                        hart.pc,
                        imm,
                        target_address,
                    });
                }
            }

            if (actually_execute) {
                hart.pc = target_address;
            }
        },
        .JALR => {
            const z = lib.traceNamed(@src(), "JALR");
            defer z.end();

            // I-type
            const imm = instruction.i_imm.read();
            const rs1 = instruction.rs1();
            const rs1_value = hart.x[@enumToInt(rs1)];
            const rd = instruction.rd();

            const target_address = addSignedToUnsignedWrap(rs1_value, imm) & ~@as(u64, 1);

            if (rd != .zero) {
                const return_address = hart.pc + 4;

                if (has_writer) {
                    try writer.print(
                        \\JALR - dest: {}, base: {}, offset: 0x{x}
                        \\  setting {} to ( pc<0x{x}> + 0x4 ) = 0x{x}
                        \\  setting pc to ( {}<0x{x}> + 0x{x} ) & ~1 = 0x{x}
                        \\
                    , .{
                        rd,
                        rs1,
                        imm,
                        rd,
                        hart.pc,
                        return_address,
                        rs1,
                        rs1_value,
                        imm,
                        target_address,
                    });
                }

                if (actually_execute) {
                    hart.x[@enumToInt(rd)] = return_address;
                }
            } else {
                if (has_writer) {
                    try writer.print(
                        \\JALR - dest: {}, base: {}, offset: 0x{x}
                        \\  setting pc to ( {}<0x{x}> + 0x{x} ) & ~1 = 0x{x}
                        \\
                    , .{
                        rd,
                        rs1,
                        imm,
                        rs1,
                        rs1_value,
                        imm,
                        target_address,
                    });
                }
            }

            if (actually_execute) {
                hart.pc = target_address;
            }
        },
        .BEQ => @panic("unimplemented instruction execution for BEQ"), // TODO: BEQ
        .BNE => {
            const z = lib.traceNamed(@src(), "BNE");
            defer z.end();

            // B-type
            const rs1 = instruction.rs1();
            const rs1_value = hart.x[@enumToInt(rs1)];

            const rs2 = instruction.rs2();
            const rs2_value = hart.x[@enumToInt(rs2)];

            const imm = instruction.b_imm.read();
            const result = addSignedToUnsignedWrap(hart.pc, imm);

            if (rs1_value != rs2_value) {
                if (has_writer) {
                    try writer.print(
                        \\BNE - src1: {}<{}>, src2: {}<{}>, offset: 0x{x}
                        \\  true
                        \\  setting pc to current ( pc<0x{x}> + 0x{x} ) = 0x{x}
                        \\
                    , .{
                        rs1,
                        rs1_value,
                        rs2,
                        rs2_value,
                        imm,
                        hart.pc,
                        imm,
                        result,
                    });
                }

                if (actually_execute) {
                    hart.pc = result;
                }
            } else {
                if (has_writer) {
                    try writer.print(
                        \\BNE - src1: {}<{}>, src2: {}<{}>, offset: 0x{x}
                        \\  false
                        \\
                    , .{
                        rs1,
                        rs1_value,
                        rs2,
                        rs1_value,
                        imm,
                    });
                }

                if (actually_execute) {
                    hart.pc += 4;
                }
            }
        },
        .BLT => @panic("unimplemented instruction execution for BLT"), // TODO: BLT
        .BGE => @panic("unimplemented instruction execution for BGE"), // TODO: BGE
        .BLTU => @panic("unimplemented instruction execution for BLTU"), // TODO: BLTU
        .BGEU => @panic("unimplemented instruction execution for BGEU"), // TODO: BGEU
        .LB => @panic("unimplemented instruction execution for LB"), // TODO: LB
        .LH => @panic("unimplemented instruction execution for LH"), // TODO: LH
        .LW => @panic("unimplemented instruction execution for LW"), // TODO: LW
        .LBU => @panic("unimplemented instruction execution for LBU"), // TODO: LBU
        .LHU => @panic("unimplemented instruction execution for LHU"), // TODO: LHU
        .SB => @panic("unimplemented instruction execution for SB"), // TODO: SB
        .SH => @panic("unimplemented instruction execution for SH"), // TODO: SH
        .SW => {
            const z = lib.traceNamed(@src(), "SW");
            defer z.end();

            // S-Type
            const rs1 = instruction.rs1();
            const rs1_value = hart.x[@enumToInt(rs1)];
            const rs2 = instruction.rs2();
            const rs2_value = hart.x[@enumToInt(rs2)];
            const imm = instruction.s_imm.read();

            const address = addSignedToUnsignedWrap(rs1_value, imm);

            if (has_writer) {
                try writer.print(
                    \\SW - base: {}, src: {}, imm: 0x{x}
                    \\  store 4 bytes from {}<{}> into memory ( {}<0x{x}> + 0x{x} ) = 0x{x}
                    \\
                , .{
                    rs1,
                    rs2,
                    imm,
                    rs2,
                    rs2_value,
                    rs1,
                    rs1_value,
                    imm,
                    address,
                });
            }

            if (actually_execute) {
                // TODO: Should this be made comptime?
                if (riscof_mode) {
                    // Check if the memory being written to is the 'tohost' symbol
                    if (hart.machine.executable.tohost == address) {
                        return false;
                    }
                }

                if (options.execution_out_of_bounds_is_fatal) {
                    try hart.storeMemory(32, address, @truncate(u32, rs2_value));
                } else {
                    hart.storeMemory(32, address, @truncate(u32, rs2_value)) catch |err| switch (err) {
                        error.ExecutionOutOfBounds => {
                            // TODO: Pass `.@"Store/AMOAccessFault"` once `throw` is implemented
                            try throw(mode, hart, {}, 0, writer, true);
                            return true;
                        },
                        else => |e| return e,
                    };
                }

                hart.pc += 4;
            }
        },
        .ADDI => {
            const z = lib.traceNamed(@src(), "ADDI");
            defer z.end();

            // I-Type
            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                const rs1_value = hart.x[@enumToInt(rs1)];

                const result = addSignedToUnsignedIgnoreOverflow(rs1_value, imm);

                if (has_writer) {
                    try writer.print(
                        \\ADDI - src: {}, dest: {}, imm: {}
                        \\  set {} to ( {}<{}> + {} ) = {}
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        rs1_value,
                        imm,
                        result,
                    });
                }

                if (actually_execute) {
                    hart.x[@enumToInt(rd)] = result;
                }
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\ADDI - src: {}, dest: {}, imm: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                    });
                }
            }

            if (actually_execute) {
                hart.pc += 4;
            }
        },
        .SLTI => @panic("unimplemented instruction execution for SLTI"), // TODO: SLTI
        .SLTIU => @panic("unimplemented instruction execution for SLTIU"), // TODO: SLTIU
        .XORI => @panic("unimplemented instruction execution for XORI"), // TODO: XORI
        .ORI => @panic("unimplemented instruction execution for ORI"), // TODO: ORI
        .ANDI => @panic("unimplemented instruction execution for ANDI"), // TODO: ANDI
        .SLLI => {
            const z = lib.traceNamed(@src(), "SLLI");
            defer z.end();

            // I-type specialization
            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = hart.x[@enumToInt(rs1)];
                const shmt = instruction.i_specialization.fullShift();

                const result = rs1_value << shmt;

                if (has_writer) {
                    try writer.print(
                        \\SLLI - src: {}, dest: {}, shmt: {}
                        \\  set {} to ( {}<{}> << {} ) = {}
                        \\
                    , .{
                        rs1,
                        rd,
                        shmt,
                        rd,
                        rs1,
                        rs1_value,
                        shmt,
                        result,
                    });
                }

                if (actually_execute) {
                    hart.x[@enumToInt(rd)] = result;
                }
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const shmt = instruction.i_specialization.fullShift();

                    try writer.print(
                        \\SLLI - src: {}, dest: {}, shmt: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        shmt,
                    });
                }
            }

            if (actually_execute) {
                hart.pc += 4;
            }
        },
        .SRLI => @panic("unimplemented instruction execution for SRLI"), // TODO: SRLI
        .SRAI => @panic("unimplemented instruction execution for SRAI"), // TODO: SRAI
        .ADD => {
            const z = lib.traceNamed(@src(), "ADD");
            defer z.end();

            // R-Type
            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                const rs1_value = hart.x[@enumToInt(rs1)];
                const rs2_value = hart.x[@enumToInt(rs2)];

                var result: u64 = undefined;
                _ = @addWithOverflow(u64, rs1_value, rs2_value, &result);

                if (has_writer) {
                    try writer.print(
                        \\ADD - src1: {}, src2: {}, dest: {}
                        \\  set {} to ( {}<{}> + {}<{}> ) = {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs1_value,
                        rs2,
                        rs2_value,
                        result,
                    });
                }

                if (actually_execute) {
                    hart.x[@enumToInt(rd)] = result;
                }
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\ADD - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }
            if (actually_execute) {
                hart.pc += 4;
            }
        },
        .SUB => @panic("unimplemented instruction execution for SUB"), // TODO: SUB
        .SLL => @panic("unimplemented instruction execution for SLL"), // TODO: SLL
        .SLT => @panic("unimplemented instruction execution for SLT"), // TODO: SLT
        .SLTU => @panic("unimplemented instruction execution for SLTU"), // TODO: SLTU
        .XOR => @panic("unimplemented instruction execution for XOR"), // TODO: XOR
        .SRL => @panic("unimplemented instruction execution for SRL"), // TODO: SRL
        .SRA => @panic("unimplemented instruction execution for SRA"), // TODO: SRA
        .OR => @panic("unimplemented instruction execution for OR"), // TODO: OR
        .AND => @panic("unimplemented instruction execution for AND"), // TODO: AND
        .FENCE => @panic("unimplemented instruction execution for FENCE"), // TODO: FENCE
        .ECALL => @panic("unimplemented instruction execution for ECALL"), // TODO: ECALL
        .EBREAK => @panic("unimplemented instruction execution for EBREAK"), // TODO: EBREAK
        .LWU => @panic("unimplemented instruction execution for LWU"), // TODO: LWU
        .LD => {
            const z = lib.traceNamed(@src(), "LD");
            defer z.end();

            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = hart.x[@enumToInt(rs1)];
                const imm = instruction.i_imm.read();

                const address = addSignedToUnsignedWrap(rs1_value, imm);

                if (has_writer) {
                    try writer.print(
                        \\LD - base: {}, dest: {}, imm: 0x{x}
                        \\  load 8 bytes into {} from memory ( {}<0x{x}> + 0x{x} ) = 0x{x}
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        rs1_value,
                        imm,
                        address,
                    });
                }

                if (actually_execute) {
                    const memory = if (options.execution_out_of_bounds_is_fatal)
                        try hart.loadMemory(64, address)
                    else blk: {
                        break :blk hart.loadMemory(64, address) catch |err| switch (err) {
                            error.ExecutionOutOfBounds => {
                                // TODO: Pass `.LoadAccessFault` once `throw` is implemented
                                try throw(mode, hart, {}, 0, writer, true);
                                return true;
                            },
                            else => |e| return e,
                        };
                    };

                    hart.x[@enumToInt(rd)] = memory;
                }
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\LD - base: {}, dest: {}, imm: 0x{x}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                    });
                }
            }

            if (actually_execute) {
                hart.pc += 4;
            }
        },
        .SD => {
            const z = lib.traceNamed(@src(), "SD");
            defer z.end();

            // S-Type
            const rs1 = instruction.rs1();
            const rs1_value = hart.x[@enumToInt(rs1)];
            const rs2 = instruction.rs2();
            const rs2_value = hart.x[@enumToInt(rs2)];
            const imm = instruction.s_imm.read();

            const address = addSignedToUnsignedWrap(rs1_value, imm);

            if (has_writer) {
                try writer.print(
                    \\SD - base: {}, src: {}, imm: 0x{x}
                    \\  store 8 bytes from {}<{}> into memory ( {}<0x{x}> + 0x{x} ) = 0x{x}
                    \\
                , .{
                    rs1,
                    rs2,
                    imm,
                    rs2,
                    rs2_value,
                    rs1,
                    rs1_value,
                    imm,
                    address,
                });
            }

            if (actually_execute) {
                if (options.execution_out_of_bounds_is_fatal) {
                    try hart.storeMemory(64, address, rs2_value);
                } else {
                    hart.storeMemory(64, address, rs2_value) catch |err| switch (err) {
                        error.ExecutionOutOfBounds => {
                            // TODO: Pass `.@"Store/AMOAccessFault"` once `throw` is implemented
                            try throw(mode, hart, {}, 0, writer, true);
                            return true;
                        },
                        else => |e| return e,
                    };
                }

                hart.pc += 4;
            }
        },
        .ADDIW => {
            const z = lib.traceNamed(@src(), "ADDIW");
            defer z.end();

            // I-type
            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = hart.x[@enumToInt(rs1)];
                const imm = instruction.i_imm.read();

                const result = signExtend32bit(addSignedToUnsignedIgnoreOverflow(rs1_value, imm) & 0xFFFFFFFF);

                if (has_writer) {
                    try writer.print(
                        \\ADDIW - src: {}, dest: {}, imm: {}
                        \\  set {} to 32bit( {}<{}> + {} ) = {}
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        rs1_value,
                        imm,
                        result,
                    });
                }

                if (actually_execute) {
                    hart.x[@enumToInt(rd)] = result;
                }
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\ADDIW - src: {}, dest: {}, imm: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                    });
                }
            }

            if (actually_execute) {
                hart.pc += 4;
            }
        },
        .SLLIW => @panic("unimplemented instruction execution for SLLIW"), // TODO: SLLIW
        .SRLIW => @panic("unimplemented instruction execution for SRLIW"), // TODO: SRLIW
        .SRAIW => @panic("unimplemented instruction execution for SRAIW"), // TODO: SRAIW
        .ADDW => {
            const z = lib.traceNamed(@src(), "ADDIW");
            defer z.end();

            // R-type
            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value_truncated = @truncate(u32, hart.x[@enumToInt(rs1)]);
                const rs2 = instruction.rs2();
                const rs2_value_truncated = @truncate(u32, hart.x[@enumToInt(rs2)]);

                var result: u32 = undefined;
                _ = @addWithOverflow(u32, rs1_value_truncated, rs2_value_truncated, &result);

                if (has_writer) {
                    try writer.print(
                        \\ADDW - src1: {}, src2: {}, dest: {}
                        \\  set {} to 32bit( {}<{}> ) + 32bit( {}<{}> ) = {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs1_value_truncated,
                        rs2,
                        rs2_value_truncated,
                        result,
                    });
                }

                if (actually_execute) {
                    hart.x[@enumToInt(rd)] = signExtend32bit(result);
                }
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\ADDW - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            if (actually_execute) {
                hart.pc += 4;
            }
        },
        .SUBW => @panic("unimplemented instruction execution for SUBW"), // TODO: SUBW
        .SLLW => @panic("unimplemented instruction execution for SLLW"), // TODO: SLLW
        .SRLW => @panic("unimplemented instruction execution for SRLW"), // TODO: SRLW
        .SRAW => @panic("unimplemented instruction execution for SRAW"), // TODO: SRAW
        .FENCE_I => @panic("unimplemented instruction execution for FENCE_I"), // TODO: FENCE_I
        .CSRRW => {
            const z = lib.traceNamed(@src(), "CSRRW");
            defer z.end();

            // I-type

            const csr: lib.Csr = if (options.unrecognised_csr_is_fatal)
                try lib.Csr.getCsr(instruction.csr.read())
            else
                lib.Csr.getCsr(instruction.csr.read()) catch {
                    // TODO: Pass `IllegalInstruction` once `throw` is implemented
                    try throw(mode, hart, {}, instruction.full_backing, writer, actually_execute);
                    return true;
                };

            const rd = instruction.rd();
            const rs1 = instruction.rs1();
            const rs1_value = hart.x[@enumToInt(rs1)];

            if (rd != .zero) {
                if (has_writer) {
                    try writer.print(
                        \\CSRRW - csr: {}, dest: {}, source: {}
                        \\  read csr {} into {}
                        \\  set csr {} to {}<{}>
                        \\
                    , .{
                        csr,
                        rd,
                        rs1,
                        csr,
                        rd,
                        csr,
                        rs1,
                        rs1_value,
                    });
                }

                if (!csr.canWrite(hart.privilege_level)) {
                    // TODO: Pass `IllegalInstruction` once `throw` is implemented
                    try throw(mode, hart, {}, instruction.full_backing, writer, actually_execute);
                    return true;
                }

                const initial_csr = readCsr(mode, hart, csr);
                try writeCsr(mode, hart, csr, rs1_value);
                hart.x[@enumToInt(rd)] = initial_csr;
            } else {
                if (has_writer) {
                    try writer.print(
                        \\CSRRW - csr: {}, dest: {}, source: {}
                        \\  set csr {} to {}<{}>
                        \\
                    , .{
                        csr,
                        rd,
                        rs1,
                        csr,
                        rs1,
                        rs1_value,
                    });
                }

                if (!csr.canWrite(hart.privilege_level)) {
                    // TODO: Pass `IllegalInstruction` once `throw` is implemented
                    try throw(mode, hart, {}, instruction.full_backing, writer, actually_execute);
                    return true;
                }

                try writeCsr(mode, hart, csr, rs1_value);
            }

            hart.pc += 4;
        },
        .CSRRS => @panic("unimplemented instruction execution for CSRRS"), // TODO: CSRRS
        .CSRRC => @panic("unimplemented instruction execution for CSRRC"), // TODO: CSRRC
        .CSRRWI => @panic("unimplemented instruction execution for CSRRWI"), // TODO: CSRRWI
        .CSRRSI => @panic("unimplemented instruction execution for CSRRSI"), // TODO: CSRRSI
        .CSRRCI => @panic("unimplemented instruction execution for CSRRCI"), // TODO: CSRRCI
        .MUL => @panic("unimplemented instruction execution for MUL"), // TODO: MUL
        .MULH => @panic("unimplemented instruction execution for MULH"), // TODO: MULH
        .MULHSU => @panic("unimplemented instruction execution for MULHSU"), // TODO: MULHSU
        .MULHU => @panic("unimplemented instruction execution for MULHU"), // TODO: MULHU
        .DIV => @panic("unimplemented instruction execution for DIV"), // TODO: DIV
        .DIVU => @panic("unimplemented instruction execution for DIVU"), // TODO: DIVU
        .REM => @panic("unimplemented instruction execution for REM"), // TODO: REM
        .REMU => @panic("unimplemented instruction execution for REMU"), // TODO: REMU
        .MULW => @panic("unimplemented instruction execution for MULW"), // TODO: MULW
        .DIVW => @panic("unimplemented instruction execution for DIVW"), // TODO: DIVW
        .DIVUW => @panic("unimplemented instruction execution for DIVUW"), // TODO: DIVUW
        .REMW => @panic("unimplemented instruction execution for REMW"), // TODO: REMW
        .REMUW => @panic("unimplemented instruction execution for REMUW"), // TODO: REMUW
        .LR_W => @panic("unimplemented instruction execution for LR_W"), // TODO: LR_W
        .SC_W => @panic("unimplemented instruction execution for SC_W"), // TODO: SC_W
        .AMOSWAP_W => @panic("unimplemented instruction execution for AMOSWAP_W"), // TODO: AMOSWAP_W
        .AMOADD_W => @panic("unimplemented instruction execution for AMOADD_W"), // TODO: AMOADD_W
        .AMOXOR_W => @panic("unimplemented instruction execution for AMOXOR_W"), // TODO: AMOXOR_W
        .AMOAND_W => @panic("unimplemented instruction execution for AMOAND_W"), // TODO: AMOAND_W
        .AMOOR_W => @panic("unimplemented instruction execution for AMOOR_W"), // TODO: AMOOR_W
        .AMOMIN_W => @panic("unimplemented instruction execution for AMOMIN_W"), // TODO: AMOMIN_W
        .AMOMAX_W => @panic("unimplemented instruction execution for AMOMAX_W"), // TODO: AMOMAX_W
        .AMOMINU_W => @panic("unimplemented instruction execution for AMOMINU_W"), // TODO: AMOMINU_W
        .AMOMAXU_W => @panic("unimplemented instruction execution for AMOMAXU_W"), // TODO: AMOMAXU_W
        .LR_D => @panic("unimplemented instruction execution for LR_D"), // TODO: LR_D
        .SC_D => @panic("unimplemented instruction execution for SC_D"), // TODO: SC_D
        .AMOSWAP_D => @panic("unimplemented instruction execution for AMOSWAP_D"), // TODO: AMOSWAP_D
        .AMOADD_D => @panic("unimplemented instruction execution for AMOADD_D"), // TODO: AMOADD_D
        .AMOXOR_D => @panic("unimplemented instruction execution for AMOXOR_D"), // TODO: AMOXOR_D
        .AMOAND_D => @panic("unimplemented instruction execution for AMOAND_D"), // TODO: AMOAND_D
        .AMOOR_D => @panic("unimplemented instruction execution for AMOOR_D"), // TODO: AMOOR_D
        .AMOMIN_D => @panic("unimplemented instruction execution for AMOMIN_D"), // TODO: AMOMIN_D
        .AMOMAX_D => @panic("unimplemented instruction execution for AMOMAX_D"), // TODO: AMOMAX_D
        .AMOMINU_D => @panic("unimplemented instruction execution for AMOMINU_D"), // TODO: AMOMINU_D
        .AMOMAXU_D => @panic("unimplemented instruction execution for AMOMAXU_D"), // TODO: AMOMAXU_D
        .FLW => @panic("unimplemented instruction execution for FLW"), // TODO: FLW
        .FSW => @panic("unimplemented instruction execution for FSW"), // TODO: FSW
        .FMADD_S => @panic("unimplemented instruction execution for FMADD_S"), // TODO: FMADD_S
        .FMSUB_S => @panic("unimplemented instruction execution for FMSUB_S"), // TODO: FMSUB_S
        .FNMSUB_S => @panic("unimplemented instruction execution for FNMSUB_S"), // TODO: FNMSUB_S
        .FNMADD_S => @panic("unimplemented instruction execution for FNMADD_S"), // TODO: FNMADD_S
        .FADD_S => @panic("unimplemented instruction execution for FADD_S"), // TODO: FADD_S
        .FSUB_S => @panic("unimplemented instruction execution for FSUB_S"), // TODO: FSUB_S
        .FMUL_S => @panic("unimplemented instruction execution for FMUL_S"), // TODO: FMUL_S
        .FDIV_S => @panic("unimplemented instruction execution for FDIV_S"), // TODO: FDIV_S
        .FSQRT_S => @panic("unimplemented instruction execution for FSQRT_S"), // TODO: FSQRT_S
        .FSGNJ_S => @panic("unimplemented instruction execution for FSGNJ_S"), // TODO: FSGNJ_S
        .FSGNJN_S => @panic("unimplemented instruction execution for FSGNJN_S"), // TODO: FSGNJN_S
        .FSGNJX_S => @panic("unimplemented instruction execution for FSGNJX_S"), // TODO: FSGNJX_S
        .FMIN_S => @panic("unimplemented instruction execution for FMIN_S"), // TODO: FMIN_S
        .FMAX_S => @panic("unimplemented instruction execution for FMAX_S"), // TODO: FMAX_S
        .FCVT_W_S => @panic("unimplemented instruction execution for FCVT_W_S"), // TODO: FCVT_W_S
        .FCVT_WU_S => @panic("unimplemented instruction execution for FCVT_WU_S"), // TODO: FCVT_WU_S
        .FMV_X_W => @panic("unimplemented instruction execution for FMV_X_W"), // TODO: FMV_X_W
        .FEQ_S => @panic("unimplemented instruction execution for FEQ_S"), // TODO: FEQ_S
        .FLT_S => @panic("unimplemented instruction execution for FLT_S"), // TODO: FLT_S
        .FLE_S => @panic("unimplemented instruction execution for FLE_S"), // TODO: FLE_S
        .FCLASS_S => @panic("unimplemented instruction execution for FCLASS_S"), // TODO: FCLASS_S
        .FCVT_S_W => @panic("unimplemented instruction execution for FCVT_S_W"), // TODO: FCVT_S_W
        .FCVT_S_WU => @panic("unimplemented instruction execution for FCVT_S_WU"), // TODO: FCVT_S_WU
        .FMV_W_X => @panic("unimplemented instruction execution for FMV_W_X"), // TODO: FMV_W_X
        .FCVT_L_S => @panic("unimplemented instruction execution for FCVT_L_S"), // TODO: FCVT_L_S
        .FCVT_LU_S => @panic("unimplemented instruction execution for FCVT_LU_S"), // TODO: FCVT_LU_S
        .FCVT_S_L => @panic("unimplemented instruction execution for FCVT_S_L"), // TODO: FCVT_S_L
        .FCVT_S_LU => @panic("unimplemented instruction execution for FCVT_S_LU"), // TODO: FCVT_S_LU
        .FLD => @panic("unimplemented instruction execution for FLD"), // TODO: FLD
        .FSD => @panic("unimplemented instruction execution for FSD"), // TODO: FSD
        .FMADD_D => @panic("unimplemented instruction execution for FMADD_D"), // TODO: FMADD_D
        .FMSUB_D => @panic("unimplemented instruction execution for FMSUB_D"), // TODO: FMSUB_D
        .FNMSUB_D => @panic("unimplemented instruction execution for FNMSUB_D"), // TODO: FNMSUB_D
        .FNMADD_D => @panic("unimplemented instruction execution for FNMADD_D"), // TODO: FNMADD_D
        .FADD_D => @panic("unimplemented instruction execution for FADD_D"), // TODO: FADD_D
        .FSUB_D => @panic("unimplemented instruction execution for FSUB_D"), // TODO: FSUB_D
        .FMUL_D => @panic("unimplemented instruction execution for FMUL_D"), // TODO: FMUL_D
        .FDIV_D => @panic("unimplemented instruction execution for FDIV_D"), // TODO: FDIV_D
        .FSQRT_D => @panic("unimplemented instruction execution for FSQRT_D"), // TODO: FSQRT_D
        .FSGNJ_D => @panic("unimplemented instruction execution for FSGNJ_D"), // TODO: FSGNJ_D
        .FSGNJN_D => @panic("unimplemented instruction execution for FSGNJN_D"), // TODO: FSGNJN_D
        .FSGNJX_D => @panic("unimplemented instruction execution for FSGNJX_D"), // TODO: FSGNJX_D
        .FMIN_D => @panic("unimplemented instruction execution for FMIN_D"), // TODO: FMIN_D
        .FMAX_D => @panic("unimplemented instruction execution for FMAX_D"), // TODO: FMAX_D
        .FCVT_S_D => @panic("unimplemented instruction execution for FCVT_S_D"), // TODO: FCVT_S_D
        .FCVT_D_S => @panic("unimplemented instruction execution for FCVT_D_S"), // TODO: FCVT_D_S
        .FEQ_D => @panic("unimplemented instruction execution for FEQ_D"), // TODO: FEQ_D
        .FLT_D => @panic("unimplemented instruction execution for FLT_D"), // TODO: FLT_D
        .FLE_D => @panic("unimplemented instruction execution for FLE_D"), // TODO: FLE_D
        .FCLASS_D => @panic("unimplemented instruction execution for FCLASS_D"), // TODO: FCLASS_D
        .FCVT_W_D => @panic("unimplemented instruction execution for FCVT_W_D"), // TODO: FCVT_W_D
        .FCVT_WU_D => @panic("unimplemented instruction execution for FCVT_WU_D"), // TODO: FCVT_WU_D
        .FCVT_D_W => @panic("unimplemented instruction execution for FCVT_D_W"), // TODO: FCVT_D_W
        .FCVT_D_WU => @panic("unimplemented instruction execution for FCVT_D_WU"), // TODO: FCVT_D_WU
        .FCVT_L_D => @panic("unimplemented instruction execution for FCVT_L_D"), // TODO: FCVT_L_D
        .FCVT_LU_D => @panic("unimplemented instruction execution for FCVT_LU_D"), // TODO: FCVT_LU_D
        .FMV_X_D => @panic("unimplemented instruction execution for FMV_X_D"), // TODO: FMV_X_D
        .FCVT_D_L => @panic("unimplemented instruction execution for FCVT_D_L"), // TODO: FCVT_D_L
        .FCVT_D_LU => @panic("unimplemented instruction execution for FCVT_D_LU"), // TODO: FCVT_D_LU
        .FMV_D_X => @panic("unimplemented instruction execution for FMV_D_X"), // TODO: FMV_D_X
        .C_ADDI4SPN => @panic("unimplemented instruction execution for C_ADDI4SPN"), // TODO: C_ADDI4SPN
        .C_FLD => @panic("unimplemented instruction execution for C_FLD"), // TODO: C_FLD
        .C_LW => @panic("unimplemented instruction execution for C_LW"), // TODO: C_LW
        .C_LD => @panic("unimplemented instruction execution for C_LD"), // TODO: C_LD
        .C_FSD => @panic("unimplemented instruction execution for C_FSD"), // TODO: C_FSD
        .C_SW => @panic("unimplemented instruction execution for C_SW"), // TODO: C_SW
        .C_SD => @panic("unimplemented instruction execution for C_SD"), // TODO: C_SD
        .C_NOP => @panic("unimplemented instruction execution for C_NOP"), // TODO: C_NOP
        .C_ADDI => @panic("unimplemented instruction execution for C_ADDI"), // TODO: C_ADDI
        .C_ADDIW => @panic("unimplemented instruction execution for C_ADDIW"), // TODO: C_ADDIW
        .C_LI => @panic("unimplemented instruction execution for C_LI"), // TODO: C_LI
        .C_ADDI16SP => @panic("unimplemented instruction execution for C_ADDI16SP"), // TODO: C_ADDI16SP
        .C_LUI => @panic("unimplemented instruction execution for C_LUI"), // TODO: C_LUI
        .C_SRLI => @panic("unimplemented instruction execution for C_SRLI"), // TODO: C_SRLI
        .C_SRAI => @panic("unimplemented instruction execution for C_SRAI"), // TODO: C_SRAI
        .C_ANDI => @panic("unimplemented instruction execution for C_ANDI"), // TODO: C_ANDI
        .C_SUB => @panic("unimplemented instruction execution for C_SUB"), // TODO: C_SUB
        .C_XOR => @panic("unimplemented instruction execution for C_XOR"), // TODO: C_XOR
        .C_OR => @panic("unimplemented instruction execution for C_OR"), // TODO: C_OR
        .C_AND => @panic("unimplemented instruction execution for C_AND"), // TODO: C_AND
        .C_SUBW => @panic("unimplemented instruction execution for C_SUBW"), // TODO: C_SUBW
        .C_ADDW => @panic("unimplemented instruction execution for C_ADDW"), // TODO: C_ADDW
        .C_J => {
            const z = lib.traceNamed(@src(), "C_J");
            defer z.end();

            // CJ Type

            const imm = instruction.compressed_jump_target.read();
            const result = addSignedToUnsignedWrap(hart.pc, imm);

            if (has_writer) {
                try writer.print(
                    \\C.J - offset: 0x{x}
                    \\  setting pc to ( pc<0x{x}> + 0x{x} ) = 0x{x}
                    \\
                , .{
                    imm,
                    hart.pc,
                    imm,
                    result,
                });
            }

            if (actually_execute) {
                hart.pc = result;
            }
        },
        .C_BEQZ => @panic("unimplemented instruction execution for C_BEQZ"), // TODO: C_BEQZ
        .C_BNEZ => @panic("unimplemented instruction execution for C_BNEZ"), // TODO: C_BNEZ
        .C_SLLI => @panic("unimplemented instruction execution for C_SLLI"), // TODO: C_SLLI
        .C_FLDSP => @panic("unimplemented instruction execution for C_FLDSP"), // TODO: C_FLDSP
        .C_LWSP => @panic("unimplemented instruction execution for C_LWSP"), // TODO: C_LWSP
        .C_LDSP => @panic("unimplemented instruction execution for C_LDSP"), // TODO: C_LDSP
        .C_JR => @panic("unimplemented instruction execution for C_JR"), // TODO: C_JR
        .C_MV => @panic("unimplemented instruction execution for C_MV"), // TODO: C_MV
        .C_EBREAK => @panic("unimplemented instruction execution for C_EBREAK"), // TODO: C_EBREAK
        .C_JALR => @panic("unimplemented instruction execution for C_JALR"), // TODO: C_JALR
        .C_ADD => @panic("unimplemented instruction execution for C_ADD"), // TODO: C_ADD
        .C_FSDSP => @panic("unimplemented instruction execution for C_FSDSP"), // TODO: C_FSDSP
        .C_SWSP => @panic("unimplemented instruction execution for C_SWSP"), // TODO: C_SWSP
        .C_SDSP => @panic("unimplemented instruction execution for C_SDSP"), // TODO: C_SDSP
    }

    return true;
}

fn readCsr(comptime mode: lib.Mode, hart: *const lib.Hart(mode), csr: lib.Csr) u64 {
    const read_csr_z = lib.traceNamed(@src(), "read csr");
    defer read_csr_z.end();

    return switch (csr) {
        .cycle => hart.cycle,
        .mhartid => hart.hart_id,
    };
}

fn writeCsr(comptime mode: lib.Mode, hart: *const lib.Hart(mode), csr: lib.Csr, value: u64) !void {
    const write_csr_z = lib.traceNamed(@src(), "write csr");
    defer write_csr_z.end();

    _ = hart;
    _ = value;

    switch (csr) {
        .cycle => unreachable, // Read-Only CSR
        .mhartid => unreachable, // Read-Only CSR
    }
}

fn throw(
    comptime mode: lib.Mode,
    hart: *lib.Hart(mode),
    exception: void,
    value: u64,
    writer: anytype,
    comptime actually_execute: bool,
) !void {
    const z = lib.traceNamed(@src(), "throw");
    defer z.end();

    const has_writer = comptime isWriter(@TypeOf(writer));
    _ = has_writer;
    _ = hart;
    _ = exception;
    _ = value;
    _ = actually_execute;
    @panic("UNIMPLEMENTED: throw"); // TODO: Exceptions
}

fn addSignedToUnsignedWrap(unsigned: u64, signed: i64) u64 {
    @setRuntimeSafety(false);
    return if (signed < 0)
        unsigned -% @bitCast(u64, -signed)
    else
        unsigned +% @bitCast(u64, signed);
}

test "addSignedToUnsignedWrap" {
    try std.testing.expectEqual(
        @as(u64, 0),
        addSignedToUnsignedWrap(@as(u64, std.math.maxInt(u64)), 1),
    );
    try std.testing.expectEqual(
        @as(u64, std.math.maxInt(u64)),
        addSignedToUnsignedWrap(0, -1),
    );
}

fn addSignedToUnsignedIgnoreOverflow(unsigned: u64, signed: i64) u64 {
    @setRuntimeSafety(false);
    var result: u64 = undefined;
    if (signed < 0) {
        _ = @subWithOverflow(u64, unsigned, @bitCast(u64, -signed), &result);
    } else {
        _ = @addWithOverflow(u64, unsigned, @bitCast(u64, signed), &result);
    }
    return result;
}

test "addSignedToUnsignedIgnoreOverflow" {
    try std.testing.expectEqual(
        @as(u64, 42),
        addSignedToUnsignedIgnoreOverflow(@as(u64, std.math.maxInt(u64)), 43),
    );
    try std.testing.expectEqual(
        @as(u64, std.math.maxInt(u64)),
        addSignedToUnsignedIgnoreOverflow(5, -6),
    );
}

inline fn signExtend64bit(value: u64) i128 {
    return @bitCast(i128, @as(u128, value) << 64) >> 64;
}

inline fn signExtend32bit(value: u64) u64 {
    return @bitCast(u64, @bitCast(i64, value << 32) >> 32);
}

inline fn signExtend16bit(value: u64) u64 {
    return @bitCast(u64, @bitCast(i64, value << 48) >> 48);
}

inline fn signExtend8bit(value: u64) u64 {
    return @bitCast(u64, @bitCast(i64, value << 56) >> 56);
}

inline fn isWriter(comptime T: type) bool {
    return comptime std.meta.trait.hasFn("print")(T);
}

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
