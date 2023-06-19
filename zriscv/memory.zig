const std = @import("std");
const zriscv = @import("zriscv");

pub inline fn Memory(comptime mode: zriscv.Mode) type {
    return switch (mode) {
        .system => SystemMemory,
        .user => UserMemory,
    };
}

// TODO: Thread-safety for mutliple harts
pub const SystemMemory = struct {
    memory: []align(std.mem.page_size) u8,

    pub fn init(minimum_memory_size: usize) !SystemMemory {
        return SystemMemory{
            .memory = try allocateMemory(
                std.mem.alignForward(usize, minimum_memory_size, std.mem.page_size),
            ),
        };
    }

    pub fn deinit(self: *SystemMemory) void {
        deallocateMemory(self.memory);
    }

    pub fn reset(self: *SystemMemory) !void {
        const memory_size = self.memory.len;
        deallocateMemory(self.memory);
        self.memory = try allocateMemory(memory_size);
    }

    pub fn loadExecutable(self: *SystemMemory, executable: zriscv.Executable) !void {
        for (executable.region_description) |descriptor| {
            if (descriptor.load_address + descriptor.length > self.memory.len) return error.OutOfBoundsWrite;
            std.mem.copy(u8, self.memory[descriptor.load_address..], descriptor.memory);
        }
    }

    fn allocateMemory(memory_size: usize) ![]align(std.mem.page_size) u8 {
        std.debug.assert(std.mem.isAligned(memory_size, std.mem.page_size));
        return std.os.mmap(
            null,
            memory_size,
            std.os.PROT.READ | std.os.PROT.WRITE,
            std.os.MAP.PRIVATE | std.os.MAP.ANONYMOUS,
            -1,
            0,
        ) catch error.OutOfMemory;
    }

    fn deallocateMemory(memory: []align(std.mem.page_size) const u8) void {
        std.os.munmap(memory);
    }
};

pub const UserMemory = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !UserMemory {
        return UserMemory{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UserMemory) void {
        _ = self;
        @panic("UNIMPLEMENTED: user memory deinit"); // TODO: user memory deinit
    }

    pub fn loadExecutable(self: *UserMemory, executable: zriscv.Executable) !void {
        _ = self;
        _ = executable;
        @panic("UNIMPLEMENTED: user memory load executable"); // TODO: user memory load executable
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
