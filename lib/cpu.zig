const std = @import("std");
const bitjuggle = @import("bitjuggle");
const Csr = @import("csr.zig").Csr;
const Mstatus = @import("csr.zig").Mstatus;
const MCause = @import("csr.zig").MCause;
const Mtvec = @import("csr.zig").Mtvec;
const Stvec = @import("csr.zig").Stvec;
const SCause = @import("csr.zig").SCause;
const Satp = @import("csr.zig").Satp;
const InstructionType = @import("instruction.zig").InstructionType;
const Instruction = @import("instruction.zig").Instruction;
const PrivilegeLevel = @import("types.zig").PrivilegeLevel;
const IntegerRegister = @import("types.zig").IntegerRegister;
const ExceptionCode = @import("types.zig").ExceptionCode;
const ContextStatus = @import("types.zig").ContextStatus;
const VectorMode = @import("types.zig").VectorMode;
const AddressTranslationMode = @import("types.zig").AddressTranslationMode;

const CpuState = @import("CpuState.zig");

pub const CpuOptions = struct {
    writer_type: type = void,

    unrecognised_instruction_is_fatal: bool = true,
    unrecognised_csr_is_fatal: bool = true,
    ebreak_is_fatal: bool = false,
    execution_out_of_bounds_is_fatal: bool = true,

    /// this option is only taken into account if a writer is given
    always_print_pc: bool = true,
};

pub fn Cpu(comptime options: CpuOptions) type {
    return struct {
        pub usingnamespace if (isWriter(options.writer_type)) struct {
            pub fn run(state: *CpuState, writer: options.writer_type) !void {
                while (true) {
                    try step(state, writer);
                }
            }

            pub fn step(state: *CpuState, writer: options.writer_type) !void {
                // This is not 100% compatible with extension C, as the very last 16 bits of memory could be a compressed instruction
                const instruction: Instruction = blk: {
                    if (options.execution_out_of_bounds_is_fatal) {
                        break :blk Instruction{ .backing = try loadMemory(state, 32, state.pc) };
                    } else {
                        const backing = loadMemory(state, 32, state.pc) catch |err| switch (err) {
                            error.ExecutionOutOfBounds => {
                                try throw(state, .InstructionAccessFault, 0, writer);
                                return;
                            },
                            else => |e| return e,
                        };
                        break :blk Instruction{ .backing = backing };
                    }
                };

                if (options.always_print_pc) {
                    try writer.print("pc: {x:0>16}\n", .{state.pc});
                }

                try execute(instruction, state, writer, options);
            }
        } else struct {
            pub fn run(state: *CpuState) !void {
                while (true) {
                    try step(state);
                }
            }

            pub fn step(state: *CpuState) !void {
                const instruction: Instruction = blk: {
                    if (options.execution_out_of_bounds_is_fatal) {
                        break :blk Instruction{ .backing = try loadMemory(state, 32, state.pc) };
                    } else {
                        const backing = loadMemory(state, 32, state.pc) catch |err| switch (err) {
                            error.ExecutionOutOfBounds => {
                                try throw(state, .InstructionAccessFault, 0, {});
                                return;
                            },
                            else => |e| return e,
                        };
                        break :blk Instruction{ .backing = backing };
                    }
                };

                try execute(instruction, state, {}, options);
            }
        };
    };
}

const LoadError = error{
    ExecutionOutOfBounds,
    Unimplemented,
};

fn loadMemory(state: *CpuState, comptime number_of_bits: comptime_int, address: u64) LoadError!std.meta.Int(.unsigned, number_of_bits) {
    const MemoryType = std.meta.Int(.unsigned, number_of_bits);

    if (address + @sizeOf(MemoryType) >= state.memory.len) {
        return LoadError.ExecutionOutOfBounds;
    }

    switch (state.address_translation_mode) {
        .Bare => {
            return std.mem.readIntSlice(MemoryType, state.memory[address..], .Little);
        },
        else => {
            std.log.emerg("Unimplemented address translation mode", .{});
            return LoadError.Unimplemented;
        },
    }
}

const StoreError = error{
    ExecutionOutOfBounds,
    Unimplemented,
};

fn storeMemory(
    state: *CpuState,
    comptime number_of_bits: comptime_int,
    address: u64,
    value: std.meta.Int(.unsigned, number_of_bits),
) StoreError!void {
    const MemoryType = std.meta.Int(.unsigned, number_of_bits);
    const number_of_bytes = @divExact(@typeInfo(MemoryType).Int.bits, 8);

    if (address + @sizeOf(MemoryType) >= state.memory.len) {
        return StoreError.ExecutionOutOfBounds;
    }

    switch (state.address_translation_mode) {
        .Bare => {
            var result: [number_of_bytes]u8 = undefined;
            std.mem.writeInt(MemoryType, &result, value, .Little);
            std.mem.copy(u8, state.memory[address..], &result);
        },
        else => {
            std.log.emerg("Unimplemented address translation mode", .{});
            return StoreError.Unimplemented;
        },
    }
}

