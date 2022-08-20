const std = @import("std");
const build_options = @import("build_options");

const enable: bool = build_options.trace;
const enable_callstack: bool = build_options.trace_callstack;
const callstack_depth = 20;

const ___tracy_c_zone_context = extern struct {
    id: u32,
    active: c_int,
};

const Ctx = struct {
    ctx: if (enable) ___tracy_c_zone_context else void = if (enable) .{ .id = 0, .active = 0 } else {},

    pub inline fn end(self: @This()) void {
        if (!enable) return;
        ___tracy_emit_zone_end(self.ctx);
    }

    pub inline fn addText(self: @This(), text: []const u8) void {
        if (!enable) return;
        ___tracy_emit_zone_text(self.ctx, text.ptr, text.len);
    }

    pub inline fn setName(self: @This(), name: []const u8) void {
        if (!enable) return;
        ___tracy_emit_zone_name(self.ctx, name.ptr, name.len);
    }

    pub inline fn setColor(self: @This(), color: u32) void {
        if (!enable) return;
        ___tracy_emit_zone_color(self.ctx, color);
    }

    pub inline fn setValue(self: @This(), value: u64) void {
        if (!enable) return;
        ___tracy_emit_zone_value(self.ctx, value);
    }
};

pub inline fn trace(comptime src: std.builtin.SourceLocation) Ctx {
    if (!enable) return .{};

    if (enable_callstack) {
        return .{ .ctx = ___tracy_emit_zone_begin_callstack(&.{
            .name = null,
            .function = src.fn_name.ptr,
            .file = src.file.ptr,
            .line = src.line,
            .color = 0,
        }, callstack_depth, 1) };
    } else {
        return .{ .ctx = ___tracy_emit_zone_begin(&.{
            .name = null,
            .function = src.fn_name.ptr,
            .file = src.file.ptr,
            .line = src.line,
            .color = 0,
        }, 1) };
    }
}

pub inline fn traceNamed(comptime src: std.builtin.SourceLocation, comptime name: [:0]const u8) Ctx {
    if (!enable) return .{};

    if (enable_callstack) {
        return .{ .ctx = ___tracy_emit_zone_begin_callstack(&.{
            .name = name.ptr,
            .function = src.fn_name.ptr,
            .file = src.file.ptr,
            .line = src.line,
            .color = 0,
        }, callstack_depth, 1) };
    } else {
        return .{ .ctx = ___tracy_emit_zone_begin(&.{
            .name = name.ptr,
            .function = src.fn_name.ptr,
            .file = src.file.ptr,
            .line = src.line,
            .color = 0,
        }, 1) };
    }
}

pub fn tracyAllocator(allocator: std.mem.Allocator) TracyAllocator(null) {
    return TracyAllocator(null).init(allocator);
}

