//! The web backend's frame as a small tree of DOM nodes. `build` turns a
//! display list into this tree. `dom_calls.render` patches the DOM to match it and
//! `dom.renderPage` prints it as HTML and CSS, so both give the same markup.

const std = @import("std");
const display_list = @import("../display_list.zig");
const geometry = @import("../geometry.zig");
const dom = @import("dom.zig");
const text = @import("../text.zig");
const image_mod = @import("../image/Image.zig");
const pointer = @import("../pointer.zig");
const icon_builtin = @import("../icon/builtin.zig");
const svg_path = @import("../icon/svg_path.zig");
const FaultSink = @import("../FaultSink.zig");

/// How many clip and scroll regions can nest. A region past this is not opened
/// and a fault is reported. A real page nests a few at most, so this catches a
/// malformed display list.
pub const max_region_depth = 32;

/// The deepest a tree can be: the container, two nodes for each scroll region,
/// and an svg holding a path.
pub const max_tree_depth = 1 + 2 * max_region_depth + 2;

pub const Kind = enum { element, element_svg };

pub const Attr = struct { name: []const u8, value: []const u8 };

/// The scroll state of a region in one frame, as values that stay valid after
/// the display list is gone.
pub const Scroll = struct {
    offset: geometry.PhysicalOffset,
    /// `ScrollRegion.moved`. A change from the last frame means phantom moved
    /// the region.
    moved: u32,
    /// Called only in the frame that built this value. After that it is only
    /// compared.
    handlers: ?*pointer.PointerHandlers,
};

pub const Node = struct {
    kind: Kind,
    tag: []const u8,
    style: []const u8 = "",
    attrs: []const Attr = &.{},
    text: []const u8 = "",
    children: []const Node = &.{},
    /// Scroll regions carry their render object's handlers, the match key.
    key: ?*const anyopaque = null,
    /// Set on the outer node of a scroll region. Its only child is the inner
    /// node that holds the content.
    scroll: ?Scroll = null,
    /// For an img, a hash of the encoded bytes. A diff compares this in place
    /// of the long data url in `src`.
    src_hash: u64 = 0,
};

/// The `:hover`, `:active` and cursor rules of one interactive class. `hash`
/// is the hash in the class name.
pub const Rule = struct { hash: u64, css: []const u8 };

pub const Tree = struct {
    root: Node,
    /// One entry for each class, in the order the frame first uses them.
    rules: []const Rule,
    /// The number of nodes in `root`, `root` included.
    count: usize,
    /// The fonts the text uses, one for each `text.Font.id`, in the order the
    /// frame first uses them.
    fonts: []const *text.Font,
    /// The page background behind the container.
    background: geometry.Color,
};

/// The CSS family name for a font, from `text.Font.id`. The page declares each
/// face once, so a name from the font's position in one frame would name a
/// different font in a frame that uses a different set. An address changes
/// between runs and between targets.
pub fn fontFamily(buf: []u8, font_ptr: *const text.Font) []const u8 {
    std.debug.assert(buf.len >= family_len);
    return std.fmt.bufPrint(buf, "pf-{x:0>16}", .{font_ptr.id}) catch unreachable;
}

/// The buffer `fontFamily` needs: "pf-" and a u64 in hex.
pub const family_len = 3 + 16;

/// Room for "border-color:rgba(255,255,255," and an alpha from `dom.alpha`.
const state_decl_len = 64;
/// "pb-" and a u64 in hex.
const class_len = 3 + 16;

/// The declaration a :hover or :active rule sets, such as
/// `background:rgba(1,2,3,0.5)`.
fn stateDecl(buf: *[state_decl_len]u8, prop: []const u8, c: geometry.Color) []const u8 {
    var abuf: [8]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}:rgba({d},{d},{d},{s})", .{ prop, dom.ch(c.r), dom.ch(c.g), dom.ch(c.b), dom.alpha(&abuf, c.a) }) catch unreachable;
}

/// One open element while `build` walks the list. A scroll region keeps its
/// outer node here and collects its content under the inner node.
const Frame = struct {
    node: Node,
    outer: ?Node = null,
    children: std.ArrayList(Node) = .empty,
    origin: ?geometry.PhysicalOffset = null,
};

