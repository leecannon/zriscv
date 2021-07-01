const std = @import("std");
const Instruction = @import("Instruction.zig").Instruction;
const InstructionType = @import("InstructionType.zig").InstructionType;

pub const Cpu = struct {
    registers: RegisterFile = .{},
    memory: []u8,

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
        // a compressed instruction, however the below check will fail in that case
        if (self.registers.pc + 3 >= self.memory.len) return error.ExecutionOutOfBounds;
        instruction.backing = std.mem.readIntSlice(u32, self.memory[self.registers.pc..], .Little);
    }

    fn execute(self: *Cpu, instruction: Instruction) !void {
        var compressed = false;

        // This while loop is only used to allow break
        while (true) {
            switch (try instruction.decode()) {
                // I
                .JAL => {
                    // J-type
                    const imm = instruction.j_imm.read();
                    const rd = instruction.rd.read();

                    std.log.debug("JAL - dest: x{}, offset: 0x{x}", .{ rd, imm });

                    if (rd != 0) {
                        self.registers.x[rd] = self.registers.pc + 4;
                    }

                    self.registers.pc = addSignedToUnsignedWrap(self.registers.pc, imm);
                    return;
                },
                .BNE => {
                    // B-type
                    const imm = instruction.b_imm.read();
                    const rs1 = instruction.rs1.read();
                    const rs2 = instruction.rs2.read();

                    std.log.debug("BNE - src1: x{}, src2: x{}, offset: 0x{x}", .{ rs1, rs2, imm });

                    if (self.registers.x[rs1] != self.registers.x[rs2]) {
                        self.registers.pc = addSignedToUnsignedWrap(self.registers.pc, imm);
                        return;
                    }
                },

                // Zicsr
                .CSRRS => {
                    // I-type

                    const rd = instruction.rd.read();
                    const csr = instruction.csr.read();
                    const rs1 = instruction.rs1.read();

                    std.log.debug("CSRRS - csr: {}, dest: x{}, source: x{}", .{ csr, rd, rs1 });

                    if (rd != 0) {
                        self.registers.x[rd] = self.registers.csr[csr];
                    }

                    if (rs1 == 0) break;

                    self.registers.csr[csr] |= self.registers.x[rs1];
                },
            }

            break;
        }

        self.registers.pc += @as(u64, if (compressed) 2 else 4);
    }

    fn dump(self: Cpu) void {
        var i: usize = 0;
        while (i < 32 - 3) : (i += 4) {
            if (i == 0) {
                std.debug.print(" pc: 0x{x:<16} x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16}\n", .{
                    self.registers.pc,
                    i + 1,
                    self.registers.x[i + 1],
                    i + 2,
                    self.registers.x[i + 2],
                    i + 3,
                    self.registers.x[i + 3],
                });
                continue;
            }

            std.debug.print("x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16} x{:0>2}: 0x{x:<16}\n", .{
                i,
                self.registers.x[i],
                i + 1,
                self.registers.x[i + 1],
                i + 2,
                self.registers.x[i + 2],
                i + 3,
                self.registers.x[i + 3],
            });
        }

        i = 0;
        for (self.registers.csr) |csr, j| {
            if (csr == 0) continue;

            if (i > 3) {
                i = 0;
                std.debug.print("\n", .{});
            }

            if (i == 0) {
                std.debug.print("csr[{:>4}]: 0x{x:<16} 0b{b:<64}", .{ j, csr, csr });
            } else {
                std.debug.print(" csr[{:>4}]: 0x{x:<16} 0b{b:<64}", .{ j, csr, csr });
            }

            i += 1;
        }
    }

    const RegisterFile = struct {
        x: [32]u64 = [_]u64{0} ** 32,
        pc: u64 = 0,
        csr: [4096]u64 = [_]u64{0} ** 4096,

        comptime {
            std.testing.refAllDecls(@This());
        }
    };

    comptime {
        std.testing.refAllDecls(@This());
    }
};

inline fn addSignedToUnsignedWrap(unsigned: u64, signed: i64) u64 {
    return if (signed < 0)
        unsigned -% @bitCast(u64, -signed)
    else
        unsigned +% @bitCast(u64, signed);
}

comptime {
    std.testing.refAllDecls(@This());
}
