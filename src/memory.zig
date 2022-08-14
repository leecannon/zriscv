const std = @import("std");

const engine = @import("engine.zig");
const Executable = @import("Executable.zig");

pub inline fn systemMemory(minimum_memory_size: usize) !Memory(.system) {
    return .{
        .impl = try SystemMemory.init(minimum_memory_size),
    };
}

pub inline fn userMemory(allocator: std.mem.Allocator) !Memory(.user) {
    return .{
        .impl = try UserMemory.init(allocator),
    };
}

pub fn Memory(comptime mode: engine.Mode) type {
    return struct {
        impl: if (mode == .system) SystemMemory else UserMemory,

        const Self = @This();

        pub inline fn deinit(self: *Self) void {
            self.impl.deinit();
        }

        pub inline fn reset(self: *Self) !void {
            return self.impl.reset();
        }

        pub inline fn loadExecutable(self: *Self, executable: Executable) !void {
            return self.impl.loadExecutable(executable);
        }
    };
}

// TODO: Thread-safety for mutliple harts
const SystemMemory = struct {
    memory: []align(std.mem.page_size) u8,

    pub fn init(minimum_memory_size: usize) !SystemMemory {
        return .{
            .memory = try allocateMemory(
                std.mem.alignForward(minimum_memory_size, std.mem.page_size),
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

    pub fn loadExecutable(self: *SystemMemory, executable: Executable) !void {
        for (executable.region_description) |descriptor| {
            if (descriptor.start_address + descriptor.memory.len > self.memory.len) return error.OutOfBoundsWrite;
            std.mem.copy(u8, self.memory[descriptor.start_address..], descriptor.memory);
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

const UserMemory = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: usize) !UserMemory {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UserMemory) void {
        _ = self;
        @panic("UNIMPLEMENTED");
    }

    pub fn reset(self: *UserMemory) void {
        _ = self;
        @panic("UNIMPLEMENTED");
    }

    pub fn loadExecutable(self: *SystemMemory, executable: Executable) !void {
        _ = self;
        _ = executable;
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
