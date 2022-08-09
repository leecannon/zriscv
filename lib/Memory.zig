const std = @import("std");

const Memory = @This();

// TODO: Thread-safety for mutliple harts

allocator: std.mem.Allocator,
// TODO: Better data structure, we do inserts into the middle
chunks: std.ArrayListUnmanaged(MemoryChunk) = .{},

pub fn init(allocator: std.mem.Allocator) Memory {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *Memory) void {
    for (self.chunks.items) |chunk| {
        self.allocator.free(chunk.memory[0..(chunk.end_address - chunk.start_address)]);
    }
    self.chunks.deinit(self.allocator);
}

pub fn reset(self: *Memory) void {
    for (self.chunks.items) |chunk| {
        self.allocator.free(chunk.memory[0..(chunk.end_address - chunk.start_address)]);
    }
    self.chunks.clearRetainingCapacity();
}

pub fn addDescriptor(self: *Memory, descriptor: MemoryDescriptor) !void {
    // TODO: this function should support merging touching chunks

    const descriptor_end_address = descriptor.start_address + descriptor.memory.len;

    var new_index: usize = 0;
    for (self.chunks.items) |chunk| {
        // we are before this chunk with no overlap, this is where we should be
        if (descriptor_end_address <= chunk.start_address) break;

        // the descriptor starts before this chunk ends, but as the above `descriptor_end_address <= chunk.start_address`
        // was false it must end *after* the start of this chunk therefore it overlaps
        if (descriptor.start_address < chunk.end_address) return error.OverlappingDescriptor;

        new_index += 1;
    }

    const new_chunk = try self.allocator.dupe(u8, descriptor.memory);
    errdefer self.allocator.free(new_chunk);

    try self.chunks.insert(self.allocator, new_index, .{
        .start_address = descriptor.start_address,
        .end_address = descriptor.start_address + new_chunk.len,
        .memory = new_chunk.ptr,
    });
}

pub const MemoryDescriptor = struct {
    start_address: usize,
    memory: []const u8,
};

const MemoryChunk = struct {
    start_address: usize,
    /// exclusive
    end_address: usize,
    memory: [*]u8,
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
