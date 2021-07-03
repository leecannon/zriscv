const std = @import("std");
const bitjuggle = @import("bitjuggle");
const Instruction = @import("Instruction.zig").Instruction;
const InstructionType = @import("InstructionType.zig").InstructionType;

const Cpu = @This();

memory: []u8,
x: [32]u64 = [_]u64{0} ** 32,
pc: usize = 0,
privilege_level: PrivilegeLevel = .Machine,

mhartid: u64 = 0,

pub fn run(self: *Cpu) !void {
    var instruction: Instruction = undefined;

    while (true) {
        if (std.builtin.mode == .Debug) {
            std.debug.print("\n", .{});
            self.dump();
            std.debug.print("\n", .{});
        }

        try self.fetch(&instruction);
        try self.execute(instruction);
    }
}

fn fetch(self: *const Cpu, instruction: *Instruction) !void {
    // This is not 100% compatible with extension C, as the very last 16 bits of memory could be
    // a compressed instruction, the below check will fail in that case
    if (self.pc + 3 >= self.memory.len) return error.ExecutionOutOfBounds;
    instruction.backing = std.mem.readIntSlice(u32, self.memory[self.pc..], .Little);
}

fn decode(self: Instruction) !InstructionType {
    return switch (self.opcode.read()) {
        0b0110111 => InstructionType.LUI,
        0b0010111 => InstructionType.AUIPC,
        0b1101111 => InstructionType.JAL,
        // BRANCH
        0b1100011 => switch (self.funct3.read()) {
            0b000 => InstructionType.BEQ,
            0b001 => InstructionType.BNE,
            0b101 => InstructionType.BGE,
            else => |funct3| {
                std.log.emerg("unimplemented funct3: BRANCH/{b:0>3}", .{funct3});
                return error.UnimplementedOpcode;
            },
        },
        // OP-IMM
        0b0010011 => switch (self.funct3.read()) {
            0b000 => InstructionType.ADDI,
            0b001 => InstructionType.SLLI,
            else => |funct3| {
                std.log.emerg("unimplemented funct3: OP-IMM/{b:0>3}", .{funct3});
                return error.UnimplementedOpcode;
            },
        },
        // SYSTEM
        0b1110011 => switch (self.funct3.read()) {
            0b001 => InstructionType.CSRRW,
            0b010 => InstructionType.CSRRS,
            0b101 => InstructionType.CSRRWI,
            else => |funct3| {
                std.log.emerg("unimplemented funct3: SYSTEM/{b:0>3}", .{funct3});
                return error.UnimplementedOpcode;
            },
        },
        // OP-IMM-32
        0b0011011 => switch (self.funct3.read()) {
            0b000 => InstructionType.ADDIW,
            else => |funct3| {
                std.log.emerg("unimplemented funct3: OP-IMM-32/{b:0>3}", .{funct3});
                return error.UnimplementedOpcode;
            },
        },
        else => |opcode| {
            std.log.emerg("unimplemented opcode: {b:0>7}", .{opcode});
            return error.UnimplementedOpcode;
        },
    };
}