const Builder = struct {
    arena: std.mem.Allocator,
    sink: ?*FaultSink,
    stack: [max_region_depth + 1]Frame = undefined,
    depth: usize = 0,
    /// Opens refused past `max_region_depth`, so a later pop can tell it was
    /// never recorded.
    skipped: usize = 0,
    rules: std.ArrayList(Rule) = .empty,
    fonts: std.ArrayList(*text.Font) = .empty,
    count: usize = 1,
    /// The scroll regions opened so far. The page reports a scroll by this
    /// index.
    regions: usize = 0,

    fn top(self: *Builder) *Frame {
        return &self.stack[self.depth];
    }

    fn offset(self: *Builder) geometry.PhysicalOffset {
        return self.top().origin orelse .zero;
    }

    fn add(self: *Builder, node: Node) !void {
        try self.top().children.append(self.arena, node);
        self.count += 1;
    }

    fn open(self: *Builder, frame: Frame, what: []const u8) bool {
        if (self.depth >= max_region_depth) {
            self.skipped += 1;
            if (self.sink) |s| s.report(.region_overflow, what);
            return false;
        }
        self.depth += 1;
        self.stack[self.depth] = frame;
        self.count += if (frame.outer == null) 1 else 2;
        return true;
    }

    /// Closes the top region into its parent. A pop with no open region is a
    /// malformed list and does nothing.
    fn close(self: *Builder) !void {
        if (self.skipped > 0) {
            self.skipped -= 1;
            return;
        }
        if (self.depth == 0) return;
        const frame = &self.stack[self.depth];
        var node = frame.node;
        node.children = frame.children.items;
        if (frame.outer) |outer_node| {
            var outer = outer_node;
            const inner = try self.arena.alloc(Node, 1);
            inner[0] = node;
            outer.children = inner;
            node = outer;
        }
        self.depth -= 1;
        try self.top().children.append(self.arena, node);
    }

    fn rrect(self: *Builder, r: display_list.RRect) !void {
        const o = self.offset();
        var abuf: [8]u8 = undefined;
        const style = if (r.stroke_width > 0)
            try self.arena.print("position:absolute;left:{f};top:{f};width:{f};height:{f};border-radius:{f};box-sizing:border-box;border:{f} solid rgba({d},{d},{d},{s});background:transparent", .{ dom.rem(r.rect.x - o.x), dom.rem(r.rect.y - o.y), dom.rem(r.rect.width), dom.rem(r.rect.height), dom.rem(r.radius), dom.rem(r.stroke_width), dom.ch(r.color.r), dom.ch(r.color.g), dom.ch(r.color.b), dom.alpha(&abuf, r.color.a) })
        else
            try self.arena.print("position:absolute;left:{f};top:{f};width:{f};height:{f};border-radius:{f};background:rgba({d},{d},{d},{s})", .{ dom.rem(r.rect.x - o.x), dom.rem(r.rect.y - o.y), dom.rem(r.rect.width), dom.rem(r.rect.height), dom.rem(r.radius), dom.ch(r.color.r), dom.ch(r.color.g), dom.ch(r.color.b), dom.alpha(&abuf, r.color.a) });

        if (r.hover_color == null and r.active_color == null) {
            return self.add(.{ .kind = .element, .tag = "div", .style = style });
        }

        // The class name is a hash of the rule text, so the same colours give
        // the same class on every frame.
        const prop = if (r.stroke_width > 0) "border-color" else "background";
        var hover_buf: [state_decl_len]u8 = undefined;
        var active_buf: [state_decl_len]u8 = undefined;
        const hover = if (r.hover_color) |h| stateDecl(&hover_buf, prop, h) else "";
        const active = if (r.active_color) |ac| stateDecl(&active_buf, prop, ac) else "";
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(hover);
        hasher.update("|");
        hasher.update(active);
        const hash = hasher.final();
        const cls = try self.arena.print("pb-{x}", .{hash});
        std.debug.assert(cls.len <= class_len);

        const attrs = try self.arena.alloc(Attr, 1);
        attrs[0] = .{ .name = "class", .value = cls };
        try self.add(.{ .kind = .element, .tag = "div", .style = style, .attrs = attrs });

        for (self.rules.items) |rule| {
            if (rule.hash == hash) return;
        }
        // The page sets the base colour on the element, and an element style
        // wins over a rule that is not important.
        var css: std.ArrayList(u8) = .empty;
        if (hover.len > 0) try css.print(self.arena, ".{s}:hover{{{s} !important}}", .{ cls, hover });
        if (active.len > 0) try css.print(self.arena, ".{s}:active{{{s} !important}}", .{ cls, active });
        // A pointer cursor tells the visitor that the rectangle responds to a tap.
        try css.print(self.arena, ".{s}{{cursor:pointer}}", .{cls});
        try self.rules.append(self.arena, .{ .hash = hash, .css = css.items });
    }

    fn image(self: *Builder, img: display_list.ImagePrimitive) !void {
        const im: *image_mod.Image = @ptrCast(@alignCast(img.image));
        // An image with no encoded bytes has nothing an <img> can show.
        if (im.bytes.len == 0) return;
        const o = self.offset();
        const style = try self.arena.print("position:absolute;left:{f};top:{f};width:{f};height:{f}", .{ dom.rem(img.rect.x - o.x), dom.rem(img.rect.y - o.y), dom.rem(img.rect.width), dom.rem(img.rect.height) });
        const enc = std.base64.standard.Encoder;
        const prefix = try self.arena.print("data:{s};base64,", .{image_mod.Image.mime(im.format)});
        const src = try self.arena.alloc(u8, prefix.len + enc.calcSize(im.bytes.len));
        @memcpy(src[0..prefix.len], prefix);
        _ = enc.encode(src[prefix.len..], im.bytes);
        const attrs = try self.arena.alloc(Attr, 1);
        attrs[0] = .{ .name = "src", .value = src };
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(prefix);
        hasher.update(im.bytes);
        try self.add(.{ .kind = .element, .tag = "img", .style = style, .attrs = attrs, .src_hash = hasher.final() });
    }

    fn icon(self: *Builder, ic: display_list.IconPrimitive) !void {
        const o = self.offset();
        const icon_path = icon_builtin.pathFor(ic.id);

        // The viewBox is the authoring grid and width and height are the size
        // the frontend asked for, so the browser does the scaling and one
        // centreline serves every size. The stroke width stays in grid units.
        var gbuf: [svg_path.coord_len]u8 = undefined;
        const grid_s = svg_path.coord(&gbuf, icon_builtin.grid);
        const svg_attrs = try self.arena.alloc(Attr, 2);
        svg_attrs[0] = .{ .name = "viewBox", .value = try self.arena.print("0 0 {s} {s}", .{ grid_s, grid_s }) };
        // Without this the browser centres the square grid in a box that is
        // not square and the mark comes out short.
        svg_attrs[1] = .{ .name = "preserveAspectRatio", .value = "none" };
        // The size is in the style, because the width and height attributes
        // take no rem.
        const style = try self.arena.print("position:absolute;left:{f};top:{f};width:{f};height:{f}", .{ dom.rem(ic.origin.x - o.x), dom.rem(ic.origin.y - o.y), dom.rem(ic.size.width), dom.rem(ic.size.height) });

        var abuf: [8]u8 = undefined;
        var sbuf: [svg_path.coord_len]u8 = undefined;
        const path_attrs = try self.arena.alloc(Attr, 6);
        path_attrs[0] = .{ .name = "d", .value = try svg_path.data(self.arena, icon_path, icon_builtin.grid) };
        // A centreline filled rather than stroked draws as a solid blob.
        path_attrs[1] = .{ .name = "fill", .value = "none" };
        path_attrs[2] = .{ .name = "stroke", .value = try self.arena.print("rgba({d},{d},{d},{s})", .{ dom.ch(ic.color.r), dom.ch(ic.color.g), dom.ch(ic.color.b), dom.alpha(&abuf, ic.color.a) }) };
        path_attrs[3] = .{ .name = "stroke-width", .value = try self.arena.dupe(u8, svg_path.coord(&sbuf, icon_path.stroke.width)) };
        path_attrs[4] = .{ .name = "stroke-linecap", .value = svg_path.lineCap(icon_path.stroke.cap) };
        path_attrs[5] = .{ .name = "stroke-linejoin", .value = svg_path.lineJoin(icon_path.stroke.join) };

        // `<title>` is the accessible name of an inline SVG, and a screen
        // reader reads the first child, so it comes before the path. An icon
        // with no name gets no title, because an empty title announces nothing.
        const children = try self.arena.alloc(Node, if (ic.label == null) 1 else 2);
        if (ic.label) |name| {
            children[0] = .{ .kind = .element_svg, .tag = "title", .text = try self.arena.dupe(u8, name) };
        }
        children[children.len - 1] = .{ .kind = .element_svg, .tag = "path", .attrs = path_attrs };
        self.count += children.len;
        try self.add(.{ .kind = .element_svg, .tag = "svg", .style = style, .attrs = svg_attrs, .children = children });
    }

    fn textRun(self: *Builder, run: display_list.TextRun) !void {
        // A zero length run has nothing to draw. Its slice can also carry a
        // dangling pointer, which the host reads before the length.
        if (run.text.len == 0) return;
        const o = self.offset();
        const font_ptr: *text.Font = @ptrCast(@alignCast(run.font));
        var fam: [family_len]u8 = undefined;
        var tbuf: [8]u8 = undefined;
        // `white-space:pre` keeps the line breaks and spaces this framework
        // already chose. Without it the browser collapses runs of spaces and
        // can break the run again.
        const style = try self.arena.print("position:absolute;left:{f};top:{f};white-space:pre;font-family:{s};font-size:{f};color:rgba({d},{d},{d},{s}){s}{s}", .{
            dom.rem(run.origin.x - o.x),
            dom.rem(run.origin.y - o.y),
            fontFamily(&fam, font_ptr),
            dom.rem(run.size),
            dom.ch(run.color.r),
            dom.ch(run.color.g),
            dom.ch(run.color.b),
            dom.alpha(&tbuf, run.color.a),
            if (run.italic and !font_ptr.isItalic()) ";font-style:italic" else "",
            if (run.underline) ";text-decoration:underline" else "",
        });
        try self.add(.{ .kind = .element, .tag = "div", .style = style, .text = try self.arena.dupe(u8, run.text) });
        for (self.fonts.items) |seen| {
            if (seen.id == font_ptr.id) return;
        }
        try self.fonts.append(self.arena, font_ptr);
    }

    fn pushScroll(self: *Builder, sr: display_list.ScrollRegion) !void {
        const o = self.offset();
        const attrs = try self.arena.alloc(Attr, 1);
        attrs[0] = .{ .name = "data-phantom-scroll", .value = try self.arena.print("{d}", .{self.regions}) };
        // The outer div is the scrolling window. The inner div is the full
        // content area that scrolls inside it.
        const outer: Node = .{
            .kind = .element,
            .tag = "div",
            .style = try self.arena.print("position:absolute;left:{f};top:{f};width:{f};height:{f};overflow:scroll", .{ dom.rem(sr.viewport.x - o.x), dom.rem(sr.viewport.y - o.y), dom.rem(sr.viewport.width), dom.rem(sr.viewport.height) }),
            .attrs = attrs,
            .key = sr.handlers,
            .scroll = .{ .offset = sr.offset, .moved = sr.moved, .handlers = sr.handlers },
        };
        const inner: Node = .{
            .kind = .element,
            .tag = "div",
            .style = try self.arena.print("position:relative;width:{f};height:{f}", .{ dom.rem(sr.content.width), dom.rem(sr.content.height) }),
        };
        if (self.open(.{ .node = inner, .outer = outer, .origin = .{ .x = sr.viewport.x, .y = sr.viewport.y } }, "scroll region nesting exceeded max_region_depth, region skipped")) {
            self.regions += 1;
        }
    }

    fn pushClip(self: *Builder, cr: display_list.ClipRegion) !void {
        const o = self.offset();
        // A browser clips to the full rounded shape, so this backend honours
        // the radius exactly.
        const node: Node = .{
            .kind = .element,
            .tag = "div",
            .style = try self.arena.print("position:absolute;left:{f};top:{f};width:{f};height:{f};border-radius:{f};overflow:hidden", .{ dom.rem(cr.rect.x - o.x), dom.rem(cr.rect.y - o.y), dom.rem(cr.rect.width), dom.rem(cr.rect.height), dom.rem(cr.radius) }),
        };
        _ = self.open(.{ .node = node, .origin = .{ .x = cr.rect.x, .y = cr.rect.y } }, "clip region nesting exceeded max_region_depth, region skipped");
    }
};

