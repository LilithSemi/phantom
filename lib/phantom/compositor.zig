//! Nested Wayland compositor support for native Phantom applications.
//!
//! The outer Phantom window and the hosted clients share one Prism device. A
//! hosted buffer is therefore borrowed directly by the display list instead of
//! being copied through Phantom's encoded-image cache.
const std = @import("std");
const builtin = @import("builtin");
const phantom = @import("../phantom.zig");

pub const supported = builtin.os.tag == .linux and !builtin.abi.isAndroid() and
    phantom.backend.prism.builds_here;

const lattice = if (supported) @import("lattice") else void;

pub const Host = if (supported) NativeHost else UnsupportedHost;

fn xkbRootHasEvdev(io: std.Io, root: []const u8, path_buf: []u8) bool {
    const rules = std.fmt.bufPrint(path_buf, "{s}/rules/evdev", .{root}) catch return false;
    std.Io.Dir.accessAbsolute(io, rules, .{}) catch return false;
    return true;
}

/// Find xkeyboard-config without requiring callers to export XKB_CONFIG_ROOT.
/// Normal Linux/AOSP installations use /usr/share. Nix installations may keep
/// the database in a profile or directly in /nix/store, so cover both layouts.
/// The returned slice aliases `path_buf` unless it came directly from `environ`.
fn discoverXkbRoot(
    io: std.Io,
    environ: *const std.process.Environ.Map,
    path_buf: []u8,
) ?[]const u8 {
    if (environ.get("XKB_CONFIG_ROOT")) |root| return root;
    if (environ.get("X11_BASE_RULES_XML")) |rules_xml| {
        if (std.mem.lastIndexOf(u8, rules_xml, "/rules/")) |i| return rules_xml[0..i];
    }

    const standard_roots = [_][]const u8{
        "/usr/share/X11/xkb",
        "/run/current-system/sw/share/X11/xkb",
        "/nix/var/nix/profiles/default/share/X11/xkb",
    };
    var check_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for (standard_roots) |root| {
        if (xkbRootHasEvdev(io, root, &check_buf)) return root;
    }

    if (environ.get("XDG_DATA_DIRS")) |data_dirs| {
        var it = std.mem.splitScalar(u8, data_dirs, ':');
        while (it.next()) |data_dir| {
            const root = std.fmt.bufPrint(path_buf, "{s}/X11/xkb", .{data_dir}) catch continue;
            if (xkbRootHasEvdev(io, root, &check_buf)) return root;
        }
    }

    var store = std.Io.Dir.openDirAbsolute(io, "/nix/store", .{ .iterate = true }) catch return null;
    defer store.close(io);
    var entries = store.iterate();
    while (entries.next(io) catch return null) |entry| {
        if (entry.kind != .directory or
            std.mem.indexOf(u8, entry.name, "-xkeyboard-config-") == null)
        {
            continue;
        }
        const root = std.fmt.bufPrint(path_buf, "/nix/store/{s}/share/X11/xkb", .{entry.name}) catch continue;
        if (xkbRootHasEvdev(io, root, &check_buf)) return root;
    }
    return null;
}

