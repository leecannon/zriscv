const std = @import("std");
const zriscv = @import("zriscv");
const tracy = @import("tracy");

pub inline fn Machine(comptime mode: zriscv.Mode) type {
    return switch (mode) {
        .system => SystemMachine,
        .user => UserMachine,
    };
}

pub const SystemMachine = struct {
    allocator: std.mem.Allocator,
    executable: zriscv.Executable,
    memory: zriscv.SystemMemory,
    harts: []zriscv.SystemHart,

    pub fn create(
        allocator: std.mem.Allocator,
        memory_size: usize,
        executable: zriscv.Executable,
        number_of_harts: usize,
    ) !*SystemMachine {
        const z = tracy.traceNamed(@src(), "system machine create");
        defer z.end();

        std.debug.assert(number_of_harts != 0); // non-zero number of harts required

        const self = try allocator.create(SystemMachine);
        errdefer allocator.destroy(self);

        var memory = try zriscv.SystemMemory.init(memory_size);
        errdefer memory.deinit();

        const harts = try allocator.alloc(zriscv.SystemHart, number_of_harts);
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
        const z = tracy.traceNamed(@src(), "system machine reset");
        defer z.end();

        for (self.harts, 0..) |*hart, i| {
            hart.* = .{
                .hart_id = i,
                .machine = self,
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

pub const UserMachine = struct {
    dummy: usize = 0,

    pub fn create(
        allocator: std.mem.Allocator,
    ) !*UserMachine {
        const z = tracy.traceNamed(@src(), "user machine create");
        defer z.end();

        const self = try allocator.create(UserMachine);
        errdefer allocator.destroy(self);

        self.* = .{};

        return self;
    }

    pub fn reset(self: *UserMachine, clear_memory: bool) !void {
        const z = tracy.traceNamed(@src(), "user machine reset");
        defer z.end();

        _ = self;
        _ = clear_memory;
        @panic("UNIMPLEMENTED: user machine reset"); // TODO: user machine reset
    }

    pub fn destroy(self: *UserMachine) !void {
        _ = self;
        @panic("UNIMPLEMENTED: user machine destroy"); // TODO: user machine destroy
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