/// Build the tree for one frame. Every string and slice in the tree is in
/// `arena`, so the tree does not borrow from `list`. `sink` gets a fault for
/// each region nested past `max_region_depth`.
pub fn build(arena: std.mem.Allocator, list: display_list.DisplayList, viewport: geometry.PhysicalSize, bg: geometry.Color, sink: ?*FaultSink) !Tree {
    var b: Builder = .{ .arena = arena, .sink = sink };
    b.stack[0] = .{ .node = .{
        .kind = .element,
        .tag = "div",
        .style = try arena.print("position:relative;width:{f};height:{f};background:rgb({d},{d},{d})", .{ dom.rem(viewport.width), dom.rem(viewport.height), dom.ch(bg.r), dom.ch(bg.g), dom.ch(bg.b) }),
    } };

    for (list.primitives.items) |p| switch (p) {
        .rrect => |r| try b.rrect(r),
        .image => |img| try b.image(img),
        .icon => |ic| try b.icon(ic),
        .text => |run| try b.textRun(run),
        .push_scroll => |sr| try b.pushScroll(sr),
        .push_clip => |cr| try b.pushClip(cr),
        .pop_scroll, .pop_clip => try b.close(),
    };
    // A region with no pop still keeps its content.
    while (b.depth > 0) try b.close();

    var root = b.stack[0].node;
    root.children = b.stack[0].children.items;
    return .{ .root = root, .rules = b.rules.items, .count = b.count, .fonts = b.fonts.items, .background = bg };
}

