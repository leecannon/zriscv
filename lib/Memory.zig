const std = @import("std");

const Memory = @This();

// TODO: Thread-safety for mutliple harts

memory: []align(std.mem.page_size) u8,

pub fn init(minimum_memory_size: usize) !Memory {
    return Memory{
        .memory = try allocateMemory(
            std.mem.alignForward(minimum_memory_size, std.mem.page_size),
        ),
    };
}

pub fn deinit(self: *Memory) void {
    deallocateMemory(self.memory);
}

pub fn reset(self: *Memory) !void {
    const memory_size = self.memory.len;
    deallocateMemory(self.memory);
    self.memory = try allocateMemory(memory_size);
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

pub fn addDescriptor(self: *Memory, descriptor: MemoryDescriptor) !void {
    if (descriptor.start_address + descriptor.memory.len > self.memory.len) return error.OutOfBoundsWrite;
    std.mem.copy(u8, self.memory[descriptor.start_address..], descriptor.memory);
}

pub const MemoryDescriptor = struct {
    start_address: usize,
    memory: []const u8,
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
