const std = @import("std");

pub const InstructionType = enum {
    // 32I

    /// load upper immediate
    LUI,
    /// add upper immediate to pc
    AUIPC,
    /// jump and link
    JAL,
    /// branch equal
    BEQ,
    /// branch not equal
    BNE,
    /// branch greater equal
    BGE,
    /// add immediate
    ADDI,
    /// logical left shift
    SLLI,

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