fn execute(
    instruction: Instruction,
    state: *CpuState,
    writer: anytype,
    comptime options: CpuOptions,
) !void {
    const has_writer = comptime isWriter(@TypeOf(writer));

    const instruction_type = if (comptime options.unrecognised_instruction_is_fatal)
        try instruction.decode(options.unrecognised_instruction_is_fatal)
    else blk: {
        break :blk instruction.decode(options.unrecognised_instruction_is_fatal) catch {
            try throw(state, .IllegalInstruction, instruction.backing, writer);
            return;
        };
    };

    switch (instruction_type) {
        // 32I

        .LUI => {
            // U-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const imm = instruction.u_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\LUI - dest: {}, value: 0x{x}
                        \\  setting {} to 0x{x}
                        \\
                    , .{
                        rd,
                        imm,
                        rd,
                        imm,
                    });
                }

                state.x[@enumToInt(rd)] = @bitCast(u64, imm);
            } else {
                if (has_writer) {
                    const imm = instruction.u_imm.read();

                    try writer.print(
                        \\LUI - dest: {}, value: 0x{x}
                        \\  nop
                        \\
                    , .{
                        rd,
                        imm,
                    });
                }
            }

            state.pc += 4;
        },
        .AUIPC => {
            // U-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const imm = instruction.u_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\AUIPC - dest: {}, offset: 0x{x}
                        \\  setting {} to current pc (0x{x}) + 0x{x}
                        \\
                    , .{
                        rd,
                        imm,
                        rd,
                        state.pc,
                        imm,
                    });
                }

                state.x[@enumToInt(rd)] = addSignedToUnsignedWrap(state.pc, imm);
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

            state.pc += 4;
        },
        .JAL => {
            // J-type

            const rd = instruction.rd();
            const imm = instruction.j_imm.read();

            if (rd != .zero) {
                if (has_writer) {
                    try writer.print(
                        \\JAL - dest: {}, offset: 0x{x}
                        \\  setting {} to current pc (0x{x}) + 0x4
                        \\  setting pc to current pc (0x{x}) + 0x{x}
                        \\
                    , .{
                        rd,
                        imm,
                        rd,
                        state.pc,
                        state.pc,
                        imm,
                    });
                }

                state.x[@enumToInt(rd)] = state.pc + 4;
            } else {
                if (has_writer) {
                    try writer.print(
                        \\JAL - dest: {}, offset: 0x{x}
                        \\  setting pc to current pc (0x{x}) + 0x{x}
                        \\
                    , .{
                        rd,
                        imm,
                        state.pc,
                        imm,
                    });
                }
            }

            state.pc = addSignedToUnsignedWrap(state.pc, imm);
        },
        .JALR => {
            // I-type

            const imm = instruction.i_imm.read();
            const rs1 = instruction.rs1();
            const rd = instruction.rd();

            const rs1_inital = state.x[@enumToInt(rs1)];

            if (rd != .zero) {
                if (has_writer) {
                    try writer.print(
                        \\JALR - dest: {}, base: {}, offset: 0x{x}
                        \\  setting {} to current pc (0x{x}) + 0x4
                        \\  setting pc to {} + 0x{x}
                        \\
                    , .{
                        rd,
                        rs1,
                        imm,
                        rd,
                        state.pc,
                        rs1,
                        imm,
                    });
                }

                state.x[@enumToInt(rd)] = state.pc + 4;
            } else {
                if (has_writer) {
                    try writer.print(
                        \\JALR - dest: {}, base: {}, offset: 0x{x}
                        \\  setting pc to {} + 0x{x}
                        \\
                    , .{
                        rd,
                        rs1,
                        imm,
                        rs1,
                        imm,
                    });
                }
            }

            state.pc = addSignedToUnsignedWrap(rs1_inital, imm) & ~@as(u64, 1);
        },
        .BEQ => {
            // B-type

            const rs1 = instruction.rs1();
            const rs2 = instruction.rs2();

            if (state.x[@enumToInt(rs1)] == state.x[@enumToInt(rs2)]) {
                const imm = instruction.b_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\BEQ - src1: {}, src2: {}, offset: 0x{x}
                        \\  true
                        \\  setting pc to current pc (0x{x}) + 0x{x}
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        state.pc,
                        imm,
                    });
                }

                state.pc = addSignedToUnsignedWrap(state.pc, imm);
            } else {
                if (has_writer) {
                    const imm = instruction.b_imm.read();

                    try writer.print(
                        \\BEQ - src1: {}, src2: {}, offset: 0x{x}
                        \\  false
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                    });
                }

                state.pc += 4;
            }
        },
        .BNE => {
            // B-type

            const rs1 = instruction.rs1();
            const rs2 = instruction.rs2();

            if (state.x[@enumToInt(rs1)] != state.x[@enumToInt(rs2)]) {
                const imm = instruction.b_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\BNE - src1: {}, src2: {}, offset: 0x{x}
                        \\  true
                        \\  setting pc to current pc (0x{x}) + 0x{x}
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        state.pc,
                        imm,
                    });
                }

                state.pc = addSignedToUnsignedWrap(state.pc, imm);
            } else {
                if (has_writer) {
                    const imm = instruction.b_imm.read();

                    try writer.print(
                        \\BNE - src1: {}, src2: {}, offset: 0x{x}
                        \\  false
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                    });
                }

                state.pc += 4;
            }
        },
        .BLT => {
            // B-type

            const rs1 = instruction.rs1();
            const rs2 = instruction.rs2();

            if (@bitCast(i64, state.x[@enumToInt(rs1)]) < @bitCast(i64, state.x[@enumToInt(rs2)])) {
                const imm = instruction.b_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\BLT - src1: {}, src2: {}, offset: 0x{x}
                        \\  true
                        \\  setting pc to current pc (0x{x}) + 0x{x}
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        state.pc,
                        imm,
                    });
                }

                state.pc = addSignedToUnsignedWrap(state.pc, imm);
            } else {
                if (has_writer) {
                    const imm = instruction.b_imm.read();

                    try writer.print(
                        \\BLT - src1: {}, src2: {}, offset: 0x{x}
                        \\  false
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                    });
                }

                state.pc += 4;
            }
        },
        .BGE => {
            // B-type

            const rs1 = instruction.rs1();
            const rs2 = instruction.rs2();

            if (@bitCast(i64, state.x[@enumToInt(rs1)]) >= @bitCast(i64, state.x[@enumToInt(rs2)])) {
                const imm = instruction.b_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\BGE - src1: {}, src2: {}, offset: 0x{x}
                        \\  true
                        \\  setting pc to current pc (0x{x}) + 0x{x}
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        state.pc,
                        imm,
                    });
                }

                state.pc = addSignedToUnsignedWrap(state.pc, imm);
            } else {
                if (has_writer) {
                    const imm = instruction.b_imm.read();

                    try writer.print(
                        \\BGE - src1: {}, src2: {}, offset: 0x{x}
                        \\  false
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                    });
                }

                state.pc += 4;
            }
        },
        .BLTU => {
            // B-type

            const rs1 = instruction.rs1();
            const rs2 = instruction.rs2();

            if (state.x[@enumToInt(rs1)] < state.x[@enumToInt(rs2)]) {
                const imm = instruction.b_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\BLTU - src1: {}, src2: {}, offset: 0x{x}
                        \\  true
                        \\  setting pc to current pc (0x{x}) + 0x{x}
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        state.pc,
                        imm,
                    });
                }

                state.pc = addSignedToUnsignedWrap(state.pc, imm);
            } else {
                if (has_writer) {
                    const imm = instruction.b_imm.read();

                    try writer.print(
                        \\BLTU - src1: {}, src2: {}, offset: 0x{x}
                        \\  false
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                    });
                }

                state.pc += 4;
            }
        },
        .BGEU => {
            // B-type

            const rs1 = instruction.rs1();
            const rs2 = instruction.rs2();

            if (state.x[@enumToInt(rs1)] >= state.x[@enumToInt(rs2)]) {
                const imm = instruction.b_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\BGEU - src1: {}, src2: {}, offset: 0x{x}
                        \\  true
                        \\  setting pc to current pc (0x{x}) + 0x{x}
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                        state.pc,
                        imm,
                    });
                }

                state.pc = addSignedToUnsignedWrap(state.pc, imm);
            } else {
                if (has_writer) {
                    const imm = instruction.b_imm.read();

                    try writer.print(
                        \\BGEU - src1: {}, src2: {}, offset: 0x{x}
                        \\  false
                        \\
                    , .{
                        rs1,
                        rs2,
                        imm,
                    });
                }

                state.pc += 4;
            }
        },
        .LB => {
            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\LB - base: {}, dest: {}, imm: 0x{x}
                        \\  load 1 byte sign extended into {} from memory {} + 0x{x}
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        imm,
                    });
                }

                const address = addSignedToUnsignedWrap(state.x[@enumToInt(rs1)], imm);

                const memory = if (options.execution_out_of_bounds_is_fatal)
                    try loadMemory(state, 8, address)
                else blk: {
                    break :blk loadMemory(state, 8, address) catch |err| switch (err) {
                        LoadError.ExecutionOutOfBounds => {
                            try throw(state, .LoadAccessFault, 0, writer);
                            return;
                        },
                        else => |e| return e,
                    };
                };

                state.x[@enumToInt(rd)] = signExtend8bit(memory);
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\LB - base: {}, dest: {}, imm: 0x{x}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                    });
                }
            }

            state.pc += 4;
        },
        .LH => {
            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\LH - base: {}, dest: {}, imm: 0x{x}
                        \\  load 2 bytes sign extended into {} from memory {} + 0x{x}
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        imm,
                    });
                }

                const address = addSignedToUnsignedWrap(state.x[@enumToInt(rs1)], imm);

                const memory = if (options.execution_out_of_bounds_is_fatal)
                    try loadMemory(state, 16, address)
                else blk: {
                    break :blk loadMemory(state, 16, address) catch |err| switch (err) {
                        LoadError.ExecutionOutOfBounds => {
                            try throw(state, .LoadAccessFault, 0, writer);
                            return;
                        },
                        else => |e| return e,
                    };
                };

                state.x[@enumToInt(rd)] = signExtend16bit(memory);
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\LH - base: {}, dest: {}, imm: 0x{x}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                    });
                }
            }

            state.pc += 4;
        },
        .LW => {
            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\LW - base: {}, dest: {}, imm: 0x{x}
                        \\  load 4 bytes sign extended into {} from memory {} + 0x{x}
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        imm,
                    });
                }

                const address = addSignedToUnsignedWrap(state.x[@enumToInt(rs1)], imm);

                const memory = if (options.execution_out_of_bounds_is_fatal)
                    try loadMemory(state, 32, address)
                else blk: {
                    break :blk loadMemory(state, 32, address) catch |err| switch (err) {
                        LoadError.ExecutionOutOfBounds => {
                            try throw(state, .LoadAccessFault, 0, writer);
                            return;
                        },
                        else => |e| return e,
                    };
                };

                state.x[@enumToInt(rd)] = signExtend32bit(memory);
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\LW - base: {}, dest: {}, imm: 0x{x}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                    });
                }
            }

            state.pc += 4;
        },
        .LBU => {
            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\LBU - base: {}, dest: {}, imm: 0x{x}
                        \\  load 1 byte into {} from memory {} + 0x{x}
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        imm,
                    });
                }

                const address = addSignedToUnsignedWrap(state.x[@enumToInt(rs1)], imm);

                const memory = if (options.execution_out_of_bounds_is_fatal)
                    try loadMemory(state, 8, address)
                else blk: {
                    break :blk loadMemory(state, 8, address) catch |err| switch (err) {
                        LoadError.ExecutionOutOfBounds => {
                            try throw(state, .LoadAccessFault, 0, writer);
                            return;
                        },
                        else => |e| return e,
                    };
                };

                state.x[@enumToInt(rd)] = memory;
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\LBU - base: {}, dest: {}, imm: 0x{x}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                    });
                }
            }

            state.pc += 4;
        },
        .LHU => {
            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\LHU - base: {}, dest: {}, imm: 0x{x}
                        \\  load 2 bytes into {} from memory {} + 0x{x}
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        imm,
                    });
                }

                const address = addSignedToUnsignedWrap(state.x[@enumToInt(rs1)], imm);

                const memory = if (options.execution_out_of_bounds_is_fatal)
                    try loadMemory(state, 16, address)
                else blk: {
                    break :blk loadMemory(state, 16, address) catch |err| switch (err) {
                        LoadError.ExecutionOutOfBounds => {
                            try throw(state, .LoadAccessFault, 0, writer);
                            return;
                        },
                        else => |e| return e,
                    };
                };

                state.x[@enumToInt(rd)] = memory;
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\LHU - base: {}, dest: {}, imm: 0x{x}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                    });
                }
            }

            state.pc += 4;
        },
        .SB => {
            // S-type

            const rs1 = instruction.rs1();
            const rs2 = instruction.rs2();
            const imm = instruction.s_imm.read();

            if (has_writer) {
                try writer.print(
                    \\SB - base: {}, src: {}, imm: 0x{x}
                    \\  store 1 byte from {} into memory {} + 0x{x}
                    \\
                , .{
                    rs1,
                    rs2,
                    imm,
                    rs2,
                    rs1,
                    imm,
                });
            }

            const address = addSignedToUnsignedWrap(state.x[@enumToInt(rs1)], imm);

            if (options.execution_out_of_bounds_is_fatal) {
                try storeMemory(state, 8, address, @truncate(u8, state.x[@enumToInt(rs2)]));
            } else {
                storeMemory(state, 8, address, @truncate(u8, state.x[@enumToInt(rs2)])) catch |err| switch (err) {
                    StoreError.ExecutionOutOfBounds => {
                        try throw(state, .@"Store/AMOAccessFault", 0, writer);
                        return;
                    },
                    else => |e| return e,
                };
            }

            state.pc += 4;
        },
        .SH => {
            // S-type

            const rs1 = instruction.rs1();
            const rs2 = instruction.rs2();
            const imm = instruction.s_imm.read();

            if (has_writer) {
                try writer.print(
                    \\SH - base: {}, src: {}, imm: 0x{x}
                    \\  store 2 bytes from {} into memory {} + 0x{x}
                    \\
                , .{
                    rs1,
                    rs2,
                    imm,
                    rs2,
                    rs1,
                    imm,
                });
            }

            const address = addSignedToUnsignedWrap(state.x[@enumToInt(rs1)], imm);

            if (options.execution_out_of_bounds_is_fatal) {
                try storeMemory(state, 16, address, @truncate(u16, state.x[@enumToInt(rs2)]));
            } else {
                storeMemory(state, 16, address, @truncate(u16, state.x[@enumToInt(rs2)])) catch |err| switch (err) {
                    StoreError.ExecutionOutOfBounds => {
                        try throw(state, .@"Store/AMOAccessFault", 0, writer);
                        return;
                    },
                    else => |e| return e,
                };
            }

            state.pc += 4;
        },
        .SW => {
            // S-type

            const rs1 = instruction.rs1();
            const rs2 = instruction.rs2();
            const imm = instruction.s_imm.read();

            if (has_writer) {
                try writer.print(
                    \\SW - base: {}, src: {}, imm: 0x{x}
                    \\  store 4 bytes from {} into memory {} + 0x{x}
                    \\
                , .{
                    rs1,
                    rs2,
                    imm,
                    rs2,
                    rs1,
                    imm,
                });
            }

            const address = addSignedToUnsignedWrap(state.x[@enumToInt(rs1)], imm);

            if (options.execution_out_of_bounds_is_fatal) {
                try storeMemory(state, 32, address, @truncate(u32, state.x[@enumToInt(rs2)]));
            } else {
                storeMemory(state, 32, address, @truncate(u32, state.x[@enumToInt(rs2)])) catch |err| switch (err) {
                    StoreError.ExecutionOutOfBounds => {
                        try throw(state, .@"Store/AMOAccessFault", 0, writer);
                        return;
                    },
                    else => |e| return e,
                };
            }

            state.pc += 4;
        },
        .SD => {
            // S-type

            const rs1 = instruction.rs1();
            const rs2 = instruction.rs2();
            const imm = instruction.s_imm.read();

            if (has_writer) {
                try writer.print(
                    \\SD - base: {}, src: {}, imm: 0x{x}
                    \\  store 8 bytes from {} into memory {} + 0x{x}
                    \\
                , .{
                    rs1,
                    rs2,
                    imm,
                    rs2,
                    rs1,
                    imm,
                });
            }

            const address = addSignedToUnsignedWrap(state.x[@enumToInt(rs1)], imm);

            if (options.execution_out_of_bounds_is_fatal) {
                try storeMemory(state, 64, address, state.x[@enumToInt(rs2)]);
            } else {
                storeMemory(state, 64, address, state.x[@enumToInt(rs2)]) catch |err| switch (err) {
                    StoreError.ExecutionOutOfBounds => {
                        try throw(state, .@"Store/AMOAccessFault", 0, writer);
                        return;
                    },
                    else => |e| return e,
                };
            }

            state.pc += 4;
        },
        .ADDI => {
            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\ADDI - src: {}, dest: {}, imm: 0x{x}
                        \\  set {} to {} + 0x{x}
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        imm,
                    });
                }

                state.x[@enumToInt(rd)] = addSignedToUnsignedIgnoreOverflow(state.x[@enumToInt(rs1)], imm);
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\ADDI - src: {}, dest: {}, imm: 0x{x}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                    });
                }
            }

            state.pc += 4;
        },
        .SLTI => {
            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\SLTI - src: {}, dest: {}, imm: 0x{x}
                        \\  set {} to {} < 0x{x} ? 1 : 0
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        imm,
                    });
                }

                state.x[@enumToInt(rd)] = @boolToInt(@bitCast(i64, state.x[@enumToInt(rs1)]) < imm);
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\SLTI - src: {}, dest: {}, imm: 0x{x}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                    });
                }
            }

            state.pc += 4;
        },
        .SLTIU => {
            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\SLTIU - src: {}, dest: {}, imm: 0x{x}
                        \\  set {} to {} < 0x{x} ? 1 : 0
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        imm,
                    });
                }

                state.x[@enumToInt(rd)] = @boolToInt(state.x[@enumToInt(rs1)] < @bitCast(u64, imm));
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\SLTIU - src: {}, dest: {}, imm: 0x{x}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                    });
                }
            }

            state.pc += 4;
        },
        .XORI => {
            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\XORI - src: {}, dest: {}, imm: 0x{x}
                        \\  set {} to {} ^ 0x{x}
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        imm,
                    });
                }

                state.x[@enumToInt(rd)] = state.x[@enumToInt(rs1)] ^ @bitCast(u64, imm);
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\XORI - src: {}, dest: {}, imm: 0x{x}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                    });
                }
            }

            state.pc += 4;
        },
        .ORI => {
            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\ORI - src: {}, dest: {}, imm: 0x{x}
                        \\  set {} to {} | 0x{x}
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        imm,
                    });
                }

                state.x[@enumToInt(rd)] = state.x[@enumToInt(rs1)] | @bitCast(u64, imm);
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

            state.pc += 4;
        },
        .ANDI => {
            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\ANDI - src: {}, dest: {}, imm: 0x{x}
                        \\  set {} to {} & 0x{x}
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        imm,
                    });
                }

                state.x[@enumToInt(rd)] = state.x[@enumToInt(rs1)] & @bitCast(u64, imm);
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\ANDI - src: {}, dest: {}, imm: 0x{x}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                    });
                }
            }

            state.pc += 4;
        },
        .SLLI => {
            // I-type specialization

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const shmt = instruction.i_specialization.fullShift();

                if (has_writer) {
                    try writer.print(
                        \\SLLI - src: {}, dest: {}, shmt: {}
                        \\  set {} to {} << {}
                        \\
                    , .{
                        rs1,
                        rd,
                        shmt,
                        rd,
                        rs1,
                        shmt,
                    });
                }

                state.x[@enumToInt(rd)] = state.x[@enumToInt(rs1)] << shmt;
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

            state.pc += 4;
        },
        .SRLI => {
            // I-type specialization

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const shmt = instruction.i_specialization.fullShift();

                if (has_writer) {
                    try writer.print(
                        \\SRLI - src: {}, dest: {}, shmt: {}
                        \\  set {} to {} >> {}
                        \\
                    , .{
                        rs1,
                        rd,
                        shmt,
                        rd,
                        rs1,
                        shmt,
                    });
                }

                state.x[@enumToInt(rd)] = state.x[@enumToInt(rs1)] >> shmt;
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const shmt = instruction.i_specialization.fullShift();

                    try writer.print(
                        \\SRLI - src: {}, dest: {}, shmt: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        shmt,
                    });
                }
            }

            state.pc += 4;
        },
        .SRAI => {
            // I-type specialization

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const shmt = instruction.i_specialization.fullShift();

                if (has_writer) {
                    try writer.print(
                        \\SRAI - src: {}, dest: {}, shmt: {}
                        \\  set {} to {} >> arithmetic {}
                        \\
                    , .{
                        rs1,
                        rd,
                        shmt,
                        rd,
                        rs1,
                        shmt,
                    });
                }

                state.x[@enumToInt(rd)] = @bitCast(u64, @bitCast(i64, state.x[@enumToInt(rs1)]) >> shmt);
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

            state.pc += 4;
        },
        .ADD => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\ADD - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} + {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                _ = @addWithOverflow(u64, state.x[@enumToInt(rs1)], state.x[@enumToInt(rs2)], &state.x[@enumToInt(rd)]);
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

            state.pc += 4;
        },
        .SUB => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\ADD - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} - {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                _ = @subWithOverflow(u64, state.x[@enumToInt(rs1)], state.x[@enumToInt(rs2)], &state.x[@enumToInt(rd)]);
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

            state.pc += 4;
        },
        .SLL => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\SLL - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} << {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                state.x[@enumToInt(rd)] = state.x[@enumToInt(rs1)] << @truncate(u6, state.x[@enumToInt(rs2)]);
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

            state.pc += 4;
        },
        .SLT => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\SLT - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} < {} ? 1 : 0
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                state.x[@enumToInt(rd)] = @boolToInt(@bitCast(i64, state.x[@enumToInt(rs1)]) < @bitCast(i64, state.x[@enumToInt(rs2)]));
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

            state.pc += 4;
        },
        .SLTU => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\SLT - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} < {} ? 1 : 0
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                state.x[@enumToInt(rd)] = @boolToInt(state.x[@enumToInt(rs1)] < state.x[@enumToInt(rs2)]);
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

            state.pc += 4;
        },
        .XOR => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\XOR - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} ^ {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                state.x[@enumToInt(rd)] = state.x[@enumToInt(rs1)] ^ state.x[@enumToInt(rs2)];
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\XOR - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },
        .SRL => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\SRL - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} >> {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                state.x[@enumToInt(rd)] = state.x[@enumToInt(rs1)] >> @truncate(u6, state.x[@enumToInt(rs2)]);
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

            state.pc += 4;
        },
        .SRA => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\SRA - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} >> {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                state.x[@enumToInt(rd)] = @bitCast(u64, @bitCast(i64, state.x[@enumToInt(rs1)]) >> @truncate(u6, state.x[@enumToInt(rs2)]));
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

            state.pc += 4;
        },
        .AND => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\AND - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} & {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                state.x[@enumToInt(rd)] = state.x[@enumToInt(rs1)] & state.x[@enumToInt(rs2)];
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

            state.pc += 4;
        },
        .OR => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\OR - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} | {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                state.x[@enumToInt(rd)] = state.x[@enumToInt(rs1)] | state.x[@enumToInt(rs2)];
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

            state.pc += 4;
        },
        .FENCE => {
            if (has_writer) {
                try writer.print("FENCE\n", .{});
            }

            state.pc += 4;
        },
        .ECALL => {
            // I-type
            if (has_writer) {
                try writer.print("ECALL\n", .{});
            }

            switch (state.privilege_level) {
                .User => try throw(state, .EnvironmentCallFromUMode, 0, writer),
                .Supervisor => try throw(state, .EnvironmentCallFromSMode, 0, writer),
                .Machine => try throw(state, .EnvironmentCallFromMMode, 0, writer),
            }
        },
        .EBREAK => {
            // I-type
            if (has_writer) {
                try writer.print("EBREAK\n", .{});
            }

            if (options.ebreak_is_fatal) return error.EBreak;

            try throw(state, .Breakpoint, 0, writer);
        },

        // 64I

        .LWU => {
            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\LWU - base: {}, dest: {}, imm: 0x{x}
                        \\  load 4 bytes into {} from memory {} + 0x{x}
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        imm,
                    });
                }

                const address = addSignedToUnsignedWrap(state.x[@enumToInt(rs1)], imm);

                const memory = if (options.execution_out_of_bounds_is_fatal)
                    try loadMemory(state, 32, address)
                else blk: {
                    break :blk loadMemory(state, 32, address) catch |err| switch (err) {
                        LoadError.ExecutionOutOfBounds => {
                            try throw(state, .LoadAccessFault, 0, writer);
                            return;
                        },
                        else => |e| return e,
                    };
                };

                state.x[@enumToInt(rd)] = memory;
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\LWU - base: {}, dest: {}, imm: 0x{x}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                    });
                }
            }

            state.pc += 4;
        },
        .LD => {
            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\LD - base: {}, dest: {}, imm: 0x{x}
                        \\  load 8 bytes into {} from memory {} + 0x{x}
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        imm,
                    });
                }

                const address = addSignedToUnsignedWrap(state.x[@enumToInt(rs1)], imm);

                const memory = if (options.execution_out_of_bounds_is_fatal)
                    try loadMemory(state, 64, address)
                else blk: {
                    break :blk loadMemory(state, 64, address) catch |err| switch (err) {
                        LoadError.ExecutionOutOfBounds => {
                            try throw(state, .LoadAccessFault, 0, writer);
                            return;
                        },
                        else => |e| return e,
                    };
                };

                state.x[@enumToInt(rd)] = memory;
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

            state.pc += 4;
        },
        .ADDIW => {
            // I-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                if (has_writer) {
                    try writer.print(
                        \\ADDIW - src: {}, dest: {}, imm: 0x{x}
                        \\  32bit set {} to {} + 0x{x}
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                        rd,
                        rs1,
                        imm,
                    });
                }

                const addition_result_32bit = addSignedToUnsignedIgnoreOverflow(state.x[@enumToInt(rs1)], imm) & 0xFFFFFFFF;
                state.x[@enumToInt(rd)] = signExtend32bit(addition_result_32bit);
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const imm = instruction.i_imm.read();

                    try writer.print(
                        \\ADDIW - src: {}, dest: {}, imm: 0x{x}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        imm,
                    });
                }
            }

            state.pc += 4;
        },
        .SLLIW => {
            // I-type specialization

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const shmt = instruction.i_specialization.smallShift();

                if (has_writer) {
                    try writer.print(
                        \\SLLIW - src: {}, dest: {}, shmt: {}
                        \\  set {} to {} << {}
                        \\
                    , .{
                        rs1,
                        rd,
                        shmt,
                        rd,
                        rs1,
                        shmt,
                    });
                }

                state.x[@enumToInt(rd)] = signExtend32bit(@truncate(u32, state.x[@enumToInt(rs1)]) << shmt);
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

            state.pc += 4;
        },
        .SRLIW => {
            // I-type specialization

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const shmt = instruction.i_specialization.smallShift();

                if (has_writer) {
                    try writer.print(
                        \\SRLIW - src: {}, dest: {}, shmt: {}
                        \\  32 bit set {} to {} >> {}
                        \\
                    , .{
                        rs1,
                        rd,
                        shmt,
                        rd,
                        rs1,
                        shmt,
                    });
                }

                state.x[@enumToInt(rd)] = signExtend32bit(@truncate(u32, state.x[@enumToInt(rs1)]) >> shmt);
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const shmt = instruction.i_specialization.fullShift();

                    try writer.print(
                        \\SRLIW - src: {}, dest: {}, shmt: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rd,
                        shmt,
                    });
                }
            }

            state.pc += 4;
        },
        .SRAIW => {
            // I-type specialization

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const shmt = instruction.i_specialization.smallShift();

                if (has_writer) {
                    try writer.print(
                        \\SRAI - src: {}, dest: {}, shmt: {}
                        \\  set {} to {} >> arithmetic {}
                        \\
                    , .{
                        rs1,
                        rd,
                        shmt,
                        rd,
                        rs1,
                        shmt,
                    });
                }

                state.x[@enumToInt(rd)] = signExtend32bit(@bitCast(u32, @bitCast(i32, @truncate(u32, state.x[@enumToInt(rs1)])) >> shmt));
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

            state.pc += 4;
        },
        .ADDW => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\ADDW - src1: {}, src2: {}, dest: {}
                        \\  32 bit set {} to {} + {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                var result: u32 = undefined;
                _ = @addWithOverflow(u32, @truncate(u32, state.x[@enumToInt(rs1)]), @truncate(u32, state.x[@enumToInt(rs2)]), &result);
                state.x[@enumToInt(rd)] = signExtend32bit(result);
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

            state.pc += 4;
        },
        .SUBW => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\SUBW - src1: {}, src2: {}, dest: {}
                        \\  32 bit set {} to {} - {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                var result: u32 = undefined;
                _ = @subWithOverflow(u32, @truncate(u32, state.x[@enumToInt(rs1)]), @truncate(u32, state.x[@enumToInt(rs2)]), &result);
                state.x[@enumToInt(rd)] = signExtend32bit(result);
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\SUBW - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },
        .SLLW => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\SLLW - src1: {}, src2: {}, dest: {}
                        \\  32 bit set {} to {} << {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                state.x[@enumToInt(rd)] = signExtend32bit(@truncate(u32, state.x[@enumToInt(rs1)]) << @truncate(u5, state.x[@enumToInt(rs2)]));
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

            state.pc += 4;
        },
        .SRLW => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\SRLW - src1: {}, src2: {}, dest: {}
                        \\  32 bit set {} to {} >> {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                state.x[@enumToInt(rd)] = signExtend32bit(@truncate(u32, state.x[@enumToInt(rs1)]) >> @truncate(u5, state.x[@enumToInt(rs2)]));
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\SRLW - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },
        .SRAW => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\SRAW - src1: {}, src2: {}, dest: {}
                        \\  32 bit set {} to {} >> {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                state.x[@enumToInt(rd)] = signExtend32bit(@bitCast(u32, @bitCast(i32, @truncate(u32, state.x[@enumToInt(rs1)])) >> @truncate(u5, state.x[@enumToInt(rs2)])));
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

            state.pc += 4;
        },

        // Zicsr

        .CSRRW => {
            // I-type

            const csr = if (comptime options.unrecognised_csr_is_fatal) try Csr.getCsr(instruction.csr.read()) else blk: {
                break :blk Csr.getCsr(instruction.csr.read()) catch {
                    try throw(state, .IllegalInstruction, instruction.backing, writer);
                    return;
                };
            };

            const rd = instruction.rd();
            const rs1 = instruction.rs1();

            if (rd != .zero) {
                if (has_writer) {
                    try writer.print(
                        \\CSRRW - csr: {s}, dest: {}, source: {}
                        \\  read csr {s} into {}
                        \\  set csr {s} to {}
                        \\
                    , .{
                        @tagName(csr),
                        rd,
                        rs1,
                        @tagName(csr),
                        rd,
                        @tagName(csr),
                        rs1,
                    });
                }

                if (!csr.canWrite(state.privilege_level)) {
                    try throw(state, .IllegalInstruction, instruction.backing, writer);
                    return;
                }

                const initial_rs1 = state.x[@enumToInt(rs1)];
                const initial_csr = readCsr(state, csr);

                try writeCsr(state, csr, initial_rs1);
                state.x[@enumToInt(rd)] = initial_csr;
            } else {
                if (has_writer) {
                    try writer.print(
                        \\CSRRW - csr: {s}, dest: {}, source: {}
                        \\  set csr {s} to {}
                        \\
                    , .{
                        @tagName(csr),
                        rd,
                        rs1,
                        @tagName(csr),
                        rs1,
                    });
                }

                if (!csr.canWrite(state.privilege_level)) {
                    try throw(state, .IllegalInstruction, instruction.backing, writer);
                    return;
                }

                try writeCsr(state, csr, state.x[@enumToInt(rs1)]);
            }

            state.pc += 4;
        },
        .CSRRS => {
            // I-type

            const csr = if (comptime options.unrecognised_csr_is_fatal) try Csr.getCsr(instruction.csr.read()) else blk: {
                break :blk Csr.getCsr(instruction.csr.read()) catch {
                    try throw(state, .IllegalInstruction, instruction.backing, writer);
                    return;
                };
            };

            const rd = instruction.rd();
            const rs1 = instruction.rs1();

            if (rs1 != .zero and rd != .zero) {
                if (has_writer) {
                    try writer.print(
                        \\CSRRS - csr: {s}, dest: {}, source: {}
                        \\  read csr {s} into {}
                        \\  set bits in csr {s} using mask in {}
                        \\
                    , .{
                        @tagName(csr),
                        rd,
                        rs1,
                        @tagName(csr),
                        rd,
                        @tagName(csr),
                        rs1,
                    });
                }

                if (!csr.canWrite(state.privilege_level)) {
                    try throw(state, .IllegalInstruction, instruction.backing, writer);
                    return;
                }

                const initial_rs1 = state.x[@enumToInt(rs1)];
                const initial_csr_value = readCsr(state, csr);

                try writeCsr(state, csr, initial_csr_value | initial_rs1);
                state.x[@enumToInt(rd)] = initial_csr_value;
            } else if (rs1 != .zero) {
                if (has_writer) {
                    try writer.print(
                        \\CSRRS - csr: {s}, dest: {}, source: {}
                        \\  set bits in csr {s} using mask in {}
                        \\
                    , .{
                        @tagName(csr),
                        rd,
                        rs1,
                        @tagName(csr),
                        rs1,
                    });
                }

                if (!csr.canWrite(state.privilege_level)) {
                    try throw(state, .IllegalInstruction, instruction.backing, writer);
                    return;
                }

                try writeCsr(state, csr, readCsr(state, csr) | state.x[@enumToInt(rs1)]);
            } else if (rd != .zero) {
                if (has_writer) {
                    try writer.print(
                        \\CSRRS - csr: {s}, dest: {}, source: {}
                        \\  read csr {s} into {}
                        \\
                    , .{
                        @tagName(csr),
                        rd,
                        rs1,
                        @tagName(csr),
                        rd,
                    });
                }

                if (!csr.canRead(state.privilege_level)) {
                    try throw(state, .IllegalInstruction, instruction.backing, writer);
                    return;
                }

                state.x[@enumToInt(rd)] = readCsr(state, csr);
            } else {
                if (has_writer) {
                    try writer.print(
                        \\CSRRS - csr: {s}, dest: {}, source: {}
                        \\  nop
                        \\
                    , .{
                        @tagName(csr),
                        rd,
                        rs1,
                    });
                }
            }

            state.pc += 4;
        },
        .CSRRC => {
            // I-type

            const csr = if (comptime options.unrecognised_csr_is_fatal) try Csr.getCsr(instruction.csr.read()) else blk: {
                break :blk Csr.getCsr(instruction.csr.read()) catch {
                    try throw(state, .IllegalInstruction, instruction.backing, writer);
                    return;
                };
            };

            const rd = instruction.rd();
            const rs1 = instruction.rs1();

            if (rs1 != .zero and rd != .zero) {
                if (has_writer) {
                    try writer.print(
                        \\CSRRC - csr: {s}, dest: {}, source: {}
                        \\  read csr {s} into {}
                        \\  clear bits in csr {s} using mask in {}
                        \\
                    , .{
                        @tagName(csr),
                        rd,
                        rs1,
                        @tagName(csr),
                        rd,
                        @tagName(csr),
                        rs1,
                    });
                }

                if (!csr.canWrite(state.privilege_level)) {
                    try throw(state, .IllegalInstruction, instruction.backing, writer);
                    return;
                }

                const initial_rs1 = state.x[@enumToInt(rs1)];
                const initial_csr_value = readCsr(state, csr);

                try writeCsr(state, csr, initial_csr_value & ~initial_rs1);
                state.x[@enumToInt(rd)] = initial_csr_value;
            } else if (rs1 != .zero) {
                if (has_writer) {
                    try writer.print(
                        \\CSRRC - csr: {s}, dest: {}, source: {}
                        \\  clear bits in csr {s} using mask in {}
                        \\
                    , .{
                        @tagName(csr),
                        rd,
                        rs1,
                        @tagName(csr),
                        rs1,
                    });
                }

                if (!csr.canWrite(state.privilege_level)) {
                    try throw(state, .IllegalInstruction, instruction.backing, writer);
                    return;
                }

                try writeCsr(state, csr, readCsr(state, csr) & ~state.x[@enumToInt(rs1)]);
            } else if (rd != .zero) {
                if (has_writer) {
                    try writer.print(
                        \\CSRRC - csr: {s}, dest: {}, source: {}
                        \\  read csr {s} into {}
                        \\
                    , .{
                        @tagName(csr),
                        rd,
                        rs1,
                        @tagName(csr),
                        rd,
                    });
                }

                if (!csr.canRead(state.privilege_level)) {
                    try throw(state, .IllegalInstruction, instruction.backing, writer);
                    return;
                }

                state.x[@enumToInt(rd)] = readCsr(state, csr);
            } else {
                if (has_writer) {
                    try writer.print(
                        \\CSRRC - csr: {s}, dest: {}, source: {}
                        \\  nop
                        \\
                    , .{
                        @tagName(csr),
                        rd,
                        rs1,
                    });
                }
            }

            state.pc += 4;
        },
        .CSRRWI => {
            // I-type

            const csr = if (comptime options.unrecognised_csr_is_fatal) try Csr.getCsr(instruction.csr.read()) else blk: {
                break :blk Csr.getCsr(instruction.csr.read()) catch {
                    try throw(state, .IllegalInstruction, instruction.backing, writer);
                    return;
                };
            };

            const rd = instruction.rd();
            const rs1 = instruction.rs1();

            if (rd != .zero) {
                if (has_writer) {
                    try writer.print(
                        \\CSRRWI - csr: {s}, dest: {}, imm: 0{}
                        \\  read csr {s} into {}
                        \\  set csr {s} to 0{}
                        \\
                    , .{
                        @tagName(csr),
                        rd,
                        rs1,
                        @tagName(csr),
                        rd,
                        @tagName(csr),
                        rs1,
                    });
                }

                if (!csr.canWrite(state.privilege_level)) {
                    try throw(state, .IllegalInstruction, instruction.backing, writer);
                    return;
                }

                const initial_csr_value = readCsr(state, csr);

                try writeCsr(state, csr, @enumToInt(rs1));
                state.x[@enumToInt(rd)] = initial_csr_value;
            } else {
                if (has_writer) {
                    try writer.print(
                        \\CSRRWI - csr: {s}, dest: {}, imm: 0{}
                        \\  set csr {s} to 0{}
                        \\
                    , .{
                        @tagName(csr),
                        rd,
                        rs1,
                        @tagName(csr),
                        rs1,
                    });
                }

                if (!csr.canWrite(state.privilege_level)) {
                    try throw(state, .IllegalInstruction, instruction.backing, writer);
                    return;
                }

                try writeCsr(state, csr, @enumToInt(rs1));
            }

            state.pc += 4;
        },

        // 32M

        .MUL => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\MUL - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} * {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                var result: u64 = undefined;
                _ = @mulWithOverflow(u64, state.x[@enumToInt(rs1)], state.x[@enumToInt(rs2)], &result);
                state.x[@enumToInt(rd)] = result;
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\MUL - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },
        .MULH => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\MULH - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} * {} high bits
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                const mul = signExtend64bit(state.x[@enumToInt(rs1)]) * signExtend64bit(state.x[@enumToInt(rs2)]);
                state.x[@enumToInt(rd)] = @truncate(u64, @bitCast(u128, mul) >> 64);
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\MULH - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },
        .MULHSU => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\MULHSU - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} * {} high bits
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                const mul = signExtend64bit(state.x[@enumToInt(rs1)]) * state.x[@enumToInt(rs2)];
                state.x[@enumToInt(rd)] = @truncate(u64, @bitCast(u128, mul) >> 64);
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\MULHSU - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },
        .MULHU => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\MULHU - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} * {} high bits
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                const mul = @as(u128, state.x[@enumToInt(rs1)]) * @as(u128, state.x[@enumToInt(rs2)]);
                state.x[@enumToInt(rd)] = @truncate(u64, @bitCast(u128, mul) >> 64);
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\MULHU - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },
        .DIV => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\DIV - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} / {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                state.x[@enumToInt(rd)] = @bitCast(
                    u64,
                    std.math.divTrunc(
                        i64,
                        @bitCast(i64, state.x[@enumToInt(rs1)]),
                        @bitCast(i64, state.x[@enumToInt(rs2)]),
                    ) catch |err| switch (err) {
                        error.DivisionByZero => @as(i64, -1),
                        error.Overflow => @as(i64, std.math.minInt(i64)),
                    },
                );
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\DIV - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },
        .DIVU => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\DIVU - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} / {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                state.x[@enumToInt(rd)] = std.math.divTrunc(
                    u64,
                    state.x[@enumToInt(rs1)],
                    state.x[@enumToInt(rs2)],
                ) catch |err| switch (err) {
                    error.DivisionByZero => @bitCast(u64, @as(i64, -1)),
                };
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\DIVU - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },
        .REM => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\REM - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} % {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                const numerator = @bitCast(i64, state.x[@enumToInt(rs1)]);
                const denominator = @bitCast(i64, state.x[@enumToInt(rs2)]);

                state.x[@enumToInt(rd)] = @bitCast(
                    u64,
                    remNegativeDenominator(
                        i64,
                        numerator,
                        denominator,
                    ) catch |err| switch (err) {
                        error.DivisionByZero => numerator,
                        error.Overflow => @as(i64, 0),
                    },
                );
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\REM - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },
        .REMU => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\REMU - src1: {}, src2: {}, dest: {}
                        \\  set {} to {} % {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                const numerator = state.x[@enumToInt(rs1)];
                const denominator = state.x[@enumToInt(rs2)];

                state.x[@enumToInt(rd)] = std.math.rem(u64, numerator, denominator) catch |err| switch (err) {
                    error.DivisionByZero => numerator,
                };
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\REMU - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },

        // 64M

        .MULW => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\MULW - src1: {}, src2: {}, dest: {}
                        \\  32 bit set {} to {} * {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                var result: u32 = undefined;
                _ = @mulWithOverflow(u32, @truncate(u32, state.x[@enumToInt(rs1)]), @truncate(u32, state.x[@enumToInt(rs2)]), &result);
                state.x[@enumToInt(rd)] = signExtend32bit(result);
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\MULW - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },
        .DIVW => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\DIVW - src1: {}, src2: {}, dest: {}
                        \\  32 bit set {} to {} / {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                state.x[@enumToInt(rd)] = signExtend32bit(
                    @bitCast(
                        u32,
                        std.math.divTrunc(
                            i32,
                            @bitCast(i32, @truncate(u32, state.x[@enumToInt(rs1)])),
                            @bitCast(i32, @truncate(u32, state.x[@enumToInt(rs2)])),
                        ) catch |err| switch (err) {
                            error.DivisionByZero => @as(i32, -1),
                            error.Overflow => @as(i32, std.math.minInt(i32)),
                        },
                    ),
                );
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\DIVW - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },
        .DIVUW => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\DIVUW - src1: {}, src2: {}, dest: {}
                        \\  32 bit set {} to {} / {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                state.x[@enumToInt(rd)] = signExtend32bit(
                    std.math.divTrunc(
                        u32,
                        @truncate(u32, state.x[@enumToInt(rs1)]),
                        @truncate(u32, state.x[@enumToInt(rs2)]),
                    ) catch |err| switch (err) {
                        error.DivisionByZero => @bitCast(u32, @as(i32, -1)),
                    },
                );
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\DIVUW - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },
        .REMW => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\REMW - src1: {}, src2: {}, dest: {}
                        \\  32 bit set {} to {} % {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                const numerator = @bitCast(i32, @truncate(u32, state.x[@enumToInt(rs1)]));
                const denominator = @bitCast(i32, @truncate(u32, state.x[@enumToInt(rs2)]));

                state.x[@enumToInt(rd)] = signExtend32bit(
                    @bitCast(
                        u32,
                        remNegativeDenominator(
                            i32,
                            numerator,
                            denominator,
                        ) catch |err| switch (err) {
                            error.DivisionByZero => numerator,
                            error.Overflow => @as(i32, 0),
                        },
                    ),
                );
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\REMW - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },
        .REMUW => {
            // R-type

            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const rs2 = instruction.rs2();

                if (has_writer) {
                    try writer.print(
                        \\REMUW - src1: {}, src2: {}, dest: {}
                        \\  32 bit set {} to {} % {}
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                        rd,
                        rs1,
                        rs2,
                    });
                }

                const numerator = @truncate(u32, state.x[@enumToInt(rs1)]);
                const denominator = @truncate(u32, state.x[@enumToInt(rs2)]);

                state.x[@enumToInt(rd)] = signExtend32bit(
                    std.math.rem(u32, numerator, denominator) catch |err| switch (err) {
                        error.DivisionByZero => numerator,
                    },
                );
            } else {
                if (has_writer) {
                    const rs1 = instruction.rs1();
                    const rs2 = instruction.rs2();

                    try writer.print(
                        \\REMUW - src1: {}, src2: {}, dest: {}
                        \\  nop
                        \\
                    , .{
                        rs1,
                        rs2,
                        rd,
                    });
                }
            }

            state.pc += 4;
        },

        // Privilege

        .MRET => {
            if (has_writer) {
                try writer.print("MRET\n", .{});
            }

            if (state.privilege_level != .Machine) {
                try throw(state, .IllegalInstruction, instruction.backing, writer);
                return;
            }

            if (state.machine_previous_privilege_level != .Machine) state.modify_privilege = false;
            state.machine_interrupts_enabled = state.machine_interrupts_enabled_prior;
            state.privilege_level = state.machine_previous_privilege_level;
            state.machine_interrupts_enabled_prior = true;
            state.machine_previous_privilege_level = .User;

            state.pc = state.mepc;
        },
    }
}

