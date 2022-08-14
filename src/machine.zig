const std = @import("std");

const Executable = @import("Executable.zig");
const Memory = @import("memory.zig").Memory;
const Hart = @import("hart.zig").Hart;
const engine = @import("engine.zig");

pub inline fn systemMachine(
    allocator: std.mem.Allocator,
    memory_size: usize,
    executable: Executable,
    number_of_harts: usize,
) !Machine(.system) {
    return Machine(.system){
        .impl = try SystemMachine.create(
            allocator,
            memory_size,
            executable,
            number_of_harts,
        ),
    };
}

pub inline fn userMachine(allocator: std.mem.Allocator) !Machine(.user) {
    return Machine(.user){
        .impl = try UserMachine.create(allocator),
    };
}

pub fn Machine(comptime mode: engine.Mode) type {
    return struct {
        impl: if (mode == .system) *SystemMachine else *UserMachine,

        const Self = @This();

        pub fn reset(self: Self, clear_memory: bool) !void {
            return self.impl.reset(clear_memory);
        }

        pub fn destroy(self: Self) void {
            self.impl.destroy();
        }
    };
}

const SystemMachine = struct {
    allocator: std.mem.Allocator,
    executable: Executable,
    memory: Memory(.system),
    harts: []Hart(.system),

    pub fn create(
        allocator: std.mem.Allocator,
        memory_size: usize,
        executable: Executable,
        number_of_harts: usize,
    ) !*SystemMachine {
        std.debug.assert(number_of_harts != 0); // non-zero number of harts required
        if (number_of_harts > 1) @panic("UNIMPLEMENTED"); // TODO: Multiple harts

        const self = try allocator.create(SystemMachine);
        errdefer allocator.destroy(self);

        var memory = try @import("memory.zig").systemMemory(memory_size);
        errdefer memory.deinit();

        const harts = try allocator.alloc(Hart(.system), number_of_harts);
        errdefer allocator.free(harts);

        self.* = .{
            .allocator = allocator,
            .executable = executable,
            .memory = memory,
            .harts = harts,
        };

        try self.reset(false);

        return self;
    }

    pub fn reset(self: *SystemMachine, clear_memory: bool) !void {
        for (self.harts) |*hart, i| {
            hart.* = .{
                .hart_id = i,
                .machine = .{ .impl = self },
                .pc = self.executable.start_address,
            };
        }

        if (clear_memory) {
            try self.memory.reset();
        }
        try self.memory.loadExecutable(self.executable);
    }

    pub fn destroy(self: *SystemMachine) void {
        self.allocator.free(self.harts);
        self.memory.deinit();
        self.allocator.destroy(self);
    }
};

const UserMachine = struct {
    dummy: usize = 0,

    pub fn create(
        allocator: std.mem.Allocator,
    ) !*UserMachine {
        const self = try allocator.create(UserMachine);
        errdefer allocator.destroy(self);

        self.* = .{};

        return self;
    }

    pub fn reset(self: *UserMachine, clear_memory: bool) !void {
        _ = self;
        _ = clear_memory;
        @panic("UNIMPLEMENTED");
    }

    pub fn destroy(self: *UserMachine) !void {
        _ = self;
        @panic("UNIMPLEMENTED");
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