fn countNodes(node: Node) usize {
    var n: usize = 1;
    for (node.children) |c| n += countNodes(c);
    return n;
}

fn testBuild(arena: std.mem.Allocator, list: display_list.DisplayList) !Tree {
    return build(arena, list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null);
}

test "vdom: the root is the container sized to the viewport with the background" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const list: display_list.DisplayList = .{};
    const tree = try build(arena_state.allocator(), list, .{ .width = 300, .height = 150 }, geometry.Color.rgb(1, 0, 0), null);
    try std.testing.expectEqualStrings("div", tree.root.tag);
    try std.testing.expectEqualStrings("position:relative;width:18.75rem;height:9.375rem;background:rgb(255,0,0)", tree.root.style);
    try std.testing.expectEqual(@as(usize, 0), tree.root.children.len);
    try std.testing.expectEqual(@as(usize, 1), tree.count);
}

test "vdom: a plain rrect is one div with no class and adds no rule" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var list: display_list.DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{ .rect = .{ .x = 10, .y = 20, .width = 30, .height = 40 }, .radius = 4, .color = geometry.Color.rgb(1, 0, 0) } });
    const tree = try testBuild(arena_state.allocator(), list);
    try std.testing.expectEqual(@as(usize, 1), tree.root.children.len);
    const node = tree.root.children[0];
    try std.testing.expectEqualStrings("position:absolute;left:0.625rem;top:1.25rem;width:1.875rem;height:2.5rem;border-radius:0.25rem;background:rgba(255,0,0,1)", node.style);
    try std.testing.expectEqual(@as(usize, 0), node.attrs.len);
    try std.testing.expectEqual(@as(usize, 0), tree.rules.len);
}

