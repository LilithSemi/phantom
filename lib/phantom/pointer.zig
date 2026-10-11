const geom = @import("geometry.zig");

pub const PointerPhase = enum { down, up, move, enter, leave };

pub const PointerEvent = struct {
    /// The point in the space of the target's origin. This is the window
    /// point, moved by the scroll offsets above the target.
    position: geom.PhysicalOffset,
    phase: PointerPhase,
};

/// Pointer callbacks installed on a RenderObject (via base.pointer) by a gesture
/// widget. Each callback carries an explicit ctx because Zig function pointers
/// cannot close over state; the installing render object passes itself as ctx.
pub const PointerHandlers = struct {
    ctx: *anyopaque,
    on_down: ?*const fn (ctx: *anyopaque, ev: PointerEvent) void = null,
    on_up: ?*const fn (ctx: *anyopaque, ev: PointerEvent) void = null,
    on_move: ?*const fn (ctx: *anyopaque, ev: PointerEvent) void = null,
    on_enter: ?*const fn (ctx: *anyopaque, ev: PointerEvent) void = null,
    on_leave: ?*const fn (ctx: *anyopaque, ev: PointerEvent) void = null,
    /// Returns true when the view moved. A false return passes the delta to the
    /// next scrollable view out.
    on_scroll: ?*const fn (ctx: *anyopaque, dx: f32, dy: f32) bool = null,
    /// Scroll to an absolute offset that something outside the tree already
    /// shows, such as a browser scroll region. Returns true when the view moved.
    on_scroll_to: ?*const fn (ctx: *anyopaque, x: f32, y: f32) bool = null,
};
