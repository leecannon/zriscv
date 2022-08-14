const std = @import("std");
const Memory = @import("Memory.zig");
const Hart = @import("Hart.zig");

const Machine = @This();

allocator: std.mem.Allocator,
memory: Memory,
harts: []Hart,

/// Create a machine with `number_of_harts` harts with `memory_description` describing the initial contents of memory.
pub fn create(
    allocator: std.mem.Allocator,
    memory_size: usize,
    memory_description: []const Memory.Descriptor,
    number_of_harts: usize,
) !*Machine {
    if (number_of_harts == 0) return error.NonZeroNumberOfHartsRequired;
    if (number_of_harts != 1) @panic("multiple harts is unimplemented");

    const self = try allocator.create(Machine);
    errdefer allocator.destroy(self);

    var memory = try Memory.init(memory_size);
    errdefer memory.deinit();

    for (memory_description) |descriptor| {
        try memory.addDescriptor(descriptor);
    }

    const harts = try allocator.alloc(Hart, number_of_harts);
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

pub fn reset(self: *Machine, memory_description: []const Memory.Descriptor) !void {
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
