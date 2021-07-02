const std = @import("std");

pub const InstructionType = enum {
    // I

    /// add upper immediate to pc
    AUIPC,

    /// jump and link
    JAL,

    /// branch not equal
    BNE,

    // Zicsr

    /// atomic read and set bits in csr
    CSRRS,
};

comptime {
    std.testing.refAllDecls(@This());
}