test "vdom: two interactive rrects of one colour share a class and one rule" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var list: display_list.DisplayList = .{};
    defer list.deinit(gpa);
    const button: display_list.Primitive = .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 80, .height = 40 },
        .radius = 4,
        .color = geometry.Color.rgb(0, 0, 1),
        .hover_color = geometry.Color.rgb(0, 0, 0.5),
    } };
    try list.append(gpa, button);
    try list.append(gpa, button);
    const tree = try testBuild(arena_state.allocator(), list);
    const a = tree.root.children[0].attrs;
    const b = tree.root.children[1].attrs;
    try std.testing.expectEqualStrings("class", a[0].name);
    try std.testing.expect(std.mem.startsWith(u8, a[0].value, "pb-"));
    try std.testing.expectEqualStrings(a[0].value, b[0].value);
    try std.testing.expectEqual(@as(usize, 1), tree.rules.len);
    var want: [96]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, tree.rules[0].css, try std.fmt.bufPrint(&want, ".{s}:hover{{background:rgba(0,0,128,1) !important}}", .{a[0].value})) != null);
    try std.testing.expect(std.mem.indexOf(u8, tree.rules[0].css, "{cursor:pointer}") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree.rules[0].css, ":active") == null);
}

test "vdom: a scroll region is an outer node with its key and one inner node holding the content" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var target: u8 = 0;
    var handlers = pointer.PointerHandlers{ .ctx = &target };
    var list: display_list.DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = .{ .x = 10, .y = 20, .width = 100, .height = 50 },
        .offset = .{ .x = 0, .y = 7 },
        .content = .{ .width = 100, .height = 300 },
        .handlers = &handlers,
        .moved = 3,
    } });
    try list.append(gpa, .{ .rrect = .{ .rect = .{ .x = 10, .y = 120, .width = 80, .height = 20 }, .radius = 0, .color = geometry.Color.rgb(1, 0, 0) } });
    try list.append(gpa, .{ .pop_scroll = {} });
    try list.append(gpa, .{ .rrect = .{ .rect = .{ .x = 1, .y = 2, .width = 3, .height = 4 }, .radius = 0, .color = geometry.Color.rgb(1, 0, 0) } });
    const tree = try testBuild(arena_state.allocator(), list);

    try std.testing.expectEqual(@as(usize, 2), tree.root.children.len);
    const outer = tree.root.children[0];
    try std.testing.expectEqualStrings("position:absolute;left:0.625rem;top:1.25rem;width:6.25rem;height:3.125rem;overflow:scroll", outer.style);
    try std.testing.expectEqual(@as(?*const anyopaque, &handlers), outer.key);
    try std.testing.expectEqual(@as(u32, 3), outer.scroll.?.moved);
    try std.testing.expectEqual(@as(f32, 7), outer.scroll.?.offset.y);
    try std.testing.expectEqual(@as(?*pointer.PointerHandlers, &handlers), outer.scroll.?.handlers);
    try std.testing.expectEqualStrings("data-phantom-scroll", outer.attrs[0].name);
    try std.testing.expectEqualStrings("0", outer.attrs[0].value);
    try std.testing.expectEqual(@as(usize, 1), outer.children.len);
    const inner = outer.children[0];
    try std.testing.expectEqualStrings("position:relative;width:6.25rem;height:18.75rem", inner.style);
    try std.testing.expectEqual(@as(?Scroll, null), inner.scroll);
    try std.testing.expectEqual(@as(usize, 0), inner.attrs.len);
    try std.testing.expectEqualStrings("position:absolute;left:0;top:6.25rem;width:5rem;height:1.25rem;border-radius:0;background:rgba(255,0,0,1)", inner.children[0].style);
    // After the pop the next rrect is back in the container's space.
    try std.testing.expect(std.mem.startsWith(u8, tree.root.children[1].style, "position:absolute;left:0.0625rem;top:0.125rem;"));
    try std.testing.expectEqual(countNodes(tree.root), tree.count);
}

