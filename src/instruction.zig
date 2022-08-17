const std = @import("std");
const lib = @import("lib.zig");

pub const Instruction = extern union {
    compressed_backing: CompressedBacking,
    full_backing: u32,

    pub const CompressedBacking = extern struct {
        low: u16,
        high: u16 = 0,

        comptime {
            std.debug.assert(@sizeOf(CompressedBacking) == @sizeOf(u32));
            std.debug.assert(@bitSizeOf(CompressedBacking) == @bitSizeOf(u32));
        }
    };

    comptime {
        std.debug.assert(@sizeOf(Instruction) == @sizeOf(u32));
        std.debug.assert(@bitSizeOf(Instruction) == @bitSizeOf(u32));
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