const UnsupportedHost = struct {
    pub fn deinit(_: *UnsupportedHost) void {}
    pub fn pump(_: *UnsupportedHost) !void {}
    pub fn endFrame(_: *UnsupportedHost) void {}
    pub fn clearFocus(_: *UnsupportedHost) void {}

    pub fn pointerMotion(_: *UnsupportedHost, _: phantom.PhysicalOffset) bool {
        return false;
    }
    pub fn pointerButton(_: *UnsupportedHost, _: phantom.PhysicalOffset, _: u32, _: bool) bool {
        return false;
    }
    pub fn pointerAxis(_: *UnsupportedHost, _: phantom.PhysicalOffset, _: f64, _: f64) bool {
        return false;
    }
    pub fn key(_: *UnsupportedHost, _: u32, _: bool) bool {
        return false;
    }

    pub fn socketName(_: *const UnsupportedHost) []const u8 {
        return "";
    }

    pub fn paint(_: *UnsupportedHost, _: *phantom.Canvas, _: phantom.PhysicalRect) !void {}

    pub fn launch(_: *UnsupportedHost, _: *const std.process.Environ.Map, _: []const []const u8) !void {
        return error.CompositorUnsupported;
    }

    pub fn isAppRunning(_: *const UnsupportedHost, _: []const u8, _: []const u8) bool {
        return false;
    }

    pub fn setChangeListener(_: *UnsupportedHost, _: ?*anyopaque, _: ?*const fn (*anyopaque) void) void {}

    pub fn setInputEnabled(_: *UnsupportedHost, _: bool) void {}
    pub fn setOverview(_: *UnsupportedHost, _: bool) void {}
    pub fn isOverview(_: *const UnsupportedHost) bool {
        return false;
    }
    pub fn setWorkspace(_: *UnsupportedHost, _: u8) void {}
    pub fn activeWorkspace(_: *const UnsupportedHost) u8 {
        return 0;
    }
    pub fn minimizeFocused(_: *UnsupportedHost) void {}

    pub fn setChildEnvironment(_: *UnsupportedHost, _: []const u8, _: []const u8) !void {
        return error.CompositorUnsupported;
    }
};

