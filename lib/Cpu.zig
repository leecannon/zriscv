const std = @import("std");
const bitjuggle = @import("bitjuggle");
usingnamespace @import("types.zig");
usingnamespace @import("csr.zig");
usingnamespace @import("instruction.zig");

const Cpu = @This();

memory: []u8,
x: [32]u64 = [_]u64{0} ** 32,
pc: usize = 0,
privilege_level: PrivilegeLevel = .Machine,

mhartid: u64 = 0,

mtvec: Mtvec = .{ .backing = 0 },
vector_base_address: u64 = 0,
vector_mode: VectorMode = .Direct,

satp: Satp = .{ .backing = 0 },
address_translation_mode: AddressTranslationMode = .Bare,
asid: u16 = 0,
ppn_address: u64 = 0,

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
                    \\CSRRW - csr: {s}, dest: x{}, source: x{}
                    \\  atomic
                    \\  read csr {s} into x{}
                    \\  set csr {s} to x{}
                , .{
                    @tagName(csr),
                    rd,
                    rs1,
                    @tagName(csr),
                    rd,
                    @tagName(csr),
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
                    \\CSRRW - csr: {s}, dest: x{}, source: x{}
                    \\  set csr {s} to x{}
                , .{
                    @tagName(csr),
                    rd,
                    rs1,
                    @tagName(csr),
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
                    \\CSRRS - csr: {s}, dest: x{}, source: x{}
                    \\  atomic
                    \\  read csr {s} into x{}
                    \\  set bits in csr {s} using mask in x{}
                , .{
                    @tagName(csr),
                    rd,
                    rs1,
                    @tagName(csr),
                    rd,
                    @tagName(csr),
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
                    \\CSRRS - csr: {s}, dest: x{}, source: x{}
                    \\  set bits in csr {s} using mask in x{}
                , .{
                    @tagName(csr),
                    rd,
                    rs1,
                    @tagName(csr),
                    rs1,
                });

                if (!csr.canWrite(self.privilege_level)) {
                    // TODO: Illegal instruction exception
                    return error.InvalidWriteToCsr;
                }

                try self.writeCsr(csr, self.readCsr(csr) | self.x[rs1]);
            } else if (rd != 0) {
                std.log.debug(
                    \\CSRRS - csr: {s}, dest: x{}, source: x{}
                    \\  read csr {s} into x{}
                , .{
                    @tagName(csr),
                    rd,
                    rs1,
                    @tagName(csr),
                    rd,
                });

                if (!csr.canRead(self.privilege_level)) {
                    // TODO: Illegal instruction exception
                    return error.InvalidReadFromCsr;
                }

                self.x[rd] = self.readCsr(csr);
            } else {
                std.log.debug(
                    \\CSRRS - csr: {s}, dest: x{}, source: x{}
                    \\  nop
                , .{
                    @tagName(csr),
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
                    \\CSRRWI - csr: {s}, dest: x{}, imm: 0x{}
                    \\  atomic
                    \\  read csr {s} into x{}
                    \\  set csr {s} to 0x{}
                , .{
                    @tagName(csr),
                    rd,
                    rs1,
                    @tagName(csr),
                    rd,
                    @tagName(csr),
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
                    \\CSRRWI - csr: {s}, dest: x{}, imm: 0x{}
                    \\  set csr {s} to 0x{}
                , .{
                    @tagName(csr),
                    rd,
                    rs1,
                    @tagName(csr),
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

        std.debug.print("x{:0>2}: 0x{x:<16} x{:0>2}: 0x{b} x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16}\n", .{
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

    std.debug.print(
        \\privilege: {s:<12} mhartid: {}
        \\vector mode: {s:<10} vector base address: 0x{x}
        \\address mode: {s:<9} asid: {:<17} ppn address: 0x{x}
    , .{
        @tagName(self.privilege_level),          self.mhartid,
        @tagName(self.vector_mode),              self.vector_base_address,
        @tagName(self.address_translation_mode), self.asid,
        self.ppn_address,
    });

    std.debug.print("\n", .{});
}

fn readCsr(self: *const Cpu, csr: Csr) u64 {
    return switch (csr) {
        .mhartid => self.mhartid,
        .mtvec => self.mtvec.backing,
        .satp => self.satp.backing,
        .pmpcfg0,
        .pmpcfg2,
        .pmpcfg4,
        .pmpcfg6,
        .pmpcfg8,
        .pmpcfg10,
        .pmpcfg12,
        .pmpcfg14,
        .pmpaddr0,
        .pmpaddr1,
        .pmpaddr2,
        .pmpaddr3,
        .pmpaddr4,
        .pmpaddr5,
        .pmpaddr6,
        .pmpaddr7,
        .pmpaddr8,
        .pmpaddr9,
        .pmpaddr10,
        .pmpaddr11,
        .pmpaddr12,
        .pmpaddr13,
        .pmpaddr14,
        .pmpaddr15,
        .pmpaddr16,
        .pmpaddr17,
        .pmpaddr18,
        .pmpaddr19,
        .pmpaddr20,
        .pmpaddr21,
        .pmpaddr22,
        .pmpaddr23,
        .pmpaddr24,
        .pmpaddr25,
        .pmpaddr26,
        .pmpaddr27,
        .pmpaddr28,
        .pmpaddr29,
        .pmpaddr30,
        .pmpaddr31,
        .pmpaddr32,
        .pmpaddr33,
        .pmpaddr34,
        .pmpaddr35,
        .pmpaddr36,
        .pmpaddr37,
        .pmpaddr38,
        .pmpaddr39,
        .pmpaddr40,
        .pmpaddr41,
        .pmpaddr42,
        .pmpaddr43,
        .pmpaddr44,
        .pmpaddr45,
        .pmpaddr46,
        .pmpaddr47,
        .pmpaddr48,
        .pmpaddr49,
        .pmpaddr50,
        .pmpaddr51,
        .pmpaddr52,
        .pmpaddr53,
        .pmpaddr54,
        .pmpaddr55,
        .pmpaddr56,
        .pmpaddr57,
        .pmpaddr58,
        .pmpaddr59,
        .pmpaddr60,
        .pmpaddr61,
        .pmpaddr62,
        .pmpaddr63,
        => 0,
    };
}

fn writeCsr(self: *Cpu, csr: Csr, value: u64) !void {
    switch (csr) {
        .mhartid => self.mhartid = value,
        .mtvec => {
            const pending_mtvec = Mtvec{ .backing = value };

            self.vector_mode = try VectorMode.getVectorMode(@truncate(u2, pending_mtvec.mode.read()));
            self.vector_base_address = pending_mtvec.base.read() << 2;

            self.mtvec = pending_mtvec;
        },
        .satp => {
            const pending_satp = Satp{ .backing = value };

            const address_translation_mode = try AddressTranslationMode.getAddressTranslationMode(@truncate(u4, pending_satp.mode.read()));
            if (address_translation_mode != .Bare) {
                std.log.debug("unsupported address_translation_mode given: {s}", .{@tagName(address_translation_mode)});
                return;
            }

            self.address_translation_mode = address_translation_mode;
            self.asid = @truncate(u16, pending_satp.asid.read());
            self.ppn_address = pending_satp.ppn.read() * 4096;

            self.satp = pending_satp;
        },
        .pmpcfg0,
        .pmpcfg2,
        .pmpcfg4,
        .pmpcfg6,
        .pmpcfg8,
        .pmpcfg10,
        .pmpcfg12,
        .pmpcfg14,
        .pmpaddr0,
        .pmpaddr1,
        .pmpaddr2,
        .pmpaddr3,
        .pmpaddr4,
        .pmpaddr5,
        .pmpaddr6,
        .pmpaddr7,
        .pmpaddr8,
        .pmpaddr9,
        .pmpaddr10,
        .pmpaddr11,
        .pmpaddr12,
        .pmpaddr13,
        .pmpaddr14,
        .pmpaddr15,
        .pmpaddr16,
        .pmpaddr17,
        .pmpaddr18,
        .pmpaddr19,
        .pmpaddr20,
        .pmpaddr21,
        .pmpaddr22,
        .pmpaddr23,
        .pmpaddr24,
        .pmpaddr25,
        .pmpaddr26,
        .pmpaddr27,
        .pmpaddr28,
        .pmpaddr29,
        .pmpaddr30,
        .pmpaddr31,
        .pmpaddr32,
        .pmpaddr33,
        .pmpaddr34,
        .pmpaddr35,
        .pmpaddr36,
        .pmpaddr37,
        .pmpaddr38,
        .pmpaddr39,
        .pmpaddr40,
        .pmpaddr41,
        .pmpaddr42,
        .pmpaddr43,
        .pmpaddr44,
        .pmpaddr45,
        .pmpaddr46,
        .pmpaddr47,
        .pmpaddr48,
        .pmpaddr49,
        .pmpaddr50,
        .pmpaddr51,
        .pmpaddr52,
        .pmpaddr53,
        .pmpaddr54,
        .pmpaddr55,
        .pmpaddr56,
        .pmpaddr57,
        .pmpaddr58,
        .pmpaddr59,
        .pmpaddr60,
        .pmpaddr61,
        .pmpaddr62,
        .pmpaddr63,
        => {},
    }
}

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
