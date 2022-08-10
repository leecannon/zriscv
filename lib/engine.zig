const std = @import("std");
const lib = @import("lib.zig");

/// Execute instructions until an exception is encountered
///
/// Note: `writer` may be void (`{}`) inorder to suppress output
pub inline fn run(state: *lib.Hart, writer: anytype) !void {
    while (true) try step(state, writer);
}

/// Execute a single instruction
///
/// Note: `writer` may be void (`{}`) inorder to suppress output
pub fn step(state: *lib.Hart, writer: anytype) !void {
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
    std.testing.refAllDeclsRecursive(@This());
}