fn TracyAllocator(comptime name: ?[:0]const u8) type {
    return struct {
        parent_allocator: std.mem.Allocator,

        first_allocation: bool = true,

        const Self = @This();

        pub fn init(parent_allocator: std.mem.Allocator) Self {
            return .{ .parent_allocator = parent_allocator };
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return std.mem.Allocator.init(self, allocFn, resizeFn, freeFn);
        }

        fn allocFn(self: *Self, len: usize, ptr_align: u29, len_align: u29, ret_addr: usize) std.mem.Allocator.Error![]u8 {
            if (self.first_allocation) {
                const val: u1 = 0;
                // this is to prevent a visual glitch with tracys graph when the application makes very few allocations
                if (name) |n| {
                    ___tracy_emit_memory_alloc_named(&val, 0, 0, n.ptr);
                    ___tracy_emit_memory_free_named(&val, 0, n.ptr);
                } else {
                    ___tracy_emit_memory_alloc(&val, 0, 0);
                    ___tracy_emit_memory_free(&val, 0);
                }
                self.first_allocation = false;
            }

            const result = self.parent_allocator.rawAlloc(len, ptr_align, len_align, ret_addr);
            if (result) |data| {
                if (data.len != 0) {
                    if (name) |n| {
                        allocNamed(data.ptr, data.len, n);
                    } else {
                        alloc(data.ptr, data.len);
                    }
                }
            } else |_| {
                traceMessageColor("allocation failed", 0xFF0000);
            }
            return result;
        }

        fn resizeFn(self: *Self, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ret_addr: usize) ?usize {
            if (self.parent_allocator.rawResize(buf, buf_align, new_len, len_align, ret_addr)) |resized_len| {
                if (name) |n| {
                    freeNamed(buf.ptr, n);
                } else {
                    free(buf.ptr);
                }

                if (name) |n| {
                    allocNamed(buf.ptr, resized_len, n);
                } else {
                    alloc(buf.ptr, resized_len);
                }

                return resized_len;
            }

            // during normal operation the compiler hits this case thousands of times due to this
            // emitting messages for it is both slow and causes clutter
            return null;
        }

        fn freeFn(self: *Self, buf: []u8, buf_align: u29, ret_addr: usize) void {
            self.parent_allocator.rawFree(buf, buf_align, ret_addr);
            // this condition is to handle free being called on an empty slice that was never even allocated
            // example case: `std.process.getSelfExeSharedLibPaths` can return `&[_][:0]u8{}`
            if (buf.len != 0) {
                if (name) |n| {
                    freeNamed(buf.ptr, n);
                } else {
                    free(buf.ptr);
                }
            }
        }
    };
}

// This function only accepts comptime known strings, see `messageCopy` for runtime strings
pub inline fn traceMessage(comptime msg: [:0]const u8) void {
    if (!enable) return;
    ___tracy_emit_messageL(msg.ptr, if (enable_callstack) callstack_depth else 0);
}

// This function only accepts comptime known strings, see `messageColorCopy` for runtime strings
pub inline fn traceMessageColor(comptime msg: [:0]const u8, color: u32) void {
    if (!enable) return;
    ___tracy_emit_messageLC(msg.ptr, color, if (enable_callstack) callstack_depth else 0);
}

pub inline fn traceMessageCopy(msg: []const u8) void {
    if (!enable) return;
    ___tracy_emit_message(msg.ptr, msg.len, if (enable_callstack) callstack_depth else 0);
}

pub inline fn traceMessageColorCopy(msg: [:0]const u8, color: u32) void {
    if (!enable) return;
    ___tracy_emit_messageC(msg.ptr, msg.len, color, if (enable_callstack) callstack_depth else 0);
}

pub inline fn traceFrameMark() void {
    if (!enable) return;
    ___tracy_emit_frame_mark(null);
}

pub inline fn traceFrameMarkNamed(comptime name: [:0]const u8) void {
    if (!enable) return;
    ___tracy_emit_frame_mark(name.ptr);
}

pub inline fn traceNamedFrame(comptime name: [:0]const u8) Frame(name) {
    frameMarkStart(name);
    return .{};
}

fn Frame(comptime name: [:0]const u8) type {
    return struct {
        pub fn end(_: @This()) void {
            frameMarkEnd(name);
        }

        pub fn mark(_: @This()) void {
            frameMarkEnd(name);
            frameMarkStart(name);
        }
    };
}

inline fn frameMarkStart(comptime name: [:0]const u8) void {
    if (!enable) return;
    ___tracy_emit_frame_mark_start(name.ptr);
}

inline fn frameMarkEnd(comptime name: [:0]const u8) void {
    if (!enable) return;
    ___tracy_emit_frame_mark_end(name.ptr);
}

inline fn alloc(ptr: [*]u8, len: usize) void {
    if (!enable) return;

    if (enable_callstack) {
        ___tracy_emit_memory_alloc_callstack(ptr, len, callstack_depth, 0);
    } else {
        ___tracy_emit_memory_alloc(ptr, len, 0);
    }
}

