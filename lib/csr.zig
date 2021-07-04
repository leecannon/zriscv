const std = @import("std");
const bitjuggle = @import("bitjuggle");
usingnamespace @import("types.zig");

pub const Csr = enum(u12) {
    /// Supervisor address translation and protection
    satp = 0x180,

    /// Supervisor trap handler base address
    stvec = 0x105,

    /// Supervisor exception program counter
    sepc = 0x141,

    /// Supervisor trap cause
    scause = 0x142,

    /// Supervisor bad address or instruction
    stval = 0x143,

    /// Hardware thread ID
    mhartid = 0xF14,

    /// Machine status register
    mstatus = 0x300,

    /// Machine trap-handler base address
    mtvec = 0x305,

    /// Machine exception delegation register
    medeleg = 0x302,

    /// Machine interrupt delegation register
    mideleg = 0x303,

    /// Machine interrupt-enable register
    mie = 0x304,

    /// Machine exception program counter
    mepc = 0x341,

    /// Machine trap cause
    mcause = 0x342,

    /// Machine bad address or instruction
    mtval = 0x343,

    /// Machine interrupt pending
    mip = 0x344,

    /// Physical memory protection configuration
    pmpcfg0 = 0x3A0,
    pmpcfg2 = 0x3A2,
    pmpcfg4 = 0x3A4,
    pmpcfg6 = 0x3A6,
    pmpcfg8 = 0x3A8,
    pmpcfg10 = 0x3AA,
    pmpcfg12 = 0x3AC,
    pmpcfg14 = 0x3AE,

    /// Physical memory protection address register
    pmpaddr0 = 0x3B0,
    pmpaddr1 = 0x3B1,
    pmpaddr2 = 0x3B2,
    pmpaddr3 = 0x3B3,
    pmpaddr4 = 0x3B4,
    pmpaddr5 = 0x3B5,
    pmpaddr6 = 0x3B6,
    pmpaddr7 = 0x3B7,
    pmpaddr8 = 0x3B8,
    pmpaddr9 = 0x3B9,
    pmpaddr10 = 0x3BA,
    pmpaddr11 = 0x3BB,
    pmpaddr12 = 0x3BC,
    pmpaddr13 = 0x3BD,
    pmpaddr14 = 0x3BE,
    pmpaddr15 = 0x3BF,
    pmpaddr16 = 0x3C0,
    pmpaddr17 = 0x3C1,
    pmpaddr18 = 0x3C2,
    pmpaddr19 = 0x3C3,
    pmpaddr20 = 0x3C4,
    pmpaddr21 = 0x3C5,
    pmpaddr22 = 0x3C6,
    pmpaddr23 = 0x3C7,
    pmpaddr24 = 0x3C8,
    pmpaddr25 = 0x3C9,
    pmpaddr26 = 0x3CA,
    pmpaddr27 = 0x3CB,
    pmpaddr28 = 0x3CC,
    pmpaddr29 = 0x3CD,
    pmpaddr30 = 0x3CE,
    pmpaddr31 = 0x3CF,
    pmpaddr32 = 0x3D0,
    pmpaddr33 = 0x3D1,
    pmpaddr34 = 0x3D2,
    pmpaddr35 = 0x3D3,
    pmpaddr36 = 0x3D4,
    pmpaddr37 = 0x3D5,
    pmpaddr38 = 0x3D6,
    pmpaddr39 = 0x3D7,
    pmpaddr40 = 0x3D8,
    pmpaddr41 = 0x3D9,
    pmpaddr42 = 0x3DA,
    pmpaddr43 = 0x3DB,
    pmpaddr44 = 0x3DC,
    pmpaddr45 = 0x3DD,
    pmpaddr46 = 0x3DE,
    pmpaddr47 = 0x3DF,
    pmpaddr48 = 0x3E0,
    pmpaddr49 = 0x3E1,
    pmpaddr50 = 0x3E2,
    pmpaddr51 = 0x3E3,
    pmpaddr52 = 0x3E4,
    pmpaddr53 = 0x3E5,
    pmpaddr54 = 0x3E6,
    pmpaddr55 = 0x3E7,
    pmpaddr56 = 0x3E8,
    pmpaddr57 = 0x3E9,
    pmpaddr58 = 0x3EA,
    pmpaddr59 = 0x3EB,
    pmpaddr60 = 0x3EC,
    pmpaddr61 = 0x3ED,
    pmpaddr62 = 0x3EE,
    pmpaddr63 = 0x3EF,

    pub fn getCsr(value: u12) !Csr {
        return std.meta.intToEnum(Csr, value) catch {
            std.log.emerg("invalid csr 0x{X}", .{value});
            return error.InvalidCsr;
        };
    }

    pub fn canRead(self: Csr, privilege_level: PrivilegeLevel) bool {
        const csr_value = @enumToInt(self);

        const lowest_privilege_level = bitjuggle.getBits(csr_value, 8, 2);
        if (@enumToInt(privilege_level) < lowest_privilege_level) return false;

        return true;
    }

    pub fn canWrite(self: Csr, privilege_level: PrivilegeLevel) bool {
        const csr_value = @enumToInt(self);

        const lowest_privilege_level = bitjuggle.getBits(csr_value, 8, 2);
        if (@enumToInt(privilege_level) < lowest_privilege_level) return false;

        return bitjuggle.getBits(csr_value, 10, 2) != @as(u12, 0b11);
    }
};