fn execute(self: *Cpu, instruction: Instruction) !void {
    switch (try decode(instruction)) {
        // 32I

        .LUI => {
            // U-type

            const rd = instruction.rd.read();
            const imm = instruction.u_imm.read();

            if (rd != 0) {
                std.log.debug(
                    \\LUI - dest: x{}, value: 0x{x}
                    \\  setting x{} to 0x{x}
                , .{
                    rd,
                    imm,
                    rd,
                    imm,
                });

                self.x[rd] = @bitCast(u64, imm);
            } else {
                std.log.debug(
                    \\LUI - dest: x{}, value: 0x{x}
                    \\  nop
                , .{
                    rd,
                    imm,
                });
            }

            self.pc += 4;
        },
        .AUIPC => {
            // U-type

            const rd = instruction.rd.read();
            const imm = instruction.u_imm.read();

            if (rd != 0) {
                std.log.debug(
                    \\AUIPC - dest: x{}, offset: 0x{x}
                    \\  setting x{} to current pc (0x{x}) + 0x{x}
                , .{
                    rd,
                    imm,
                    rd,
                    self.pc,
                    imm,
                });

                self.x[rd] = addSignedToUnsignedWrap(self.pc, imm);
            } else {
                std.log.debug(
                    \\AUIPC - dest: x{}, offset: 0x{x}
                    \\  nop
                , .{
                    rd,
                    imm,
                });
            }

            self.pc += 4;
        },
        .JAL => {
            // J-type

            const imm = instruction.j_imm.read();
            const rd = instruction.rd.read();

            if (rd != 0) {
                std.log.debug(
                    \\JAL - dest: x{}, offset: 0x{x}
                    \\  setting x{} to current pc (0x{x}) + 0x4
                    \\  setting pc to current pc (0x{x}) + 0x{x}
                , .{
                    rd,
                    imm,
                    rd,
                    self.pc,
                    self.pc,
                    imm,
                });

                self.x[rd] = self.pc + 4;
            } else {
                std.log.debug(
                    \\JAL - dest: x{}, offset: 0x{x}
                    \\  setting pc to current pc (0x{x}) + 0x{x}
                , .{
                    rd,
                    imm,
                    self.pc,
                    imm,
                });
            }

            self.pc = addSignedToUnsignedWrap(self.pc, imm);
        },
        .BEQ => {
            // B-type

            const imm = instruction.b_imm.read();
            const rs1 = instruction.rs1.read();
            const rs2 = instruction.rs2.read();

            if (self.x[rs1] == self.x[rs2]) {
                std.log.debug(
                    \\BEQ - src1: x{}, src2: x{}, offset: 0x{x}
                    \\  true
                    \\  setting pc to current pc (0x{x}) + 0x{x}
                , .{
                    rs1,
                    rs2,
                    imm,
                    self.pc,
                    imm,
                });

                self.pc = addSignedToUnsignedWrap(self.pc, imm);
            } else {
                std.log.debug(
                    \\BEQ - src1: x{}, src2: x{}, offset: 0x{x}
                    \\  false
                , .{
                    rs1,
                    rs2,
                    imm,
                });

                self.pc += 4;
            }
        },
        .BNE => {
            // B-type

            const imm = instruction.b_imm.read();
            const rs1 = instruction.rs1.read();
            const rs2 = instruction.rs2.read();

            if (self.x[rs1] != self.x[rs2]) {
                std.log.debug(
                    \\BNE - src1: x{}, src2: x{}, offset: 0x{x}
                    \\  true
                    \\  setting pc to current pc (0x{x}) + 0x{x}
                , .{
                    rs1,
                    rs2,
                    imm,
                    self.pc,
                    imm,
                });

                self.pc = addSignedToUnsignedWrap(self.pc, imm);
            } else {
                std.log.debug(
                    \\BNE - src1: x{}, src2: x{}, offset: 0x{x}
                    \\  false
                , .{
                    rs1,
                    rs2,
                    imm,
                });

                self.pc += 4;
            }
        },
        .BGE => {
            // B-type

            const imm = instruction.b_imm.read();
            const rs1 = instruction.rs1.read();
            const rs2 = instruction.rs2.read();

            if (@bitCast(i64, self.x[rs1]) >= @bitCast(i64, self.x[rs2])) {
                std.log.debug(
                    \\BGE - src1: x{}, src2: x{}, offset: 0x{x}
                    \\  true
                    \\  setting pc to current pc (0x{x}) + 0x{x}
                , .{
                    rs1,
                    rs2,
                    imm,
                    self.pc,
                    imm,
                });

                self.pc = addSignedToUnsignedWrap(self.pc, imm);
            } else {
                std.log.debug(
                    \\BGE - src1: x{}, src2: x{}, offset: 0x{x}
                    \\  false
                , .{
                    rs1,
                    rs2,
                    imm,
                });

                self.pc += 4;
            }
        },
        .ADDI => {
            // I-type

            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();
            const imm = instruction.i_imm.read();

            if (rd != 0) {
                std.log.debug(
                    \\ADDI - src: x{}, dest: x{}, imm: 0x{x}
                    \\  set x{} to x{} + 0x{x}
                , .{
                    rs1,
                    rd,
                    imm,
                    rd,
                    rs1,
                    imm,
                });

                self.x[rd] = addSignedToUnsignedIgnoreOverflow(self.x[rs1], imm);
            } else {
                std.log.debug(
                    \\ADDI - src: x{}, dest: x{}, imm: 0x{x}
                    \\  nop
                , .{
                    rs1,
                    rd,
                    imm,
                });
            }

            self.pc += 4;
        },
        .SLLI => {
            // I-type specialization

            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();
            const shmt = instruction.i_specialization.fullShift();

            if (rd != 0) {
                std.log.debug(
                    \\SLLI - src: x{}, dest: x{}, shmt: {}
                    \\  set x{} to x{} << {}
                , .{
                    rs1,
                    rd,
                    shmt,
                    rd,
                    rs1,
                    shmt,
                });

                self.x[rd] = self.x[rs1] << shmt;
            } else {
                std.log.debug(
                    \\SLLI - src: x{}, dest: x{}, shmt: {}
                    \\  nop
                , .{
                    rs1,
                    rd,
                    shmt,
                });
            }

            self.pc += 4;
        },

        // 64I

        .ADDIW => {
            // I-type

            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();
            const imm = instruction.i_imm.read();

            if (rd != 0) {
                std.log.debug(
                    \\ADDIW - src: x{}, dest: x{}, imm: 0x{x}
                    \\  32bit set x{} to x{} + 0x{x}
                , .{
                    rs1,
                    rd,
                    imm,
                    rd,
                    rs1,
                    imm,
                });

                // const a1 = addSignedToUnsignedIgnoreOverflow(
                //     self.x[rs1],
                //     imm,
                // );
                // const a2 = a1 *

                self.x[rd] = @bitCast(
                    u64,
                    @bitCast(
                        i64,
                        (addSignedToUnsignedIgnoreOverflow(
                            self.x[rs1],
                            imm,
                        ) & 0xFFFFFFFF) << 32,
                    ) >> 32,
                );
            } else {
                std.log.debug(
                    \\ADDIW - src: x{}, dest: x{}, imm: 0x{x}
                    \\  nop
                , .{
                    rs1,
                    rd,
                    imm,
                });
            }

            self.pc += 4;
        },

        // Zicsr

        .CSRRW => {
            // I-type

            const csr = try Csr.getCsr(instruction.csr.read());
            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();

            if (rd != 0) {
                std.log.debug(
                    \\CSRRW - csr: {}, dest: x{}, source: x{}
                    \\  atomic
                    \\  read csr {} into x{}
                    \\  set csr {} to x{}
                , .{
                    csr,
                    rd,
                    rs1,
                    csr,
                    rd,
                    csr,
                    rs1,
                });

                if (!csr.canWrite(self.privilege_level)) {
                    // TODO: Illegal instruction exception
                    return error.InvalidWriteToCsr;
                }

                const initial_rs1 = self.x[rs1];
                self.x[rd] = self.readCsr(csr);
                try self.writeCsr(csr, initial_rs1);
            } else {
                std.log.debug(
                    \\CSRRW - csr: {}, dest: x{}, source: x{}
                    \\  set csr {} to x{}
                , .{
                    csr,
                    rd,
                    rs1,
                    csr,
                    rs1,
                });

                if (!csr.canWrite(self.privilege_level)) {
                    // TODO: Illegal instruction exception
                    return error.InvalidWriteToCsr;
                }

                try self.writeCsr(csr, self.x[rs1]);
            }

            self.pc += 4;
        },
        .CSRRS => {
            // I-type

            const csr = try Csr.getCsr(instruction.csr.read());
            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();

            if (rs1 != 0 and rd != 0) {
                std.log.debug(
                    \\CSRRS - csr: {}, dest: x{}, source: x{}
                    \\  atomic
                    \\  read csr {} into x{}
                    \\  set bits in csr {} using mask in x{}
                , .{
                    csr,
                    rd,
                    rs1,
                    csr,
                    rd,
                    csr,
                    rs1,
                });

                if (!csr.canWrite(self.privilege_level)) {
                    // TODO: Illegal instruction exception
                    return error.InvalidWriteToCsr;
                }

                const initial_rs1 = self.x[rs1];
                const csr_value = self.readCsr(csr);

                self.x[rd] = csr_value;
                try self.writeCsr(csr, csr_value | initial_rs1);
            } else if (rs1 != 0) {
                std.log.debug(
                    \\CSRRS - csr: {}, dest: x{}, source: x{}
                    \\  set bits in csr {} using mask in x{}
                , .{
                    csr,
                    rd,
                    rs1,
                    csr,
                    rs1,
                });

                if (!csr.canWrite(self.privilege_level)) {
                    // TODO: Illegal instruction exception
                    return error.InvalidWriteToCsr;
                }

                try self.writeCsr(csr, self.readCsr(csr) | self.x[rs1]);
            } else if (rd != 0) {
                std.log.debug(
                    \\CSRRS - csr: {}, dest: x{}, source: x{}
                    \\  read csr {} into x{}
                , .{
                    csr,
                    rd,
                    rs1,
                    csr,
                    rd,
                });

                if (!csr.canRead(self.privilege_level)) {
                    // TODO: Illegal instruction exception
                    return error.InvalidReadFromCsr;
                }

                self.x[rd] = self.readCsr(csr);
            } else {
                std.log.debug(
                    \\CSRRS - csr: {}, dest: x{}, source: x{}
                    \\  nop
                , .{
                    csr,
                    rd,
                    rs1,
                });
            }

            self.pc += 4;
        },
        .CSRRWI => {
            // I-type

            const csr = try Csr.getCsr(instruction.csr.read());
            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();

            if (rd != 0) {
                std.log.debug(
                    \\CSRRWI - csr: {}, dest: x{}, imm: 0x{}
                    \\  atomic
                    \\  read csr {} into x{}
                    \\  set csr {} to 0x{}
                , .{
                    csr,
                    rd,
                    rs1,
                    csr,
                    rd,
                    csr,
                    rs1,
                });

                if (!csr.canWrite(self.privilege_level)) {
                    // TODO: Illegal instruction exception
                    return error.InvalidWriteToCsr;
                }

                self.x[rd] = self.readCsr(csr);
                try self.writeCsr(csr, rs1);
            } else {
                std.log.debug(
                    \\CSRRWI - csr: {}, dest: x{}, imm: 0x{}
                    \\  set csr {} to 0x{}
                , .{
                    csr,
                    rd,
                    rs1,
                    csr,
                    rs1,
                });

                if (!csr.canWrite(self.privilege_level)) {
                    // TODO: Illegal instruction exception
                    return error.InvalidWriteToCsr;
                }

                try self.writeCsr(csr, rs1);
            }

            self.pc += 4;
        },
    }
}

