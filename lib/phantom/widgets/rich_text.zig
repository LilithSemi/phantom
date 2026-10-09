const std = @import("std");
const phantom = @import("../../phantom.zig");
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const Canvas = phantom.Canvas;
const geom = phantom.geometry;
const layout_mod = phantom.layout;
const text_layout = @import("../text/layout.zig");
const Font = @import("../text/Font.zig");
const mono = @import("../text/mono.zig");
const dl = phantom.display_list;
const theme_mod = @import("../theme.zig");

/// One span resolved to a concrete font, colour and run flags. Owns its text
/// and url, since the widget config lives in the per-frame build arena.
const Resolved = struct {
    text: []u8,
    url: ?[]u8,
    font: *Font,
    color: geom.Color,
    italic: bool,
    underline: bool,
    background: ?geom.Color,
};

/// A tappable area painted by the last layout, in offset-relative physical
/// coordinates.
const Link = struct { rect: geom.PhysicalRect, url: []const u8 };

const RenderRichText = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    spans: []Resolved = &.{},
    size: f32,
    physical_size: f32 = 0,
    wrap: bool,
    text_metrics: *const mono.TextMetrics,
    laid: ?text_layout.SpanLayout = null,
    links: std.ArrayList(Link) = .empty,
    handlers: phantom.pointer.PointerHandlers = undefined,
    on_link: ?*const fn (ctx: *anyopaque, url: []const u8) void = null,
    user_ctx: *anyopaque = undefined,
    max_width: f32 = 0,

    fn widthOf(ctx: ?*anyopaque, _: usize) f32 {
        const self: *RenderRichText = @ptrCast(@alignCast(ctx.?));
        return self.max_width;
    }

    fn layoutFn(base: *RenderObject, c: layout_mod.BoxConstraints) geom.PhysicalSize {
        const self: *RenderRichText = @fieldParentPtr("base", base);
        self.dropLayout();
        self.physical_size = self.size * c.scale;
        self.max_width = if (self.wrap and std.math.isFinite(c.max_width)) c.max_width else 0;
        const laid = self.gpa.alloc(text_layout.Span, self.spans.len) catch return c.constrain(.{ .width = 0, .height = 0 });
        defer self.gpa.free(laid);
        for (self.spans, laid) |s, *l| l.* = .{ .text = s.text, .font = s.font, .size = self.physical_size, .metrics = self.text_metrics.* };
        const result = text_layout.layoutSpans(self.gpa, laid, .{ .ctx = self, .width_of = widthOf }) catch
            return c.constrain(.{ .width = 0, .height = 0 });
        self.laid = result;
        return c.constrain(.{ .width = result.width, .height = result.height });
    }

    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderRichText = @fieldParentPtr("base", base);
        const laid = self.laid orelse return;
        self.links.clearRetainingCapacity();
        var y = offset.y;
        for (laid.rows) |row| {
            for (row.pieces) |pc| {
                const s = self.spans[pc.span];
                const x = offset.x + pc.x;
                if (s.background) |bg| try cv.fillRRect(.{ .x = x, .y = y, .width = pc.width, .height = row.height }, 3, bg);
                try cv.drawText(.{
                    .glyphs = pc.glyphs,
                    .text = s.text[pc.start..pc.end],
                    .font = @ptrCast(s.font),
                    .size = self.physical_size,
                    .color = s.color,
                    .origin = .{ .x = x, .y = y + row.ascent - pc.ascent },
                    .ascent = pc.ascent,
                    .italic = s.italic,
                    .underline = s.underline,
                });
                if (s.url) |u| try self.links.append(self.gpa, .{
                    .rect = .{ .x = x - offset.x, .y = y - offset.y, .width = pc.width, .height = row.height },
                    .url = u,
                });
            }
            y += row.height;
        }
    }

    fn onUp(ctx: *anyopaque, ev: phantom.pointer.PointerEvent) void {
        const self: *RenderRichText = @ptrCast(@alignCast(ctx));
        const f = self.on_link orelse return;
        const lx = ev.position.x - self.base.origin.x;
        const ly = ev.position.y - self.base.origin.y;
        for (self.links.items) |l| {
            if (lx >= l.rect.x and lx < l.rect.x + l.rect.width and ly >= l.rect.y and ly < l.rect.y + l.rect.height) {
                f(self.user_ctx, l.url);
                return;
            }
        }
    }

    fn dropLayout(self: *RenderRichText) void {
        if (self.laid) |*l| l.deinit(self.gpa);
        self.laid = null;
    }

    fn freeSpans(self: *RenderRichText) void {
        for (self.spans) |s| {
            self.gpa.free(s.text);
            if (s.url) |u| self.gpa.free(u);
        }
        self.gpa.free(self.spans);
        self.spans = &.{};
    }

    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderRichText = @fieldParentPtr("base", base);
        self.dropLayout();
        self.freeSpans();
        self.links.deinit(self.gpa);
        gpa.destroy(self);
    }
};

