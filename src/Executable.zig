const std = @import("std");

const Executable = @This();

pub const Format = enum {
    flat,
    elf,
};

pub const RegionDescriptor = struct {
    start_address: usize,
    memory: []const u8,
};

contents: []align(std.mem.page_size) const u8,
region_description: []const RegionDescriptor,
start_address: usize,

pub fn load(
    allocator: std.mem.Allocator,
    stderr: anytype,
    file_path: []const u8,
    opt_format: ?Format,
    opt_start_address: ?usize,
) Executable {
    const contents = mapFile(file_path, stderr);

    const format = if (opt_format) |f| f else @panic("UNIMPLEMENTED"); // TODO: Autodetect file format

    var start_address: usize = undefined;
    var region_description: []RegionDescriptor = undefined;

    switch (format) {
        .flat => {
            region_description = allocator.alloc(RegionDescriptor, 1) catch {
                stderr.writeAll("ERROR: failed to allocate memory\n") catch unreachable;
                std.process.exit(1);
            };
            region_description[0] = .{
                .start_address = 0,
                .memory = contents,
            };

            start_address = if (opt_start_address) |addr| addr else 0;
        },
        .elf => @panic("UNIMPLEMENTED"), // TODO: Add ELF parsing
    }

    return Executable{
        .contents = contents,
        .region_description = region_description,
        .start_address = start_address,
    };
}

fn mapFile(file_path: []const u8, stderr: anytype) []align(std.mem.page_size) u8 {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => stderr.print(
                "ERROR: file not found: {s}\n",
                .{file_path},
            ) catch unreachable,
            else => |e| stderr.print(
                "ERROR: failed to open file '{s}': {s}\n",
                .{ file_path, @errorName(e) },
            ) catch unreachable,
        }

        std.process.exit(1);
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        stderr.print(
            "ERROR: failed to stat file '{s}': {s}\n",
            .{ file_path, @errorName(err) },
        ) catch unreachable;
        std.process.exit(1);
    };

    const ptr = std.os.mmap(
        null,
        stat.size,
        std.os.PROT.READ,
        std.os.MAP.PRIVATE,
        file.handle,
        0,
    ) catch |err| {
        stderr.print(
            "ERROR: failed to map file '{s}': {s}\n",
            .{ file_path, @errorName(err) },
        ) catch unreachable;
        std.process.exit(1);
    };

    return ptr[0..stat.size];
}

pub fn unload(self: Executable, allocator: std.mem.Allocator) void {
    allocator.free(self.region_description);
    std.os.munmap(self.contents);
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
