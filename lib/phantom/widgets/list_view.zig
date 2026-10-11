//! A scrolling list that builds only the rows near the viewport. The scrolling
//! comes from a `ScrollView`, so the wheel, the keys and a `ScrollController`
//! work on a `ListView` as they do on a `ScrollView`.
const std = @import("std");
const phantom = @import("../../phantom.zig");
const geom = phantom.geometry;
const layout = phantom.layout;
const Canvas = phantom.Canvas;
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const BuildContext = phantom.BuildContext;
const scroll_view = @import("scroll_view.zig");
const ScrollView = scroll_view.ScrollView;
const ScrollController = scroll_view.ScrollController;
const testing = @import("../testing.zig");

pub const ListView = struct {
    count: usize,
    builder: *const fn (ctx: *anyopaque, b: *BuildContext, index: usize) Widget,
    ctx: *anyopaque = undefined,
    /// Every row this tall, in logical px. Null lets rows differ.
    item_extent: ?f32 = null,
    /// The height assumed for a row not laid out yet, in logical px.
    estimated_extent: f32 = 48,
    controller: ?*ScrollController = null,
    id: ?[]const u8 = null,

    pub fn widget(self: *const ListView) Widget {
        return phantom.StatefulWidget(ListView, self);
    }

    /// Row indices, half open.
    const Range = struct { first: usize, last: usize };

    pub const State = struct {
        base: phantom.StateBase = .{},
        count: usize = 0,
        builder: *const fn (ctx: *anyopaque, b: *BuildContext, index: usize) Widget = undefined,
        ctx: *anyopaque = undefined,
        item_extent: ?f32 = null,
        estimated_extent: f32 = 48,
        controller: ?*ScrollController = null,
        /// A copy, because a rebuild from `markNeedsBuild` runs after the arena
        /// that held the config is reset.
        id: phantom.focus.OwnedId = .{},
        /// The scroll view uses this one when the caller gives none. The window
        /// reads the scroll offset through it.
        own_controller: ScrollController = .{},
        /// One logical height per row. NaN marks a row not laid out yet.
        heights: std.ArrayList(f32) = .empty,
        known_sum: f64 = 0,
        known_count: usize = 0,
        /// The built rows, half open.
        first: usize = 0,
        last: usize = 0,
        /// Physical px per logical px at the last layout.
        scale: f32 = 1,

        pub fn initState(s: *State, config: *const ListView) anyerror!void {
            try s.configure(config);
        }

        pub fn didUpdateWidget(s: *State, config: *const ListView) anyerror!void {
            try s.configure(config);
        }

        pub fn dispose(s: *State) void {
            const gpa = s.base.gpa();
            s.heights.deinit(gpa);
            s.id.deinit(gpa);
        }

        fn configure(s: *State, config: *const ListView) !void {
            s.count = config.count;
            s.builder = config.builder;
            s.ctx = config.ctx;
            // A size that is not a positive number cannot place a row, so a bad
            // fixed extent falls back to measured rows and a bad estimate to 1.
            s.item_extent = if (config.item_extent) |e| (if (usable(e)) e else null) else null;
            s.estimated_extent = if (usable(config.estimated_extent)) config.estimated_extent else 1;
            s.controller = config.controller;
            try s.id.set(s.base.gpa(), config.id);
        }

        fn usable(extent: f32) bool {
            return std.math.isFinite(extent) and extent > 0;
        }

        pub fn scrollController(s: *State) *ScrollController {
            return s.controller orelse &s.own_controller;
        }

        pub fn build(s: *State, b: *BuildContext) anyerror!Widget {
            try s.syncCount(s.base.gpa());
            var offset: f32 = 0;
            var viewport: f32 = 0;
            if (s.scrollController().view) |v| {
                offset = v.offset.y / s.scale;
                viewport = v.viewport.height / s.scale;
            }
            // Before the first layout the viewport is not known, so the size of
            // the window stands in for it.
            if (viewport <= 0) viewport = phantom.MediaQuery.of(b).size.height;
            const window = s.rangeFor(offset - viewport, offset + 2 * viewport) orelse Range{ .first = 0, .last = 0 };

            const rows = try b.arena.alloc(Widget, window.last - window.first);
            for (rows, window.first..) |*row, index| row.* = s.builder(s.ctx, b, index);
            s.first = window.first;
            s.last = window.last;

            const list_window = b.new(ListWindow{ .state = s, .first = window.first, .rows = rows });
            return b.new(ScrollView{
                .controller = s.scrollController(),
                .id = s.id.text,
                .child = list_window.widget(),
            }).widget();
        }

        /// Fit the height table to the row count. Rows past a lower count take
        /// their known heights with them.
        fn syncCount(s: *State, gpa: std.mem.Allocator) !void {
            const have = s.heights.items.len;
            if (s.count > have) {
                try s.heights.appendNTimes(gpa, std.math.nan(f32), s.count - have);
                return;
            }
            for (s.heights.items[s.count..]) |height| {
                if (std.math.isNan(height)) continue;
                s.known_sum -= height;
                s.known_count -= 1;
            }
            s.heights.shrinkRetainingCapacity(s.count);
        }

        fn record(s: *State, index: usize, height: f32) void {
            if (index >= s.heights.items.len) return;
            const old = s.heights.items[index];
            if (std.math.isNan(old)) {
                s.known_count += 1;
                s.known_sum += height;
            } else {
                s.known_sum += height - old;
            }
            s.heights.items[index] = height;
        }

        fn extentOf(s: *const State, index: usize) f32 {
            if (s.item_extent) |e| return e;
            if (index >= s.heights.items.len) return s.estimated_extent;
            const height = s.heights.items[index];
            return if (std.math.isNan(height)) s.estimated_extent else height;
        }

        fn totalExtent(s: *const State) f32 {
            const count: f64 = @floatFromInt(s.count);
            if (s.item_extent) |e| return @floatCast(count * @as(f64, e));
            const unknown: f64 = @floatFromInt(s.count -| s.known_count);
            return @floatCast(s.known_sum + unknown * s.estimated_extent);
        }

        /// The top of row `index`. With rows that differ this sums every row
        /// above, which stays cheap for lists of up to about 100k rows.
        fn startOf(s: *const State, index: usize) f32 {
            if (s.item_extent) |e| return @as(f32, @floatFromInt(index)) * e;
            var y: f32 = 0;
            for (0..@min(index, s.count)) |i| y += s.extentOf(i);
            return y;
        }

        /// The rows that cover part of `[lo, hi)`, or null when none do.
        fn rangeFor(s: *const State, lo: f32, hi: f32) ?Range {
            if (s.count == 0 or hi <= lo or hi <= 0) return null;
            var range: Range = undefined;
            if (s.item_extent) |e| {
                range = .{ .first = s.rowAt(lo / e, .floor), .last = s.rowAt(hi / e, .ceil) };
            } else {
                var y: f32 = 0;
                var i: usize = 0;
                while (i < s.count and y + s.extentOf(i) <= lo) : (i += 1) y += s.extentOf(i);
                range.first = i;
                while (i < s.count and y < hi) : (i += 1) y += s.extentOf(i);
                range.last = i;
            }
            if (range.first >= range.last) return null;
            return range;
        }

        /// A row number from a position in rows, clamped to the list before the
        /// float becomes an integer.
        fn rowAt(s: *const State, rows: f32, comptime round: enum { floor, ceil }) usize {
            const count: f32 = @floatFromInt(s.count);
            const clamped = std.math.clamp(rows, 0, count);
            const whole = switch (round) {
                .floor => @floor(clamped),
                .ceil => @ceil(clamped),
            };
            return @min(s.count, @as(usize, @intFromFloat(whole)));
        }

        /// Ask for a rebuild when the scroll offset nears the edge of the built
        /// rows. Half a viewport of margin asks for the next rows before a blank
        /// space can show.
        fn checkWindow(s: *State) void {
            const v = s.scrollController().view orelse return;
            const offset = v.offset.y / s.scale;
            const viewport = v.viewport.height / s.scale;
            const need = s.rangeFor(offset - viewport / 2, offset + viewport * 1.5) orelse return;
            if (need.first < s.first or need.last > s.last) phantom.markNeedsBuild(s);
        }
    };
};

