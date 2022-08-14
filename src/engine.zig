const std = @import("std");

const Hart = @import("hart.zig").Hart;

pub const Mode = enum {
    user,
    system,
};

/// Execute instructions until an exception is encountered
///
/// Note: `writer` may be void (`{}`) inorder to suppress output
pub inline fn run(comptime mode: Mode, state: *Hart(mode), writer: anytype) !void {
    while (true) try step(mode, state, writer);
}

/// Execute a single instruction
///
/// Note: `writer` may be void (`{}`) inorder to suppress output
pub fn step(comptime mode: Mode, state: *Hart(mode), writer: anytype) !void {
    _ = state;
    _ = writer;
    @panic("unimplemented");

    // decode

    // execute
}

inline fn isWriter(comptime T: type) bool {
    return std.meta.trait.hasFn("print")(T);
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