pub fn remNegativeDenominator(comptime T: type, numerator: T, denominator: T) !T {
    @setRuntimeSafety(false);

    if (denominator == 0) return error.DivisionByZero;
    if (@typeInfo(T) == .Int and @typeInfo(T).Int.signedness == .signed and numerator == std.math.minInt(T) and denominator == -1) return error.Overflow;

    if (denominator < 0) {
        var temp: T = undefined;
        if (@mulWithOverflow(T, @divTrunc(numerator, denominator), denominator, &temp)) return error.Overflow;
        return numerator - temp;
    }

    return @rem(numerator, denominator);
}

fn throw(
    state: *CpuState,
    exception: ExceptionCode,
    val: u64,
    writer: anytype,
) !void {
    const has_writer = comptime isWriter(@TypeOf(writer));

    if (state.privilege_level != .Machine and isExceptionDelegated(state, exception)) {
        if (has_writer) {
            try writer.print("exception {s} caught in {s} jumping to {s}\n", .{
                @tagName(exception),
                @tagName(state.privilege_level),
                @tagName(PrivilegeLevel.Supervisor),
            });
        }

        state.scause.code.write(@enumToInt(exception));
        state.scause.interrupt.write(0);

        state.stval = val;

        state.supervisor_previous_privilege_level = state.privilege_level;
        state.mstatus.spp.write(@truncate(u1, @enumToInt(state.privilege_level)));
        state.privilege_level = .Supervisor;

        state.supervisor_interrupts_enabled_prior = state.supervisor_interrupts_enabled;
        state.mstatus.spie.write(@boolToInt(state.supervisor_interrupts_enabled));

        state.supervisor_interrupts_enabled = false;
        state.mstatus.sie.write(0);

        state.sepc = state.pc;
        state.pc = state.supervisor_vector_base_address;

        return;
    }

    if (has_writer) {
        try writer.print("Exception {s} caught in {s} jumping to {s}\n", .{
            @tagName(exception),
            @tagName(state.privilege_level),
            @tagName(PrivilegeLevel.Machine),
        });
    }

    state.mcause.code.write(@enumToInt(exception));
    state.mcause.interrupt.write(0);

    state.mtval = val;

    state.machine_previous_privilege_level = state.privilege_level;
    state.mstatus.mpp.write(@enumToInt(state.privilege_level));
    state.privilege_level = .Machine;

    state.machine_interrupts_enabled_prior = state.machine_interrupts_enabled;
    state.mstatus.mpie.write(@boolToInt(state.machine_interrupts_enabled));

    state.machine_interrupts_enabled = false;
    state.mstatus.mie.write(0);

    state.mepc = state.pc;
    state.pc = state.machine_vector_base_address;
}

