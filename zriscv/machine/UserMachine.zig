const std = @import("std");
const zriscv = @import("zriscv");
const tracy = @import("tracy");

const UserMachine = @This();

allocator: std.mem.Allocator,
executable: zriscv.Executable,
memory: zriscv.UserMemory,

stack_size: usize,

hart_lock: std.Thread.Mutex = .{},
harts: std.ArrayListUnmanaged(*zriscv.UserHart) = .{},

pub fn create(
    allocator: std.mem.Allocator,
    executable: zriscv.Executable,
    stack_size: usize,
) !*UserMachine {
    const z = tracy.traceNamed(@src(), "user machine create");
    defer z.end();

    const self = try allocator.create(UserMachine);
    errdefer allocator.destroy(self);

    var memory = try zriscv.UserMemory.init(allocator);
    errdefer memory.deinit();

    self.* = .{
        .allocator = allocator,
        .executable = executable,
        .memory = memory,
        .stack_size = stack_size,
    };

    try self.memory.loadExecutable(self.executable);
    const hart = try self.createHart();
    zriscv.UserHart.current_hart = hart;

    return self;
}

pub fn createHart(self: *UserMachine) !*zriscv.UserHart {
    var hart = try zriscv.UserHart.create(self, self.stack_size);
    errdefer hart.destroy();

    hart.pc = self.executable.start_address;

    {
        self.hart_lock.lock();
        defer self.hart_lock.unlock();
        try self.harts.append(self.allocator, hart);
    }

    return hart;
}

pub fn destroy(self: *UserMachine) void {
    for (self.harts.items) |item| {
        item.destroy();
    }
    self.harts.deinit(self.allocator);
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
