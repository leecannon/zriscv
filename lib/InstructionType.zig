const std = @import("std");

pub const InstructionType = enum {
    // I

    /// Jump and link
    JAL,

    /// Branch Not Equal
    BNE,

    // Zicsr

    /// Atomic Read and Set Bits in CSR
    CSRRS,
};

comptime {
    std.testing.refAllDecls(@This());
}