test "vdom: a clip nested in a scroll is placed in the scroll's space and holds its own content" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var list: display_list.DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = .{ .x = 10, .y = 20, .width = 100, .height = 100 },
        .offset = .{ .x = 0, .y = 0 },
        .content = .{ .width = 100, .height = 300 },
    } });
    try list.append(gpa, .{ .push_clip = .{ .rect = .{ .x = 30, .y = 50, .width = 40, .height = 40 }, .radius = 6 } });
    try list.append(gpa, .{ .rrect = .{ .rect = .{ .x = 35, .y = 55, .width = 5, .height = 5 }, .radius = 0, .color = geometry.Color.rgb(1, 0, 0) } });
    try list.append(gpa, .{ .pop_clip = {} });
    try list.append(gpa, .{ .pop_scroll = {} });
    const tree = try testBuild(arena_state.allocator(), list);

    const outer = tree.root.children[0];
    try std.testing.expectEqual(@as(?*const anyopaque, null), outer.key);
    try std.testing.expect(outer.scroll != null);
    const clip = outer.children[0].children[0];
    try std.testing.expectEqualStrings("position:absolute;left:1.25rem;top:1.875rem;width:2.5rem;height:2.5rem;border-radius:0.375rem;overflow:hidden", clip.style);
    try std.testing.expect(std.mem.startsWith(u8, clip.children[0].style, "position:absolute;left:0.3125rem;top:0.3125rem;"));
    try std.testing.expectEqual(@as(usize, 5), tree.count);
}

