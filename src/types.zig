const std = @import("std");
const lib = @import("lib.zig");

pub const AddressTranslationMode = enum(u4) {
    Bare = 0,
    Sv39 = 8,
    Sv48 = 9,

    pub fn getAddressTranslationMode(value: u4) !AddressTranslationMode {
        return std.meta.intToEnum(AddressTranslationMode, value) catch {
            std.log.err("invalid address translation mode {b}", .{value});
            return error.InvalidAddressTranslationMode;
        };
    }
};

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