fn isExceptionDelegated(state: *const CpuState, exception: ExceptionCode) bool {
    return switch (exception) {
        .InstructionAddressMisaligned => bitjuggle.getBit(state.medeleg, 0) != 0,
        .InstructionAccessFault => bitjuggle.getBit(state.medeleg, 1) != 0,
        .IllegalInstruction => bitjuggle.getBit(state.medeleg, 2) != 0,
        .Breakpoint => bitjuggle.getBit(state.medeleg, 3) != 0,
        .LoadAddressMisaligned => bitjuggle.getBit(state.medeleg, 4) != 0,
        .LoadAccessFault => bitjuggle.getBit(state.medeleg, 5) != 0,
        .@"Store/AMOAddressMisaligned" => bitjuggle.getBit(state.medeleg, 6) != 0,
        .@"Store/AMOAccessFault" => bitjuggle.getBit(state.medeleg, 7) != 0,
        .EnvironmentCallFromUMode => bitjuggle.getBit(state.medeleg, 8) != 0,
        .EnvironmentCallFromSMode => bitjuggle.getBit(state.medeleg, 9) != 0,
        .EnvironmentCallFromMMode => bitjuggle.getBit(state.medeleg, 11) != 0,
        .InstructionPageFault => bitjuggle.getBit(state.medeleg, 12) != 0,
        .LoadPageFault => bitjuggle.getBit(state.medeleg, 13) != 0,
        .Store_AMOPageFault => bitjuggle.getBit(state.medeleg, 15) != 0,
    };
}

