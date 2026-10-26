//! Paint a child at a logical offset without changing its layout size.
const std = @import("std");
const phantom = @import("../../phantom.zig");

const RenderTranslate = struct {
    base: phantom.RenderObject,
    child: ?*phantom.RenderObject = null,
    offset: phantom.LogicalOffset,
    scale: f32 = 1,

    fn layoutFn(base: *phantom.RenderObject, constraints: phantom.BoxConstraints) phantom.PhysicalSize {
        const self: *RenderTranslate = @fieldParentPtr("base", base);
        self.scale = constraints.scale;
        if (self.child) |child| return child.layout(constraints);
        return constraints.constrain(.zero);
    }

    fn paintFn(base: *phantom.RenderObject, canvas: *phantom.Canvas, origin: phantom.PhysicalOffset) anyerror!void {
        const self: *RenderTranslate = @fieldParentPtr("base", base);
        if (self.child) |child| try child.paint(canvas, origin.add(self.offset.toPhysical(self.scale)));
    }

    fn adopt(base: *phantom.RenderObject, child: ?*phantom.RenderObject) void {
        const self: *RenderTranslate = @fieldParentPtr("base", base);
        self.child = child;
    }

    fn destroyFn(base: *phantom.RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderTranslate = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
};

pub const Translate = struct {
    offset: phantom.LogicalOffset = .zero,
    child: phantom.Widget,

    const vtable = phantom.Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const Translate) phantom.Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *phantom.BuildContext, parent: ?*phantom.Element) anyerror!*phantom.Element {
        const self: *const Translate = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const render = try gpa.create(RenderTranslate);
        render.* = .{
            .base = .{
                .layoutFn = RenderTranslate.layoutFn,
                .paintFn = RenderTranslate.paintFn,
                .destroyFn = RenderTranslate.destroyFn,
                .adoptChildFn = RenderTranslate.adopt,
            },
            .offset = self.offset,
        };
        const element = try gpa.create(phantom.Element);
        element.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(Translate),
            .render_object = &render.base,
            .depth = phantom.widget.depthOf(parent),
        };
        errdefer element.deinit(gpa);
        element.child = try element.updateChild(null, self.child, bctx);
        render.base.adoptChild(if (element.child) |child| child.renderObject() else null);
        return element;
    }

    fn update(ptr: *const anyopaque, element: *phantom.Element, bctx: *phantom.BuildContext) anyerror!void {
        const self: *const Translate = @ptrCast(@alignCast(ptr));
        const render: *RenderTranslate = @fieldParentPtr("base", element.render_object.?);
        render.offset = self.offset;
        element.child = try element.updateChild(element.child, self.child, bctx);
        render.base.adoptChild(if (element.child) |child| child.renderObject() else null);
    }
};

test "Translate moves paint without changing layout size" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };
    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 0, 0), .radius = 0 };
    var sized = phantom.SizedBox{ .width = 20, .height = 10, .child = box.widget() };
    var translated = Translate{ .offset = .{ .x = 7, .y = 9 }, .child = sized.widget() };
    const element = try translated.widget().mount(&bctx, null);
    defer element.deinit(std.testing.allocator);
    const render = element.renderObject().?;
    const size = render.layout(.{ .max_width = 100, .max_height = 100 });
    var canvas = phantom.Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try render.paint(&canvas, .zero);
    try std.testing.expectEqual(@as(f32, 20), size.width);
    const rect = canvas.list.primitives.items[0].rrect.rect;
    try std.testing.expectEqual(@as(f32, 7), rect.x);
    try std.testing.expectEqual(@as(f32, 9), rect.y);
}
