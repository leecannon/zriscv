const std = @import("std");

const Machine = @import("machine.zig").Machine;
const engine = @import("engine.zig");

pub fn Hart(comptime mode: engine.Mode) type {
    return struct {
        hart_id: usize,
        machine: Machine(mode),

        pc: usize = 0,
        x: [32]u64 = [_]u64{0} ** 32,
    };
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