fn readCsr(state: *const CpuState, csr: Csr) u64 {
    return switch (csr) {
        .mhartid => state.mhartid,
        .mtvec => state.mtvec.backing,
        .stvec => state.stvec.backing,
        .satp => state.satp.backing,
        .medeleg => state.medeleg,
        .mideleg => state.mideleg,
        .mie => state.mie,
        .mip => state.mip,
        .mstatus => state.mstatus.backing,
        .mepc => state.mepc,
        .mcause => state.mcause.backing,
        .mtval => state.mtval,
        .sepc => state.sepc,
        .scause => state.scause.backing,
        .stval => state.stval,
        .pmpcfg0, .pmpcfg2, .pmpcfg4, .pmpcfg6, .pmpcfg8, .pmpcfg10, .pmpcfg12, .pmpcfg14, .pmpaddr0, .pmpaddr1, .pmpaddr2, .pmpaddr3, .pmpaddr4, .pmpaddr5, .pmpaddr6, .pmpaddr7, .pmpaddr8, .pmpaddr9, .pmpaddr10, .pmpaddr11, .pmpaddr12, .pmpaddr13, .pmpaddr14, .pmpaddr15, .pmpaddr16, .pmpaddr17, .pmpaddr18, .pmpaddr19, .pmpaddr20, .pmpaddr21, .pmpaddr22, .pmpaddr23, .pmpaddr24, .pmpaddr25, .pmpaddr26, .pmpaddr27, .pmpaddr28, .pmpaddr29, .pmpaddr30, .pmpaddr31, .pmpaddr32, .pmpaddr33, .pmpaddr34, .pmpaddr35, .pmpaddr36, .pmpaddr37, .pmpaddr38, .pmpaddr39, .pmpaddr40, .pmpaddr41, .pmpaddr42, .pmpaddr43, .pmpaddr44, .pmpaddr45, .pmpaddr46, .pmpaddr47, .pmpaddr48, .pmpaddr49, .pmpaddr50, .pmpaddr51, .pmpaddr52, .pmpaddr53, .pmpaddr54, .pmpaddr55, .pmpaddr56, .pmpaddr57, .pmpaddr58, .pmpaddr59, .pmpaddr60, .pmpaddr61, .pmpaddr62, .pmpaddr63 => 0,
    };
}

