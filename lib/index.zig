usingnamespace @import("common.zig");

pub const Cpu = struct {
    registers: RegisterFile = .{},
    memory: []u8,

    pub fn execute(self: *Cpu) !void {
        var instruction: Instruction = undefined;

        while (true) {
            if (std.builtin.mode == .Debug) {
                std.debug.print("\n", .{});
                self.dump();
                std.debug.print("\n", .{});
            }

            // Fetch
            {
                // This is not 100% compatible with extension C, as the very last 16 bits of memory could be
                // a compressed instruction, however the below check will fail in that case
                if (self.registers.pc + 3 >= self.memory.len) return error.ExecutionOutOfBounds;
                instruction.backing = std.mem.readIntSlice(u32, self.memory[self.registers.pc..], .Little);
            }

            // Decode
            const instruction_type: InstructionType = switch (instruction.opcode.read()) {
                0b1101111 => .JAL,
                else => |opcode| {
                    std.log.emerg("unimplemented opcode: 0b{b:0>7}", .{opcode});
                    return error.UnimplementedOpcode;
                },
            };

            // Execute
            var compressed = false;

            switch (instruction_type) {
                .JAL => {
                    const offset = instruction.j.readImm();
                    const dest = instruction.j.rd.read();

                    std.log.debug("JAL - dest: x{:0>2}, offset: 0x{x:0>16}", .{ dest, offset });

                    if (dest != 0) {
                        self.registers.setX(dest, self.registers.pc + 4);
                    }

                    self.registers.pc = addSignedToUnsignedWrap(self.registers.pc, offset);

                    continue;
                },
            }

            self.registers.pc += if (compressed) 2 else 4;
        }
    }

    fn dump(self: Cpu) void {
        var i: usize = 0;
        while (i < 32 - 3) : (i += 4) {
            if (i == 0) {
                std.debug.print(" pc: 0x{x:0>16} x{:0>2}: 0x{x:0>16} x{:0>2}: 0x{x:0>16} x{:0>2}: 0x{x:0>16}\n", .{
                    self.registers.pc,
                    i + 1,
                    self.registers.getX(i + 1),
                    i + 2,
                    self.registers.getX(i + 2),
                    i + 3,
                    self.registers.getX(i + 3),
                });
                continue;
            }

            std.debug.print("x{:0>2}: 0x{x:0>16} x{:0>2}: 0x{x:0>16} x{:0>2}: 0x{x:0>16} x{:0>2}: 0x{x:0>16}\n", .{
                i,
                self.registers.getX(i),
                i + 1,
                self.registers.getX(i + 1),
                i + 2,
                self.registers.getX(i + 2),
                i + 3,
                self.registers.getX(i + 3),
            });
        }
    }

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

pub const InstructionType = enum {
    JAL,
};

pub const Instruction = extern union {
    j: J,

    opcode: bitjuggle.Bitfield(u32, 0, 7),

    backing: u32,

    pub const J = extern union {
        opcode: bitjuggle.Bitfield(u32, 0, 7),
        rd: bitjuggle.Bitfield(u32, 7, 5),
        imm19_12: bitjuggle.Bitfield(u32, 12, 8),
        imm11: bitjuggle.Bitfield(u32, 20, 1),
        imm10_1: bitjuggle.Bitfield(u32, 21, 10),
        imm20: bitjuggle.Bitfield(u32, 31, 1),

        backing: u32,

        pub fn readImm(self: J) i64 {
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

    comptime {
        std.testing.refAllDecls(@This());
    }
};

pub const RegisterFile = struct {
    general_purpose_registers: [32]u64 = [_]u64{0} ** 32,
    pc: u64 = 0,

    pub inline fn getX(self: RegisterFile, x: u64) u64 {
        // It's faster to just have a 32 long array of registers, instead of a branch and subtraction
        return self.general_purpose_registers[x];
    }

    pub inline fn setX(self: *RegisterFile, x: u64, value: u64) void {
        std.debug.assert(x != 0);
        self.general_purpose_registers[x] = value;
    }

    comptime {
        std.testing.refAllDecls(@This());
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
