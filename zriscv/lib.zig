const std = @import("std");

pub usingnamespace @import("types.zig");

const csr = @import("csr.zig");
pub const Csr = csr.Csr;

const execution = @import("execution.zig");
pub const ExecutionOptions = execution.ExecutionOptions;
pub const step = execution.step;

const machine = @import("machine.zig");
pub const Machine = machine.Machine;
pub const SystemMachine = machine.SystemMachine;
pub const UserMachine = machine.UserMachine;

const hart = @import("hart.zig");
pub const Hart = hart.Hart;
pub const SystemHart = hart.SystemHart;
pub const UserHart = hart.UserHart;

const memory = @import("memory.zig");
pub const Memory = memory.Memory;
pub const SystemMemory = memory.SystemMemory;
pub const UserMemory = memory.UserMemory;

const instruction = @import("instruction.zig");
pub const Instruction = instruction.Instruction;
pub const InstructionType = instruction.InstructionType;

pub const Executable = @import("Executable.zig");

pub const Mode = enum {
    user,
    system,
};

comptime {
    _ = @import("tests.zig");
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
