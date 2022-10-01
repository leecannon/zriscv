const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const args = @import("args");
const tracy = @import("tracy");
const zriscv = @import("zriscv");

const State = @import("State.zig");

// Configure tracy
pub const trace = build_options.trace;
pub const trace_callstack = build_options.trace_callstack;

pub const is_debug_or_test = builtin.is_test or builtin.mode == .Debug;

pub fn main() if (is_debug_or_test) anyerror!u8 else u8 {
    const main_z = tracy.traceNamed(@src(), "main");
    // this causes the frame to start with our main instead of `std.start`
    tracy.traceFrameMark();

    var gpa = if (is_debug_or_test) std.heap.GeneralPurposeAllocator(.{}){} else {};

    defer {
        if (is_debug_or_test) _ = gpa.deinit();
        main_z.end();
    }

    const allocator = if (is_debug_or_test) gpa.allocator() else std.heap.c_allocator;

    const stderr = std.io.getStdErr().writer();

    var state = State.init(allocator, stderr) catch |err| {
        if (is_debug_or_test) return err;
        return 1;
    };
    defer if (is_debug_or_test) state.deinit();

    state.run() catch |err| {
        if (is_debug_or_test) return err;
        return 1;
    };

    return 0;
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