const NativeHost = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    inner: *lattice.Compositor,
    surfaces: std.ArrayList(Surface) = .empty,
    children: std.ArrayList(std.process.Child) = .empty,
    child_environment: std.process.Environ.Map,
    initial_environ: *const std.process.Environ.Map,
    initial_argv: []const []const u8,
    initial_spawned: bool = false,
    change_ctx: ?*anyopaque = null,
    change_fn: ?*const fn (*anyopaque) void = null,
    focused: ?lattice.compositor_types.HostedSurfaceId = null,
    move_grab: ?lattice.compositor_types.HostedSurfaceId = null,
    resize_grab: ?ResizeGrab = null,
    last_pointer: phantom.PhysicalOffset = .zero,
    last_client_pointer: phantom.PhysicalOffset = .zero,
    move_offset: phantom.PhysicalOffset = .zero,
    dirty: bool = true,
    input_enabled: bool = true,
    overview: bool = false,
    active_workspace: u8 = 0,
    last_bounds: phantom.PhysicalRect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    const ResizeGrab = struct {
        id: lattice.compositor_types.HostedSurfaceId,
        edge: lattice.compositor_types.ResizeEdge,
        start_pointer: phantom.PhysicalOffset,
        start_rect: phantom.PhysicalRect,
    };

    const Surface = struct {
        id: lattice.compositor_types.HostedSurfaceId,
        width: u32,
        height: u32,
        texture: *anyopaque,
        parent: ?lattice.compositor_types.HostedSurfaceId = null,
        offset_x: i32 = 0,
        offset_y: i32 = 0,
        above_parent: bool = true,
        uv: phantom.display_list.TexturePrimitive.UvRect = .{},
        rect: phantom.PhysicalRect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        positioned: bool = false,
        requested_width: ?f32 = null,
        requested_height: ?f32 = null,
        restore_rect: ?phantom.PhysicalRect = null,
        maximized: bool = false,
        fullscreen: bool = false,
        minimized: bool = false,
        workspace: u8 = 0,
        overview_rect: phantom.PhysicalRect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        device: anytype,
        environ: *const std.process.Environ.Map,
        client_argv: []const []const u8,
    ) !NativeHost {
        const runtime_dir = environ.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDirectory;
        var xkb_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const xkb_root = discoverXkbRoot(io, environ, &xkb_path_buf);
        const inner = try lattice.Compositor.init(gpa, io, device, .{
            .runtime_dir = runtime_dir,
            .xkb_config_root = xkb_root,
            // GPU Wayland clients (Vulkan WSI and EGL) require linux-dmabuf;
            // wl_shm alone is not a presentation path for those APIs.
            .enable_dmabuf = true,
        });
        errdefer inner.deinit();

        const self = NativeHost{
            .gpa = gpa,
            .io = io,
            .inner = inner,
            .child_environment = std.process.Environ.Map.init(gpa),
            .initial_environ = environ,
            .initial_argv = client_argv,
        };
        return self;
    }

    pub fn deinit(self: *NativeHost) void {
        for (self.children.items) |*child| child.kill(self.io);
        self.children.deinit(self.gpa);
        self.child_environment.deinit();
        self.surfaces.deinit(self.gpa);
        self.inner.deinit();
        self.* = undefined;
    }

    pub fn socketName(self: *const NativeHost) []const u8 {
        return self.inner.socketName();
    }

    fn spawn(self: *NativeHost, environ: *const std.process.Environ.Map, argv: []const []const u8) !void {
        var child_env = std.process.Environ.Map.init(self.gpa);
        defer child_env.deinit();
        for (environ.keys(), environ.values()) |name, value| try child_env.put(name, value);
        for (self.child_environment.keys(), self.child_environment.values()) |name, value| try child_env.put(name, value);
        try child_env.put("WAYLAND_DISPLAY", self.socketName());
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .environ_map = &child_env,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        self.children.append(self.gpa, child) catch |err| {
            child.kill(self.io);
            return err;
        };
    }

    /// Start another client with this compositor's Wayland socket in its
    /// environment. The host retains the child so it can terminate every
    /// process it started when the shell shuts down.
    pub fn launch(self: *NativeHost, environ: *const std.process.Environ.Map, argv: []const []const u8) !void {
        if (argv.len == 0) return error.EmptyCommand;
        try self.spawn(environ, argv);
    }

    /// Add or replace one environment value inherited by every subsequently
    /// launched hosted client. The host owns both strings through its map.
    pub fn setChildEnvironment(self: *NativeHost, name: []const u8, value: []const u8) !void {
        try self.child_environment.put(name, value);
    }

    pub fn setChangeListener(
        self: *NativeHost,
        ctx: ?*anyopaque,
        callback: ?*const fn (*anyopaque) void,
    ) void {
        self.change_ctx = ctx;
        self.change_fn = callback;
    }

    fn sameAppId(actual: []const u8, expected: []const u8) bool {
        if (expected.len == 0) return false;
        const without_suffix = if (std.mem.endsWith(u8, expected, ".desktop")) expected[0 .. expected.len - ".desktop".len] else expected;
        return std.ascii.eqlIgnoreCase(actual, expected) or std.ascii.eqlIgnoreCase(actual, without_suffix);
    }

    /// Whether a mapped root toplevel identifies itself as this desktop entry.
    pub fn isAppRunning(self: *const NativeHost, desktop_id: []const u8, startup_wm_class: []const u8) bool {
        for (self.inner.surfaces()) |surface| {
            if (!surface.mapped or surface.parent != null or surface.role != .toplevel) continue;
            if (sameAppId(surface.app_id, desktop_id) or sameAppId(surface.app_id, startup_wm_class)) return true;
        }
        return false;
    }

    fn event(ctx: *anyopaque, ev: lattice.CompositorEvent) void {
        const self: *NativeHost = @ptrCast(@alignCast(ctx));
        var app_set_changed = false;
        switch (ev) {
            .surface_mapped, .surface_unmapped, .client_disconnected => app_set_changed = true,
            .surface_move_requested => |id| {
                for (self.surfaces.items) |surface| {
                    if (surface.id == id) {
                        self.move_grab = id;
                        self.move_offset = .{
                            .x = self.last_pointer.x - surface.rect.x,
                            .y = self.last_pointer.y - surface.rect.y,
                        };
                        break;
                    }
                }
            },
            .surface_resize_requested => |req| {
                if (self.findLocalSurface(req.id)) |surface| {
                    self.resize_grab = .{
                        .id = req.id,
                        .edge = req.edge,
                        .start_pointer = self.last_pointer,
                        .start_rect = surface.rect,
                    };
                }
            },
            .surface_maximize_requested => |req| self.setMaximized(req.id, req.maximized, false),
            .surface_fullscreen_requested => |req| self.setMaximized(req.id, req.fullscreen, true),
            else => {},
        }
        // A video can commit sixty surfaces per second without changing which
        // applications are open. Rebuilding the whole shell on every commit
        // would make the provider notification itself a frame-drop source.
        if (app_set_changed) if (self.change_fn) |callback| callback(self.change_ctx.?);
        self.dirty = true;
    }

    /// Service all requests which are ready without blocking the outer window.
    pub fn pump(self: *NativeHost) !void {
        // Root mounting installs session-scoped environment overrides. Delay
        // the command-line client until the first pump so it inherits them too.
        if (!self.initial_spawned) {
            self.initial_spawned = true;
            if (self.initial_argv.len > 0) try self.spawn(self.initial_environ, self.initial_argv);
        }
        try self.inner.pump(0, event, self);
        try self.syncSurfaces();
    }

    fn syncSurfaces(self: *NativeHost) !void {
        var next: std.ArrayList(Surface) = .empty;
        errdefer next.deinit(self.gpa);
        for (self.inner.surfaces()) |surface| {
            if (!surface.mapped or surface.texture == null or (surface.role == .none and surface.parent == null)) continue;
            var item = Surface{
                .id = surface.id,
                .width = surface.width,
                .height = surface.height,
                .texture = surface.texture.?,
                .parent = surface.parent,
                .offset_x = surface.offset_x,
                .offset_y = surface.offset_y,
                .above_parent = surface.above_parent,
                .uv = .{ .x = surface.uv_x, .y = surface.uv_y, .width = surface.uv_width, .height = surface.uv_height },
            };
            for (self.surfaces.items) |old| {
                if (old.id == surface.id) {
                    item.rect = old.rect;
                    item.positioned = old.positioned;
                    item.requested_width = old.requested_width;
                    item.requested_height = old.requested_height;
                    item.restore_rect = old.restore_rect;
                    item.maximized = old.maximized;
                    item.fullscreen = old.fullscreen;
                    item.minimized = old.minimized;
                    item.workspace = old.workspace;
                    item.overview_rect = old.overview_rect;
                    break;
                }
            }
            if (!item.positioned and item.parent == null) item.workspace = self.active_workspace;
            try next.append(self.gpa, item);
        }
        self.surfaces.deinit(self.gpa);
        self.surfaces = next;
    }

    /// Lay out and paint hosted toplevels. Newest surfaces are later in the
    /// display list and therefore appear on top.
    pub fn paint(self: *NativeHost, canvas: *phantom.Canvas, bounds: phantom.PhysicalRect) !void {
        self.last_bounds = bounds;
        var root_count: usize = 0;
        for (self.surfaces.items) |surface| if (surface.parent == null and (!surface.minimized or self.overview) and surface.workspace == self.active_workspace) {
            root_count += 1;
        };
        const columns: usize = if (root_count <= 1) 1 else if (root_count <= 4) 2 else 3;
        const rows: usize = @max(1, (root_count + columns - 1) / columns);
        var root_i: usize = 0;
        for (self.surfaces.items) |*surface| {
            if (surface.parent != null or (surface.minimized and !self.overview) or surface.workspace != self.active_workspace) continue;
            const natural_w: f32 = @floatFromInt(surface.width);
            const natural_h: f32 = @floatFromInt(surface.height);
            const max_w = @max(1, bounds.width * 0.82);
            const max_h = @max(1, bounds.height * 0.82);
            const factor = @min(1, @min(max_w / @max(1, natural_w), max_h / @max(1, natural_h)));
            const width = surface.requested_width orelse natural_w * factor;
            const height = surface.requested_height orelse natural_h * factor;
            const cascade: f32 = @floatFromInt(root_i % 7);
            const spread = if (root_count > 1) cascade * 34 else 0;
            if (!surface.positioned) {
                surface.rect.x = bounds.x + @max(16, (bounds.width - width) * 0.5 - 70 + spread);
                surface.rect.y = bounds.y + @max(16, (bounds.height - height) * 0.5 - 45 + spread);
                surface.positioned = true;
            }
            surface.rect.width = width;
            surface.rect.height = height;
            if (self.overview) {
                const gap: f32 = 24;
                const cell_w = (bounds.width - gap * @as(f32, @floatFromInt(columns + 1))) / @as(f32, @floatFromInt(columns));
                const cell_h = (bounds.height - gap * @as(f32, @floatFromInt(rows + 1))) / @as(f32, @floatFromInt(rows));
                const preview_scale = @min(cell_w / @max(1, surface.rect.width), cell_h / @max(1, surface.rect.height));
                const preview_w = surface.rect.width * preview_scale;
                const preview_h = surface.rect.height * preview_scale;
                const column = root_i % columns;
                const row = root_i / columns;
                surface.overview_rect = .{
                    .x = bounds.x + gap + @as(f32, @floatFromInt(column)) * (cell_w + gap) + (cell_w - preview_w) * 0.5,
                    .y = bounds.y + gap + @as(f32, @floatFromInt(row)) * (cell_h + gap) + (cell_h - preview_h) * 0.5,
                    .width = preview_w,
                    .height = preview_h,
                };
                const saved = surface.rect;
                surface.rect = surface.overview_rect;
                self.layoutChildren(surface);
                try self.paintChildren(canvas, surface.id, false);
                try canvas.drawTexture(.{ .texture = surface.texture, .rect = surface.rect, .uv = surface.uv });
                try self.paintChildren(canvas, surface.id, true);
                surface.rect = saved;
                root_i += 1;
                continue;
            }
            self.layoutChildren(surface);
            try self.paintChildren(canvas, surface.id, false);
            try canvas.drawTexture(.{ .texture = surface.texture, .rect = surface.rect, .uv = surface.uv });
            try self.paintChildren(canvas, surface.id, true);
            root_i += 1;
        }
        self.dirty = false;
    }

    fn layoutChildren(self: *NativeHost, parent: *const Surface) void {
        const scale = parent.rect.width / @max(1, @as(f32, @floatFromInt(parent.width)));
        for (self.surfaces.items) |*child| {
            if (child.parent != parent.id) continue;
            child.rect = .{
                .x = parent.rect.x + @as(f32, @floatFromInt(child.offset_x)) * scale,
                .y = parent.rect.y + @as(f32, @floatFromInt(child.offset_y)) * scale,
                .width = @as(f32, @floatFromInt(child.width)) * scale,
                .height = @as(f32, @floatFromInt(child.height)) * scale,
            };
            child.positioned = true;
            self.layoutChildren(child);
        }
    }

    fn paintChildren(self: *NativeHost, canvas: *phantom.Canvas, parent: lattice.compositor_types.HostedSurfaceId, above: bool) !void {
        for (self.surfaces.items) |*child| {
            if (child.parent != parent or child.above_parent != above) continue;
            try self.paintChildren(canvas, child.id, false);
            try canvas.drawTexture(.{ .texture = child.texture, .rect = child.rect, .uv = child.uv });
            try self.paintChildren(canvas, child.id, true);
        }
    }

    fn surfaceAt(self: *NativeHost, point: phantom.PhysicalOffset) ?usize {
        var i = self.surfaces.items.len;
        while (i > 0) {
            i -= 1;
            if (self.surfaces.items[i].parent != null or (self.surfaces.items[i].minimized and !self.overview) or self.surfaces.items[i].workspace != self.active_workspace) continue;
            if (self.overview) {
                if (contains(self.surfaces.items[i].overview_rect, point)) return i;
                continue;
            }
            if (self.childAt(self.surfaces.items[i].id, point, true)) |child| return child;
            const r = self.surfaces.items[i].rect;
            if (contains(r, point)) return i;
            if (self.childAt(self.surfaces.items[i].id, point, false)) |child| return child;
        }
        return null;
    }

    fn childAt(self: *NativeHost, parent: lattice.compositor_types.HostedSurfaceId, point: phantom.PhysicalOffset, above: bool) ?usize {
        var i = self.surfaces.items.len;
        while (i > 0) {
            i -= 1;
            const child = &self.surfaces.items[i];
            if (child.parent != parent or child.above_parent != above) continue;
            if (self.childAt(child.id, point, true)) |nested| return nested;
            if (contains(child.rect, point)) return i;
            if (self.childAt(child.id, point, false)) |nested| return nested;
        }
        return null;
    }

    fn contains(rect: phantom.PhysicalRect, point: phantom.PhysicalOffset) bool {
        return point.x >= rect.x and point.y >= rect.y and point.x < rect.x + rect.width and point.y < rect.y + rect.height;
    }

    pub fn pointerMotion(self: *NativeHost, point: phantom.PhysicalOffset) bool {
        self.last_pointer = point;
        if (!self.input_enabled) return false;
        if (self.overview) return self.surfaceAt(point) != null;
        if (self.resize_grab) |grab| {
            if (self.findLocalSurface(grab.id)) |surface| {
                const next = resizeRect(grab.start_rect, grab.start_pointer, point, grab.edge, 160, 100);
                surface.rect = next;
                surface.requested_width = next.width;
                surface.requested_height = next.height;
                surface.positioned = true;
                self.inner.configureToplevel(grab.id, @intFromFloat(next.width), @intFromFloat(next.height), .{
                    .resizing = true,
                    .activated = true,
                });
                self.dirty = true;
                return true;
            }
            self.resize_grab = null;
        }
        if (self.move_grab) |id| {
            for (self.surfaces.items) |*surface| {
                if (surface.id == id) {
                    surface.rect.x = point.x - self.move_offset.x;
                    surface.rect.y = point.y - self.move_offset.y;
                    surface.positioned = true;
                    self.dirty = true;
                    return true;
                }
            }
            self.move_grab = null;
        }
        const i = self.surfaceAt(point) orelse return false;
        // Subsurfaces are part of their toplevel's visual tree, not separate
        // application windows. Give seat focus to the root so toolkits match
        // wl_keyboard.enter with the window that owns the text field.
        const root_i = self.rootIndex(i);
        const surface = &self.surfaces.items[root_i];
        if (self.focused != surface.id) {
            self.focused = surface.id;
            self.inner.focus(surface.id);
        }
        // Hosted buffers may be scaled down to fit the shell. Wayland pointer
        // coordinates are in the client's surface coordinate space, so undo
        // the display transform before forwarding the motion/click position.
        const scale_x = surface.rect.width / @max(1, @as(f32, @floatFromInt(surface.width)));
        const scale_y = surface.rect.height / @max(1, @as(f32, @floatFromInt(surface.height)));
        self.last_client_pointer = .{
            .x = (point.x - surface.rect.x) / @max(scale_x, 0.0001),
            .y = (point.y - surface.rect.y) / @max(scale_y, 0.0001),
        };
        self.inner.pointerMotion(self.last_client_pointer.x, self.last_client_pointer.y);
        return true;
    }

    pub fn pointerButton(self: *NativeHost, point: phantom.PhysicalOffset, button: u32, pressed: bool) bool {
        self.last_pointer = point;
        if (!self.input_enabled) return false;
        if (self.overview) {
            if (!pressed) return self.surfaceAt(point) != null;
            const index = self.surfaceAt(point) orelse return false;
            var selected = self.surfaces.orderedRemove(index);
            const id = selected.id;
            selected.minimized = false;
            self.surfaces.append(self.gpa, selected) catch return false;
            self.focused = id;
            self.inner.focus(id);
            self.overview = false;
            self.dirty = true;
            if (self.change_fn) |callback| callback(self.change_ctx.?);
            return true;
        }
        if (!pressed and self.resize_grab != null) {
            const grab = self.resize_grab.?;
            self.inner.pointerButton(button, false);
            if (self.findLocalSurface(grab.id)) |surface| {
                self.inner.configureToplevel(grab.id, @intFromFloat(surface.rect.width), @intFromFloat(surface.rect.height), .{
                    .maximized = surface.maximized,
                    .fullscreen = surface.fullscreen,
                    .activated = true,
                });
            }
            self.resize_grab = null;
            self.dirty = true;
            return true;
        }
        if (!pressed and self.move_grab != null) {
            const id = self.move_grab.?;
            self.inner.pointerButton(button, false);
            self.move_grab = null;
            self.snapSurface(id, point);
            self.dirty = true;
            return true;
        }
        const i = self.surfaceAt(point) orelse return false;
        const root_i = self.rootIndex(i);
        var root_above = false;
        for (self.surfaces.items[root_i + 1 ..]) |surface| {
            if (surface.parent == null) {
                root_above = true;
                break;
            }
        }
        if (pressed and root_above) {
            const raised = self.surfaces.orderedRemove(root_i);
            self.surfaces.append(self.gpa, raised) catch {};
            self.dirty = true;
        }
        _ = self.pointerMotion(point);
        self.inner.pointerButton(button, pressed);
        return true;
    }

    fn rootIndex(self: *const NativeHost, start: usize) usize {
        var current = start;
        while (self.surfaces.items[current].parent) |parent| {
            var found = false;
            for (self.surfaces.items, 0..) |surface, i| {
                if (surface.id == parent) {
                    current = i;
                    found = true;
                    break;
                }
            }
            if (!found) break;
        }
        return current;
    }

    fn findLocalSurface(self: *NativeHost, id: lattice.compositor_types.HostedSurfaceId) ?*Surface {
        for (self.surfaces.items) |*surface| if (surface.id == id) return surface;
        return null;
    }

    fn setMaximized(self: *NativeHost, id: lattice.compositor_types.HostedSurfaceId, enabled: bool, fullscreen: bool) void {
        const bounds = self.last_bounds;
        const surface = self.findLocalSurface(id) orelse return;
        if (enabled) {
            if (surface.restore_rect == null) surface.restore_rect = surface.rect;
            surface.rect = bounds;
            surface.requested_width = bounds.width;
            surface.requested_height = bounds.height;
        } else if (surface.restore_rect) |restore| {
            surface.rect = restore;
            surface.requested_width = restore.width;
            surface.requested_height = restore.height;
            surface.restore_rect = null;
        }
        if (fullscreen) surface.fullscreen = enabled else surface.maximized = enabled;
        self.inner.configureToplevel(id, @intFromFloat(surface.rect.width), @intFromFloat(surface.rect.height), .{
            .maximized = surface.maximized,
            .fullscreen = surface.fullscreen,
            .activated = true,
        });
        self.dirty = true;
    }

    pub fn pointerAxis(self: *NativeHost, point: phantom.PhysicalOffset, horizontal: f64, vertical: f64) bool {
        if (!self.input_enabled) return false;
        if (!self.pointerMotion(point)) return false;
        self.inner.pointerAxis(horizontal, vertical);
        return true;
    }

    pub fn key(self: *NativeHost, keycode: u32, pressed: bool) bool {
        if (!self.input_enabled) return false;
        if (self.focused == null) {
            return false;
        }
        return self.inner.key(keycode, pressed);
    }

    pub fn clearFocus(self: *NativeHost) void {
        self.focused = null;
        self.inner.focus(null);
    }

    /// Temporarily remove hosted clients from input arbitration while a shell
    /// modal (such as an application launcher) is above them.
    pub fn setInputEnabled(self: *NativeHost, enabled: bool) void {
        if (self.input_enabled == enabled) return;
        self.input_enabled = enabled;
        if (!enabled) {
            self.move_grab = null;
            self.resize_grab = null;
            self.clearFocus();
        }
    }

    pub fn setOverview(self: *NativeHost, enabled: bool) void {
        self.overview = enabled;
        self.dirty = true;
    }
    pub fn isOverview(self: *const NativeHost) bool {
        return self.overview;
    }

    pub fn setWorkspace(self: *NativeHost, workspace: u8) void {
        self.active_workspace = @min(workspace, 3);
        self.clearFocus();
        self.dirty = true;
    }

    pub fn activeWorkspace(self: *const NativeHost) u8 {
        return self.active_workspace;
    }

    pub fn minimizeFocused(self: *NativeHost) void {
        const id = self.focused orelse return;
        if (self.findLocalSurface(id)) |surface| surface.minimized = true;
        self.clearFocus();
        self.dirty = true;
    }

    fn snapSurface(self: *NativeHost, id: lattice.compositor_types.HostedSurfaceId, point: phantom.PhysicalOffset) void {
        const surface = self.findLocalSurface(id) orelse return;
        const bounds = self.last_bounds;
        const threshold: f32 = 32;
        var target: ?phantom.PhysicalRect = null;
        var maximized = false;
        if (point.y <= bounds.y + threshold) {
            target = bounds;
            maximized = true;
        } else if (point.x <= bounds.x + threshold) {
            target = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width * 0.5, .height = bounds.height };
        } else if (point.x >= bounds.x + bounds.width - threshold) {
            target = .{ .x = bounds.x + bounds.width * 0.5, .y = bounds.y, .width = bounds.width * 0.5, .height = bounds.height };
        }
        const rect = target orelse return;
        if (surface.restore_rect == null) surface.restore_rect = surface.rect;
        surface.rect = rect;
        surface.requested_width = rect.width;
        surface.requested_height = rect.height;
        surface.maximized = maximized;
        self.inner.configureToplevel(id, @intFromFloat(rect.width), @intFromFloat(rect.height), .{ .maximized = maximized, .activated = true });
    }

    pub fn endFrame(self: *NativeHost) void {
        self.inner.endFrame();
    }
};

