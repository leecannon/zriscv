const std = @import("std");
const lib = @import("lib.zig");

pub const EngineOptions = struct {
    unrecognised_instruction_is_fatal: bool = true,
    execution_out_of_bounds_is_fatal: bool = true,

    /// this option is only taken into account if a writer is given
    always_print_pc: bool = true,
};

pub fn Engine(comptime options: EngineOptions) type {
    _ = options;
    return struct {
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
    };
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
