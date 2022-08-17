const std = @import("std");
const lib = @import("lib.zig");

/// Execute instructions until an exception is encountered
///
/// Note: `writer` may be void (`{}`) in order to suppress output
pub inline fn run(comptime mode: lib.Mode, state: *lib.Hart(mode), writer: anytype) !void {
    while (true) try step(mode, state, writer);
}

/// Execute a single instruction
///
/// Note: `writer` may be void (`{}`) in order to suppress output
pub fn step(comptime mode: lib.Mode, state: *lib.Hart(mode), writer: anytype) !void {
    const has_writer = comptime isWriter(@TypeOf(writer));
    _ = has_writer;

    _ = state;
    @panic("UNIMPLEMENTED");

    // decode

    // execute
}

inline fn isWriter(comptime T: type) bool {
    return comptime std.meta.trait.hasFn("print")(T);
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
