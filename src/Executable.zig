const std = @import("std");
const lib = @import("lib.zig");

const Executable = @This();

pub const RegionDescriptor = struct {
    load_address: u64,
    // This length can be less than the length of `memory`, this allows a region to have a zeroed section
    length: u64,
    memory: []const u8,
    flags: Flags,

    pub const Flags = struct {
        readable: bool,
        writeable: bool,
        executable: bool,
    };
};

contents: []align(std.mem.page_size) const u8,
region_description: []const RegionDescriptor,
start_address: u64,

pub fn load(allocator: std.mem.Allocator, stderr: anytype, file_path: []const u8) !Executable {
    const z = lib.traceNamed(@src(), "executable loading");
    defer z.end();

    const contents = try mapFile(file_path, stderr);

    const elf_header = ElfHeader.read(contents) catch |err| {
        stderr.print("ERROR: invalid ELF file: {s}\n", .{@errorName(err)}) catch unreachable;
        return err;
    };

    if (elf_header.machine != .RISCV) {
        stderr.writeAll("ERROR: ELF file is not risc-v\n") catch unreachable;
        return error.ElfNotRiscV;
    }

    if (!elf_header.is_64) {
        stderr.writeAll("ERROR: ELF file is not 64-bit\n") catch unreachable;
        return error.ElfNot64Bit;
    }

    if (elf_header.endian != .Little) {
        stderr.writeAll("ERROR: ELF file is not little endian\n") catch unreachable;
        return error.ElfNotLittleEndian;
    }

    if (elf_header.@"type" != .EXEC) {
        stderr.writeAll("ERROR: ELF file is not an executable\n") catch unreachable;
        return error.ElfNotAnExecutable;
    }

    var regions: std.ArrayListUnmanaged(RegionDescriptor) = .{};
    errdefer regions.deinit(allocator);

    var program_header_iter: ProgramHeaderIterator = .{
        .elf_header = elf_header,
        .source = contents,
    };

    while (program_header_iter.next()) |program_header| {
        switch (program_header.p_type) {
            std.elf.PT_NULL, std.elf.PT_NOTE, std.elf.PT_PHDR, std.elf.PT_NUM => {}, // ignored
            std.elf.PT_LOAD => {
                regions.append(allocator, .{
                    .load_address = program_header.p_vaddr,
                    .length = program_header.p_memsz,
                    .memory = contents[program_header.p_offset..(program_header.p_offset + program_header.p_filesz)],
                    .flags = .{
                        .readable = program_header.p_flags & std.elf.PF_R != 0,
                        .writeable = program_header.p_flags & std.elf.PF_W != 0,
                        .executable = program_header.p_flags & std.elf.PF_X != 0,
                    },
                }) catch |err| {
                    stderr.writeAll("ERROR: ELF file is not little endian\n") catch unreachable;
                    return err;
                };
            },
            std.elf.PT_DYNAMIC => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: PT_DYNAMIC\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.PT_INTERP => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: PT_INTERP\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.PT_SHLIB => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: PT_SHLIB\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.PT_TLS => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: PT_TLS\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.PT_GNU_EH_FRAME => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: PT_GNU_EH_FRAME\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.PT_GNU_STACK => {
                // TODO: Support PT_GNU_STACK
            },
            std.elf.PT_GNU_RELRO => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: PT_GNU_RELRO\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            0x70000003 => {
                // RISCV ATTRIBUTES as specified here: https://github.com/riscv-non-isa/riscv-elf-psabi-doc
                continue;
            },
            else => {
                if (program_header.p_type >= std.elf.PT_LOOS and program_header.p_type <= std.elf.PT_HIOS) {
                    stderr.print("unhandled OS specific program header: 0x{x}\n", .{program_header.p_type}) catch unreachable;
                    continue;
                }

                if (program_header.p_type >= std.elf.PT_LOPROC and program_header.p_type <= std.elf.PT_HIPROC) {
                    stderr.print("unhandled processor specific program header: 0x{x}\n", .{program_header.p_type}) catch unreachable;
                    continue;
                }

                stderr.print("ERROR: unknown program section type in ELF file: 0x{x}\n", .{program_header.p_type}) catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
        }
    }

    return Executable{
        .contents = contents,
        .region_description = regions.toOwnedSlice(allocator),
        .start_address = elf_header.entry,
    };
}

const native_endian = @import("builtin").target.cpu.arch.endian();

// Copied from `std.elf.Header` but includes the Elf type
const ElfHeader = struct {
    endian: std.builtin.Endian,
    @"type": std.elf.ET,
    machine: std.elf.EM,
    is_64: bool,
    entry: u64,
    phoff: u64,
    shoff: u64,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,

    // Copied from `std.elf.Header.read` but specialised to work on slice instead of a file
    pub fn read(source: []const u8) !ElfHeader {
        var hdr_buf: [@sizeOf(std.elf.Elf64_Ehdr)]u8 align(@alignOf(std.elf.Elf64_Ehdr)) = undefined;
        std.mem.copy(u8, std.mem.asBytes(&hdr_buf), source[0..@sizeOf(std.elf.Elf64_Ehdr)]);
        return ElfHeader.parse(&hdr_buf);
    }

    // Copied from `std.elf.Header.parse` but specialised to work on slice instead of a file
    pub fn parse(hdr_buf: *align(@alignOf(std.elf.Elf64_Ehdr)) const [@sizeOf(std.elf.Elf64_Ehdr)]u8) !ElfHeader {
        const hdr32 = @ptrCast(*const std.elf.Elf32_Ehdr, hdr_buf);
        const hdr64 = @ptrCast(*const std.elf.Elf64_Ehdr, hdr_buf);
        if (!std.mem.eql(u8, hdr32.e_ident[0..4], std.elf.MAGIC)) return error.InvalidElfMagic;
        if (hdr32.e_ident[std.elf.EI_VERSION] != 1) return error.InvalidElfVersion;

        const endian: std.builtin.Endian = switch (hdr32.e_ident[std.elf.EI_DATA]) {
            std.elf.ELFDATA2LSB => .Little,
            std.elf.ELFDATA2MSB => .Big,
            else => return error.InvalidElfEndian,
        };
        const need_bswap = endian != native_endian;

        const is_64 = switch (hdr32.e_ident[std.elf.EI_CLASS]) {
            std.elf.ELFCLASS32 => false,
            std.elf.ELFCLASS64 => true,
            else => return error.InvalidElfClass,
        };

        const machine = if (need_bswap) blk: {
            const value = @enumToInt(hdr32.e_machine);
            break :blk @intToEnum(std.elf.EM, @byteSwap(u16, value));
        } else hdr32.e_machine;

        const @"type" = if (need_bswap) blk: {
            const value = @enumToInt(hdr32.e_type);
            break :blk @intToEnum(std.elf.ET, @byteSwap(u16, value));
        } else hdr32.e_type;

        return ElfHeader{
            .endian = endian,
            .machine = machine,
            .is_64 = is_64,
            .@"type" = @"type",
            .entry = std.elf.int(is_64, need_bswap, hdr32.e_entry, hdr64.e_entry),
            .phoff = std.elf.int(is_64, need_bswap, hdr32.e_phoff, hdr64.e_phoff),
            .shoff = std.elf.int(is_64, need_bswap, hdr32.e_shoff, hdr64.e_shoff),
            .phentsize = std.elf.int(is_64, need_bswap, hdr32.e_phentsize, hdr64.e_phentsize),
            .phnum = std.elf.int(is_64, need_bswap, hdr32.e_phnum, hdr64.e_phnum),
            .shentsize = std.elf.int(is_64, need_bswap, hdr32.e_shentsize, hdr64.e_shentsize),
            .shnum = std.elf.int(is_64, need_bswap, hdr32.e_shnum, hdr64.e_shnum),
            .shstrndx = std.elf.int(is_64, need_bswap, hdr32.e_shstrndx, hdr64.e_shstrndx),
        };
    }

    pub fn program_header_iterator(self: ElfHeader, source: []const u8) ProgramHeaderIterator {
        return .{
            .elf_header = self,
            .source = source,
        };
    }
};

// Copied from `std.elf.Header.ProgramHeaderIterator` but specialised to work on slice instead of a file
const ProgramHeaderIterator = struct {
    elf_header: ElfHeader,
    source: []const u8,
    index: usize = 0,

    pub fn next(self: *@This()) ?std.elf.Elf64_Phdr {
        if (self.index >= self.elf_header.phnum) return null;
        defer self.index += 1;

        if (self.elf_header.is_64) {
            var phdr: std.elf.Elf64_Phdr = undefined;
            const offset = self.elf_header.phoff + @sizeOf(@TypeOf(phdr)) * self.index;
            std.mem.copy(u8, std.mem.asBytes(&phdr), self.source[offset..(offset + @sizeOf(std.elf.Elf64_Phdr))]);

            // ELF endianness matches native endianness.
            if (self.elf_header.endian == native_endian) return phdr;

            // Convert fields to native endianness.
            std.mem.byteSwapAllFields(std.elf.Elf64_Phdr, &phdr);
            return phdr;
        }

        var phdr: std.elf.Elf32_Phdr = undefined;
        const offset = self.elf_header.phoff + @sizeOf(@TypeOf(phdr)) * self.index;
        std.mem.copy(u8, std.mem.asBytes(&phdr), self.source[offset..(offset + @sizeOf(std.elf.Elf32_Phdr))]);

        // ELF endianness does NOT match native endianness.
        if (self.elf_header.endian != native_endian) {
            // Convert fields to native endianness.
            std.mem.byteSwapAllFields(std.elf.Elf32_Phdr, &phdr);
        }

        // Convert 32-bit header to 64-bit.
        return std.elf.Elf64_Phdr{
            .p_type = phdr.p_type,
            .p_offset = phdr.p_offset,
            .p_vaddr = phdr.p_vaddr,
            .p_paddr = phdr.p_paddr,
            .p_filesz = phdr.p_filesz,
            .p_memsz = phdr.p_memsz,
            .p_flags = phdr.p_flags,
            .p_align = phdr.p_align,
        };
    }
};

fn mapFile(file_path: []const u8, stderr: anytype) ![]align(std.mem.page_size) u8 {
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

        return err;
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        stderr.print(
            "ERROR: failed to stat file '{s}': {s}\n",
            .{ file_path, @errorName(err) },
        ) catch unreachable;
        return err;
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
        return err;
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
