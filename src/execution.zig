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

    const instruction = readInstruction(mode, hart) catch |err| {
        if (options.execution_out_of_bounds_is_fatal) return err;

        switch (err) {
            // TODO: Pass `InstructionAccessFault` once `throw` is implemented
            error.ExecutionOutOfBounds => {
                try throw(mode, hart, {}, 0, writer, actually_execute);
                return true;
            },
        }
    };

    if (has_writer and options.always_print_pc) {
        try writer.print("pc: {x:0>16}\n", .{hart.pc});
    }

    return try execute(mode, hart, instruction, writer, riscof_mode, options, actually_execute);
}

fn readInstruction(comptime mode: lib.Mode, hart: *lib.Hart(mode)) !lib.Instruction {
    // try to load 32-bit instruction
    if (hart.loadMemory(32, hart.pc)) |mem| {
        return lib.Instruction{ .full_backing = mem };
    } else |full_err| switch (full_err) {
        error.ExecutionOutOfBounds => {
            // try to load 16-bit compressed instruction which happens to be at the very end of readable memory region
            if (hart.loadMemory(16, hart.pc)) |mem| {
                const instruction = lib.Instruction{ .compressed_backing = .{ .low = mem } };
                if (instruction.op.read() == 0b11) {
                    // This doesn't look like a compressed instruction
                    return error.ExecutionOutOfBounds;
                }
                return instruction;
            } else |e| return e;
        },
        else => |e| return e,
    }
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
                        \\AUIPC - dest: {}, offset: {x}
                        \\  setting {} to pc<{x}> + {x} = {x}
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
                        \\AUIPC - dest: {}, offset: {x}
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
                        \\JAL - dest: {}, offset: {x}
                        \\  setting {} to pc<{x}> + 4 = {x}
                        \\  setting pc to pc<{x}> + {x} = {x}
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
                        \\JAL - dest: {}, offset: {x}
                        \\  setting pc to pc<{x}> + {x} = {x}
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
                        \\JALR - dest: {}, base: {}, offset: {x}
                        \\  setting {} to pc<{x}> + 4 = {x}
                        \\  setting pc to ({}<{x}> + {x}) & ~1 = {x}
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
                        \\JALR - dest: {}, base: {}, offset: {x}
                        \\  setting pc to ({}<{x}> + {x}) & ~1 = {x}
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
        .BEQ => {
            const z = lib.traceNamed(@src(), "BEQ");
            defer z.end();

            // B-type

            const rs1 = instruction.rs1();
            const rs1_value = hart.x[@enumToInt(rs1)];
            const rs2 = instruction.rs2();
            const rs2_value = hart.x[@enumToInt(rs2)];

            if (rs1_value == rs2_value) {
                const imm = instruction.b_imm.read();
                const result = addSignedToUnsignedWrap(hart.pc, imm);

                if (has_writer) {
                    try writer.print(
                        \\BEQ - src1: {}, src2: {}, offset: {x}
                        \\  ( {}<{}> == {}<{}> ) == true
                        \\  setting pc to pc<{x}> + {x} = {x}
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        rs1,
                        rs1_value,
                        rs2,
                        rs2_value,
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
                    const imm = instruction.b_imm.read();

                    try writer.print(
                        \\BEQ - src1: {}, src2: {}, offset: 0x{x}
                        \\  ( {}<{}> == {}<{}> ) == false
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        rs1,
                        rs1_value,
                        rs2,
                        rs2_value,
                    });
                }

                if (actually_execute) {
                    hart.pc += 4;
                }
            }
        },
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
                        \\BNE - src1: {}, src2: {}, offset: {x}
                        \\  ( {}<{}> != {}<{}> ) == true
                        \\  setting pc to pc<{x}> + {x} = {x}
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        rs1,
                        rs1_value,
                        rs2,
                        rs2_value,
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
                        \\BNE - src1: {}, src2: {}, offset: {x}
                        \\  ( {}<{}> != {}<{}> ) == false
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        rs1,
                        rs1_value,
                        rs2,
                        rs2_value,
                    });
                }

                if (actually_execute) {
                    hart.pc += 4;
                }
            }
        },
        .BLT => {
            const z = lib.traceNamed(@src(), "BLT");
            defer z.end();

            // B-type

            const rs1 = instruction.rs1();
            const rs1_value = @bitCast(i64, hart.x[@enumToInt(rs1)]);
            const rs2 = instruction.rs2();
            const rs2_value = @bitCast(i64, hart.x[@enumToInt(rs2)]);

            if (rs1_value < rs2_value) {
                const imm = instruction.b_imm.read();
                const result = addSignedToUnsignedWrap(hart.pc, imm);

                if (has_writer) {
                    try writer.print(
                        \\BLT - src1: {}, src2: {}, offset: {x}
                        \\  ( {}<{}> < {}<{}> ) == true
                        \\  setting pc to pc<{x}> + {x} = {x}
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        rs1,
                        rs1_value,
                        rs2,
                        rs2_value,
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
                    const imm = instruction.b_imm.read();

                    try writer.print(
                        \\BLT - src1: {}, src2: {}, offset: {x}
                        \\  ( {}<{}> < {}<{}> ) == false
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        rs1,
                        rs1_value,
                        rs2,
                        rs2_value,
                    });
                }

                if (actually_execute) {
                    hart.pc += 4;
                }
            }
        },
        .BGE => {
            const z = lib.traceNamed(@src(), "BGE");
            defer z.end();

            // B-type

            const rs1 = instruction.rs1();
            const rs1_value = @bitCast(i64, hart.x[@enumToInt(rs1)]);
            const rs2 = instruction.rs2();
            const rs2_value = @bitCast(i64, hart.x[@enumToInt(rs2)]);

            if (rs1_value >= rs2_value) {
                const imm = instruction.b_imm.read();
                const result = addSignedToUnsignedWrap(hart.pc, imm);

                if (has_writer) {
                    try writer.print(
                        \\BGE - src1: {}, src2: {}, offset: {x}
                        \\  ( {}<{}> >= {}<{}> ) == true
                        \\  setting pc to pc<{x}> + {x} = {x}
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        rs1,
                        rs1_value,
                        rs2,
                        rs2_value,
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
                    const imm = instruction.b_imm.read();

                    try writer.print(
                        \\BGE - src1: {}, src2: {}, offset: {x}
                        \\  ( {}<{}> >= {}<{}> ) == false
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        rs1,
                        rs1_value,
                        rs2,
                        rs2_value,
                    });
                }

                if (actually_execute) {
                    hart.pc += 4;
                }
            }
        },
        .BLTU => {
            const z = lib.traceNamed(@src(), "BLTU");
            defer z.end();

            // B-type

            const rs1 = instruction.rs1();
            const rs1_value = hart.x[@enumToInt(rs1)];
            const rs2 = instruction.rs2();
            const rs2_value = hart.x[@enumToInt(rs2)];

            if (rs1_value < rs2_value) {
                const imm = instruction.b_imm.read();
                const result = addSignedToUnsignedWrap(hart.pc, imm);

                if (has_writer) {
                    try writer.print(
                        \\BLTU - src1: {}, src2: {}, offset: {x}
                        \\  ( {}<{}> < {}<{}> ) == true
                        \\  setting pc to pc<{x}> + {x} = {x}
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        rs1,
                        rs1_value,
                        rs2,
                        rs2_value,
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
                    const imm = instruction.b_imm.read();

                    try writer.print(
                        \\BLTU - src1: {}, src2: {}, offset: {x}
                        \\  ( {}<{}> < {}<{}> ) == false
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        rs1,
                        rs1_value,
                        rs2,
                        rs2_value,
                    });
                }

                if (actually_execute) {
                    hart.pc += 4;
                }
            }
        },
        .BGEU => {
            const z = lib.traceNamed(@src(), "BGEU");
            defer z.end();

            // B-type

            const rs1 = instruction.rs1();
            const rs1_value = hart.x[@enumToInt(rs1)];
            const rs2 = instruction.rs2();
            const rs2_value = hart.x[@enumToInt(rs2)];

            if (rs1_value >= rs2_value) {
                const imm = instruction.b_imm.read();
                const result = addSignedToUnsignedWrap(hart.pc, imm);

                if (has_writer) {
                    try writer.print(
                        \\BGEU - src1: {}, src2: {}, offset: {x}
                        \\  ( {}<{}> >= {}<{}> ) == true
                        \\  setting pc to pc<{x}> + {x} = {x}
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        rs1,
                        rs1_value,
                        rs2,
                        rs2_value,
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
                    const imm = instruction.b_imm.read();

                    try writer.print(
                        \\BGEU - src1: {}, src2: {}, offset: {x}
                        \\  ( {}<{}> >= {}<{}> ) == false
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        rs1,
                        rs1_value,
                        rs2,
                        rs2_value,
                    });
                }

                if (actually_execute) {
                    hart.pc += 4;
                }
            }
        },
        .LB => {
            const z = lib.traceNamed(@src(), "LB");
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
                        \\LB - base: {}, dest: {}, imm: {x}
                        \\  load 1 byte into {} from memory ( {}<{x}> + {x} ) = {x}
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
                        try hart.loadMemory(8, address)
                    else blk: {
                        break :blk hart.loadMemory(8, address) catch |err| switch (err) {
                            error.ExecutionOutOfBounds => {
                                // TODO: Pass `.LoadAccessFault` once `throw` is implemented
                                try throw(mode, hart, {}, 0, writer, true);
                                return true;
                            },
                            else => |e| return e,
                        };
                    };

                    hart.x[@enumToInt(rd)] = signExtend8bit(memory);
                }
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\LB - base: {}, dest: {}, imm: {x}
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
        .LH => {
            const z = lib.traceNamed(@src(), "LH");
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
                        \\LH - base: {}, dest: {}, imm: {x}
                        \\  load 2 bytes into {} from memory ( {}<{x}> + {x} ) = {x}
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
                        try hart.loadMemory(16, address)
                    else blk: {
                        break :blk hart.loadMemory(16, address) catch |err| switch (err) {
                            error.ExecutionOutOfBounds => {
                                // TODO: Pass `.LoadAccessFault` once `throw` is implemented
                                try throw(mode, hart, {}, 0, writer, true);
                                return true;
                            },
                            else => |e| return e,
                        };
                    };

                    hart.x[@enumToInt(rd)] = signExtend16bit(memory);
                }
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\LH - base: {}, dest: {}, imm: {x}
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
        .LW => {
            const z = lib.traceNamed(@src(), "LW");
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
                        \\LW - base: {}, dest: {}, imm: {x}
                        \\  load 4 bytes into {} from memory ( {}<{x}> + {x} ) = {x}
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
                        try hart.loadMemory(32, address)
                    else blk: {
                        break :blk hart.loadMemory(32, address) catch |err| switch (err) {
                            error.ExecutionOutOfBounds => {
                                // TODO: Pass `.LoadAccessFault` once `throw` is implemented
                                try throw(mode, hart, {}, 0, writer, true);
                                return true;
                            },
                            else => |e| return e,
                        };
                    };

                    hart.x[@enumToInt(rd)] = signExtend32bit(memory);
                }
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\LW - base: {}, dest: {}, imm: {x}
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
        .LBU => {
            const z = lib.traceNamed(@src(), "LBU");
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
                        \\LBU - base: {}, dest: {}, imm: {x}
                        \\  load 1 byte into {} from memory ( {}<{x}> + {x} ) = {x}
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
                        try hart.loadMemory(8, address)
                    else blk: {
                        break :blk hart.loadMemory(8, address) catch |err| switch (err) {
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
                        \\LB - base: {}, dest: {}, imm: {x}
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
        .LHU => {
            const z = lib.traceNamed(@src(), "LHU");
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
                        \\LHU - base: {}, dest: {}, imm: {x}
                        \\  load 2 bytes into {} from memory ( {}<{x}> + {x} ) = {x}
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
                        try hart.loadMemory(16, address)
                    else blk: {
                        break :blk hart.loadMemory(16, address) catch |err| switch (err) {
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
                        \\LHU - base: {}, dest: {}, imm: {x}
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
        .SB => {
            const z = lib.traceNamed(@src(), "SB");
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
                    \\SB - base: {}, src: {}, imm: {x}
                    \\  store 1 byte from {}<{}> into memory ( {}<{x}> + {x} ) = {x}
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
                    try hart.storeMemory(8, address, @truncate(u8, rs2_value));
                } else {
                    hart.storeMemory(8, address, @truncate(u8, rs2_value)) catch |err| switch (err) {
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
        .SH => {
            const z = lib.traceNamed(@src(), "SH");
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
                    \\SH - base: {}, src: {}, imm: {x}
                    \\  store 2 bytes from {}<{}> into memory ( {}<{x}> + {x} ) = {x}
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
                    try hart.storeMemory(16, address, @truncate(u16, rs2_value));
                } else {
                    hart.storeMemory(16, address, @truncate(u16, rs2_value)) catch |err| switch (err) {
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
                    \\SW - base: {}, src: {}, imm: {x}
                    \\  store 4 bytes from {}<{}> into memory ( {}<{x}> + {x} ) = {x}
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
                        \\  set {} to {}<{}> + {} = {}
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
        .SLTI => {
            const z = lib.traceNamed(@src(), "SLTI");
            defer z.end();

            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = @bitCast(i64, hart.x[@enumToInt(rs1)]);
                const imm = instruction.i_imm.read();
                const result = @boolToInt(rs1_value < imm);

                if (has_writer) {
                    try writer.print(
                        \\SLTI - src: {}, dest: {}, imm: {x}
                        \\  set {} to {}<{}> < {x} ? 1 : 0
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        rs1_value,
                        imm,
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
                        \\SLTI - src: {}, dest: {}, imm: {x}
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
        .SLTIU => {
            const z = lib.traceNamed(@src(), "SLTIU");
            defer z.end();

            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = hart.x[@enumToInt(rs1)];
                const imm = @bitCast(u64, instruction.i_imm.read());
                const result = @boolToInt(rs1_value < imm);

                if (has_writer) {
                    try writer.print(
                        \\SLTIU - src: {}, dest: {}, imm: {x}
                        \\  set {} to {}<{}> < {x} ? 1 : 0
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        rs1_value,
                        imm,
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
                        \\SLTIU - src: {}, dest: {}, imm: {x}
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
        .XORI => {
            const z = lib.traceNamed(@src(), "ADDI");
            defer z.end();

            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = hart.x[@enumToInt(rs1)];
                const imm = @bitCast(u64, instruction.i_imm.read());
                const result = rs1_value ^ @bitCast(u64, imm);

                if (has_writer) {
                    try writer.print(
                        \\XORI - src: {}, dest: {}, imm: {}
                        \\  set {} to {}<{}> ^ {} = {}
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
                        \\XORI - src: {}, dest: {}, imm: {}
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
        .ORI => {
            const z = lib.traceNamed(@src(), "ORI");
            defer z.end();

            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = hart.x[@enumToInt(rs1)];
                const imm = @bitCast(u64, instruction.i_imm.read());
                const result = rs1_value | @bitCast(u64, imm);

                if (has_writer) {
                    try writer.print(
                        \\ORI - src: {}, dest: {}, imm: {}
                        \\  set {} to {}<{}> & {} = {}
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
                        \\ORI - src: {}, dest: {}, imm: 0x{x}
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
        .ANDI => {
            const z = lib.traceNamed(@src(), "ANDI");
            defer z.end();

            // I-type
            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = hart.x[@enumToInt(rs1)];
                const imm = @bitCast(u64, instruction.i_imm.read());
                const result = rs1_value & imm;

                if (has_writer) {
                    try writer.print(
                        \\ANDI - src: {}, dest: {}, imm: {}
                        \\  set {} to {}<{}> & {} = {}
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
                        \\ANDI - src: {}, dest: {}, imm: {}
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
                        \\  set {} to {}<{}> << {} = {}
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
        .SRLI => return instructionExecutionUnimplemented("SRLI"), // TODO: SRLI
        .SRAI => {
            const z = lib.traceNamed(@src(), "SRAI");
            defer z.end();

            // I-type specialization

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = @bitCast(i64, hart.x[@enumToInt(rs1)]);
                const shmt = instruction.i_specialization.fullShift();
                const result = @bitCast(u64, @bitCast(i64, rs1_value >> shmt));

                if (has_writer) {
                    try writer.print(
                        \\SRAI - src: {}, dest: {}, shmt: {}
                        \\  set {} to {}<{}> >> {} = {}
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
                        \\SRAI - src: {}, dest: {}, shmt: {}
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
                        \\  set {} to {}<{}> + {}<{}> = {}
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
        .SUB => {
            const z = lib.traceNamed(@src(), "SUB");
            defer z.end();

            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = hart.x[@enumToInt(rs1)];
                const rs2 = instruction.rs2();
                const rs2_value = hart.x[@enumToInt(rs2)];

                var result: u64 = undefined;
                _ = @subWithOverflow(u64, rs1_value, rs2_value, &result);

                if (has_writer) {
                    try writer.print(
                        \\ADD - src1: {}, src2: {}, dest: {}
                        \\  set {} to {}<{}> + {}<{}> = {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs1_value,
                        rs2,
                        rs1_value,
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
        .SLL => {
            const z = lib.traceNamed(@src(), "SUB");
            defer z.end();

            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = hart.x[@enumToInt(rs1)];
                const rs2 = instruction.rs2();
                const rs2_value = @truncate(u6, hart.x[@enumToInt(rs2)]);
                const result = rs1_value << rs2_value;

                if (has_writer) {
                    try writer.print(
                        \\SLL - src1: {}, src2: {}, dest: {}
                        \\  set {} to {}<{}> << u6({}<{}>) = {}
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
                        \\SLL - src1: {}, src2: {}, dest: {}
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
        .SLT => {
            const z = lib.traceNamed(@src(), "SLT");
            defer z.end();

            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = @bitCast(i64, hart.x[@enumToInt(rs1)]);
                const rs2 = instruction.rs2();
                const rs2_value = @bitCast(i64, hart.x[@enumToInt(rs2)]);
                const result = @boolToInt(rs1_value < rs2_value);

                if (has_writer) {
                    try writer.print(
                        \\SLT - src1: {}, src2: {}, dest: {}
                        \\  set {} to {}<{}> < {}<{}> ? 1 : 0
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
                        \\SLT - src1: {}, src2: {}, dest: {}
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
        .SLTU => {
            const z = lib.traceNamed(@src(), "SLTU");
            defer z.end();

            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = hart.x[@enumToInt(rs1)];
                const rs2 = instruction.rs2();
                const rs2_value = hart.x[@enumToInt(rs2)];
                const result = @boolToInt(rs1_value < rs2_value);

                if (has_writer) {
                    try writer.print(
                        \\SLTU - src1: {}, src2: {}, dest: {}
                        \\  set {} to {}<{}> < {}<{}> ? 1 : 0
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
                        \\SLTU - src1: {}, src2: {}, dest: {}
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
        .XOR => return instructionExecutionUnimplemented("XOR"), // TODO: XOR
        .SRL => {
            const z = lib.traceNamed(@src(), "SRL");
            defer z.end();

            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = hart.x[@enumToInt(rs1)];
                const rs2 = instruction.rs2();
                const rs2_value = @truncate(u6, hart.x[@enumToInt(rs2)]);
                const result = rs1_value >> rs2_value;

                if (has_writer) {
                    try writer.print(
                        \\SRL - src1: {}, src2: {}, dest: {}
                        \\  set {} to {}<{}> >> {}<{}> = {}
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
                        \\SRL - src1: {}, src2: {}, dest: {}
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
        .SRA => {
            const z = lib.traceNamed(@src(), "SRA");
            defer z.end();

            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = @bitCast(i64, hart.x[@enumToInt(rs1)]);
                const rs2 = instruction.rs2();
                const rs2_value = @truncate(u6, hart.x[@enumToInt(rs2)]);
                const result = @bitCast(u64, rs1_value >> rs2_value);

                if (has_writer) {
                    try writer.print(
                        \\SRA - src1: {}, src2: {}, dest: {}
                        \\  set {} to {}<{}> >> {}<{}> = {}
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
                        \\SRA - src1: {}, src2: {}, dest: {}
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
        .OR => {
            const z = lib.traceNamed(@src(), "OR");
            defer z.end();

            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = hart.x[@enumToInt(rs1)];
                const rs2 = instruction.rs2();
                const rs2_value = hart.x[@enumToInt(rs2)];
                const result = rs1_value | rs2_value;

                if (has_writer) {
                    try writer.print(
                        \\OR - src1: {}, src2: {}, dest: {}
                        \\  set {} to {}<{}> & {}<{}> = {}
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
                        \\OR - src1: {}, src2: {}, dest: {}
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
        .AND => {
            const z = lib.traceNamed(@src(), "AND");
            defer z.end();

            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = hart.x[@enumToInt(rs1)];
                const rs2 = instruction.rs2();
                const rs2_value = hart.x[@enumToInt(rs2)];
                const result = rs1_value & rs2_value;

                if (has_writer) {
                    try writer.print(
                        \\AND - src1: {}, src2: {}, dest: {}
                        \\  set {} to {}<{}> & {}<{}> = {}
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
                        \\AND - src1: {}, src2: {}, dest: {}
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
        .FENCE => {
            const z = lib.traceNamed(@src(), "FENCE");
            defer z.end();

            if (has_writer) {
                try writer.print("FENCE\n", .{});
            }

            if (actually_execute) {
                // TODO: More precise atomic order
                @fence(.SeqCst);

                hart.pc += 4;
            }
        },
        .ECALL => return instructionExecutionUnimplemented("ECALL"), // TODO: ECALL
        .EBREAK => return instructionExecutionUnimplemented("EBREAK"), // TODO: EBREAK
        .LWU => {
            const z = lib.traceNamed(@src(), "LWU");
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
                        \\LWU - base: {}, dest: {}, imm: {x}
                        \\  load 4 bytes into {} from memory {}<{x}> + {x} = {x}
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
                        try hart.loadMemory(32, address)
                    else blk: {
                        break :blk hart.loadMemory(32, address) catch |err| switch (err) {
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
                        \\LWU - base: {}, dest: {}, imm: {x}
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
                        \\LD - base: {}, dest: {}, imm: {x}
                        \\  load 8 bytes into {} from memory {}<{x}> + {x} = {x}
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
                        \\LD - base: {}, dest: {}, imm: {x}
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
                    \\SD - base: {}, src: {}, imm: {x}
                    \\  store 8 bytes from {}<{}> into memory {}<{x}> + {x} = {x}
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
        .SLLIW => {
            const z = lib.traceNamed(@src(), "SLLIW");
            defer z.end();

            // I-type specialization

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = @truncate(u32, hart.x[@enumToInt(rs1)]);
                const shmt = instruction.i_specialization.smallShift();
                const result = signExtend32bit(rs1_value << shmt);

                if (has_writer) {
                    try writer.print(
                        \\SLLIW - src: {}, dest: {}, shmt: {}
                        \\  set {} to u32({}<{}>) << {} = {}
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
                        \\SLLIW - src: {}, dest: {}, shmt: {}
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
        .SRLIW => return instructionExecutionUnimplemented("SRLIW"), // TODO: SRLIW
        .SRAIW => {
            const z = lib.traceNamed(@src(), "SRAIW");
            defer z.end();

            // I-type specialization

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = @bitCast(i32, @truncate(u32, hart.x[@enumToInt(rs1)]));
                const shmt = instruction.i_specialization.smallShift();
                const result = signExtend32bit(@bitCast(u32, rs1_value >> shmt));

                if (has_writer) {
                    try writer.print(
                        \\SRAI - src: {}, dest: {}, shmt: {}
                        \\  set {} to {}<{}> >> {} = {}
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
                        \\SRAI - src: {}, dest: {}, shmt: {}
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
        .ADDW => {
            const z = lib.traceNamed(@src(), "ADDW");
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
        .SUBW => return instructionExecutionUnimplemented("SUBW"), // TODO: SUBW
        .SLLW => {
            const z = lib.traceNamed(@src(), "SLLW");
            defer z.end();

            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = @truncate(u32, hart.x[@enumToInt(rs1)]);
                const rs2 = instruction.rs2();
                const rs2_value = @truncate(u5, hart.x[@enumToInt(rs2)]);
                const result = signExtend32bit(rs1_value << rs2_value);

                if (has_writer) {
                    try writer.print(
                        \\SLLW - src1: {}, src2: {}, dest: {}
                        \\  set {} to u32( {}<{}> ) << u5( {}<{}> ) = {}
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
                        \\SLLW - src1: {}, src2: {}, dest: {}
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
        .SRLW => return instructionExecutionUnimplemented("SRLW"), // TODO: SRLW
        .SRAW => {
            const z = lib.traceNamed(@src(), "SRAW");
            defer z.end();

            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs1_value = @bitCast(i32, @truncate(u32, hart.x[@enumToInt(rs1)]));
                const rs2 = instruction.rs2();
                const rs2_value = @truncate(u5, hart.x[@enumToInt(rs2)]);
                const result = signExtend32bit(@bitCast(u32, rs1_value >> rs2_value));

                if (has_writer) {
                    try writer.print(
                        \\SRAW - src1: {}, src2: {}, dest: {}
                        \\  set {} to {}<{}> >> {}<{}> = {}
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
                        \\SRAW - src1: {}, src2: {}, dest: {}
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
        .FENCE_I => return instructionExecutionUnimplemented("FENCE_I"), // TODO: FENCE_I
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

                if (actually_execute) {
                    const initial_csr = readCsr(mode, hart, csr);
                    try writeCsr(mode, hart, csr, rs1_value);
                    hart.x[@enumToInt(rd)] = initial_csr;
                }
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

                if (actually_execute) {
                    try writeCsr(mode, hart, csr, rs1_value);
                }
            }

            if (actually_execute) {
                hart.pc += 4;
            }
        },
        .CSRRS => return instructionExecutionUnimplemented("CSRRS"), // TODO: CSRRS
        .CSRRC => return instructionExecutionUnimplemented("CSRRC"), // TODO: CSRRC
        .CSRRWI => return instructionExecutionUnimplemented("CSRRWI"), // TODO: CSRRWI
        .CSRRSI => return instructionExecutionUnimplemented("CSRRSI"), // TODO: CSRRSI
        .CSRRCI => return instructionExecutionUnimplemented("CSRRCI"), // TODO: CSRRCI
        .MUL => return instructionExecutionUnimplemented("MUL"), // TODO: MUL
        .MULH => return instructionExecutionUnimplemented("MULH"), // TODO: MULH
        .MULHSU => return instructionExecutionUnimplemented("MULHSU"), // TODO: MULHSU
        .MULHU => return instructionExecutionUnimplemented("MULHU"), // TODO: MULHU
        .DIV => return instructionExecutionUnimplemented("DIV"), // TODO: DIV
        .DIVU => return instructionExecutionUnimplemented("DIVU"), // TODO: DIVU
        .REM => return instructionExecutionUnimplemented("REM"), // TODO: REM
        .REMU => return instructionExecutionUnimplemented("REMU"), // TODO: REMU
        .MULW => return instructionExecutionUnimplemented("MULW"), // TODO: MULW
        .DIVW => return instructionExecutionUnimplemented("DIVW"), // TODO: DIVW
        .DIVUW => return instructionExecutionUnimplemented("DIVUW"), // TODO: DIVUW
        .REMW => return instructionExecutionUnimplemented("REMW"), // TODO: REMW
        .REMUW => return instructionExecutionUnimplemented("REMUW"), // TODO: REMUW
        .LR_W => return instructionExecutionUnimplemented("LR_W"), // TODO: LR_W
        .SC_W => return instructionExecutionUnimplemented("SC_W"), // TODO: SC_W
        .AMOSWAP_W => return instructionExecutionUnimplemented("AMOSWAP_W"), // TODO: AMOSWAP_W
        .AMOADD_W => return instructionExecutionUnimplemented("AMOADD_W"), // TODO: AMOADD_W
        .AMOXOR_W => return instructionExecutionUnimplemented("AMOXOR_W"), // TODO: AMOXOR_W
        .AMOAND_W => return instructionExecutionUnimplemented("AMOAND_W"), // TODO: AMOAND_W
        .AMOOR_W => return instructionExecutionUnimplemented("AMOOR_W"), // TODO: AMOOR_W
        .AMOMIN_W => return instructionExecutionUnimplemented("AMOMIN_W"), // TODO: AMOMIN_W
        .AMOMAX_W => return instructionExecutionUnimplemented("AMOMAX_W"), // TODO: AMOMAX_W
        .AMOMINU_W => return instructionExecutionUnimplemented("AMOMINU_W"), // TODO: AMOMINU_W
        .AMOMAXU_W => return instructionExecutionUnimplemented("AMOMAXU_W"), // TODO: AMOMAXU_W
        .LR_D => return instructionExecutionUnimplemented("LR_D"), // TODO: LR_D
        .SC_D => return instructionExecutionUnimplemented("SC_D"), // TODO: SC_D
        .AMOSWAP_D => return instructionExecutionUnimplemented("AMOSWAP_D"), // TODO: AMOSWAP_D
        .AMOADD_D => return instructionExecutionUnimplemented("AMOADD_D"), // TODO: AMOADD_D
        .AMOXOR_D => return instructionExecutionUnimplemented("AMOXOR_D"), // TODO: AMOXOR_D
        .AMOAND_D => return instructionExecutionUnimplemented("AMOAND_D"), // TODO: AMOAND_D
        .AMOOR_D => return instructionExecutionUnimplemented("AMOOR_D"), // TODO: AMOOR_D
        .AMOMIN_D => return instructionExecutionUnimplemented("AMOMIN_D"), // TODO: AMOMIN_D
        .AMOMAX_D => return instructionExecutionUnimplemented("AMOMAX_D"), // TODO: AMOMAX_D
        .AMOMINU_D => return instructionExecutionUnimplemented("AMOMINU_D"), // TODO: AMOMINU_D
        .AMOMAXU_D => return instructionExecutionUnimplemented("AMOMAXU_D"), // TODO: AMOMAXU_D
        .FLW => return instructionExecutionUnimplemented("FLW"), // TODO: FLW
        .FSW => return instructionExecutionUnimplemented("FSW"), // TODO: FSW
        .FMADD_S => return instructionExecutionUnimplemented("FMADD_S"), // TODO: FMADD_S
        .FMSUB_S => return instructionExecutionUnimplemented("FMSUB_S"), // TODO: FMSUB_S
        .FNMSUB_S => return instructionExecutionUnimplemented("FNMSUB_S"), // TODO: FNMSUB_S
        .FNMADD_S => return instructionExecutionUnimplemented("FNMADD_S"), // TODO: FNMADD_S
        .FADD_S => return instructionExecutionUnimplemented("FADD_S"), // TODO: FADD_S
        .FSUB_S => return instructionExecutionUnimplemented("FSUB_S"), // TODO: FSUB_S
        .FMUL_S => return instructionExecutionUnimplemented("FMUL_S"), // TODO: FMUL_S
        .FDIV_S => return instructionExecutionUnimplemented("FDIV_S"), // TODO: FDIV_S
        .FSQRT_S => return instructionExecutionUnimplemented("FSQRT_S"), // TODO: FSQRT_S
        .FSGNJ_S => return instructionExecutionUnimplemented("FSGNJ_S"), // TODO: FSGNJ_S
        .FSGNJN_S => return instructionExecutionUnimplemented("FSGNJN_S"), // TODO: FSGNJN_S
        .FSGNJX_S => return instructionExecutionUnimplemented("FSGNJX_S"), // TODO: FSGNJX_S
        .FMIN_S => return instructionExecutionUnimplemented("FMIN_S"), // TODO: FMIN_S
        .FMAX_S => return instructionExecutionUnimplemented("FMAX_S"), // TODO: FMAX_S
        .FCVT_W_S => return instructionExecutionUnimplemented("FCVT_W_S"), // TODO: FCVT_W_S
        .FCVT_WU_S => return instructionExecutionUnimplemented("FCVT_WU_S"), // TODO: FCVT_WU_S
        .FMV_X_W => return instructionExecutionUnimplemented("FMV_X_W"), // TODO: FMV_X_W
        .FEQ_S => return instructionExecutionUnimplemented("FEQ_S"), // TODO: FEQ_S
        .FLT_S => return instructionExecutionUnimplemented("FLT_S"), // TODO: FLT_S
        .FLE_S => return instructionExecutionUnimplemented("FLE_S"), // TODO: FLE_S
        .FCLASS_S => return instructionExecutionUnimplemented("FCLASS_S"), // TODO: FCLASS_S
        .FCVT_S_W => return instructionExecutionUnimplemented("FCVT_S_W"), // TODO: FCVT_S_W
        .FCVT_S_WU => return instructionExecutionUnimplemented("FCVT_S_WU"), // TODO: FCVT_S_WU
        .FMV_W_X => return instructionExecutionUnimplemented("FMV_W_X"), // TODO: FMV_W_X
        .FCVT_L_S => return instructionExecutionUnimplemented("FCVT_L_S"), // TODO: FCVT_L_S
        .FCVT_LU_S => return instructionExecutionUnimplemented("FCVT_LU_S"), // TODO: FCVT_LU_S
        .FCVT_S_L => return instructionExecutionUnimplemented("FCVT_S_L"), // TODO: FCVT_S_L
        .FCVT_S_LU => return instructionExecutionUnimplemented("FCVT_S_LU"), // TODO: FCVT_S_LU
        .FLD => return instructionExecutionUnimplemented("FLD"), // TODO: FLD
        .FSD => return instructionExecutionUnimplemented("FSD"), // TODO: FSD
        .FMADD_D => return instructionExecutionUnimplemented("FMADD_D"), // TODO: FMADD_D
        .FMSUB_D => return instructionExecutionUnimplemented("FMSUB_D"), // TODO: FMSUB_D
        .FNMSUB_D => return instructionExecutionUnimplemented("FNMSUB_D"), // TODO: FNMSUB_D
        .FNMADD_D => return instructionExecutionUnimplemented("FNMADD_D"), // TODO: FNMADD_D
        .FADD_D => return instructionExecutionUnimplemented("FADD_D"), // TODO: FADD_D
        .FSUB_D => return instructionExecutionUnimplemented("FSUB_D"), // TODO: FSUB_D
        .FMUL_D => return instructionExecutionUnimplemented("FMUL_D"), // TODO: FMUL_D
        .FDIV_D => return instructionExecutionUnimplemented("FDIV_D"), // TODO: FDIV_D
        .FSQRT_D => return instructionExecutionUnimplemented("FSQRT_D"), // TODO: FSQRT_D
        .FSGNJ_D => return instructionExecutionUnimplemented("FSGNJ_D"), // TODO: FSGNJ_D
        .FSGNJN_D => return instructionExecutionUnimplemented("FSGNJN_D"), // TODO: FSGNJN_D
        .FSGNJX_D => return instructionExecutionUnimplemented("FSGNJX_D"), // TODO: FSGNJX_D
        .FMIN_D => return instructionExecutionUnimplemented("FMIN_D"), // TODO: FMIN_D
        .FMAX_D => return instructionExecutionUnimplemented("FMAX_D"), // TODO: FMAX_D
        .FCVT_S_D => return instructionExecutionUnimplemented("FCVT_S_D"), // TODO: FCVT_S_D
        .FCVT_D_S => return instructionExecutionUnimplemented("FCVT_D_S"), // TODO: FCVT_D_S
        .FEQ_D => return instructionExecutionUnimplemented("FEQ_D"), // TODO: FEQ_D
        .FLT_D => return instructionExecutionUnimplemented("FLT_D"), // TODO: FLT_D
        .FLE_D => return instructionExecutionUnimplemented("FLE_D"), // TODO: FLE_D
        .FCLASS_D => return instructionExecutionUnimplemented("FCLASS_D"), // TODO: FCLASS_D
        .FCVT_W_D => return instructionExecutionUnimplemented("FCVT_W_D"), // TODO: FCVT_W_D
        .FCVT_WU_D => return instructionExecutionUnimplemented("FCVT_WU_D"), // TODO: FCVT_WU_D
        .FCVT_D_W => return instructionExecutionUnimplemented("FCVT_D_W"), // TODO: FCVT_D_W
        .FCVT_D_WU => return instructionExecutionUnimplemented("FCVT_D_WU"), // TODO: FCVT_D_WU
        .FCVT_L_D => return instructionExecutionUnimplemented("FCVT_L_D"), // TODO: FCVT_L_D
        .FCVT_LU_D => return instructionExecutionUnimplemented("FCVT_LU_D"), // TODO: FCVT_LU_D
        .FMV_X_D => return instructionExecutionUnimplemented("FMV_X_D"), // TODO: FMV_X_D
        .FCVT_D_L => return instructionExecutionUnimplemented("FCVT_D_L"), // TODO: FCVT_D_L
        .FCVT_D_LU => return instructionExecutionUnimplemented("FCVT_D_LU"), // TODO: FCVT_D_LU
        .FMV_D_X => return instructionExecutionUnimplemented("FMV_D_X"), // TODO: FMV_D_X
        .C_ADDI4SPN => return instructionExecutionUnimplemented("C_ADDI4SPN"), // TODO: C_ADDI4SPN
        .C_FLD => return instructionExecutionUnimplemented("C_FLD"), // TODO: C_FLD
        .C_LW => return instructionExecutionUnimplemented("C_LW"), // TODO: C_LW
        .C_LD => return instructionExecutionUnimplemented("C_LD"), // TODO: C_LD
        .C_FSD => return instructionExecutionUnimplemented("C_FSD"), // TODO: C_FSD
        .C_SW => return instructionExecutionUnimplemented("C_SW"), // TODO: C_SW
        .C_SD => return instructionExecutionUnimplemented("C_SD"), // TODO: C_SD
        .C_NOP => return instructionExecutionUnimplemented("C_NOP"), // TODO: C_NOP
        .C_ADDI => return instructionExecutionUnimplemented("C_ADDI"), // TODO: C_ADDI
        .C_ADDIW => return instructionExecutionUnimplemented("C_ADDIW"), // TODO: C_ADDIW
        .C_LI => return instructionExecutionUnimplemented("C_LI"), // TODO: C_LI
        .C_ADDI16SP => return instructionExecutionUnimplemented("C_ADDI16SP"), // TODO: C_ADDI16SP
        .C_LUI => return instructionExecutionUnimplemented("C_LUI"), // TODO: C_LUI
        .C_SRLI => return instructionExecutionUnimplemented("C_SRLI"), // TODO: C_SRLI
        .C_SRAI => return instructionExecutionUnimplemented("C_SRAI"), // TODO: C_SRAI
        .C_ANDI => return instructionExecutionUnimplemented("C_ANDI"), // TODO: C_ANDI
        .C_SUB => return instructionExecutionUnimplemented("C_SUB"), // TODO: C_SUB
        .C_XOR => return instructionExecutionUnimplemented("C_XOR"), // TODO: C_XOR
        .C_OR => return instructionExecutionUnimplemented("C_OR"), // TODO: C_OR
        .C_AND => return instructionExecutionUnimplemented("C_AND"), // TODO: C_AND
        .C_SUBW => return instructionExecutionUnimplemented("C_SUBW"), // TODO: C_SUBW
        .C_ADDW => return instructionExecutionUnimplemented("C_ADDW"), // TODO: C_ADDW
        .C_J => {
            const z = lib.traceNamed(@src(), "C_J");
            defer z.end();

            // CJ Type

            const imm = instruction.compressed_jump_target.read();
            const result = addSignedToUnsignedWrap(hart.pc, imm);

            if (has_writer) {
                try writer.print(
                    \\C.J - offset: {x}
                    \\  setting pc to pc<{x}> + {x} = {x}
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
        .C_BEQZ => return instructionExecutionUnimplemented("C_BEQZ"), // TODO: C_BEQZ
        .C_BNEZ => return instructionExecutionUnimplemented("C_BNEZ"), // TODO: C_BNEZ
        .C_SLLI => return instructionExecutionUnimplemented("C_SLLI"), // TODO: C_SLLI
        .C_FLDSP => return instructionExecutionUnimplemented("C_FLDSP"), // TODO: C_FLDSP
        .C_LWSP => return instructionExecutionUnimplemented("C_LWSP"), // TODO: C_LWSP
        .C_LDSP => return instructionExecutionUnimplemented("C_LDSP"), // TODO: C_LDSP
        .C_JR => return instructionExecutionUnimplemented("C_JR"), // TODO: C_JR
        .C_MV => return instructionExecutionUnimplemented("C_MV"), // TODO: C_MV
        .C_EBREAK => return instructionExecutionUnimplemented("C_EBREAK"), // TODO: C_EBREAK
        .C_JALR => return instructionExecutionUnimplemented("C_JALR"), // TODO: C_JALR
        .C_ADD => return instructionExecutionUnimplemented("C_ADD"), // TODO: C_ADD
        .C_FSDSP => return instructionExecutionUnimplemented("C_FSDSP"), // TODO: C_FSDSP
        .C_SWSP => return instructionExecutionUnimplemented("C_SWSP"), // TODO: C_SWSP
        .C_SDSP => return instructionExecutionUnimplemented("C_SDSP"), // TODO: C_SDSP
    }

    return true;
}

inline fn instructionExecutionUnimplemented(comptime name: []const u8) bool {
    if (build_options.dont_panic_on_unimplemented) {
        std.debug.print("unimplemented instruction execution for " ++ name, .{});
        return false;
    }
    @panic("unimplemented instruction execution for " ++ name);
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
