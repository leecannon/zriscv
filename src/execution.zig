const std = @import("std");
const lib = @import("lib.zig");

pub const ExecutionOptions = struct {
    unrecognised_instruction_is_fatal: bool = true,
    unrecognised_csr_is_fatal: bool = true,
    ebreak_is_fatal: bool = false,
    execution_out_of_bounds_is_fatal: bool = true,

    /// this option is only taken into account if a writer is given
    always_print_pc: bool = true,
};

/// Execute instructions until an exception is encountered
///
/// Note: `writer` may be void (`{}`) in order to suppress output
pub inline fn run(comptime mode: lib.Mode, hart: *lib.Hart(mode), writer: anytype, comptime options: ExecutionOptions) !void {
    while (true) try step(mode, hart, writer, options);
}

/// Execute a single instruction
///
/// Note: `writer` may be void (`{}`) in order to suppress output
pub fn step(comptime mode: lib.Mode, hart: *lib.Hart(mode), writer: anytype, comptime options: ExecutionOptions) !void {
    const has_writer = comptime isWriter(@TypeOf(writer));

    const instruction: lib.Instruction = blk: {
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
                                        try throw(mode, hart, {}, 0, writer);
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
        try writer.print("pc: 0x{x:0>16}\n", .{hart.pc});
    }

    try execute(mode, hart, instruction, writer, options);
}

fn execute(
    comptime mode: lib.Mode,
    hart: *lib.Hart(mode),
    instruction: lib.Instruction,
    writer: anytype,
    comptime options: ExecutionOptions,
) !void {
    const has_writer = comptime isWriter(@TypeOf(writer));

    const instruction_type = if (options.unrecognised_instruction_is_fatal)
        try instruction.decode(options.unrecognised_instruction_is_fatal)
    else
        instruction.decode(options.unrecognised_instruction_is_fatal) catch {
            // TODO: Pass `IllegalInstruction` once `throw` is implemented
            try throw(mode, hart, {}, instruction.full_backing, writer);
            return;
        };

    switch (instruction_type) {
        .ADDI => {
            // I-Type
            const rd = instruction.rd();

            if (rd != .zero) {
                const rs1 = instruction.rs1();
                const imm = instruction.i_imm.read();

                const rs1_value = hart.x[@enumToInt(rs1)];

                if (has_writer) {
                    try writer.print(
                        \\ADDI - src: {}, dest: {}, imm: <0x{x}>
                        \\  set {} to {}<0x{x}> + <0x{x}>
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

                hart.x[@enumToInt(rd)] = addSignedToUnsignedIgnoreOverflow(rs1_value, imm);
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

            hart.pc += 4;
        },
        else => |e| std.debug.panic("unimplemented instruction execution for {s}", .{@tagName(e)}),
    }
}

fn throw(comptime mode: lib.Mode, hart: *lib.Hart(mode), exception: void, value: u64, writer: anytype) !void {
    const has_writer = comptime isWriter(@TypeOf(writer));
    _ = has_writer;
    _ = hart;
    _ = exception;
    _ = value;
    @panic("UNIMPLEMENTED"); // TODO: Exceptions
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
