//! A compact boolean control with pointer and keyboard operation.
const std = @import("std");
const phantom = @import("../../phantom.zig");
const geom = phantom.geometry;
const layout = phantom.layout;

const RenderSwitch = struct {
    base: phantom.RenderObject,
    handlers: phantom.PointerHandlers = .{ .ctx = undefined },
    focus_handlers: phantom.FocusHandlers = .{ .ctx = undefined },
    value: bool,
    enabled: bool,
    focused: bool = false,
    width: f32,
    height: f32,
    scale: f32 = 1,
    active: geom.Color,
    inactive: geom.Color,
    knob: geom.Color,
    disabled: geom.Color,
    on_changed: ?*const fn (*anyopaque, bool) void,
    user_ctx: *anyopaque,

    fn layoutFn(base: *phantom.RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderSwitch = @fieldParentPtr("base", base);
        self.scale = c.scale;
        return c.constrain(.{ .width = self.width * c.scale, .height = self.height * c.scale });
    }
    fn paintFn(base: *phantom.RenderObject, cv: *phantom.Canvas, origin: geom.PhysicalOffset) anyerror!void {
        const self: *RenderSwitch = @fieldParentPtr("base", base);
        const track = geom.PhysicalRect.fromOriginSize(origin, base.size);
        const color = if (!self.enabled) self.disabled else if (self.value) self.active else self.inactive;
        try cv.fillRRect(track, track.height / 2, color);
        if (self.focused) try cv.strokeRRect(track, track.height / 2, self.scale, self.active);
        const inset = 3 * self.scale;
        const diameter = @max(0, track.height - inset * 2);
        const x = if (self.value) track.x + track.width - inset - diameter else track.x + inset;
        try cv.fillRRect(.{ .x = x, .y = track.y + inset, .width = diameter, .height = diameter }, diameter / 2, self.knob);
    }
    fn destroyFn(base: *phantom.RenderObject, gpa: std.mem.Allocator) void {
        gpa.destroy(@as(*RenderSwitch, @fieldParentPtr("base", base)));
    }
    fn activate(self: *RenderSwitch) void {
        if (self.enabled) if (self.on_changed) |callback| callback(self.user_ctx, !self.value);
    }
    fn up(ctx: *anyopaque, event: phantom.PointerEvent) void {
        const self: *RenderSwitch = @ptrCast(@alignCast(ctx));
        const o = self.base.origin;
        const s = self.base.size;
        if (event.position.x >= o.x and event.position.x < o.x + s.width and event.position.y >= o.y and event.position.y < o.y + s.height) self.activate();
    }
    fn key(ctx: *anyopaque, event: phantom.input.KeyEvent) bool {
        const self: *RenderSwitch = @ptrCast(@alignCast(ctx));
        if (!self.enabled or event.action == .release or !event.mods.none()) return false;
        if (event.keysym != .enter and event.keysym != phantom.input.Keysym.fromCodepoint(' ')) return false;
        self.activate();
        return true;
    }
    fn focus(ctx: *anyopaque, value: bool) void {
        const self: *RenderSwitch = @ptrCast(@alignCast(ctx));
        self.focused = value;
    }
    fn available(ctx: *anyopaque) bool {
        return (@as(*RenderSwitch, @ptrCast(@alignCast(ctx)))).enabled;
    }
    fn install(self: *RenderSwitch) void {
        self.handlers = .{ .ctx = self, .on_up = up };
        self.base.pointer = if (self.enabled) &self.handlers else null;
        self.focus_handlers = .{ .ctx = self, .on_key = key, .on_focus_change = focus, .available = available, .node = &self.base };
        self.base.focus = &self.focus_handlers;
    }
};

