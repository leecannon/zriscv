const std = @import("std");
const zriscv = @import("zriscv");
const tracy = @import("tracy");
const helpers = @import("../helpers.zig");

const UserHart = @This();

machine: *zriscv.UserMachine,

pc: usize = 0,
x: [32]u64 = [_]u64{0} ** 32,
cycle: u64 = 0,

pub threadlocal var current_hart: *UserHart = undefined;

pub fn create(machine: *zriscv.UserMachine, stack_size: usize) !*UserHart {
    std.debug.assert(stack_size != 0 and std.mem.isAligned(stack_size, std.mem.page_size));

    const self = try machine.allocator.create(UserHart);
    errdefer machine.allocator.destroy(self);

    self.* = .{
        .machine = machine,
    };

    const stack = std.os.mmap(
        null,
        stack_size,
        std.os.PROT.READ | std.os.PROT.WRITE,
        std.os.MAP.PRIVATE | std.os.MAP.ANONYMOUS,
        -1,
        0,
    ) catch return error.OutOfMemory;
    errdefer std.os.munmap(stack);

    self.x[@enumToInt(zriscv.IntegerRegister.sp)] = @ptrToInt(stack.ptr) + stack.len;

    return self;
}

pub fn destroy(self: *UserHart) void {
    self.machine.allocator.destroy(self);
}

pub fn loadMemory(
    self: *UserHart,
    comptime number_of_bits: comptime_int,
    virtual_address: u64,
) zriscv.LoadError!std.meta.Int(.unsigned, number_of_bits) {
    _ = self;
    const z = tracy.traceNamed(@src(), "user load memory");
    defer z.end();

    const MemoryType = std.meta.Int(.unsigned, number_of_bits);
    const number_of_bytes = @divExact(number_of_bits, 8);

    // TODO: Eventually memory mappings will have to be resolved here and checked

    return std.mem.readInt(
        MemoryType,
        @intToPtr([*]const u8, virtual_address)[0..number_of_bytes],
        .Little,
    );
}

pub fn storeMemory(
    self: *UserHart,
    comptime number_of_bits: comptime_int,
    virtual_address: u64,
    value: std.meta.Int(.unsigned, number_of_bits),
) zriscv.StoreError!void {
    _ = self;
    const z = tracy.traceNamed(@src(), "user store memory");
    defer z.end();

    const MemoryType = std.meta.Int(.unsigned, number_of_bits);
    const number_of_bytes = @divExact(number_of_bits, 8);

    // TODO: Eventually memory mappings will have to be resolved here and checked

    std.mem.writeInt(
        MemoryType,
        @intToPtr(*[number_of_bytes]u8, virtual_address),
        value,
        .Little,
    );
}

const syscall_number = @enumToInt(zriscv.IntegerRegister.a7);
const syscall_return = @enumToInt(zriscv.IntegerRegister.a0);
const syscall_return2 = @enumToInt(zriscv.IntegerRegister.a1);
const syscall_arg1 = @enumToInt(zriscv.IntegerRegister.a0);
const syscall_arg2 = @enumToInt(zriscv.IntegerRegister.a1);
const syscall_arg3 = @enumToInt(zriscv.IntegerRegister.a2);
const syscall_arg4 = @enumToInt(zriscv.IntegerRegister.a3);
const syscall_arg5 = @enumToInt(zriscv.IntegerRegister.a4);
const syscall_arg6 = @enumToInt(zriscv.IntegerRegister.a5);

pub fn handleSyscall(
    self: *zriscv.UserHart,
    writer: anytype,
    comptime options: zriscv.ExecutionOptions,
) !bool {
    _ = options;
    const syscall_trace = tracy.traceNamed(@src(), "handle syscall");
    defer syscall_trace.end();

    const has_writer = comptime helpers.isWriter(@TypeOf(writer));

    const syscall = std.meta.intToEnum(std.os.linux.syscalls.RiscV64, self.x[syscall_number]) catch {
        std.debug.panic("unrecognised syscall number: {}", .{self.x[syscall_number]});
    };

    switch (syscall) {
        .exit_group => {
            const exit_code = self.x[syscall_arg1];

            if (has_writer) {
                try writer.print("SYSCALL: exit_group, exit code: {}\n", .{exit_code});
            }

            _ = std.os.linux.syscall1(.exit_group, exit_code);
            unreachable;
        },
        .write => {
            const fd = self.x[syscall_arg1];
            const buf = self.x[syscall_arg2];
            const count = self.x[syscall_arg3];

            if (has_writer) {
                try writer.print("SYSCALL: write, fd: {}, buf: 0x{x}, count: {}\n", .{ fd, buf, count });
            }

            const return_value = std.os.linux.syscall3(.write, fd, buf, count);

            if (has_writer) {
                try writer.print("SYSCALL return value: {}\n", .{return_value});
            }

            self.x[syscall_return] = return_value;
        },
        else => |s| std.debug.panic("unimplemented syscall: {s}", .{@tagName(s)}),
    }

    return true;
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
