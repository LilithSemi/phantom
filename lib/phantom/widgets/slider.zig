//! A normalized or ranged slider with drag and arrow-key operation.
const std = @import("std");
const phantom = @import("../../phantom.zig");
const geom = phantom.geometry;
const layout = phantom.layout;

const RenderSlider = struct {
    base: phantom.RenderObject,
    handlers: phantom.PointerHandlers = .{ .ctx = undefined },
    focus_handlers: phantom.FocusHandlers = .{ .ctx = undefined },
    value: f32,
    min: f32,
    max: f32,
    step: f32,
    width: f32,
    height: f32,
    enabled: bool,
    focused: bool = false,
    dragging: bool = false,
    scale: f32 = 1,
    accent: geom.Color,
    track: geom.Color,
    knob: geom.Color,
    disabled: geom.Color,
    on_changed: ?*const fn (*anyopaque, f32) void,
    user_ctx: *anyopaque,

    fn fraction(self: *const RenderSlider) f32 {
        return if (self.max <= self.min) 0 else std.math.clamp((self.value - self.min) / (self.max - self.min), 0, 1);
    }
    fn layoutFn(base: *phantom.RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderSlider = @fieldParentPtr("base", base);
        self.scale = c.scale;
        return c.constrain(.{ .width = self.width * c.scale, .height = self.height * c.scale });
    }
    fn paintFn(base: *phantom.RenderObject, cv: *phantom.Canvas, o: geom.PhysicalOffset) anyerror!void {
        const self: *RenderSlider = @fieldParentPtr("base", base);
        const rail_h = 4 * self.scale;
        const rail = geom.PhysicalRect{ .x = o.x, .y = o.y + (base.size.height - rail_h) / 2, .width = base.size.width, .height = rail_h };
        try cv.fillRRect(rail, rail_h / 2, if (self.enabled) self.track else self.disabled);
        const fill_w = rail.width * self.fraction();
        if (fill_w > 0) try cv.fillRRect(.{ .x = rail.x, .y = rail.y, .width = fill_w, .height = rail.height }, rail_h / 2, if (self.enabled) self.accent else self.disabled);
        const diameter = 18 * self.scale;
        const cx = rail.x + fill_w;
        const knob = geom.PhysicalRect{ .x = cx - diameter / 2, .y = o.y + (base.size.height - diameter) / 2, .width = diameter, .height = diameter };
        try cv.fillRRect(knob, diameter / 2, if (self.enabled) self.knob else self.disabled);
        if (self.focused) try cv.strokeRRect(knob, diameter / 2, self.scale, self.accent);
    }
    fn destroyFn(base: *phantom.RenderObject, gpa: std.mem.Allocator) void {
        gpa.destroy(@as(*RenderSlider, @fieldParentPtr("base", base)));
    }
    fn emitAt(self: *RenderSlider, x: f32) void {
        if (!self.enabled or self.max <= self.min) return;
        var value = self.min + std.math.clamp((x - self.base.origin.x) / self.base.size.width, 0, 1) * (self.max - self.min);
        if (self.step > 0) value = self.min + @round((value - self.min) / self.step) * self.step;
        value = std.math.clamp(value, self.min, self.max);
        if (self.on_changed) |callback| callback(self.user_ctx, value);
    }
    fn down(ctx: *anyopaque, event: phantom.PointerEvent) void {
        const self: *RenderSlider = @ptrCast(@alignCast(ctx));
        self.dragging = true;
        self.emitAt(event.position.x);
    }
    fn move(ctx: *anyopaque, event: phantom.PointerEvent) void {
        const self: *RenderSlider = @ptrCast(@alignCast(ctx));
        if (self.dragging) self.emitAt(event.position.x);
    }
    fn up(ctx: *anyopaque, event: phantom.PointerEvent) void {
        const self: *RenderSlider = @ptrCast(@alignCast(ctx));
        if (self.dragging) self.emitAt(event.position.x);
        self.dragging = false;
    }
    fn key(ctx: *anyopaque, event: phantom.input.KeyEvent) bool {
        const self: *RenderSlider = @ptrCast(@alignCast(ctx));
        if (!self.enabled or event.action == .release or !event.mods.none()) return false;
        const direction: f32 = if (event.keysym == .left or event.keysym == .down) -1 else if (event.keysym == .right or event.keysym == .up) 1 else return false;
        const amount = if (self.step > 0) self.step else (self.max - self.min) / 20;
        if (self.on_changed) |callback| callback(self.user_ctx, std.math.clamp(self.value + direction * amount, self.min, self.max));
        return true;
    }
    fn focus(ctx: *anyopaque, value: bool) void {
        (@as(*RenderSlider, @ptrCast(@alignCast(ctx)))).focused = value;
    }
    fn available(ctx: *anyopaque) bool {
        return (@as(*RenderSlider, @ptrCast(@alignCast(ctx)))).enabled;
    }
    fn install(self: *RenderSlider) void {
        self.handlers = .{ .ctx = self, .on_down = down, .on_move = move, .on_up = up };
        self.base.pointer = if (self.enabled) &self.handlers else null;
        self.focus_handlers = .{ .ctx = self, .on_key = key, .on_focus_change = focus, .available = available, .node = &self.base };
        self.base.focus = &self.focus_handlers;
    }
};

