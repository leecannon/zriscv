const std = @import("std");
const zriscv = @import("zriscv");
const tracy = @import("tracy");

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
file_path: []const u8,

/// Start of the riscof signature, only defined in riscof mode
begin_signature: u64 = undefined,

/// End of the riscof signature, only defined in riscof mode
end_signature: u64 = undefined,

/// The 'tohost' symbol used for riscof test to tell the runner to stop, only defined in riscof mode
tohost: u64 = undefined,

pub fn load(allocator: std.mem.Allocator, stderr: anytype, file_path: []const u8, riscof_mode: bool) !Executable {
    const z = tracy.traceNamed(@src(), "executable loading");
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

    if (elf_header.endian != .little) {
        stderr.writeAll("ERROR: ELF file is not little endian\n") catch unreachable;
        return error.ElfNotLittleEndian;
    }

    if (elf_header.type != .EXEC) {
        stderr.writeAll("ERROR: ELF file is not an executable\n") catch unreachable;
        return error.ElfNotAnExecutable;
    }

    const section_headers = try elf_header.getSectionHeaders(allocator, contents);
    defer allocator.free(section_headers);

    const program_headers = try elf_header.getProgramHeaders(allocator, contents);
    defer allocator.free(program_headers);

    var opt_symbol_section: ?std.elf.Elf64_Shdr = null;

    for (section_headers) |section_header| {
        switch (section_header.sh_type) {
            std.elf.SHT_SYMTAB, std.elf.SHT_DYNSYM => {
                if (opt_symbol_section != null) {
                    stderr.writeAll("ERROR: symbol table already located?\n") catch unreachable;
                    return error.MultipleSymbolTablesInElf;
                }
                opt_symbol_section = section_header;
            },
            std.elf.SHT_STRTAB => {}, // these are referenced using the `sh_link`: field https://stackoverflow.com/a/69888949
            std.elf.SHT_NULL, std.elf.SHT_PROGBITS => {}, // ignored
            0x70000003 => {
                // RISCV ATTRIBUTES as specified here: https://github.com/riscv-non-isa/riscv-elf-psabi-doc
                continue;
            },
            std.elf.SHT_RELA => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: SHT_RELA\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.SHT_HASH => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: SHT_HASH\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.SHT_DYNAMIC => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: SHT_DYNAMIC\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.SHT_NOTE => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: SHT_NOTE\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.SHT_NOBITS => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: SHT_NOBITS\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.SHT_REL => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: SHT_REL\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.SHT_SHLIB => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: SHT_SHLIB\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.SHT_INIT_ARRAY => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: SHT_INIT_ARRAY\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.SHT_FINI_ARRAY => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: SHT_FINI_ARRAY\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.SHT_PREINIT_ARRAY => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: SHT_PREINIT_ARRAY\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.SHT_GROUP => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: SHT_GROUP\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            std.elf.SHT_SYMTAB_SHNDX => {
                stderr.writeAll("ERROR: unsupported program section type in ELF file: SHT_SYMTAB_SHNDX\n") catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
            else => {
                if (section_header.sh_type >= std.elf.SHT_LOOS and section_header.sh_type <= std.elf.SHT_HIOS) {
                    stderr.print("unhandled OS specific section header: 0x{x}\n", .{section_header.sh_type}) catch unreachable;
                    continue;
                }

                if (section_header.sh_type >= std.elf.SHT_LOPROC and section_header.sh_type <= std.elf.SHT_HIPROC) {
                    stderr.print("unhandled processor specific section header: 0x{x}\n", .{section_header.sh_type}) catch unreachable;
                    continue;
                }

                if (section_header.sh_type >= std.elf.SHT_LOUSER and section_header.sh_type <= std.elf.SHT_HIUSER) {
                    stderr.print("unhandled user specific section header: 0x{x}\n", .{section_header.sh_type}) catch unreachable;
                    continue;
                }

                stderr.print("ERROR: unknown program section type in ELF file: 0x{x}\n", .{section_header.sh_type}) catch unreachable;
                return error.UnsupportedProgramSectionInElf;
            },
        }
    }

    const symbol_section = opt_symbol_section orelse {
        stderr.writeAll("ERROR: no symbol section in ELF file\n") catch unreachable;
        return error.NoSymbolSectionInElf;
    };

    const string_section = blk: {
        if (symbol_section.sh_link == 0) {
            stderr.writeAll("ERROR: no string table in ELF\n") catch unreachable;
            return error.NoStringTableInElf;
        }
        if (symbol_section.sh_link >= section_headers.len) {
            stderr.print("ERROR: symbol section's link is to header {} but only {} headers are present\n", .{ symbol_section.sh_link, elf_header.shnum }) catch unreachable;
            return error.NoStringTableInElf;
        }
        break :blk section_headers[symbol_section.sh_link];
    };

    var symbols_to_find = std.ArrayList([]const u8).init(allocator);
    defer symbols_to_find.deinit();

    if (riscof_mode) {
        try symbols_to_find.append("begin_signature");
        try symbols_to_find.append("end_signature");
        try symbols_to_find.append("tohost");
    }

    var symbols = try elf_header.findSymbols(allocator, symbol_section, string_section, contents, symbols_to_find.items);
    defer symbols.deinit();

    var regions: std.ArrayListUnmanaged(RegionDescriptor) = .{};
    defer regions.deinit(allocator);

    for (program_headers) |program_header| {
        switch (program_header.p_type) {
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
            0x70000003 => {
                // RISCV ATTRIBUTES as specified here: https://github.com/riscv-non-isa/riscv-elf-psabi-doc
                continue;
            },
            std.elf.PT_GNU_STACK => {
                // TODO: Support PT_GNU_STACK
            },
            std.elf.PT_NULL, std.elf.PT_NOTE, std.elf.PT_PHDR, std.elf.PT_NUM => {}, // ignored
            std.elf.PT_DYNAMIC => {
                stderr.writeAll("ERROR: unsupported program header type in ELF file: PT_DYNAMIC\n") catch unreachable;
                return error.UnsupportedProgramHeaderInElf;
            },
            std.elf.PT_INTERP => {
                stderr.writeAll("ERROR: unsupported program header type in ELF file: PT_INTERP\n") catch unreachable;
                return error.UnsupportedProgramHeaderInElf;
            },
            std.elf.PT_SHLIB => {
                stderr.writeAll("ERROR: unsupported program header type in ELF file: PT_SHLIB\n") catch unreachable;
                return error.UnsupportedProgramHeaderInElf;
            },
            std.elf.PT_TLS => {
                stderr.writeAll("ERROR: unsupported program header type in ELF file: PT_TLS\n") catch unreachable;
                return error.UnsupportedProgramHeaderInElf;
            },
            std.elf.PT_GNU_EH_FRAME => {
                stderr.writeAll("ERROR: unsupported program header type in ELF file: PT_GNU_EH_FRAME\n") catch unreachable;
                return error.UnsupportedProgramHeaderInElf;
            },
            std.elf.PT_GNU_RELRO => {
                stderr.writeAll("ERROR: unsupported program header type in ELF file: PT_GNU_RELRO\n") catch unreachable;
                return error.UnsupportedProgramHeaderInElf;
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

                stderr.print("ERROR: unknown program header type in ELF file: 0x{x}\n", .{program_header.p_type}) catch unreachable;
                return error.UnsupportedProgramHeaderInElf;
            },
        }
    }

    var executable = Executable{
        .contents = contents,
        .region_description = try regions.toOwnedSlice(allocator),
        .start_address = elf_header.entry,
        .file_path = file_path,
    };

    if (riscof_mode) {
        if (symbols.get("begin_signature")) |begin_signature| {
            executable.begin_signature = begin_signature;
        } else {
            stderr.writeAll("ERROR: ELF file does not contain 'begin_signature' section required for riscof mode\n") catch unreachable;
            return error.NoBeginSignatureInElf;
        }
        if (symbols.get("end_signature")) |end_signature| {
            executable.end_signature = end_signature;
        } else {
            stderr.writeAll("ERROR: ELF file does not contain 'end_signature' section required for riscof mode\n") catch unreachable;
            return error.NoEndSignatureInElf;
        }
        if (symbols.get("tohost")) |tohost| {
            executable.tohost = tohost;
        } else {
            stderr.writeAll("ERROR: ELF file does not contain 'tohost' section required for riscof mode\n") catch unreachable;
            return error.NoToHostInElf;
        }
    }

    return executable;
}

const native_endian = @import("builtin").target.cpu.arch.endian();

// Copied from `std.elf.Header` but includes the Elf type
const ElfHeader = struct {
    endian: std.builtin.Endian,
    type: std.elf.ET,
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
        const hdr32: *const std.elf.Elf32_Ehdr = @ptrCast(hdr_buf);
        const hdr64: *const std.elf.Elf64_Ehdr = @ptrCast(hdr_buf);
        if (!std.mem.eql(u8, hdr32.e_ident[0..4], std.elf.MAGIC)) return error.InvalidElfMagic;
        if (hdr32.e_ident[std.elf.EI_VERSION] != 1) return error.InvalidElfVersion;

        const endian: std.builtin.Endian = switch (hdr32.e_ident[std.elf.EI_DATA]) {
            std.elf.ELFDATA2LSB => .little,
            std.elf.ELFDATA2MSB => .big,
            else => return error.InvalidElfEndian,
        };
        const need_bswap = endian != native_endian;

        const is_64 = switch (hdr32.e_ident[std.elf.EI_CLASS]) {
            std.elf.ELFCLASS32 => false,
            std.elf.ELFCLASS64 => true,
            else => return error.InvalidElfClass,
        };

        const machine: std.elf.EM = if (need_bswap) blk: {
            const value = @intFromEnum(hdr32.e_machine);
            break :blk @enumFromInt(@byteSwap(value));
        } else hdr32.e_machine;

        const @"type": std.elf.ET = if (need_bswap) blk: {
            const value = @intFromEnum(hdr32.e_type);
            break :blk @enumFromInt(@byteSwap(value));
        } else hdr32.e_type;

        return ElfHeader{
            .endian = endian,
            .machine = machine,
            .is_64 = is_64,
            .type = @"type",
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

    pub fn getSectionHeaders(self: ElfHeader, allocator: std.mem.Allocator, contents: []const u8) ![]const std.elf.Elf64_Shdr {
        var sections = try allocator.alloc(std.elf.Elf64_Shdr, self.shnum);
        errdefer allocator.free(sections);

        var i: usize = 0;
        while (i < self.shnum) : (i += 1) {
            if (self.is_64) {
                const offset = self.shoff + @sizeOf(std.elf.Elf64_Shdr) * i;
                std.mem.copy(u8, std.mem.asBytes(&sections[i]), contents[offset..(offset + @sizeOf(std.elf.Elf64_Shdr))]);

                // ELF endianness does NOT match native endianness.
                if (self.endian != native_endian) {
                    // Convert fields to native endianness.
                    std.mem.byteSwapAllFields(std.elf.Elf64_Shdr, &sections[i]);
                }
            } else {
                const offset = self.shoff + @sizeOf(std.elf.Elf32_Shdr) * i;
                var shdr: std.elf.Elf32_Shdr = undefined;
                std.mem.copy(u8, std.mem.asBytes(&shdr), contents[offset..(offset + @sizeOf(std.elf.Elf32_Shdr))]);

                // ELF endianness does NOT match native endianness.
                if (self.endian != native_endian) {
                    // Convert fields to native endianness.
                    std.mem.byteSwapAllFields(std.elf.Elf32_Shdr, &shdr);
                }

                sections[i] = .{
                    .sh_name = shdr.sh_name,
                    .sh_type = shdr.sh_type,
                    .sh_flags = shdr.sh_flags,
                    .sh_addr = shdr.sh_addr,
                    .sh_offset = shdr.sh_offset,
                    .sh_size = shdr.sh_size,
                    .sh_link = shdr.sh_link,
                    .sh_info = shdr.sh_info,
                    .sh_addralign = shdr.sh_addralign,
                    .sh_entsize = shdr.sh_entsize,
                };
            }
        }

        return sections;
    }

    pub fn getProgramHeaders(self: ElfHeader, allocator: std.mem.Allocator, contents: []const u8) ![]const std.elf.Elf64_Phdr {
        var program_headers = try allocator.alloc(std.elf.Elf64_Phdr, self.phnum);
        errdefer allocator.free(program_headers);

        var i: usize = 0;
        while (i < self.phnum) : (i += 1) {
            if (self.is_64) {
                const offset = self.phoff + @sizeOf(std.elf.Elf64_Phdr) * i;
                std.mem.copy(u8, std.mem.asBytes(&program_headers[i]), contents[offset..(offset + @sizeOf(std.elf.Elf64_Phdr))]);

                // ELF endianness does NOT match native endianness.
                if (self.endian != native_endian) {
                    // Convert fields to native endianness.
                    std.mem.byteSwapAllFields(std.elf.Elf64_Phdr, &program_headers[i]);
                }
            } else {
                const offset = self.phoff + @sizeOf(std.elf.Elf32_Phdr) * i;
                var phdr: std.elf.Elf32_Phdr = undefined;
                std.mem.copy(u8, std.mem.asBytes(&phdr), contents[offset..(offset + @sizeOf(std.elf.Elf32_Phdr))]);

                // ELF endianness does NOT match native endianness.
                if (self.endian != native_endian) {
                    // Convert fields to native endianness.
                    std.mem.byteSwapAllFields(std.elf.Elf32_Phdr, &phdr);
                }

                program_headers[i] = .{
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
        }

        return program_headers;
    }

    pub fn findSymbols(
        self: ElfHeader,
        allocator: std.mem.Allocator,
        symbol_section: std.elf.Elf64_Shdr,
        string_section: std.elf.Elf64_Shdr,
        contents: []const u8,
        symbol_names: []const []const u8,
    ) !std.StringHashMap(u64) {
        var symbols = std.StringHashMap(u64).init(allocator);
        errdefer symbols.deinit();

        try symbols.ensureTotalCapacity(@intCast(symbol_names.len));

        const symbol_section_source = contents[symbol_section.sh_offset..(symbol_section.sh_offset + symbol_section.sh_size)];
        const string_section_source = contents[string_section.sh_offset..(string_section.sh_offset + string_section.sh_size) :0];

        outer: for (symbol_names) |symbol_name| {
            var symbol_iter: SymbolIterator = .{
                .elf_header = self,
                .symbol_section_source = symbol_section_source,
            };

            while (symbol_iter.next()) |symbol| {
                const name = std.mem.sliceTo(string_section_source[symbol.st_name..], 0);

                if (std.mem.eql(u8, symbol_name, name)) {
                    symbols.putAssumeCapacity(name, symbol.st_value);
                    continue :outer;
                }
            }
        }

        return symbols;
    }

    const SymbolIterator = struct {
        elf_header: ElfHeader,
        symbol_section_source: []const u8,
        start: usize = 0,

        pub fn next(self: *@This()) ?std.elf.Elf64_Sym {
            if (self.elf_header.is_64) {
                const end = (self.start + @sizeOf(std.elf.Elf64_Sym));
                if (end > self.symbol_section_source.len) return null;

                var sym: std.elf.Elf64_Sym = undefined;
                std.mem.copy(u8, std.mem.asBytes(&sym), self.symbol_section_source[self.start..end]);
                self.start += @sizeOf(std.elf.Elf64_Sym);

                // ELF endianness matches native endianness.
                if (self.elf_header.endian == native_endian) return sym;

                // Convert fields to native endianness.
                std.mem.byteSwapAllFields(std.elf.Elf64_Sym, &sym);
                return sym;
            }

            const end = (self.start + @sizeOf(std.elf.Elf64_Sym));
            if (end > self.symbol_section_source.len) return null;

            var sym: std.elf.Elf32_Sym = undefined;
            std.mem.copy(u8, std.mem.asBytes(&sym), self.symbol_section_source[self.start..end]);
            self.start += @sizeOf(std.elf.Elf32_Sym);

            // ELF endianness does NOT match native endianness.
            if (self.elf_header.endian != native_endian) {
                // Convert fields to native endianness.
                std.mem.byteSwapAllFields(std.elf.Elf32_Sym, &sym);
            }

            return std.elf.Elf64_Sym{
                .st_name = sym.st_name,
                .st_info = sym.st_info,
                .st_other = sym.st_other,
                .st_shndx = sym.st_shndx,
                .st_value = sym.st_value,
                .st_size = sym.st_size,
            };
        }
    };
};

const Symbol = struct {
    name: []const u8,
    value: ?u64,
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