/// The rows a `ListView` built, placed at their y inside its scroll view.
const ListWindow = struct {
    state: *ListView.State,
    first: usize,
    rows: []const Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    fn widget(self: *const ListWindow) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const ListWindow = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderListWindow);
        ro.* = .{
            .base = .{
                .layoutFn = RenderListWindow.layoutFn,
                .paintFn = RenderListWindow.paintFn,
                .destroyFn = RenderListWindow.destroyFn,
            },
            .state = self.state,
            .first = self.first,
            .element = undefined,
        };
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(ro);
            return e;
        };
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(ListWindow),
            .render_object = &ro.base,
            .depth = phantom.widget.depthOf(parent),
        };
        ro.element = el;
        errdefer el.deinit(gpa);
        try reconcile(el, ro, self.first, self.rows, bctx);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const ListWindow = @ptrCast(@alignCast(ptr));
        const ro: *RenderListWindow = @fieldParentPtr("base", el.render_object.?);
        ro.state = self.state;
        try reconcile(el, ro, self.first, self.rows, bctx);
    }

    /// Match the mounted rows to `rows`, which start at row `first`. A row that
    /// stays in the window keeps its element, so a stateful row keeps its state.
    fn reconcile(el: *Element, ro: *RenderListWindow, first: usize, rows: []const Widget, bctx: *BuildContext) !void {
        const gpa = bctx.owner.gpa;
        const kids = &el.children;
        const old_first = ro.first;
        const keep_first = @max(old_first, first);
        const keep_last = @min(old_first + kids.items.len, first + rows.len);
        ro.first = first;
        if (keep_first >= keep_last) {
            clear(kids, gpa);
        } else {
            while (old_first + kids.items.len > keep_last) kids.pop().?.deinit(gpa);
            const drop = keep_first - old_first;
            for (kids.items[0..drop]) |k| k.deinit(gpa);
            std.mem.copyForwards(*Element, kids.items, kids.items[drop..]);
            kids.shrinkRetainingCapacity(kids.items.len - drop);
        }
        // Every slot holds a live element at each step below, so a failure can
        // drop them all and leave an empty window that matches `ro.first`.
        errdefer clear(kids, gpa);

        const kept = kids.items.len;
        const head = if (kept == 0) rows.len else keep_first - first;
        for (kids.items, rows[head..][0..kept]) |*k, row| {
            if (row.canUpdate(k.*)) {
                try row.update(k.*, bctx);
            } else {
                const fresh = try row.mount(bctx, el);
                k.*.deinit(gpa);
                k.* = fresh;
            }
        }
        try kids.ensureUnusedCapacity(gpa, rows.len - kept);
        for (rows[0..head], 0..) |row, j| kids.insertAssumeCapacity(j, try row.mount(bctx, el));
        for (rows[head + kept ..]) |row| kids.appendAssumeCapacity(try row.mount(bctx, el));
    }

    fn clear(kids: *std.ArrayList(*Element), gpa: std.mem.Allocator) void {
        while (kids.pop()) |k| k.deinit(gpa);
    }
};