pub const Switch = struct {
    value: bool,
    enabled: bool = true,
    width: f32 = 44,
    height: f32 = 24,
    /// Accessible name reserved for host semantics trees.
    label: ?[]const u8 = null,
    on_changed: ?*const fn (*anyopaque, bool) void = null,
    ctx: *anyopaque = undefined,

    const vtable = phantom.Widget.VTable{ .mount = mount, .update = update };
    pub fn widget(self: *const Switch) phantom.Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn configure(self: *const Switch, b: *phantom.BuildContext, anchor: ?*phantom.Element, ro: *RenderSwitch) void {
        _ = self.label;
        const theme = phantom.inheritedOf(anchor, phantom.ThemeData) orelse phantom.theme.defaultTheme(b.owner);
        ro.value = self.value;
        ro.enabled = self.enabled;
        ro.width = self.width;
        ro.height = self.height;
        ro.on_changed = self.on_changed;
        ro.user_ctx = self.ctx;
        ro.active = theme.accent;
        ro.inactive = theme.colors.fg_dim;
        ro.knob = theme.colors.fg;
        ro.disabled = geom.Color.mix(theme.colors.fg_dim, theme.colors.bg, 0.6);
        ro.install();
    }
    fn mount(ptr: *const anyopaque, b: *phantom.BuildContext, parent: ?*phantom.Element) anyerror!*phantom.Element {
        const self: *const Switch = @ptrCast(@alignCast(ptr));
        const ro = try b.owner.gpa.create(RenderSwitch);
        errdefer b.owner.gpa.destroy(ro);
        ro.* = .{ .base = .{ .layoutFn = RenderSwitch.layoutFn, .paintFn = RenderSwitch.paintFn, .destroyFn = RenderSwitch.destroyFn }, .value = self.value, .enabled = self.enabled, .width = self.width, .height = self.height, .active = undefined, .inactive = undefined, .knob = undefined, .disabled = undefined, .on_changed = self.on_changed, .user_ctx = self.ctx };
        self.configure(b, parent, ro);
        const el = try b.owner.gpa.create(phantom.Element);
        el.* = .{ .owner = b.owner, .parent = parent, .vtable = &vtable, .type_name = @typeName(Switch), .render_object = &ro.base, .depth = phantom.widget.depthOf(parent) };
        return el;
    }
    fn update(ptr: *const anyopaque, el: *phantom.Element, b: *phantom.BuildContext) anyerror!void {
        const self: *const Switch = @ptrCast(@alignCast(ptr));
        self.configure(b, el.parent, @fieldParentPtr("base", el.render_object.?));
    }
};

test "Switch toggles by pointer and disabled switches do not install a pointer handler" {
    const Changed = struct {
        value: ?bool = null,
        fn call(ctx: *anyopaque, value: bool) void {
            (@as(*@This(), @ptrCast(@alignCast(ctx)))).value = value;
        }
    };
    var changed = Changed{};
    var control = Switch{ .value = false, .on_changed = Changed.call, .ctx = &changed };
    var harness = try phantom.testing.mount(std.testing.allocator, control.widget());
    defer harness.deinit();
    harness.viewport = .{ .width = 44, .height = 24 };
    try harness.pump();
    var dispatcher = phantom.input.Dispatcher{};
    dispatcher.down(harness.root, .{ .x = 10, .y = 10 });
    dispatcher.up(harness.root, .{ .x = 10, .y = 10 });
    try std.testing.expectEqual(@as(?bool, true), changed.value);
    try std.testing.expect(harness.root.renderObject().?.pointer != null);

    var disabled = Switch{ .value = false, .enabled = false, .on_changed = Changed.call, .ctx = &changed };
    var disabled_harness = try phantom.testing.mount(std.testing.allocator, disabled.widget());
    defer disabled_harness.deinit();
    disabled_harness.viewport = .{ .width = 44, .height = 24 };
    try disabled_harness.pump();
    changed.value = null;
    dispatcher.down(disabled_harness.root, .{ .x = 10, .y = 10 });
    dispatcher.up(disabled_harness.root, .{ .x = 10, .y = 10 });
    try std.testing.expectEqual(@as(?bool, null), changed.value);
    try std.testing.expect(disabled_harness.root.renderObject().?.pointer == null);
}
