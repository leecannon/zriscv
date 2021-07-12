const std = @import("std");
usingnamespace @import("types.zig");
usingnamespace @import("csr.zig");

const CpuState = @This();

memory: []u8,
x: [32]u64 = [_]u64{0} ** 32,
pc: usize = 0,
privilege_level: PrivilegeLevel = .Machine,

mstatus: Mstatus = Mstatus.initial_state,
/// mstatus:sie
supervisor_interrupts_enabled: bool = false,
/// mstatus:spie
supervisor_interrupts_enabled_prior: bool = false,
/// mstatus:spp
supervisor_previous_privilege_level: PrivilegeLevel = .Supervisor,
/// mstatus:mie
machine_interrupts_enabled: bool = false,
/// mstatus:mpie
machine_interrupts_enabled_prior: bool = false,
/// mstatus:mpp
machine_previous_privilege_level: PrivilegeLevel = .Machine,
/// mstatus:fs
floating_point_status: ContextStatus = .Initial,
/// mstatus:xs
extension_status: ContextStatus = .Initial,
/// mstatus:ds
state_dirty: bool = false,
/// mstatus:mprv
modify_privilege: bool = false,
/// mstatus:sum
supervisor_user_memory_access: bool = false,
/// mstatus:mxr
executable_readable: bool = false,
/// mstatus:tvm
trap_virtual_memory: bool = false,
/// mstatus:tw
timeout_wait: bool = false,
/// mstatus:tsr
trap_sret: bool = false,

mepc: u64 = 0,
mcause: MCause = .{ .backing = 0 },
mtval: u64 = 0,

sepc: u64 = 0,
scause: SCause = .{ .backing = 0 },
stval: u64 = 0,

mhartid: u64 = 0,

mtvec: Mtvec = .{ .backing = 0 },
machine_vector_base_address: u64 = 0,
machine_vector_mode: VectorMode = .Direct,

stvec: Stvec = .{ .backing = 0 },
supervisor_vector_base_address: u64 = 0,
supervisor_vector_mode: VectorMode = .Direct,

satp: Satp = .{ .backing = 0 },
address_translation_mode: AddressTranslationMode = .Bare,
asid: u16 = 0,
ppn_address: u64 = 0,

medeleg: u64 = 0,
mideleg: u64 = 0,

mie: u64 = 0,
mip: u64 = 0,

pub fn dump(self: CpuState, writer: anytype) !void {
    var i: usize = 0;
    while (i < 32 - 3) : (i += 4) {
        if (i == 0) {
            try writer.print("{s:>9}: 0x{x:<16} {s:>9}: 0x{x:<16} {s:>9}: 0x{x:<16} {s:>9}: 0x{x:<16}\n", .{
                "pc",
                self.pc,
                IntegerRegister.getIntegerRegister(i + 1).getString(),
                self.x[i + 1],
                IntegerRegister.getIntegerRegister(i + 2).getString(),
                self.x[i + 2],
                IntegerRegister.getIntegerRegister(i + 3).getString(),
                self.x[i + 3],
            });
            continue;
        }

        try writer.print("{s:>9}: 0x{x:<16} {s:>9}: 0x{x:<16} {s:>9}: 0x{x:<16} {s:>9}: 0x{x:<16}\n", .{
            IntegerRegister.getIntegerRegister(i).getString(),
            self.x[i],
            IntegerRegister.getIntegerRegister(i + 1).getString(),
            self.x[i + 1],
            IntegerRegister.getIntegerRegister(i + 2).getString(),
            self.x[i + 2],
            IntegerRegister.getIntegerRegister(i + 3).getString(),
            self.x[i + 3],
        });
    }

    try writer.print("privilege: {s} - mhartid: {} - machine interrupts: {} - super interrupts: {}\n", .{
        @tagName(self.privilege_level),
        self.mhartid,
        self.machine_interrupts_enabled,
        self.supervisor_interrupts_enabled,
    });
    try writer.print("super interrupts prior: {} - super previous privilege: {s}\n", .{
        self.supervisor_interrupts_enabled_prior,
        @tagName(self.supervisor_previous_privilege_level),
    });
    try writer.print("machine interrupts prior: {} - machine previous privilege: {s}\n", .{
        self.machine_interrupts_enabled_prior,
        @tagName(self.machine_previous_privilege_level),
    });
    try writer.print("mcause: {x} - machine exception pc: 0x{x} - machine trap value {}\n", .{
        self.mcause.backing,
        self.mepc,
        self.mtval,
    });
    try writer.print("scause: {x} - super exception pc: 0x{x} - super trap value {}\n", .{
        self.scause.backing,
        self.sepc,
        self.stval,
    });
    try writer.print("address mode: {s} - asid: {} - ppn address: 0x{x}\n", .{
        @tagName(self.address_translation_mode),
        self.asid,
        self.ppn_address,
    });
    try writer.print("medeleg: 0b{b:0>64}\n", .{self.medeleg});
    try writer.print("mideleg: 0b{b:0>64}\n", .{self.mideleg});
    try writer.print("mie:     0b{b:0>64}\n", .{self.mie});
    try writer.print("mip:     0b{b:0>64}\n", .{self.mip});
    try writer.print("machine vector mode:    {s}    machine vector base address: 0x{x}\n", .{
        @tagName(self.machine_vector_mode),
        self.machine_vector_base_address,
    });
    try writer.print("super vector mode:      {s} super vector base address: 0x{x}\n", .{
        @tagName(self.supervisor_vector_mode),
        self.supervisor_vector_base_address,
    });
    try writer.print("dirty state: {} - floating point: {s} - extension: {s}\n", .{
        self.state_dirty,
        @tagName(self.floating_point_status),
        @tagName(self.extension_status),
    });
    try writer.print("modify privilege: {} - super user access: {} - execute readable: {}\n", .{
        self.modify_privilege,
        self.supervisor_user_memory_access,
        self.executable_readable,
    });
    try writer.print("trap virtual memory: {} - timeout wait: {} - trap sret: {}\n", .{
        self.trap_virtual_memory,
        self.timeout_wait,
        self.trap_sret,
    });
}

comptime {
    std.testing.refAllDecls(@This());
}
