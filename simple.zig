const std = @import("std");

pub export fn _start() callconv(.Naked) noreturn {
    const stdout = std.io.getStdOut();
    stdout.writeAll("Hello World!\n") catch {};
    std.os.exit(42);
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = msg;
    _ = error_return_trace;
    _ = ret_addr;
    while (true) {}
}
