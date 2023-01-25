const std = @import("std");

pub usingnamespace @import("types.zig");

const csr = @import("csr.zig");
pub const Csr = csr.Csr;

const execution = @import("execution.zig");
pub const ExecutionOptions = execution.ExecutionOptions;
pub const step = execution.step;

pub inline fn Machine(comptime mode: Mode) type {
    return switch (mode) {
        .system => SystemMachine,
        .user => UserMachine,
    };
}
pub const SystemMachine = @import("machine/SystemMachine.zig");
pub const UserMachine = @import("machine/UserMachine.zig");

pub const LoadError = error{
    ExecutionOutOfBounds,
    Unimplemented,
};

pub const StoreError = error{
    ExecutionOutOfBounds,
    Unimplemented,
};

pub inline fn Hart(comptime mode: Mode) type {
    return switch (mode) {
        .system => SystemHart,
        .user => UserHart,
    };
}
pub const SystemHart = @import("hart/SystemHart.zig");
pub const UserHart = @import("hart/UserHart.zig");

pub inline fn Memory(comptime mode: Mode) type {
    return switch (mode) {
        .system => SystemMemory,
        .user => UserMemory,
    };
}
pub const SystemMemory = @import("memory/SystemMemory.zig");
pub const UserMemory = @import("memory/UserMemory.zig");

const instruction = @import("instruction.zig");
pub const Instruction = instruction.Instruction;
pub const InstructionType = instruction.InstructionType;

pub const Executable = @import("Executable.zig");

pub const Mode = enum {
    user,
    system,
};

comptime {
    _ = @import("helpers.zig");
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