pub const Mstatus = extern union {
    /// supervisor interrupts enabled
    sie: bitjuggle.Bitfield(u64, 1, 1),
    /// machine interrupts enabled
    mie: bitjuggle.Bitfield(u64, 3, 1),
    /// supervisor interrupts enabled - prior
    spie: bitjuggle.Bitfield(u64, 5, 1),
    // user endian
    ube: bitjuggle.Bitfield(u64, 6, 1),
    /// machine interrupts enabled - prior
    mpie: bitjuggle.Bitfield(u64, 7, 1),
    /// supervisor previous privilege level
    spp: bitjuggle.Bitfield(u64, 8, 1),
    /// machine previous privilege level
    mpp: bitjuggle.Bitfield(u64, 11, 2),
    /// floating point state
    fs: bitjuggle.Bitfield(u64, 13, 2),
    /// extension state
    xs: bitjuggle.Bitfield(u64, 15, 2),
    /// modify privilege of loads and stores
    mprv: bitjuggle.Bitfield(u64, 17, 1),
    /// supervisor user memory access
    sum: bitjuggle.Bitfield(u64, 18, 1),
    /// make executable readable
    mxr: bitjuggle.Bitfield(u64, 19, 1),
    /// trap virtual memory
    tvm: bitjuggle.Bitfield(u64, 20, 1),
    /// timeout wait
    tw: bitjuggle.Bitfield(u64, 21, 1),
    /// trap sret
    tsr: bitjuggle.Bitfield(u64, 22, 1),
    /// user X-LEN
    uxl: bitjuggle.Bitfield(u64, 32, 2),
    /// supervisor X-LEN
    sxl: bitjuggle.Bitfield(u64, 34, 2),
    // supervisor endian
    sbe: bitjuggle.Bitfield(u64, 36, 1),
    // machine endian
    mbe: bitjuggle.Bitfield(u64, 37, 1),
    /// state dirty
    sd: bitjuggle.Bitfield(u64, 63, 1),

    backing: u64,

    pub const unmodifiable_mask: u64 = blk: {
        var unmodifiable = Mstatus{ .backing = 0 };

        unmodifiable.ube.write(1);
        unmodifiable.uxl.write(std.math.maxInt(u2));
        unmodifiable.sxl.write(std.math.maxInt(u2));
        unmodifiable.sbe.write(1);
        unmodifiable.mbe.write(1);

        break :blk unmodifiable.backing;
    };

    pub const modifiable_mask = ~unmodifiable_mask;

    pub const initial_state: Mstatus = blk: {
        var initial = Mstatus{ .backing = 0 };

        initial.mpp.write(@enumToInt(PrivilegeLevel.Machine));
        initial.spp.write(@enumToInt(PrivilegeLevel.Supervisor));
        initial.fs.write(@enumToInt(ContextStatus.Initial));
        initial.xs.write(@enumToInt(ContextStatus.Initial));
        initial.uxl.write(2);
        initial.sxl.write(2);

        break :blk initial;
    };
};

pub const MCause = extern union {
    code: bitjuggle.Bitfield(u64, 0, 63),
    interrupt: bitjuggle.Bitfield(u64, 63, 1),

    backing: u64,
};

pub const Mtvec = extern union {
    mode: bitjuggle.Bitfield(u64, 0, 2),
    base: bitjuggle.Bitfield(u64, 2, 62),

    backing: u64,
};

pub const Stvec = extern union {
    mode: bitjuggle.Bitfield(u64, 0, 2),
    base: bitjuggle.Bitfield(u64, 2, 62),

    backing: u64,
};

pub const SCause = extern union {
    code: bitjuggle.Bitfield(u64, 0, 63),
    interrupt: bitjuggle.Bitfield(u64, 63, 1),

    backing: u64,
};

pub const Satp = extern union {
    ppn: bitjuggle.Bitfield(u64, 0, 44),
    asid: bitjuggle.Bitfield(u64, 44, 16),
    mode: bitjuggle.Bitfield(u64, 60, 4),

    backing: u64,
};

comptime {
    std.testing.refAllDecls(@This());
}
