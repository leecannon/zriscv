const std = @import("std");
const zriscv = @import("zriscv");
const tracy = @import("tracy");

const SystemHart = @This();

hart_id: u64,
machine: *zriscv.SystemMachine,

pc: usize = 0,
x: [32]u64 = [_]u64{0} ** 32,
cycle: u64 = 0,

address_translation_mode: zriscv.AddressTranslationMode = .Bare,
privilege_level: zriscv.PrivilegeLevel = .Machine,

pub fn loadMemory(
    self: *SystemHart,
    comptime number_of_bits: comptime_int,
    virtual_address: u64,
) zriscv.LoadError!std.meta.Int(.unsigned, number_of_bits) {
    const z = tracy.traceNamed(@src(), "system load memory");
    defer z.end();

    const MemoryType = std.meta.Int(.unsigned, number_of_bits);

    const address = try self.translateAddress(virtual_address);

    const memory = &self.machine.memory;

    if (address + @sizeOf(MemoryType) >= memory.memory.len) {
        return zriscv.LoadError.ExecutionOutOfBounds;
    }

    return std.mem.readIntSlice(
        MemoryType,
        memory.memory[address..],
        .Little,
    );
}

pub fn storeMemory(
    self: *SystemHart,
    comptime number_of_bits: comptime_int,
    virtual_address: u64,
    value: std.meta.Int(.unsigned, number_of_bits),
) zriscv.StoreError!void {
    const z = tracy.traceNamed(@src(), "system store memory");
    defer z.end();

    const MemoryType = std.meta.Int(.unsigned, number_of_bits);
    const number_of_bytes = @divExact(number_of_bits, 8);

    const address = try self.translateAddress(virtual_address);

    const memory = &self.machine.memory;

    if (address + @sizeOf(MemoryType) >= memory.memory.len) {
        return zriscv.StoreError.ExecutionOutOfBounds;
    }

    std.mem.writeInt(
        MemoryType,
        @ptrCast(*[number_of_bytes]u8, memory.memory[address..].ptr),
        value,
        .Little,
    );
}

fn translateAddress(self: *SystemHart, virtual_address: u64) !u64 {
    const z = tracy.traceNamed(@src(), "system translate address");
    defer z.end();

    // TODO: Is this correct with multiple harts, atomic read?
    switch (self.address_translation_mode) {
        .Bare => return virtual_address,
        else => {
            std.log.err("unimplemented address translation mode", .{});
            return zriscv.LoadError.Unimplemented;
        },
    }
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
