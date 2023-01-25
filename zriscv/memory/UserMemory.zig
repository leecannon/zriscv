const std = @import("std");
const zriscv = @import("zriscv");
const tracy = @import("tracy");

const UserMemory = @This();

allocator: std.mem.Allocator,

pub fn init(
    allocator: std.mem.Allocator,
) !UserMemory {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *UserMemory) void {
    _ = self;
    // TODO: user memory deinit
}

pub fn loadExecutable(self: *UserMemory, executable: zriscv.Executable) !void {
    _ = self;
    for (executable.region_description) |descriptor| {
        // TODO: For now we assume the executable can be mapped directly with no offsets

        const allocation_base = std.mem.alignBackward(descriptor.load_address, std.mem.page_size);
        const offset = descriptor.load_address - allocation_base;

        const minimum_length_of_allocation = offset + descriptor.length;
        const aligned_length = std.mem.alignForward(minimum_length_of_allocation, std.mem.page_size);

        const desired_ptr = @intToPtr(?[*]align(std.mem.page_size) u8, allocation_base);

        const mem = std.os.mmap(
            desired_ptr,
            aligned_length,
            std.os.PROT.READ | std.os.PROT.WRITE,
            std.os.MAP.PRIVATE | std.os.MAP.ANONYMOUS | std.os.MAP.FIXED_NOREPLACE,
            -1,
            0,
        ) catch return error.OutOfMemory;

        if (mem.ptr != desired_ptr) {
            // TODO: Our assumption about being to directly map the executable is false :(
            return error.CannotDirectMapExecutable;
        }

        std.mem.copy(u8, mem[offset..], descriptor.memory);

        if (!descriptor.flags.writeable) {
            try std.os.mprotect(mem, std.os.PROT.READ);
        }

        // TODO: Actually keep track of allocated memory
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
