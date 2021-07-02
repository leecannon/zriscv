const std = @import("std");

pub const InstructionType = enum {
    // I

    /// add upper immediate to pc
    AUIPC,
    /// jump and link
    JAL,

    // add immediate
    ADDI,

    /// branch not equal
    BNE,

    // Zicsr

    // atomic read/write csr
    CSRRW,
    /// atomic read and set bits in csr
    CSRRS,
    /// atomic read/write csr - immediate
    CSRRWI,
};

comptime {
    std.testing.refAllDecls(@This());
}
