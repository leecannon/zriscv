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

mstatus: Mstatus = Mstatus.initial_state,
/// mstatus:sie
supervisor_interrupts_enabled: bool = false,
/// mstatus:spie
supervisor_interrupts_enabled_prior: bool = false,
/// mstatus:spp
supervisor_previous_privilege_level: PrivilegeLevel = .Supervisor,
/// mstatus:mie
machine_interrupts_enabled: bool = false,
/// mstatus:mpie
machine_interrupts_enabled_prior: bool = false,
/// mstatus:mpp
machine_previous_privilege_level: PrivilegeLevel = .Machine,
/// mstatus:fs
floating_point_status: ContextStatus = .Initial,
/// mstatus:xs
extension_status: ContextStatus = .Initial,
/// mstatus:ds
state_dirty: bool = false,
/// mstatus:mprv
modify_privilege: bool = false,
/// mstatus:sum
supervisor_user_memory_access: bool = false,
/// mstatus:mxr
executable_readable: bool = false,
/// mstatus:tvm
trap_virtual_memory: bool = false,
/// mstatus:tw
timeout_wait: bool = false,
/// mstatus:tsr
trap_sret: bool = false,

mepc: u64 = 0,
mcause: MCause = .{ .backing = 0 },
mtval: u64 = 0,

sepc: u64 = 0,
scause: SCause = .{ .backing = 0 },
stval: u64 = 0,

mhartid: u64 = 0,

mtvec: Mtvec = .{ .backing = 0 },
machine_vector_base_address: u64 = 0,
machine_vector_mode: VectorMode = .Direct,

stvec: Stvec = .{ .backing = 0 },
supervisor_vector_base_address: u64 = 0,
supervisor_vector_mode: VectorMode = .Direct,

satp: Satp = .{ .backing = 0 },
address_translation_mode: AddressTranslationMode = .Bare,
asid: u16 = 0,
ppn_address: u64 = 0,

medeleg: u64 = 0,
mideleg: u64 = 0,

mie: u64 = 0,
mip: u64 = 0,