const RenderListWindow = struct {
    base: RenderObject,
    state: *ListView.State,
    /// The row the first child element holds.
    first: usize,
    /// The element that owns this object. Rows are read from its children, so
    /// a row that rebuilt into a new render object is never missed.
    element: *Element,
    /// The top of the first row in the content, in physical px.
    top: f32 = 0,

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderListWindow = @fieldParentPtr("base", base);
        const s = self.state;
        if (c.scale > 0) s.scale = c.scale;
        const width_known = std.math.isFinite(c.max_width);
        var row_c = layout.BoxConstraints{
            .min_width = if (width_known) c.max_width else 0,
            .max_width = c.max_width,
            .min_height = 0,
            .max_height = std.math.inf(f32),
            .scale = c.scale,
        };
        if (s.item_extent) |e| {
            row_c.min_height = e * s.scale;
            row_c.max_height = e * s.scale;
        }
        self.top = s.startOf(self.first) * s.scale;
        var widest: f32 = 0;
        for (self.element.children.items, self.first..) |row, index| {
            const ro = row.renderObject() orelse continue;
            const size = ro.layout(row_c);
            widest = @max(widest, size.width);
            if (s.item_extent == null) s.record(index, size.height / s.scale);
        }
        return c.constrain(.{
            .width = if (width_known) c.max_width else widest,
            .height = s.totalExtent() * s.scale,
        });
    }

    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderListWindow = @fieldParentPtr("base", base);
        var y = self.top;
        for (self.element.children.items) |row| {
            const ro = row.renderObject() orelse continue;
            try ro.paint(cv, offset.add(.{ .x = 0, .y = y }));
            y += ro.size.height;
        }
        // The parent scroll view has its final offset and viewport by now.
        self.state.checkWindow();
    }

    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderListWindow = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Counts the builder calls and makes rows that alternate between two heights.
