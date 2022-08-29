const std = @import("std");
const lib = @import("lib.zig");

pub inline fn Hart(comptime mode: lib.Mode) type {
    return switch (mode) {
        .system => SystemHart,
        .user => UserHart,
    };
}

const LoadError = error{
    ExecutionOutOfBounds,
    Unimplemented,
};

const StoreError = error{
    ExecutionOutOfBounds,
    Unimplemented,
};

pub const SystemHart = struct {
    hart_id: u64,
    machine: *lib.SystemMachine,

    pc: usize = 0,
    x: [32]u64 = [_]u64{0} ** 32,
    cycle: u64 = 0,

    address_translation_mode: lib.AddressTranslationMode = .Bare,
    privilege_level: lib.PrivilegeLevel = .Machine,

    pub fn loadMemory(
        self: *SystemHart,
        comptime number_of_bits: comptime_int,
        virtual_address: u64,
    ) LoadError!std.meta.Int(.unsigned, number_of_bits) {
        const z = lib.traceNamed(@src(), "system load memory");
        defer z.end();

        const MemoryType = std.meta.Int(.unsigned, number_of_bits);

        const address = try self.translateAddress(virtual_address);

        const memory = &self.machine.memory;

        if (address + @sizeOf(MemoryType) >= memory.memory.len) {
            return LoadError.ExecutionOutOfBounds;
        }

        return std.mem.readIntSlice(MemoryType, memory.memory[address..], .Little);
    }

    pub fn storeMemory(
        self: *SystemHart,
        comptime number_of_bits: comptime_int,
        virtual_address: u64,
        value: std.meta.Int(.unsigned, number_of_bits),
    ) StoreError!void {
        const z = lib.traceNamed(@src(), "system store memory");
        defer z.end();

        const MemoryType = std.meta.Int(.unsigned, number_of_bits);
        const number_of_bytes = @divExact(@typeInfo(MemoryType).Int.bits, 8);

        const address = try self.translateAddress(virtual_address);

        const memory = &self.machine.memory;

        if (address + @sizeOf(MemoryType) >= memory.memory.len) {
            return StoreError.ExecutionOutOfBounds;
        }

        std.mem.writeInt(MemoryType, @ptrCast(*[number_of_bytes]u8, memory.memory[address..].ptr), value, .Little);
    }

    fn translateAddress(self: *SystemHart, virtual_address: u64) !u64 {
        const z = lib.traceNamed(@src(), "system translate address");
        defer z.end();

        // TODO: Is this correct with multiple harts, atomic read?
        switch (self.address_translation_mode) {
            .Bare => return virtual_address,
            else => {
                std.log.err("unimplemented address translation mode", .{});
                return LoadError.Unimplemented;
            },
        }
    }
};

pub const UserHart = struct {
    hart_id: usize,
    machine: *lib.UserMachine,

    pc: usize = 0,
    x: [32]u64 = [_]u64{0} ** 32,
    cycle: u64 = 0,

    pub fn loadMemory(
        self: *UserHart,
        comptime number_of_bits: comptime_int,
        virtual_address: u64,
    ) LoadError!std.meta.Int(.unsigned, number_of_bits) {
        const z = lib.traceNamed(@src(), "user load memory");
        defer z.end();

        const MemoryType = std.meta.Int(.unsigned, number_of_bits);
        _ = MemoryType;

        _ = self;
        _ = virtual_address;
        @panic("UNIMPLEMENTED: user load memory"); // TODO: user load memory
    }

    pub fn storeMemory(
        self: *SystemHart,
        comptime number_of_bits: comptime_int,
        virtual_address: u64,
        value: std.meta.Int(.unsigned, number_of_bits),
    ) StoreError!void {
        const z = lib.traceNamed(@src(), "user store memory");
        defer z.end();

        const MemoryType = std.meta.Int(.unsigned, number_of_bits);
        _ = MemoryType;

        _ = self;
        _ = virtual_address;
        _ = value;
        @panic("UNIMPLEMENTED: user store memory"); // TODO: user store memory
    }
};

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