pub const RichText = struct {
    spans: []const Span,
    /// Logical size for every span. Null takes the theme's.
    size: ?f32 = null,
    /// Replaces the body font for non-code spans. Headings use this.
    font: ?*Font = null,
    wrap: bool = true,
    /// Paint the theme's code background behind code spans. A code block
    /// that draws its own background turns this off.
    code_background: bool = true,
    on_link: ?*const fn (ctx: *anyopaque, url: []const u8) void = null,
    ctx: *anyopaque = undefined,

    pub const Style = packed struct { strong: bool = false, em: bool = false, code: bool = false, underline: bool = false };
    pub const Span = struct { text: []const u8, style: Style = .{}, color: ?geom.Color = null, url: ?[]const u8 = null };

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const RichText) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn resolveSpans(self: *const RichText, gpa: std.mem.Allocator, td: *const theme_mod.ThemeData) ![]Resolved {
        const out = try gpa.alloc(Resolved, self.spans.len);
        var done: usize = 0;
        errdefer {
            for (out[0..done]) |r| {
                gpa.free(r.text);
                if (r.url) |u| gpa.free(u);
            }
            gpa.free(out);
        }
        for (self.spans, out) |s, *r| {
            const st = s.style;
            const font = if (st.code)
                (if (st.strong) td.code_bold_font else if (st.em) td.code_italic_font else td.code_font)
            else if (self.font) |f| f else if (st.strong) td.body_bold_font else td.body_font;
            const text = try gpa.dupe(u8, s.text);
            errdefer gpa.free(text);
            const url = if (s.url) |u| try gpa.dupe(u8, u) else null;
            r.* = .{
                .text = text,
                .url = url,
                .font = font,
                .color = s.color orelse if (s.url != null) td.accent else if (st.code) td.code_color else td.text_color,
                .italic = st.em and !font.isItalic(),
                .underline = st.underline or s.url != null,
                .background = if (st.code and self.code_background) td.code_background else null,
            };
            done += 1;
        }
        return out;
    }

    fn mount(ptr: *const anyopaque, bctx: *phantom.BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const RichText = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const td = phantom.inheritedOf(parent, theme_mod.ThemeData) orelse theme_mod.defaultTheme(bctx.owner);
        const spans = try self.resolveSpans(gpa, td);
        errdefer {
            for (spans) |s| {
                gpa.free(s.text);
                if (s.url) |u| gpa.free(u);
            }
            gpa.free(spans);
        }
        const ro = try gpa.create(RenderRichText);
        errdefer gpa.destroy(ro);
        ro.* = .{
            .base = .{
                .layoutFn = RenderRichText.layoutFn,
                .paintFn = RenderRichText.paintFn,
                .destroyFn = RenderRichText.destroyFn,
            },
            .gpa = gpa,
            .spans = spans,
            .size = self.size orelse td.text_size,
            .wrap = self.wrap,
            .text_metrics = &bctx.owner.text_metrics,
            .on_link = self.on_link,
            .user_ctx = self.ctx,
        };
        ro.handlers = .{ .ctx = ro, .on_up = RenderRichText.onUp };
        ro.base.pointer = if (self.on_link != null) &ro.handlers else null;
        const el = try gpa.create(Element);
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(RichText),
            .render_object = &ro.base,
            .depth = phantom.widget.depthOf(parent),
        };
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *phantom.BuildContext) anyerror!void {
        const self: *const RichText = @ptrCast(@alignCast(ptr));
        const ro: *RenderRichText = @fieldParentPtr("base", el.render_object.?);
        const td = phantom.inheritedOf(el.parent, theme_mod.ThemeData) orelse theme_mod.defaultTheme(bctx.owner);
        const spans = try self.resolveSpans(ro.gpa, td);
        ro.freeSpans();
        ro.spans = spans;
        ro.size = self.size orelse td.text_size;
        ro.wrap = self.wrap;
        ro.on_link = self.on_link;
        ro.user_ctx = self.ctx;
        ro.handlers = .{ .ctx = ro, .on_up = RenderRichText.onUp };
        ro.base.pointer = if (self.on_link != null) &ro.handlers else null;
        ro.dropLayout();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn mountAndPaint(gpa: std.mem.Allocator, owner: *phantom.BuildOwner, rt: *const RichText, canvas: *phantom.Canvas) !*Element {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = owner };
    const el = try rt.widget().mount(&bctx, null);
    _ = el.render_object.?.layout(layout_mod.BoxConstraints{ .max_width = 400, .max_height = 400 });
    try el.render_object.?.paint(canvas, geom.PhysicalOffset.zero);
    return el;
}

