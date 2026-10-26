//! A viewport for every toplevel hosted by Phantom's nested compositor.
const std = @import("std");
const phantom = @import("../../phantom.zig");

const RenderCompositorView = struct {
    base: phantom.RenderObject,
    host: ?*phantom.compositor.Host,
    input_enabled: bool,

    fn layoutFn(_: *phantom.RenderObject, constraints: phantom.BoxConstraints) phantom.PhysicalSize {
        return constraints.biggest();
    }

    fn paintFn(base: *phantom.RenderObject, canvas: *phantom.Canvas, offset: phantom.PhysicalOffset) anyerror!void {
        const self: *RenderCompositorView = @fieldParentPtr("base", base);
        if (self.host) |host| try host.paint(canvas, .fromOriginSize(offset, base.size));
    }

    fn destroyFn(base: *phantom.RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderCompositorView = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
};

pub const CompositorView = struct {
    /// False while a shell-owned modal is above the hosted desktop. Painting
    /// continues, but pointer and keyboard events fall through to shell widgets.
    input_enabled: bool = true,
    const vtable = phantom.Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const CompositorView) phantom.Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *phantom.BuildContext, parent: ?*phantom.Element) anyerror!*phantom.Element {
        const self: *const CompositorView = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderCompositorView);
        errdefer gpa.destroy(ro);
        ro.* = .{
            .base = .{ .layoutFn = RenderCompositorView.layoutFn, .paintFn = RenderCompositorView.paintFn, .destroyFn = RenderCompositorView.destroyFn },
            .host = phantom.compositor.fromOwner(bctx.owner),
            .input_enabled = self.input_enabled,
        };
        if (ro.host) |host| host.setInputEnabled(ro.input_enabled);
        const el = try gpa.create(phantom.Element);
        el.* = .{ .owner = bctx.owner, .parent = parent, .vtable = &vtable, .type_name = @typeName(CompositorView), .render_object = &ro.base, .depth = phantom.widget.depthOf(parent) };
        return el;
    }

    fn update(ptr: *const anyopaque, el: *phantom.Element, bctx: *phantom.BuildContext) anyerror!void {
        const self: *const CompositorView = @ptrCast(@alignCast(ptr));
        const ro: *RenderCompositorView = @fieldParentPtr("base", el.render_object.?);
        ro.host = phantom.compositor.fromOwner(bctx.owner);
        ro.input_enabled = self.input_enabled;
        if (ro.host) |host| host.setInputEnabled(ro.input_enabled);
    }
};

test "a compositor view without a native host fills its viewport and paints nothing" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };
    var view = CompositorView{ .input_enabled = false };
    const el = try view.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    const ro = el.renderObject().?;
    const compositor_ro: *RenderCompositorView = @fieldParentPtr("base", ro);
    try std.testing.expect(!compositor_ro.input_enabled);
    const size = ro.layout(phantom.BoxConstraints.tight(.{ .width = 640, .height = 480 }));
    try std.testing.expectEqual(@as(f32, 640), size.width);
    var canvas = phantom.Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try ro.paint(&canvas, .zero);
    try std.testing.expectEqual(@as(usize, 0), canvas.list.primitives.items.len);
}