test "vdom: an icon is an svg holding a title and a stroked path" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var list: display_list.DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 40, .height = 32 },
        .color = geometry.Color.rgb(1, 0, 0),
        .origin = .{ .x = 6, .y = 9 },
        .label = "Gate",
    } });
    const tree = try testBuild(arena_state.allocator(), list);

    const svg = tree.root.children[0];
    try std.testing.expectEqual(Kind.element_svg, svg.kind);
    try std.testing.expectEqualStrings("svg", svg.tag);
    try std.testing.expectEqualStrings("position:absolute;left:0.375rem;top:0.5625rem;width:2.5rem;height:2rem", svg.style);
    try std.testing.expectEqualStrings("0 0 24 24", svg.attrs[0].value);
    try std.testing.expectEqualStrings("none", svg.attrs[1].value);
    try std.testing.expectEqual(@as(usize, 2), svg.attrs.len);
    try std.testing.expectEqual(@as(usize, 2), svg.children.len);
    try std.testing.expectEqualStrings("title", svg.children[0].tag);
    try std.testing.expectEqualStrings("Gate", svg.children[0].text);
    const path = svg.children[1];
    try std.testing.expectEqualStrings("path", path.tag);
    try std.testing.expectEqual(Kind.element_svg, path.kind);
    try std.testing.expect(std.mem.startsWith(u8, path.attrs[0].value, "M3.84 3.218Q12 4.887 20.16 3.218"));
    try std.testing.expectEqualStrings("none", path.attrs[1].value);
    try std.testing.expectEqualStrings("rgba(255,0,0,1)", path.attrs[2].value);
    try std.testing.expectEqualStrings("1.7", path.attrs[3].value);
    try std.testing.expectEqual(@as(usize, 4), tree.count);
}

test "vdom: a text run is a div holding its text, and an empty run makes no node" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var list: display_list.DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .text = .{ .glyphs = &.{}, .text = "", .font = &font, .size = 16, .color = geometry.Color.rgb(1, 1, 1), .origin = .{ .x = 0, .y = 0 } } });
    try list.append(gpa, .{ .text = .{ .glyphs = &.{}, .text = "  hi", .font = &font, .size = 16, .color = geometry.Color.rgb(1, 1, 1), .origin = .{ .x = 5, .y = 8 }, .underline = true } });
    const tree = try testBuild(arena_state.allocator(), list);

    try std.testing.expectEqual(@as(usize, 1), tree.root.children.len);
    const node = tree.root.children[0];
    try std.testing.expectEqualStrings("  hi", node.text);
    var fam: [family_len]u8 = undefined;
    var want: [256]u8 = undefined;
    const style = try std.fmt.bufPrint(&want, "position:absolute;left:0.3125rem;top:0.5rem;white-space:pre;font-family:{s};font-size:1rem;color:rgba(255,255,255,1);text-decoration:underline", .{fontFamily(&fam, &font)});
    try std.testing.expectEqualStrings(style, node.style);
}

test "vdom: a region nested past the limit reports a fault and its content goes to the parent" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var sink = FaultSink{};
    var list: display_list.DisplayList = .{};
    defer list.deinit(gpa);
    for (0..max_region_depth + 1) |_| {
        try list.append(gpa, .{ .push_clip = .{ .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 } } });
    }
    try list.append(gpa, .{ .rrect = .{ .rect = .{ .x = 1, .y = 1, .width = 1, .height = 1 }, .radius = 0, .color = geometry.Color.rgb(1, 0, 0) } });
    for (0..max_region_depth + 1) |_| try list.append(gpa, .{ .pop_clip = {} });
    try list.append(gpa, .{ .rrect = .{ .rect = .{ .x = 2, .y = 2, .width = 1, .height = 1 }, .radius = 0, .color = geometry.Color.rgb(1, 0, 0) } });
    const tree = try build(arena_state.allocator(), list, .{ .width = 10, .height = 10 }, geometry.Color.rgb(0, 0, 0), &sink);

    try std.testing.expectEqual(FaultSink.FaultCode.region_overflow, sink.first.?.code);
    // The first clip and the trailing rrect sit in the container.
    try std.testing.expectEqual(@as(usize, 2), tree.root.children.len);
    var node = tree.root.children[0];
    var levels: usize = 1;
    while (node.children.len > 0 and std.mem.endsWith(u8, node.children[0].style, "overflow:hidden")) : (levels += 1) {
        node = node.children[0];
    }
    try std.testing.expectEqual(@as(usize, max_region_depth), levels);
    try std.testing.expectEqual(@as(usize, 1), node.children.len);
    try std.testing.expectEqual(countNodes(tree.root), tree.count);
}