inline fn allocNamed(ptr: [*]u8, len: usize, comptime name: [:0]const u8) void {
    if (!enable) return;

    if (enable_callstack) {
        ___tracy_emit_memory_alloc_callstack_named(ptr, len, callstack_depth, 0, name.ptr);
    } else {
        ___tracy_emit_memory_alloc_named(ptr, len, 0, name.ptr);
    }
}

inline fn free(ptr: [*]u8) void {
    if (!enable) return;

    if (enable_callstack) {
        ___tracy_emit_memory_free_callstack(ptr, callstack_depth, 0);
    } else {
        ___tracy_emit_memory_free(ptr, 0);
    }
}

inline fn freeNamed(ptr: [*]u8, comptime name: [:0]const u8) void {
    if (!enable) return;

    if (enable_callstack) {
        ___tracy_emit_memory_free_callstack_named(ptr, callstack_depth, 0, name.ptr);
    } else {
        ___tracy_emit_memory_free_named(ptr, 0, name.ptr);
    }
}

extern fn ___tracy_emit_zone_begin(
    srcloc: *const ___tracy_source_location_data,
    active: c_int,
) ___tracy_c_zone_context;
extern fn ___tracy_emit_zone_begin_callstack(
    srcloc: *const ___tracy_source_location_data,
    depth: c_int,
    active: c_int,
) ___tracy_c_zone_context;
extern fn ___tracy_emit_zone_text(ctx: ___tracy_c_zone_context, txt: [*]const u8, size: usize) void;
extern fn ___tracy_emit_zone_name(ctx: ___tracy_c_zone_context, txt: [*]const u8, size: usize) void;
extern fn ___tracy_emit_zone_color(ctx: ___tracy_c_zone_context, color: u32) void;
extern fn ___tracy_emit_zone_value(ctx: ___tracy_c_zone_context, value: u64) void;
extern fn ___tracy_emit_zone_end(ctx: ___tracy_c_zone_context) void;
extern fn ___tracy_emit_memory_alloc(ptr: *const anyopaque, size: usize, secure: c_int) void;
extern fn ___tracy_emit_memory_alloc_callstack(ptr: *const anyopaque, size: usize, depth: c_int, secure: c_int) void;
extern fn ___tracy_emit_memory_free(ptr: *const anyopaque, secure: c_int) void;
extern fn ___tracy_emit_memory_free_callstack(ptr: *const anyopaque, depth: c_int, secure: c_int) void;
extern fn ___tracy_emit_memory_alloc_named(ptr: *const anyopaque, size: usize, secure: c_int, name: [*:0]const u8) void;
extern fn ___tracy_emit_memory_alloc_callstack_named(ptr: *const anyopaque, size: usize, depth: c_int, secure: c_int, name: [*:0]const u8) void;
extern fn ___tracy_emit_memory_free_named(ptr: *const anyopaque, secure: c_int, name: [*:0]const u8) void;
extern fn ___tracy_emit_memory_free_callstack_named(ptr: *const anyopaque, depth: c_int, secure: c_int, name: [*:0]const u8) void;
extern fn ___tracy_emit_message(txt: [*]const u8, size: usize, callstack: c_int) void;
extern fn ___tracy_emit_messageL(txt: [*:0]const u8, callstack: c_int) void;
extern fn ___tracy_emit_messageC(txt: [*]const u8, size: usize, color: u32, callstack: c_int) void;
extern fn ___tracy_emit_messageLC(txt: [*:0]const u8, color: u32, callstack: c_int) void;
extern fn ___tracy_emit_frame_mark(name: ?[*:0]const u8) void;
extern fn ___tracy_emit_frame_mark_start(name: [*:0]const u8) void;
extern fn ___tracy_emit_frame_mark_end(name: [*:0]const u8) void;

const ___tracy_source_location_data = extern struct {
    name: ?[*:0]const u8,
    function: [*:0]const u8,
    file: [*:0]const u8,
    line: u32,
    color: u32,
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