const Rows = struct {
    calls: usize = 0,
    lowest: usize = std.math.maxInt(usize),
    highest: usize = 0,
    even: f32 = 20,
    odd: f32 = 20,

    fn reset(self: *Rows) void {
        self.calls = 0;
        self.lowest = std.math.maxInt(usize);
        self.highest = 0;
    }

    fn heightOf(self: *const Rows, index: usize) f32 {
        return if (index % 2 == 0) self.even else self.odd;
    }

    fn build(ctx: *anyopaque, b: *BuildContext, index: usize) Widget {
        const self: *Rows = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.lowest = @min(self.lowest, index);
        self.highest = @max(self.highest, index);
        const box = b.new(phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) });
        return b.new(phantom.SizedBox{ .height = self.heightOf(index), .child = box.widget() }).widget();
    }
};

fn pushScrollOf(prims: []const phantom.Primitive) ?phantom.display_list.ScrollRegion {
    for (prims) |p| {
        switch (p) {
            .push_scroll => |sr| return sr,
            else => {},
        }
    }
    return null;
}

fn contentHeight(h: *testing.Harness) !f32 {
    const sr = pushScrollOf(h.canvas.list.primitives.items) orelse return error.NoPushScroll;
    return sr.content.height;
}

test "a ListView builds only the rows near the viewport" {
    const gpa = std.testing.allocator;
    var rows = Rows{};
    const list = ListView{ .count = 10_000, .builder = Rows.build, .ctx = &rows, .item_extent = 20 };
    var h = try testing.mount(gpa, list.widget());
    defer h.deinit();
    h.viewport = .{ .width = 200, .height = 200 };
    try h.pump();
    try h.pump();

    // Ten rows show. One viewport of overscan on each side adds ten more each way.
    try std.testing.expect(rows.calls > 0);
    try std.testing.expect(rows.calls <= 40);
    try std.testing.expect(rows.highest < 40);
    try std.testing.expectEqual(@as(f32, 200_000), try contentHeight(&h));
    try h.expectNoFaults();
}

test "a jump far down builds the rows at the new offset and not the old ones" {
    const gpa = std.testing.allocator;
    var rows = Rows{};
    var ctl = ScrollController{};
    const list = ListView{ .count = 10_000, .builder = Rows.build, .ctx = &rows, .item_extent = 20, .controller = &ctl };
    var h = try testing.mount(gpa, list.widget());
    defer h.deinit();
    h.viewport = .{ .width = 200, .height = 200 };
    try h.pump();
    try h.pump();

    rows.reset();
    try std.testing.expect(ctl.jumpTo(.{ .x = 0, .y = 50_000 }));
    // The first frame finds the window behind the offset, the second builds it.
    try h.pump();
    try h.pump();

    try std.testing.expect(rows.calls > 0);
    try std.testing.expect(rows.lowest <= 2500);
    try std.testing.expect(rows.highest >= 2510);
    // Row 0 is far above the overscan, so it was not built again.
    try std.testing.expect(rows.lowest >= 2480);
    try std.testing.expectEqual(@as(f32, 50_000), ctl.offset().?.y);
}

