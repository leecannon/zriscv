const std = @import("std");

pub const PrivilegeLevel = enum(u2) {
    User = 0,
    Supervisor = 1,
    Machine = 3,

    pub fn getPrivilegeLevel(value: u2) !PrivilegeLevel {
        return std.meta.intToEnum(PrivilegeLevel, value) catch {
            std.log.emerg("invalid privlege mode {b}", .{value});
            return error.InvalidPrivilegeLevel;
        };
    }
};

pub const IntegerRegister = enum(u5) {
    zero = 0,
    // return address
    ra = 1,
    // stack pointer
    sp = 2,
    // global pointer
    gp = 3,
    // thread pointer
    tp = 4,
    // temporaries
    t0 = 5,
    t1 = 6,
    t2 = 7,
    // saved register / frame pointer
    @"s0/fp" = 8,
    // saved register
    s1 = 9,
    // function arguments / return values
    a0 = 10,
    a1 = 11,
    // function arguments
    a2 = 12,
    a3 = 13,
    a4 = 14,
    a5 = 15,
    a6 = 16,
    a7 = 17,
    // saved registers
    s2 = 18,
    s3 = 19,
    s4 = 20,
    s5 = 21,
    s6 = 22,
    s7 = 23,
    s8 = 24,
    s9 = 25,
    s10 = 26,
    s11 = 27,
    // temporaries
    t3 = 28,
    t4 = 29,
    t5 = 30,
    t6 = 31,

    pub fn getIntegerRegister(value: usize) IntegerRegister {
        return std.meta.intToEnum(IntegerRegister, value) catch unreachable;
    }

    pub fn format(value: IntegerRegister, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll(value.getString());
    }

    pub fn getString(register: IntegerRegister) []const u8 {
        return switch (register) {
            .zero => "zero(x0)",
            .ra => "ra(x1)",
            .sp => "sp(x2)",
            .gp => "gp(x3)",
            .tp => "tp(x4)",
            .t0 => "t0(x5)",
            .t1 => "t1(x6)",
            .t2 => "t2(x7)",
            .@"s0/fp" => "s0/fp(x8)",
            .s1 => "s1(x9)",
            .a0 => "a0(x10)",
            .a1 => "a1(x11)",
            .a2 => "a2(x12)",
            .a3 => "a3(x13)",
            .a4 => "a4(x14)",
            .a5 => "a5(x15)",
            .a6 => "a6(x16)",
            .a7 => "a7(x17)",
            .s2 => "s2(x18)",
            .s3 => "s3(x19)",
            .s4 => "s4(x20)",
            .s5 => "s5(x21)",
            .s6 => "s6(x22)",
            .s7 => "s7(x23)",
            .s8 => "s8(x24)",
            .s9 => "s9(x25)",
            .s10 => "s10(x26)",
            .s11 => "s11(x27)",
            .t3 => "t3(x28)",
            .t4 => "t4(x29)",
            .t5 => "t5(x30)",
            .t6 => "t6(31)",
        };
    }
};

pub const ExceptionCode = enum(u63) {
    InstructionAddressMisaligned = 0,
    InstructionAccessFault = 1,
    IllegalInstruction = 2,
    Breakpoint = 3,
    LoadAddressMisaligned = 4,
    LoadAccessFault = 5,
    @"Store/AMOAddressMisaligned" = 6,
    @"Store/AMOAccessFault" = 7,
    EnvironmentCallFromUMode = 8,
    EnvironmentCallFromSMode = 9,
    EnvironmentCallFromMMode = 11,
    InstructionPageFault = 12,
    LoadPageFault = 13,
    Store_AMOPageFault = 15,
};

pub const ContextStatus = enum(u2) {
    Off = 0,
    Initial = 1,
    Clean = 2,
    Dirty = 3,

    pub fn getContextStatus(value: u2) !ContextStatus {
        return std.meta.intToEnum(ContextStatus, value) catch {
            std.log.emerg("invalid context status {b}", .{value});
            return error.InvalidContextStatus;
        };
    }
};

pub const VectorMode = enum(u2) {
    Direct,
    Vectored,

    pub fn getVectorMode(value: u2) !VectorMode {
        return std.meta.intToEnum(VectorMode, value) catch {
            std.log.emerg("invalid vector mode {b}", .{value});
            return error.InvalidVectorMode;
        };
    }
};

pub const AddressTranslationMode = enum(u4) {
    Bare = 0,
    Sv39 = 8,
    Sv48 = 9,

    pub fn getAddressTranslationMode(value: u4) !AddressTranslationMode {
        return std.meta.intToEnum(AddressTranslationMode, value) catch {
            std.log.emerg("invalid address translation mode {b}", .{value});
            return error.InvalidAddressTranslationMode;
        };
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