pub fn run(self: *Cpu) !void {
    var instruction: Instruction = undefined;

    while (true) {
        self.dump();

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
    const funct3 = self.funct3.read();
    const funct7 = self.funct7.read();

    return switch (self.opcode.read()) {
        0b0110111 => InstructionType.LUI,
        0b0010111 => InstructionType.AUIPC,
        0b1101111 => InstructionType.JAL,
        // BRANCH
        0b1100011 => switch (funct3) {
            0b000 => InstructionType.BEQ,
            0b001 => InstructionType.BNE,
            0b101 => InstructionType.BGE,
            else => {
                std.log.emerg("unimplemented funct3: BRANCH/{b:0>3}", .{funct3});
                return error.UnimplementedOpcode;
            },
        },
        // OP-IMM
        0b0010011 => switch (funct3) {
            0b000 => InstructionType.ADDI,
            0b001 => InstructionType.SLLI,
            0b110 => InstructionType.ORI,
            0b101 => if (funct7 == 0) InstructionType.SRLI else InstructionType.SRAI,
            else => {
                std.log.emerg("unimplemented funct3: OP-IMM/{b:0>3}", .{funct3});
                return error.UnimplementedOpcode;
            },
        },
        // OP
        0b0110011 => switch (funct3) {
            0b000 => if (funct7 == 0) InstructionType.ADD else InstructionType.SUB,
            0b111 => InstructionType.AND,
            else => {
                std.log.emerg("unimplemented funct3: OP/{b:0>3}", .{funct3});
                return error.UnimplementedOpcode;
            },
        },
        0b001111 => InstructionType.FENCE,
        // SYSTEM
        0b1110011 => switch (funct3) {
            0b000 => switch (funct7) {
                0b0000000 => InstructionType.ECALL,
                0b0011000 => InstructionType.MRET,
                else => {
                    std.log.emerg("unimplemented funct7: SYSTEM/000/{b:0>7}", .{funct7});
                    return error.UnimplementedOpcode;
                },
            },
            0b001 => InstructionType.CSRRW,
            0b010 => InstructionType.CSRRS,
            0b011 => InstructionType.CSRRC,
            0b101 => InstructionType.CSRRWI,
            else => {
                std.log.emerg("unimplemented funct3: SYSTEM/{b:0>3}", .{funct3});
                return error.UnimplementedOpcode;
            },
        },
        // OP-IMM-32
        0b0011011 => switch (funct3) {
            0b000 => InstructionType.ADDIW,
            else => {
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
        .ORI => {
            // I-type

            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();
            const imm = instruction.i_imm.read();

            if (rd != 0) {
                std.log.debug(
                    \\ORI - src: x{}, dest: x{}, imm: 0x{x}
                    \\  set x{} to x{} | 0x{x}
                , .{
                    rs1,
                    rd,
                    imm,
                    rd,
                    rs1,
                    imm,
                });

                self.x[rd] = self.x[rs1] | @bitCast(u64, imm);
            } else {
                std.log.debug(
                    \\ORI - src: x{}, dest: x{}, imm: 0x{x}
                    \\  nop
                , .{
                    rs1,
                    rd,
                    imm,
                });
            }

            self.pc += 4;
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
        .SRLI => {
            // I-type specialization

            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();
            const shmt = instruction.i_specialization.fullShift();

            if (rd != 0) {
                std.log.debug(
                    \\SRLI - src: x{}, dest: x{}, shmt: {}
                    \\  set x{} to x{} >> {}
                , .{
                    rs1,
                    rd,
                    shmt,
                    rd,
                    rs1,
                    shmt,
                });

                self.x[rd] = self.x[rs1] >> shmt;
            } else {
                std.log.debug(
                    \\SRLI - src: x{}, dest: x{}, shmt: {}
                    \\  nop
                , .{
                    rs1,
                    rd,
                    shmt,
                });
            }

            self.pc += 4;
        },
        .SRAI => {
            // I-type specialization

            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();
            const shmt = instruction.i_specialization.fullShift();

            if (rd != 0) {
                std.log.debug(
                    \\SRAI - src: x{}, dest: x{}, shmt: {}
                    \\  set x{} to x{} >> arithmetic {}
                , .{
                    rs1,
                    rd,
                    shmt,
                    rd,
                    rs1,
                    shmt,
                });

                self.x[rd] = @bitCast(u64, @bitCast(i64, self.x[rs1]) >> shmt);
            } else {
                std.log.debug(
                    \\SRAI - src: x{}, dest: x{}, shmt: {}
                    \\  nop
                , .{
                    rs1,
                    rd,
                    shmt,
                });
            }

            self.pc += 4;
        },
        .ADD => {
            // R-type

            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();
            const rs2 = instruction.rs2.read();

            if (rd != 0) {
                std.log.debug(
                    \\ADD - src1: x{}, src2: x{}, dest: x{}
                    \\  set x{} to x{} + x{}
                , .{
                    rs1,
                    rs2,
                    rd,
                    rd,
                    rs1,
                    rs2,
                });

                _ = @addWithOverflow(u64, self.x[rs1], self.x[rs2], &self.x[rd]);
            } else {
                std.log.debug(
                    \\ADD - src1: x{}, src2: x{}, dest: x{}
                    \\  nop
                , .{
                    rs1,
                    rs2,
                    rd,
                });
            }

            self.pc += 4;
        },
        .SUB => {
            // R-type

            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();
            const rs2 = instruction.rs2.read();

            if (rd != 0) {
                std.log.debug(
                    \\ADD - src1: x{}, src2: x{}, dest: x{}
                    \\  set x{} to x{} - x{}
                , .{
                    rs1,
                    rs2,
                    rd,
                    rd,
                    rs1,
                    rs2,
                });

                _ = @subWithOverflow(u64, self.x[rs1], self.x[rs2], &self.x[rd]);
            } else {
                std.log.debug(
                    \\ADD - src1: x{}, src2: x{}, dest: x{}
                    \\  nop
                , .{
                    rs1,
                    rs2,
                    rd,
                });
            }

            self.pc += 4;
        },
        .AND => {
            // R-type

            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();
            const rs2 = instruction.rs2.read();

            if (rd != 0) {
                std.log.debug(
                    \\AND - src1: x{}, src2: x{}, dest: x{}
                    \\  set x{} to x{} & x{}
                , .{
                    rs1,
                    rs2,
                    rd,
                    rd,
                    rs1,
                    rs2,
                });

                self.x[rd] = self.x[rs1] & self.x[rs2];
            } else {
                std.log.debug(
                    \\AND - src1: x{}, src2: x{}, dest: x{}
                    \\  nop
                , .{
                    rs1,
                    rs2,
                    rd,
                });
            }

            self.pc += 4;
        },
        .FENCE => {
            std.log.debug("FENCE", .{});

            self.pc += 4;
        },
        .ECALL => {
            // I-type
            std.log.debug("ECALL", .{});
            switch (self.privilege_level) {
                .User => self.throw(.EnvironmentCallFromUMode, 0),
                .Supervisor => self.throw(.EnvironmentCallFromSMode, 0),
                .Machine => self.throw(.EnvironmentCallFromMMode, 0),
            }
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

            // TODO: Proper exceptions
            // const csr = Csr.getCsr(instruction.csr.read()) catch {
            //     self.throw(.IllegalInstruction, instruction.backing);
            //     return;
            // };

            const csr = try Csr.getCsr(instruction.csr.read());
            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();

            if (rd != 0) {
                std.log.debug(
                    \\CSRRW - csr: {s}, dest: x{}, source: x{}
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
                    self.throw(.IllegalInstruction, instruction.backing);
                    return;
                }

                const initial_rs1 = self.x[rs1];
                const initial_csr = self.readCsr(csr);

                try self.writeCsr(csr, initial_rs1);
                self.x[rd] = initial_csr;
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
                    self.throw(.IllegalInstruction, instruction.backing);
                    return;
                }

                try self.writeCsr(csr, self.x[rs1]);
            }

            self.pc += 4;
        },
        .CSRRS => {
            // I-type

            // TODO: Proper exceptions
            // const csr = Csr.getCsr(instruction.csr.read()) catch {
            //     self.throw(.IllegalInstruction, instruction.backing);
            //     return;
            // };

            const csr = try Csr.getCsr(instruction.csr.read());
            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();

            if (rs1 != 0 and rd != 0) {
                std.log.debug(
                    \\CSRRS - csr: {s}, dest: x{}, source: x{}
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
                    self.throw(.IllegalInstruction, instruction.backing);
                    return;
                }

                const initial_rs1 = self.x[rs1];
                const initial_csr_value = self.readCsr(csr);

                try self.writeCsr(csr, initial_csr_value | initial_rs1);
                self.x[rd] = initial_csr_value;
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
                    self.throw(.IllegalInstruction, instruction.backing);
                    return;
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
                    self.throw(.IllegalInstruction, instruction.backing);
                    return;
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
        .CSRRC => {
            // I-type

            // TODO: Proper exceptions
            // const csr = Csr.getCsr(instruction.csr.read()) catch {
            //     self.throw(.IllegalInstruction, instruction.backing);
            //     return;
            // };

            const csr = try Csr.getCsr(instruction.csr.read());
            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();

            if (rs1 != 0 and rd != 0) {
                std.log.debug(
                    \\CSRRC - csr: {s}, dest: x{}, source: x{}
                    \\  read csr {s} into x{}
                    \\  clear bits in csr {s} using mask in x{}
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
                    self.throw(.IllegalInstruction, instruction.backing);
                    return;
                }

                const initial_rs1 = self.x[rs1];
                const initial_csr_value = self.readCsr(csr);

                try self.writeCsr(csr, initial_csr_value & ~initial_rs1);
                self.x[rd] = initial_csr_value;
            } else if (rs1 != 0) {
                std.log.debug(
                    \\CSRRC - csr: {s}, dest: x{}, source: x{}
                    \\  clear bits in csr {s} using mask in x{}
                , .{
                    @tagName(csr),
                    rd,
                    rs1,
                    @tagName(csr),
                    rs1,
                });

                if (!csr.canWrite(self.privilege_level)) {
                    self.throw(.IllegalInstruction, instruction.backing);
                    return;
                }

                try self.writeCsr(csr, self.readCsr(csr) & ~self.x[rs1]);
            } else if (rd != 0) {
                std.log.debug(
                    \\CSRRC - csr: {s}, dest: x{}, source: x{}
                    \\  read csr {s} into x{}
                , .{
                    @tagName(csr),
                    rd,
                    rs1,
                    @tagName(csr),
                    rd,
                });

                if (!csr.canRead(self.privilege_level)) {
                    self.throw(.IllegalInstruction, instruction.backing);
                    return;
                }

                self.x[rd] = self.readCsr(csr);
            } else {
                std.log.debug(
                    \\CSRRC - csr: {s}, dest: x{}, source: x{}
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

            // TODO: Proper exceptions
            // const csr = Csr.getCsr(instruction.csr.read()) catch {
            //     self.throw(.IllegalInstruction, instruction.backing);
            //     return;
            // };

            const csr = try Csr.getCsr(instruction.csr.read());
            const rd = instruction.rd.read();
            const rs1 = instruction.rs1.read();

            if (rd != 0) {
                std.log.debug(
                    \\CSRRWI - csr: {s}, dest: x{}, imm: 0x{}
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
                    self.throw(.IllegalInstruction, instruction.backing);
                    return;
                }

                const initial_csr_value = self.readCsr(csr);

                try self.writeCsr(csr, rs1);
                self.x[rd] = initial_csr_value;
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
                    self.throw(.IllegalInstruction, instruction.backing);
                    return;
                }

                try self.writeCsr(csr, rs1);
            }

            self.pc += 4;
        },

        // Privilege
        .MRET => {
            std.log.debug("MRET\n", .{});

            if (self.privilege_level != .Machine) {
                self.throw(.IllegalInstruction, instruction.backing);
                return;
            }

            if (self.machine_previous_privilege_level != .Machine) self.modify_privilege = false;
            self.machine_interrupts_enabled = self.machine_interrupts_enabled_prior;
            self.privilege_level = self.machine_previous_privilege_level;
            self.machine_interrupts_enabled_prior = true;
            self.machine_previous_privilege_level = .User;

            self.pc = self.mepc;
        },
    }
}

fn throw(self: *Cpu, exception: ExceptionCode, val: u64) void {
    if (self.privilege_level != .Machine and self.isExceptionDelegated(exception)) {
        std.log.debug("Exception {s} caught in {s} jumping to {s}", .{
            @tagName(exception),
            @tagName(self.privilege_level),
            @tagName(PrivilegeLevel.Supervisor),
        });

        self.scause.code.write(@enumToInt(exception));
        self.scause.interrupt.write(0);

        self.stval = val;

        self.supervisor_previous_privilege_level = self.privilege_level;
        self.mstatus.spp.write(@truncate(u1, @enumToInt(self.privilege_level)));
        self.privilege_level = .Supervisor;

        self.supervisor_interrupts_enabled_prior = self.supervisor_interrupts_enabled;
        self.mstatus.spie.write(@boolToInt(self.supervisor_interrupts_enabled));

        self.supervisor_interrupts_enabled = false;
        self.mstatus.sie.write(0);

        self.sepc = self.pc;
        self.pc = self.supervisor_vector_base_address;

        return;
    }

    std.log.debug("Exception {s} caught in {s} jumping to {s}", .{
        @tagName(exception),
        @tagName(self.privilege_level),
        @tagName(PrivilegeLevel.Machine),
    });

    self.mcause.code.write(@enumToInt(exception));
    self.mcause.interrupt.write(0);

    self.mtval = val;

    self.machine_previous_privilege_level = self.privilege_level;
    self.mstatus.mpp.write(@enumToInt(self.privilege_level));
    self.privilege_level = .Machine;

    self.machine_interrupts_enabled_prior = self.machine_interrupts_enabled;
    self.mstatus.mpie.write(@boolToInt(self.machine_interrupts_enabled));

    self.machine_interrupts_enabled = false;
    self.mstatus.mie.write(0);

    self.mepc = self.pc;
    self.pc = self.machine_vector_base_address;
}

fn isExceptionDelegated(self: Cpu, exception: ExceptionCode) bool {
    return switch (exception) {
        .InstructionAddressMisaligned => bitjuggle.getBit(self.medeleg, 0) != 0,
        .InstructionAccessFault => bitjuggle.getBit(self.medeleg, 1) != 0,
        .IllegalInstruction => bitjuggle.getBit(self.medeleg, 2) != 0,
        .Breakpoint => bitjuggle.getBit(self.medeleg, 3) != 0,
        .LoadAddressMisaligned => bitjuggle.getBit(self.medeleg, 4) != 0,
        .LoadAccessFault => bitjuggle.getBit(self.medeleg, 5) != 0,
        .Store_AMOAddressMisaligned => bitjuggle.getBit(self.medeleg, 6) != 0,
        .Store_AMOAccessFault => bitjuggle.getBit(self.medeleg, 7) != 0,
        .EnvironmentCallFromUMode => bitjuggle.getBit(self.medeleg, 8) != 0,
        .EnvironmentCallFromSMode => bitjuggle.getBit(self.medeleg, 9) != 0,
        .EnvironmentCallFromMMode => bitjuggle.getBit(self.medeleg, 11) != 0,
        .InstructionPageFault => bitjuggle.getBit(self.medeleg, 12) != 0,
        .LoadPageFault => bitjuggle.getBit(self.medeleg, 13) != 0,
        .Store_AMOPageFault => bitjuggle.getBit(self.medeleg, 15) != 0,
    };
}

fn dump(self: Cpu) void {
    std.log.debug("", .{});

    var i: usize = 0;
    while (i < 32 - 3) : (i += 4) {
        if (i == 0) {
            std.log.debug(" pc: 0x{x:<16} x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16}", .{
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

        std.log.debug("x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16}", .{
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

    std.log.debug("privilege: {s} - mhartid: {} - machine interrupts: {} - super interrupts: {}", .{ @tagName(self.privilege_level), self.mhartid, self.machine_interrupts_enabled, self.supervisor_interrupts_enabled });
    std.log.debug("super interrupts prior: {} - super previous privilege: {s}", .{ self.supervisor_interrupts_enabled_prior, @tagName(self.supervisor_previous_privilege_level) });
    std.log.debug("machine interrupts prior: {} - machine previous privilege: {s}", .{ self.machine_interrupts_enabled_prior, @tagName(self.machine_previous_privilege_level) });
    std.log.debug("mcause: {x} - machine exception pc: 0x{x} - machine trap value {}", .{ self.mcause.backing, self.mepc, self.mtval });
    std.log.debug("scause: {x} - super exception pc: 0x{x} - super trap value {}", .{ self.scause.backing, self.sepc, self.stval });
    std.log.debug("address mode: {s} - asid: {} - ppn address: 0x{x}", .{ @tagName(self.address_translation_mode), self.asid, self.ppn_address });
    std.log.debug("medeleg: 0b{b:0>64}", .{self.medeleg});
    std.log.debug("mideleg: 0b{b:0>64}", .{self.mideleg});
    std.log.debug("mie:     0b{b:0>64}", .{self.mie});
    std.log.debug("mip:     0b{b:0>64}", .{self.mip});
    std.log.debug("machine vector mode:    {s}    machine vector base address: 0x{x}", .{ @tagName(self.machine_vector_mode), self.machine_vector_base_address });
    std.log.debug("super vector mode:      {s} super vector base address: 0x{x}", .{ @tagName(self.supervisor_vector_mode), self.supervisor_vector_base_address });
    std.log.debug("dirty state: {} - floating point: {s} - extension: {s}", .{ self.state_dirty, @tagName(self.floating_point_status), @tagName(self.extension_status) });
    std.log.debug("modify privilege: {} - super user access: {} - execute readable: {}", .{ self.modify_privilege, self.supervisor_user_memory_access, self.executable_readable });
    std.log.debug("trap virtual memory: {} - timeout wait: {} - trap sret: {}", .{ self.trap_virtual_memory, self.timeout_wait, self.trap_sret });

    std.log.debug("", .{});
}

fn readCsr(self: *const Cpu, csr: Csr) u64 {
    return switch (csr) {
        .mhartid => self.mhartid,
        .mtvec => self.mtvec.backing,
        .stvec => self.stvec.backing,
        .satp => self.satp.backing,
        .medeleg => self.medeleg,
        .mideleg => self.mideleg,
        .mie => self.mie,
        .mip => self.mip,
        .mstatus => self.mstatus.backing,
        .mepc => self.mepc,
        .mcause => self.mcause.backing,
        .mtval => self.mtval,
        .sepc => self.sepc,
        .scause => self.scause.backing,
        .stval => self.stval,
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
        .mcause => self.mcause.backing = value,
        .mtval => self.mtval = value,
        .scause => self.scause.backing = value,
        .stval => self.stval = value,
        .sepc => self.sepc = value & ~(@as(u64, 0)),
        .mstatus => {
            const pending_mstatus = Mstatus{
                .backing = self.mstatus.backing & Mstatus.unmodifiable_mask |
                    value & Mstatus.modifiable_mask,
            };

            const super_previous_level = try PrivilegeLevel.getPrivilegeLevel(pending_mstatus.spp.read());
            const machine_previous_level = try PrivilegeLevel.getPrivilegeLevel(pending_mstatus.mpp.read());
            const floating_point_state = try ContextStatus.getContextStatus(pending_mstatus.fs.read());
            const extension_state = try ContextStatus.getContextStatus(pending_mstatus.xs.read());

            self.supervisor_interrupts_enabled = pending_mstatus.sie.read() != 0;
            self.machine_interrupts_enabled = pending_mstatus.mie.read() != 0;
            self.supervisor_interrupts_enabled_prior = pending_mstatus.spie.read() != 0;
            self.machine_interrupts_enabled_prior = pending_mstatus.mpie.read() != 0;
            self.supervisor_previous_privilege_level = super_previous_level;
            self.machine_previous_privilege_level = machine_previous_level;
            self.floating_point_status = floating_point_state;
            self.extension_status = extension_state;
            self.modify_privilege = pending_mstatus.mprv.read() != 0;
            self.supervisor_user_memory_access = pending_mstatus.sum.read() != 0;
            self.executable_readable = pending_mstatus.mxr.read() != 0;
            self.trap_virtual_memory = pending_mstatus.tvm.read() != 0;
            self.timeout_wait = pending_mstatus.tw.read() != 0;
            self.trap_sret = pending_mstatus.tsr.read() != 0;
            self.state_dirty = pending_mstatus.sd.read() != 0;

            self.mstatus = pending_mstatus;
        },
        .mepc => self.mepc = value & ~(@as(u64, 0)),
        .mtvec => {
            const pending_mtvec = Mtvec{ .backing = value };

            self.machine_vector_mode = try VectorMode.getVectorMode(pending_mtvec.mode.read());
            self.machine_vector_base_address = pending_mtvec.base.read() << 2;

            self.mtvec = pending_mtvec;
        },
        .stvec => {
            const pending_stvec = Stvec{ .backing = value };

            self.supervisor_vector_mode = try VectorMode.getVectorMode(pending_stvec.mode.read());
            self.supervisor_vector_base_address = pending_stvec.base.read() << 2;

            self.stvec = pending_stvec;
        },
        .satp => {
            const pending_satp = Satp{ .backing = value };

            const address_translation_mode = try AddressTranslationMode.getAddressTranslationMode(pending_satp.mode.read());
            if (address_translation_mode != .Bare) {
                std.log.debug("unsupported address_translation_mode given: {s}", .{@tagName(address_translation_mode)});
                return;
            }

            self.address_translation_mode = address_translation_mode;
            self.asid = pending_satp.asid.read();
            self.ppn_address = pending_satp.ppn.read() * 4096;

            self.satp = pending_satp;
        },
        .medeleg => self.medeleg = value,
        .mideleg => self.mideleg = value,
        .mip => self.mip = value,
        .mie => self.mie = value,
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
