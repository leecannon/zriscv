const std = @import("std");
const lib = @import("lib.zig");

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
    comptime options: ExecutionOptions,
    comptime actually_execute: bool,
) !void {
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
                                        return;
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

    try execute(mode, hart, instruction, writer, options, actually_execute);
}

fn execute(
    comptime mode: lib.Mode,
    hart: *lib.Hart(mode),
    instruction: lib.Instruction,
    writer: anytype,
    comptime options: ExecutionOptions,
    comptime actually_execute: bool,
) !void {
    const execute_z = lib.traceNamed(@src(), "execute");
    defer execute_z.end();

    defer if (actually_execute) {
        hart.cycle += 1;
    };

    const has_writer = comptime isWriter(@TypeOf(writer));

    // Order of the branches loosely follows RV32/64G Instruction Set Listings from the RISC-V Unprivledged ISA
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
                        \\LUI - dest: {}, value: <{x}>
                        \\  setting {} to <{x}>
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
                        \\LUI - dest: {}, value: <{x}>
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
                        \\BNE - src1: {}<{x}>, src2: {}<{x}>, offset: <{x}>
                        \\  true
                        \\  setting pc to current ( pc<{x}> + <{x}> ) = <{x}>
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
                        \\BNE - src1: {}<{x}>, src2: {}<{x}>, offset: <{x}>
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
                        \\ADDI - src: {}, dest: {}, imm: <{x}>
                        \\  set {} to ( {}<{x}> + <{x}> ) = <{x}>
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
                        \\ADDI - src: {}, dest: {}, imm: <{x}>
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
                        \\  set {} to ( {}<{x}> + {}<{x}> ) = <{x}>
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
                    \\SD - base: {}, src: {}, imm: <{x}>
                    \\  store 8 bytes from {}<{x}> into memory ( {}<{x}> + <{x}> ) = <{x}>
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
                            return;
                        },
                        else => |e| return e,
                    };
                }

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
                        \\SLLI - src: {}, dest: {}, shmt: <{x}>
                        \\  set {} to ( {}<{x}> << <{x}> ) = <{x}>
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
                        \\SLLI - src: {}, dest: {}, shmt: <{x}>
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
                    return;
                };

            const rd = instruction.rd();
            const rs1 = instruction.rs1();
            const rs1_value = hart.x[@enumToInt(rs1)];

            if (rd != .zero) {
                if (has_writer) {
                    try writer.print(
                        \\CSRRW - csr: {}, dest: {}, source: {}
                        \\  read csr {} into {}
                        \\  set csr {} to {}<{x}>
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
                    return;
                }

                const initial_csr = readCsr(mode, hart, csr);
                try writeCsr(mode, hart, csr, rs1_value);
                hart.x[@enumToInt(rd)] = initial_csr;
            } else {
                if (has_writer) {
                    try writer.print(
                        \\CSRRW - csr: {}, dest: {}, source: {}
                        \\  set csr {} to {}<{x}>
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
                    return;
                }

                try writeCsr(mode, hart, csr, rs1_value);
            }

            hart.pc += 4;
        },
        .C_J => {
            const z = lib.traceNamed(@src(), "C_J");
            defer z.end();

            // CJ Type

            const imm = instruction.compressed_jump_target.read();
            const result = addSignedToUnsignedWrap(hart.pc, imm);

            if (has_writer) {
                try writer.print(
                    \\C.J - offset: <{x}>
                    \\  setting pc to ( pc<{x}> + <{x}> ) = <{x}>
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
        else => |e| std.debug.panic("unimplemented instruction execution for {s}", .{@tagName(e)}),
    }
}

fn readCsr(comptime mode: lib.Mode, hart: *const lib.Hart(mode), csr: lib.Csr) u64 {
    return switch (csr) {
        .cycle => hart.cycle,
        .mhartid => hart.hart_id,
    };
}

fn writeCsr(comptime mode: lib.Mode, hart: *const lib.Hart(mode), csr: lib.Csr, value: u64) !void {
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
    @panic("UNIMPLEMENTED"); // TODO: Exceptions
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