test "rows of different heights are recorded and the rest are estimated" {
    const gpa = std.testing.allocator;
    var rows = Rows{ .even = 20, .odd = 60 };
    const list = ListView{ .count = 1000, .builder = Rows.build, .ctx = &rows };
    var h = try testing.mount(gpa, list.widget());
    defer h.deinit();
    h.viewport = .{ .width = 200, .height = 200 };
    try h.pump();
    try h.pump();
    try h.pump();

    const s = try h.stateOf(testing.find.byType(ListView), ListView.State);
    try std.testing.expect(s.last > s.first);
    try std.testing.expectEqual(@as(usize, 1000), s.heights.items.len);
    var known: f32 = 0;
    for (s.heights.items, 0..) |height, i| {
        if (i >= s.first and i < s.last) {
            try std.testing.expectEqual(rows.heightOf(i), height);
            known += height;
        } else {
            try std.testing.expect(std.math.isNan(height));
        }
    }
    const unknown: f32 = @floatFromInt(1000 - (s.last - s.first));
    try std.testing.expectEqual(known + unknown * 48, try contentHeight(&h));
}

test "the wheel and the End key scroll a ListView like a ScrollView" {
    const gpa = std.testing.allocator;
    var rows = Rows{};
    var ctl = ScrollController{};
    const list = ListView{ .count = 100, .builder = Rows.build, .ctx = &rows, .item_extent = 20, .controller = &ctl };
    var h = try testing.mount(gpa, list.widget());
    defer h.deinit();
    h.viewport = .{ .width = 200, .height = 200 };
    try h.pump();
    try h.pump();

    try h.scrollAt(.{ .x = 10, .y = 10 }, 0, 30);
    try std.testing.expectEqual(@as(f32, 30), ctl.offset().?.y);

    const handlers = h.root.renderObject().?.focus orelse return error.NoFocusHandlers;
    try std.testing.expect(handlers.on_key.?(handlers.ctx, .{ .keysym = .end }));
    try h.pump();
    try h.pump();
    try std.testing.expectEqual(@as(f32, 1800), ctl.offset().?.y);
    try std.testing.expectEqual(@as(usize, 99), rows.highest);
}

test "an empty ListView builds nothing and has no content" {
    const gpa = std.testing.allocator;
    var rows = Rows{};
    const list = ListView{ .count = 0, .builder = Rows.build, .ctx = &rows };
    var h = try testing.mount(gpa, list.widget());
    defer h.deinit();
    h.viewport = .{ .width = 200, .height = 200 };
    try h.pump();
    try h.pump();

    try std.testing.expectEqual(@as(usize, 0), rows.calls);
    try std.testing.expectEqual(@as(f32, 0), try contentHeight(&h));
    try h.expectNoFaults();
}

test "a row keeps its element when the window moves past it" {
    const gpa = std.testing.allocator;
    var rows = Rows{};
    var ctl = ScrollController{};
    const list = ListView{ .count = 100, .builder = Rows.build, .ctx = &rows, .item_extent = 20, .controller = &ctl };
    var h = try testing.mount(gpa, list.widget());
    defer h.deinit();
    h.viewport = .{ .width = 200, .height = 200 };
    try h.pump();
    try h.pump();

    const s = try h.stateOf(testing.find.byType(ListView), ListView.State);
    const window = h.root.child.?.child orelse return error.NoWindow;
    const before_first = s.first;
    if (window.children.items.len <= 10) return error.WindowTooSmall;
    const row10 = window.children.items[10 - before_first];

    try std.testing.expect(ctl.jumpTo(.{ .x = 0, .y = 300 }));
    try h.pump();
    try h.pump();
    // The window now starts below row 0, so row 10 sits in an earlier slot.
    try std.testing.expect(s.first > before_first);
    try std.testing.expect(s.first <= 10);
    try std.testing.expectEqual(row10, window.children.items[10 - s.first]);
}

test "mounting, scrolling and unmounting a ListView frees everything" {
    const gpa = std.testing.allocator;
    var rows = Rows{ .even = 30, .odd = 70 };
    var ctl = ScrollController{};
    const list = ListView{ .count = 500, .builder = Rows.build, .ctx = &rows, .controller = &ctl, .id = "log" };
    var h = try testing.mount(gpa, list.widget());
    h.viewport = .{ .width = 200, .height = 200 };
    try h.pump();
    try h.pump();
    var step: usize = 0;
    while (step < 20) : (step += 1) {
        try h.scrollAt(.{ .x = 10, .y = 10 }, 0, 400);
        try h.pump();
    }
    try std.testing.expect(ctl.offset().?.y > 0);
    try std.testing.expect(rows.highest > 100);

    h.deinit();
    try std.testing.expect(!ctl.attached());
}
