const std = @import("std");
const lib = @import("lib.zig");

/// Execute instructions until an exception is encountered
///
/// Note: `writer` may be void (`{}`) in order to suppress output
pub inline fn run(comptime mode: lib.Mode, hart: *lib.Hart(mode), writer: anytype) !void {
    while (true) try step(mode, hart, writer);
}

/// Execute a single instruction
///
/// Note: `writer` may be void (`{}`) in order to suppress output
pub fn step(comptime mode: lib.Mode, hart: *lib.Hart(mode), writer: anytype) !void {
    const has_writer = comptime isWriter(@TypeOf(writer));

    const instruction: lib.Instruction = blk: {
        break :blk .{
            // try to load 32-bit instruction
            .full_backing = hart.loadMemory(32, hart.pc) catch |err| switch (err) {
                // try to load 16-bit compressed instruction
                error.ExecutionOutOfBounds => {
                    break :blk .{
                        .compressed_backing = .{
                            .low = hart.loadMemory(16, hart.pc) catch |compressed_err| switch (compressed_err) {
                                // TODO: Pass `InstructionAccessFault` once `throw` is implemented
                                error.ExecutionOutOfBounds => {
                                    try throw(mode, hart, {}, 0, writer);
                                    return;
                                },
                                else => |e| return e,
                            },
                        },
                    };
                },
                else => |e| return e,
            },
        };
    };
    if (has_writer) {
        try writer.print("pc: 0x{x:0>16}\n", .{hart.pc});
    }

    try execute(mode, hart, instruction, writer);
}

fn execute(comptime mode: lib.Mode, hart: *lib.Hart(mode), instruction: lib.Instruction, writer: anytype) !void {
    const has_writer = comptime isWriter(@TypeOf(writer));
    _ = has_writer;

    _ = hart;
    _ = instruction;
    @panic("UNIMPLEMENTED");
}

fn throw(comptime mode: lib.Mode, hart: *lib.Hart(mode), exception: void, value: u64, writer: anytype) !void {
    const has_writer = comptime isWriter(@TypeOf(writer));
    _ = has_writer;
    _ = hart;
    _ = exception;
    _ = value;
    @panic("UNIMPLEMENTED"); // TODO: Exceptions
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
