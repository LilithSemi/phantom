//! First standalone compositor bring-up for the shared shell example.
//! The Phantom chrome from app.zig is the Android/SystemUI surface today; this
//! entry owns the Wayland server and client composition path. The next step is
//! rendering that same widget tree around the hosted surface render target.

const std = @import("std");
const lattice = @import("lattice");

const Shell = struct {
    ctx: *lattice.Context,
    output: lattice.SurfaceId,
    compositor: *lattice.Compositor,
    active: ?lattice.compositor_types.HostedSurfaceId = null,
    done: bool = false,

    fn compositorEvent(ptr: *anyopaque, event: lattice.CompositorEvent) void {
        const self: *Shell = @ptrCast(@alignCast(ptr));
        switch (event) {
            .surface_mapped => |id| {
                self.active = id;
                self.compositor.focus(id);
            },
            .surface_unmapped => |id| if (self.active == id) {
                self.active = null;
                self.compositor.focus(null);
            },
            .pointer_constraint => |request| self.ctx.applyPointerConstraint(request),
            else => {},
        }
    }

    fn outputEvent(ptr: *anyopaque, event: lattice.Event) void {
        const self: *Shell = @ptrCast(@alignCast(ptr));
        switch (event) {
            .close_requested => {
                self.done = true;
                self.ctx.quit();
            },
            .input => |input| switch (input) {
                .pointer_motion => |motion| self.compositor.pointerMotion(motion.x, @max(0, motion.y - 36)),
                .pointer_relative => |motion| self.compositor.pointerRelative(motion.dx, motion.dy, motion.dx_unaccel, motion.dy_unaccel),
                .pointer_button => |button| self.compositor.pointerButton(button.button, button.state == .pressed),
                .pointer_axis => |axis| self.compositor.pointerAxis(axis.horizontal, axis.vertical),
                .key => |key| self.compositor.key(key.keycode, key.state == .pressed),
                .tablet_proximity => |tablet| self.compositor.tabletProximity(tablet.in_prox),
                .tablet_axis => |tablet| self.compositor.tabletAxis(tablet.x, tablet.y, tablet.pressure),
                .tablet_tip => |tablet| self.compositor.tabletTip(tablet.down),
                else => {},
            },
            else => {},
        }
    }

    fn render(self: *Shell) !void {
        if (!self.ctx.renderAvailable(self.output)) return;
        const target = try self.ctx.renderTarget(self.output);
        var commands = try target.context.beginCommands();
        errdefer commands.deinit();
        try commands.setRenderTarget(target.target);
        try commands.clear(.{ .r = 0.055, .g = 0.07, .b = 0.12, .a = 1 });
        try target.context.submit(commands);
        commands.deinit();

        if (self.active) |id| {
            for (self.compositor.surfaces()) |surface| {
                if (surface.id != id or !surface.mapped) continue;
                const available_height = target.height -| 100;
                const scale = @min(
                    @as(f32, @floatFromInt(target.width)) / @as(f32, @floatFromInt(@max(1, surface.width))),
                    @as(f32, @floatFromInt(available_height)) / @as(f32, @floatFromInt(@max(1, surface.height))),
                );
                const width = @as(f32, @floatFromInt(surface.width)) * @min(scale, 1);
                const height = @as(f32, @floatFromInt(surface.height)) * @min(scale, 1);
                try self.compositor.drawSurface(target.target, target.width, target.height, id, .{
                    .x = (@as(f32, @floatFromInt(target.width)) - width) / 2,
                    .y = 36,
                    .w = width,
                    .h = height,
                });
                break;
            }
        }
        try self.compositor.drawCursor(target.target, target.width, target.height);
        try self.ctx.commit(self.output);
        self.compositor.endFrame();
    }
};

pub fn main(init: std.process.Init) !void {
    var context = try lattice.Context.init(init.gpa, init.io, init.environ_map, .{
        .initial_width = 1280,
        .initial_height = 800,
    });
    defer context.deinit();
    const output = try context.createSurface(.{
        .title = "Phantom Shell",
        .width = 1280,
        .height = 800,
        .color = lattice.ColorConfig.sdr(.xrgb8888),
    });
    defer context.destroySurface(output.id);

    const device = context.renderDevice() orelse return error.NoRenderDevice;
    const runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory;
    const xkb_root = init.environ_map.get("XKB_CONFIG_ROOT");
    const compositor = try lattice.Compositor.init(init.gpa, init.io, device, .{
        .runtime_dir = runtime_dir,
        .xkb_config_root = xkb_root,
    });
    defer compositor.deinit();

    std.debug.print("phantom-shell: WAYLAND_DISPLAY={s}\n", .{compositor.socketName()});
    var shell = Shell{ .ctx = &context, .output = output.id, .compositor = compositor };
    context.running = true;
    while (!shell.done and context.running) {
        var fds: [2]std.posix.pollfd = undefined;
        var count: usize = 0;
        if (context.fd()) |fd| {
            fds[count] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
            count += 1;
        }
        fds[count] = .{ .fd = compositor.fd(), .events = std.posix.POLL.IN, .revents = 0 };
        count += 1;
        _ = try std.posix.poll(fds[0..count], 16);
        try compositor.pump(0, Shell.compositorEvent, &shell);
        try context.poll(0, Shell.outputEvent, &shell);
        try shell.render();
    }
}