pub const Slider = struct {
    value: f32,
    min: f32 = 0,
    max: f32 = 1,
    step: f32 = 0,
    width: f32 = 180,
    height: f32 = 28,
    enabled: bool = true,
    label: ?[]const u8 = null,
    on_changed: ?*const fn (*anyopaque, f32) void = null,
    ctx: *anyopaque = undefined,
    const vtable = phantom.Widget.VTable{ .mount = mount, .update = update };
    pub fn widget(self: *const Slider) phantom.Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn configure(self: *const Slider, b: *phantom.BuildContext, anchor: ?*phantom.Element, ro: *RenderSlider) void {
        _ = self.label;
        const theme = phantom.inheritedOf(anchor, phantom.ThemeData) orelse phantom.theme.defaultTheme(b.owner);
        ro.value = std.math.clamp(self.value, self.min, self.max);
        ro.min = self.min;
        ro.max = self.max;
        ro.step = @max(0, self.step);
        ro.width = self.width;
        ro.height = self.height;
        ro.enabled = self.enabled;
        ro.on_changed = self.on_changed;
        ro.user_ctx = self.ctx;
        ro.accent = theme.accent;
        ro.track = theme.colors.fg_dim;
        ro.knob = theme.colors.fg;
        ro.disabled = geom.Color.mix(theme.colors.fg_dim, theme.colors.bg, 0.6);
        ro.install();
    }
    fn mount(ptr: *const anyopaque, b: *phantom.BuildContext, parent: ?*phantom.Element) anyerror!*phantom.Element {
        const self: *const Slider = @ptrCast(@alignCast(ptr));
        const ro = try b.owner.gpa.create(RenderSlider);
        errdefer b.owner.gpa.destroy(ro);
        ro.* = .{ .base = .{ .layoutFn = RenderSlider.layoutFn, .paintFn = RenderSlider.paintFn, .destroyFn = RenderSlider.destroyFn }, .value = self.value, .min = self.min, .max = self.max, .step = self.step, .width = self.width, .height = self.height, .enabled = self.enabled, .accent = undefined, .track = undefined, .knob = undefined, .disabled = undefined, .on_changed = self.on_changed, .user_ctx = self.ctx };
        self.configure(b, parent, ro);
        const el = try b.owner.gpa.create(phantom.Element);
        el.* = .{ .owner = b.owner, .parent = parent, .vtable = &vtable, .type_name = @typeName(Slider), .render_object = &ro.base, .depth = phantom.widget.depthOf(parent) };
        return el;
    }
    fn update(ptr: *const anyopaque, el: *phantom.Element, b: *phantom.BuildContext) anyerror!void {
        const self: *const Slider = @ptrCast(@alignCast(ptr));
        self.configure(b, el.parent, @fieldParentPtr("base", el.render_object.?));
    }
};

test "Slider maps pointer position into its range and snaps to step" {
    const Changed = struct {
        value: f32 = -1,
        fn call(ctx: *anyopaque, value: f32) void {
            (@as(*@This(), @ptrCast(@alignCast(ctx)))).value = value;
        }
    };
    var changed = Changed{};
    var slider = Slider{ .value = 0, .min = 0, .max = 100, .step = 10, .width = 100, .on_changed = Changed.call, .ctx = &changed };
    var harness = try phantom.testing.mount(std.testing.allocator, slider.widget());
    defer harness.deinit();
    harness.viewport = .{ .width = 100, .height = 28 };
    try harness.pump();
    var dispatcher = phantom.input.Dispatcher{};
    dispatcher.down(harness.root, .{ .x = 74, .y = 14 });
    dispatcher.up(harness.root, .{ .x = 74, .y = 14 });
    try std.testing.expectEqual(@as(f32, 70), changed.value);
}