fn resizeRect(
    start: phantom.PhysicalRect,
    origin: phantom.PhysicalOffset,
    point: phantom.PhysicalOffset,
    edge: lattice.compositor_types.ResizeEdge,
    min_width: f32,
    min_height: f32,
) phantom.PhysicalRect {
    var result = start;
    const dx = point.x - origin.x;
    const dy = point.y - origin.y;
    const left = edge == .left or edge == .top_left or edge == .bottom_left;
    const right = edge == .right or edge == .top_right or edge == .bottom_right;
    const top = edge == .top or edge == .top_left or edge == .top_right;
    const bottom = edge == .bottom or edge == .bottom_left or edge == .bottom_right;
    if (left) {
        result.width = @max(min_width, start.width - dx);
        result.x = start.x + start.width - result.width;
    } else if (right) result.width = @max(min_width, start.width + dx);
    if (top) {
        result.height = @max(min_height, start.height - dy);
        result.y = start.y + start.height - result.height;
    } else if (bottom) result.height = @max(min_height, start.height + dy);
    return result;
}

test "interactive resize preserves the opposite corner and enforces minimums" {
    if (!supported) return error.SkipZigTest;
    const start = phantom.PhysicalRect{ .x = 100, .y = 80, .width = 500, .height = 300 };
    const origin = phantom.PhysicalOffset{ .x = 100, .y = 80 };
    const grown = resizeRect(start, origin, .{ .x = 60, .y = 30 }, .top_left, 160, 100);
    try std.testing.expectEqual(@as(f32, 60), grown.x);
    try std.testing.expectEqual(@as(f32, 30), grown.y);
    try std.testing.expectEqual(@as(f32, 540), grown.width);
    try std.testing.expectEqual(@as(f32, 350), grown.height);

    const clamped = resizeRect(start, origin, .{ .x = 1000, .y = 1000 }, .top_left, 160, 100);
    try std.testing.expectEqual(@as(f32, 440), clamped.x);
    try std.testing.expectEqual(@as(f32, 280), clamped.y);
    try std.testing.expectEqual(@as(f32, 160), clamped.width);
    try std.testing.expectEqual(@as(f32, 100), clamped.height);
}

pub fn fromOwner(owner: *phantom.BuildOwner) ?*Host {
    const ptr = owner.compositor_host orelse return null;
    return @ptrCast(@alignCast(ptr));
}
