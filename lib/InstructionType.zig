const std = @import("std");

pub const InstructionType = enum {
    // 32I

    /// add upper immediate to pc
    AUIPC,
    /// jump and link
    JAL,
    // add immediate
    ADDI,
    /// branch not equal
    BNE,

    // 64I

    /// add immediate - 32 bit
    ADDIW,

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
