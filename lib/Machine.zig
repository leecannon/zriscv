const std = @import("std");
const lib = @import("lib.zig");

const Machine = @This();

allocator: std.mem.Allocator,
memory: lib.Memory,
harts: []lib.Hart,

/// Create a machine with `number_of_harts` harts with `memory_description` describing the initial contents of memory.
pub fn create(
    allocator: std.mem.Allocator,
    memory_size: usize,
    memory_description: []const lib.MemoryDescriptor,
    number_of_harts: usize,
) !*Machine {
    if (number_of_harts == 0) return error.NonZeroNumberOfHartsRequired;
    if (number_of_harts != 1) @panic("multiple harts is unimplemented");

    const self = try allocator.create(Machine);
    errdefer allocator.destroy(self);

    var memory = try lib.Memory.init(memory_size);
    errdefer memory.deinit();

    for (memory_description) |descriptor| {
        try memory.addDescriptor(descriptor);
    }

    const harts = try allocator.alloc(lib.Hart, number_of_harts);
    errdefer allocator.free(harts);

    for (harts) |*hart, i| {
        hart.* = .{
            .hart_id = i,
            .machine = self,
        };
    }

    self.* = .{
        .allocator = allocator,
        .memory = memory,
        .harts = harts,
    };

    return self;
}

pub fn reset(self: *Machine, memory_description: []const lib.MemoryDescriptor) !void {
    for (self.harts) |*hart, i| {
        hart.* = .{
            .hart_id = i,
            .machine = self,
        };
    }

    try self.memory.reset();

    for (memory_description) |descriptor| {
        try self.memory.addDescriptor(descriptor);
    }
}

pub fn destory(self: *Machine) void {
    self.allocator.free(self.harts);
    self.memory.deinit();
    self.allocator.destroy(self);
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
