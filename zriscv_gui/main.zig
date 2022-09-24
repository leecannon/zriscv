const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const args = @import("args");
const tracy = @import("tracy");
const zriscv = @import("zriscv");

// Configure tracy
pub const trace = build_options.trace;
pub const trace_callstack = build_options.trace_callstack;

pub fn main() void {
    std.debug.print("Hello from gzriscv!\n", .{});
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