fn writeCsr(state: *CpuState, csr: Csr, value: u64) !void {
    switch (csr) {
        .mhartid => state.mhartid = value,
        .mcause => state.mcause.backing = value,
        .mtval => state.mtval = value,
        .scause => state.scause.backing = value,
        .stval => state.stval = value,
        .sepc => state.sepc = value & ~@as(u64, 0),
        .mstatus => {
            const pending_mstatus = Mstatus{
                .backing = state.mstatus.backing & Mstatus.unmodifiable_mask |
                    value & Mstatus.modifiable_mask,
            };

            const super_previous_level = try PrivilegeLevel.getPrivilegeLevel(pending_mstatus.spp.read());
            const machine_previous_level = try PrivilegeLevel.getPrivilegeLevel(pending_mstatus.mpp.read());
            const floating_point_state = try ContextStatus.getContextStatus(pending_mstatus.fs.read());
            const extension_state = try ContextStatus.getContextStatus(pending_mstatus.xs.read());

            state.supervisor_interrupts_enabled = pending_mstatus.sie.read() != 0;
            state.machine_interrupts_enabled = pending_mstatus.mie.read() != 0;
            state.supervisor_interrupts_enabled_prior = pending_mstatus.spie.read() != 0;
            state.machine_interrupts_enabled_prior = pending_mstatus.mpie.read() != 0;
            state.supervisor_previous_privilege_level = super_previous_level;
            state.machine_previous_privilege_level = machine_previous_level;
            state.floating_point_status = floating_point_state;
            state.extension_status = extension_state;
            state.modify_privilege = pending_mstatus.mprv.read() != 0;
            state.supervisor_user_memory_access = pending_mstatus.sum.read() != 0;
            state.executable_readable = pending_mstatus.mxr.read() != 0;
            state.trap_virtual_memory = pending_mstatus.tvm.read() != 0;
            state.timeout_wait = pending_mstatus.tw.read() != 0;
            state.trap_sret = pending_mstatus.tsr.read() != 0;
            state.state_dirty = pending_mstatus.sd.read() != 0;

            state.mstatus = pending_mstatus;
        },
        .mepc => state.mepc = value & ~@as(u64, 0),
        .mtvec => {
            const pending_mtvec = Mtvec{ .backing = value };

            state.machine_vector_mode = try VectorMode.getVectorMode(pending_mtvec.mode.read());
            state.machine_vector_base_address = pending_mtvec.base.read() << 2;

            state.mtvec = pending_mtvec;
        },
        .stvec => {
            const pending_stvec = Stvec{ .backing = value };

            state.supervisor_vector_mode = try VectorMode.getVectorMode(pending_stvec.mode.read());
            state.supervisor_vector_base_address = pending_stvec.base.read() << 2;

            state.stvec = pending_stvec;
        },
        .satp => {
            const pending_satp = Satp{ .backing = value };

            const address_translation_mode = try AddressTranslationMode.getAddressTranslationMode(pending_satp.mode.read());
            if (address_translation_mode != .Bare) {
                std.log.emerg("unsupported address_translation_mode given: {s}", .{@tagName(address_translation_mode)});
                return error.UnsupportedAddressTranslationMode;
            }

            state.address_translation_mode = address_translation_mode;
            state.asid = pending_satp.asid.read();
            state.ppn_address = pending_satp.ppn.read() * 4096;

            state.satp = pending_satp;
        },
        .medeleg => state.medeleg = value,
        .mideleg => state.mideleg = value,
        .mip => state.mip = value,
        .mie => state.mie = value,
        .pmpcfg0, .pmpcfg2, .pmpcfg4, .pmpcfg6, .pmpcfg8, .pmpcfg10, .pmpcfg12, .pmpcfg14, .pmpaddr0, .pmpaddr1, .pmpaddr2, .pmpaddr3, .pmpaddr4, .pmpaddr5, .pmpaddr6, .pmpaddr7, .pmpaddr8, .pmpaddr9, .pmpaddr10, .pmpaddr11, .pmpaddr12, .pmpaddr13, .pmpaddr14, .pmpaddr15, .pmpaddr16, .pmpaddr17, .pmpaddr18, .pmpaddr19, .pmpaddr20, .pmpaddr21, .pmpaddr22, .pmpaddr23, .pmpaddr24, .pmpaddr25, .pmpaddr26, .pmpaddr27, .pmpaddr28, .pmpaddr29, .pmpaddr30, .pmpaddr31, .pmpaddr32, .pmpaddr33, .pmpaddr34, .pmpaddr35, .pmpaddr36, .pmpaddr37, .pmpaddr38, .pmpaddr39, .pmpaddr40, .pmpaddr41, .pmpaddr42, .pmpaddr43, .pmpaddr44, .pmpaddr45, .pmpaddr46, .pmpaddr47, .pmpaddr48, .pmpaddr49, .pmpaddr50, .pmpaddr51, .pmpaddr52, .pmpaddr53, .pmpaddr54, .pmpaddr55, .pmpaddr56, .pmpaddr57, .pmpaddr58, .pmpaddr59, .pmpaddr60, .pmpaddr61, .pmpaddr62, .pmpaddr63 => {},
    }
}

inline fn isWriter(comptime T: type) bool {
    return std.meta.trait.hasFn("print")(T);
}

inline fn addSignedToUnsignedWrap(unsigned: u64, signed: i64) u64 {
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

inline fn addSignedToUnsignedIgnoreOverflow(unsigned: u64, signed: i64) u64 {
    var result = unsigned;
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

comptime {
    std.testing.refAllDecls(@This());
}