test "styles become fonts and run flags" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    const td = theme_mod.defaultTheme(&owner);
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    const rt = RichText{ .spans = &.{
        .{ .text = "b", .style = .{ .strong = true } },
        .{ .text = "i", .style = .{ .em = true } },
        .{ .text = "c", .style = .{ .code = true } },
        .{ .text = "ci", .style = .{ .code = true, .em = true } },
    } };
    const el = try mountAndPaint(gpa, &owner, &rt, &canvas);
    defer el.deinit(gpa);
    var runs: std.ArrayList(dl.TextRun) = .empty;
    defer runs.deinit(gpa);
    for (canvas.list.primitives.items) |p| if (p == .text) try runs.append(gpa, p.text);
    try std.testing.expectEqual(@as(usize, 4), runs.items.len);
    try std.testing.expect(@as(*Font, @ptrCast(@alignCast(runs.items[0].font))) == td.body_bold_font);
    try std.testing.expect(runs.items[1].italic);
    try std.testing.expect(@as(*Font, @ptrCast(@alignCast(runs.items[2].font))) == td.code_font);
    try std.testing.expect(@as(*Font, @ptrCast(@alignCast(runs.items[3].font))) == td.code_italic_font);
}

test "a code span paints its background before its text" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    const rt = RichText{ .spans = &.{.{ .text = "x", .style = .{ .code = true } }} };
    const el = try mountAndPaint(gpa, &owner, &rt, &canvas);
    defer el.deinit(gpa);
    const items = canvas.list.primitives.items;
    try std.testing.expect(items[0] == .rrect);
    try std.testing.expect(items[1] == .text);

    var bare = phantom.Canvas.init(gpa);
    defer bare.deinit();
    const no_bg = RichText{ .spans = &.{.{ .text = "x", .style = .{ .code = true } }}, .code_background = false };
    const el2 = try mountAndPaint(gpa, &owner, &no_bg, &bare);
    defer el2.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), bare.list.primitives.items.len);
    try std.testing.expect(bare.list.primitives.items[0] == .text);
}

test "a tap on a link calls on_link with its url, and a tap beside it calls nothing" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    const Spy = struct {
        url: [32]u8 = undefined,
        len: usize = 0,
        calls: u32 = 0,
        fn onLink(ctx: *anyopaque, url: []const u8) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(s.url[0..url.len], url);
            s.len = url.len;
            s.calls += 1;
        }
    };
    var spy = Spy{};
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    const rt = RichText{
        .spans = &.{ .{ .text = "see " }, .{ .text = "docs", .url = "https://x.dev" } },
        .on_link = Spy.onLink,
        .ctx = &spy,
    };
    const el = try mountAndPaint(gpa, &owner, &rt, &canvas);
    defer el.deinit(gpa);
    const ro: *RenderRichText = @fieldParentPtr("base", el.render_object.?);
    const h = el.render_object.?.pointer.?;
    const link = ro.links.items[0];
    h.on_up.?(h.ctx, .{ .position = .{ .x = link.rect.x + 1, .y = link.rect.y + 1 }, .phase = .up });
    try std.testing.expectEqual(@as(u32, 1), spy.calls);
    try std.testing.expectEqualStrings("https://x.dev", spy.url[0..spy.len]);
    h.on_up.?(h.ctx, .{ .position = .{ .x = 1, .y = 1 }, .phase = .up });
    try std.testing.expectEqual(@as(u32, 1), spy.calls);
}
