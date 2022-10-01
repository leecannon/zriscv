const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const tracy = @import("tracy");
const zriscv = @import("zriscv");

const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");

allocator: std.mem.Allocator,
stderr: std.fs.File.Writer,

window: zglfw.Window,
gctx: *zgpu.GraphicsContext,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, stderr: std.fs.File.Writer) !Self {
    const z = tracy.traceNamed(@src(), "state init");
    defer z.end();

    zglfw.init() catch |e| {
        stderr.print("ERROR: unable to initalize glfw: {s}\n", .{@errorName(e)}) catch unreachable;
        return e;
    };
    errdefer zglfw.terminate();

    zglfw.defaultWindowHints();
    zglfw.windowHint(.cocoa_retina_framebuffer, 1);
    zglfw.windowHint(.client_api, 0);

    const window = zglfw.createWindow(
        1600,
        1000,
        "Hello World",
        null,
        null,
    ) catch |e| {
        stderr.print("ERROR: unable to create window: {s}\n", .{@errorName(e)}) catch unreachable;
        return e;
    };
    errdefer window.destroy();

    window.setSizeLimits(400, 400, -1, -1);

    const gctx = zgpu.GraphicsContext.init(allocator, window) catch |e| {
        stderr.print("ERROR: unable to initalize graphics context: {s}\n", .{@errorName(e)}) catch unreachable;
        return e;
    };
    errdefer gctx.deinit(allocator);

    zgui.init(allocator);
    errdefer zgui.deinit();

    zgui.backend.init(
        window,
        gctx.device,
        @enumToInt(zgpu.GraphicsContext.swapchain_format),
    );
    errdefer zgui.backend.deinit();

    return Self{
        .allocator = allocator,
        .stderr = stderr,
        .window = window,
        .gctx = gctx,
    };
}

pub fn deinit(self: *Self) void {
    zgui.backend.deinit();
    zgui.deinit();
    self.gctx.deinit(self.allocator);
    self.window.destroy();
    zglfw.terminate();
}

pub fn run(self: *Self) !void {
    while (!self.window.shouldClose()) {
        zglfw.pollEvents();

        try self.update();
        self.draw();
    }
}

fn update(self: *Self) !void {
    zgui.backend.newFrame(
        self.gctx.swapchain_descriptor.width,
        self.gctx.swapchain_descriptor.height,
    );

    if (!zgui.begin("Demo Settings", .{})) {
        zgui.end();
        return;
    }

    zgui.text("Hello?", .{});

    zgui.end();
}

fn draw(self: *Self) void {
    const swapchain_texv = self.gctx.swapchain.getCurrentTextureView();
    defer swapchain_texv.release();

    const commands = commands: {
        const encoder = self.gctx.device.createCommandEncoder(null);
        defer encoder.release();

        // Gui pass.
        {
            const pass = zgpu.util.beginRenderPassSimple(
                encoder,
                .load,
                swapchain_texv,
                null,
                null,
                null,
            );
            defer zgpu.util.endRelease(pass);
            zgui.backend.draw(pass);
        }

        break :commands encoder.finish(null);
    };
    defer commands.release();

    self.gctx.submit(&.{commands});
    _ = self.gctx.present();
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