fn dump(self: Cpu) void {
    var i: usize = 0;
    while (i < 32 - 3) : (i += 4) {
        if (i == 0) {
            std.debug.print(" pc: 0x{x:<16} x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16}\n", .{
                self.pc,
                i + 1,
                self.x[i + 1],
                i + 2,
                self.x[i + 2],
                i + 3,
                self.x[i + 3],
            });
            continue;
        }

        std.debug.print("x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16}\n", .{
            i,
            self.x[i],
            i + 1,
            self.x[i + 1],
            i + 2,
            self.x[i + 2],
            i + 3,
            self.x[i + 3],
        });
    }

    std.debug.print("pl: {} mhartid: {}", .{
        self.privilege_level,
        self.mhartid,
    });

    std.debug.print("\n", .{});
}

const PrivilegeLevel = enum(u2) {
    User = 0,
    Supervisor = 1,
    Machine = 3,
};

fn readCsr(self: *const Cpu, csr: Csr) u64 {
    return switch (csr) {
        .mhartid => self.mhartid,
    };
}

fn writeCsr(self: *Cpu, csr: Csr, value: u64) !void {
    switch (csr) {
        .mhartid => self.mhartid = value,
    }
}

const Csr = enum(u12) {
    mhartid = 0xF14,

    pub fn getCsr(value: u12) !Csr {
        return std.meta.intToEnum(Csr, value) catch {
            std.log.emerg("invalid csr 0x{X}", .{value});
            return error.InvalidCsr;
        };
    }

    pub fn canRead(self: Csr, privilege_level: PrivilegeLevel) bool {
        const csr_value = @enumToInt(self);

        const lowest_privilege_level = bitjuggle.getBits(csr_value, 8, 2);
        if (@enumToInt(privilege_level) < lowest_privilege_level) return false;

        return true;
    }

    pub fn canWrite(self: Csr, privilege_level: PrivilegeLevel) bool {
        const csr_value = @enumToInt(self);

        const lowest_privilege_level = bitjuggle.getBits(csr_value, 8, 2);
        if (@enumToInt(privilege_level) < lowest_privilege_level) return false;

        return bitjuggle.getBits(csr_value, 10, 2) != @as(u12, 0b11);
    }
};

inline fn addSignedToUnsignedWrap(unsigned: u64, signed: i64) u64 {
    return if (signed < 0)
        unsigned -% @bitCast(u64, -signed)
    else
        unsigned +% @bitCast(u64, signed);
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

comptime {
    std.testing.refAllDecls(@This());
}