test "vdom: a region with no pop keeps its content, and a stray pop changes nothing" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var list: display_list.DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .pop_clip = {} });
    try list.append(gpa, .{ .push_clip = .{ .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 } } });
    try list.append(gpa, .{ .rrect = .{ .rect = .{ .x = 1, .y = 1, .width = 1, .height = 1 }, .radius = 0, .color = geometry.Color.rgb(1, 0, 0) } });
    const tree = try testBuild(arena_state.allocator(), list);
    try std.testing.expectEqual(@as(usize, 1), tree.root.children.len);
    try std.testing.expectEqual(@as(usize, 1), tree.root.children[0].children.len);
    try std.testing.expectEqual(@as(usize, 3), tree.count);
}

test "vdom: an image with encoded bytes is an img with a data url, and one without makes no node" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const png_bytes = &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01 };
    var img = image_mod.Image.fromBytes(png_bytes, 10, 10);
    const rgba: [16]u8 = @splat(255);
    var raw = image_mod.Image.fromRgba(&rgba, 2, 2);
    var list: display_list.DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .image = .{ .image = &raw, .rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 } } });
    try list.append(gpa, .{ .image = .{ .image = &img, .rect = .{ .x = 5, .y = 15, .width = 64, .height = 32 } } });
    const tree = try testBuild(arena_state.allocator(), list);
    try std.testing.expectEqual(@as(usize, 1), tree.root.children.len);
    const node = tree.root.children[0];
    try std.testing.expectEqualStrings("img", node.tag);
    try std.testing.expectEqualStrings("position:absolute;left:0.3125rem;top:0.9375rem;width:4rem;height:2rem", node.style);
    try std.testing.expectEqualStrings("src", node.attrs[0].name);
    try std.testing.expectEqualStrings("data:image/png;base64,iVBORw0KGgoAAQ==", node.attrs[0].value);
}

test "vdom: scroll regions are numbered in the order they open, nested ones included" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const region: display_list.Primitive = .{ .push_scroll = .{
        .viewport = .{ .x = 0, .y = 0, .width = 50, .height = 50 },
        .offset = .zero,
        .content = .{ .width = 50, .height = 200 },
    } };
    var list: display_list.DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, region);
    try list.append(gpa, region);
    try list.append(gpa, .{ .pop_scroll = {} });
    try list.append(gpa, .{ .pop_scroll = {} });
    try list.append(gpa, region);
    try list.append(gpa, .{ .pop_scroll = {} });
    const tree = try testBuild(arena_state.allocator(), list);

    const first = tree.root.children[0];
    const nested = first.children[0].children[0];
    const last = tree.root.children[1];
    try std.testing.expectEqualStrings("0", first.attrs[0].value);
    try std.testing.expectEqualStrings("1", nested.attrs[0].value);
    try std.testing.expectEqualStrings("2", last.attrs[0].value);
}

test "vdom: the image hash follows the bytes, not the buffer that holds them" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var a_bytes = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01 };
    var b_bytes = a_bytes;
    var a = image_mod.Image.fromBytes(&a_bytes, 10, 10);
    var b = image_mod.Image.fromBytes(&b_bytes, 10, 10);
    var list: display_list.DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .image = .{ .image = &a, .rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 } } });
    try list.append(gpa, .{ .image = .{ .image = &b, .rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 } } });
    const same = try testBuild(arena_state.allocator(), list);
    try std.testing.expect(same.root.children[0].src_hash != 0);
    try std.testing.expectEqual(same.root.children[0].src_hash, same.root.children[1].src_hash);

    b_bytes[9] = 0x02;
    const changed = try testBuild(arena_state.allocator(), list);
    try std.testing.expect(changed.root.children[0].src_hash != changed.root.children[1].src_hash);
}

test "vdom: a font family comes from the font bytes, so two loads of one file share it" {
    const gpa = std.testing.allocator;
    var a = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer a.deinit(gpa);
    var b = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer b.deinit(gpa);
    var fam_a: [family_len]u8 = undefined;
    var fam_b: [family_len]u8 = undefined;
    // A literal, so a change in the hash or a target that hashes differently fails here.
    try std.testing.expectEqualStrings("pf-0b107d216918b3e5", fontFamily(&fam_a, &a));
    try std.testing.expectEqualStrings(fontFamily(&fam_a, &a), fontFamily(&fam_b, &b));
}
