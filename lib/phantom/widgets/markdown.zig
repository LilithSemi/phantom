//! Draws Markdown text as a column of blocks. Each block is a `RichText`.
//! Paragraph lines join until a blank line or another block starts.
const std = @import("std");
const phantom = @import("../../phantom.zig");
const Widget = phantom.Widget;
const RichText = phantom.RichText;
const parse = phantom.text.markdown;
const Font = @import("../text/Font.zig");
const theme_mod = @import("../theme.zig");
const dl = phantom.display_list;
const testing = phantom.testing;

pub const Markdown = struct {
    text: []const u8,
    /// Called when a link is tapped. Null opens the url through the platform
    /// in a new tab.
    on_link: ?*const fn (ctx: *anyopaque, url: []const u8) void = null,
    ctx: *anyopaque = undefined,

    pub fn widget(self: *const Markdown) Widget {
        return phantom.StatefulWidget(Markdown, self);
    }

    pub const State = struct {
        base: phantom.StateBase = .{},
        source: std.ArrayList(u8) = .empty,
        on_link: ?*const fn (ctx: *anyopaque, url: []const u8) void = null,
        user_ctx: *anyopaque = undefined,

        pub fn initState(s: *State, config: *const Markdown) !void {
            try s.take(config);
        }

        pub fn didUpdateWidget(s: *State, config: *const Markdown) !void {
            try s.take(config);
        }

        pub fn dispose(s: *State) void {
            s.source.deinit(s.base.gpa());
        }

        fn take(s: *State, config: *const Markdown) !void {
            s.source.clearRetainingCapacity();
            try s.source.appendSlice(s.base.gpa(), config.text);
            s.on_link = config.on_link;
            s.user_ctx = config.ctx;
        }

        fn openLink(ctx: *anyopaque, url: []const u8) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            if (!s.base.element.owner.platform.openUrl(url, .new_tab)) {
                s.base.sink().report(.link_unsupported, url);
            }
        }

        pub fn build(s: *State, b: *phantom.BuildContext) anyerror!Widget {
            const ctx: *anyopaque = if (s.on_link != null) s.user_ctx else s;
            var builder = Builder{
                .b = b,
                .td = phantom.Theme.of(b),
                .on_link = s.on_link orelse openLink,
                .ctx = ctx,
            };
            var parser: parse.Parser = .{};
            var lines = std.mem.splitScalar(u8, s.source.items, '\n');
            while (lines.next()) |raw| try builder.line(try parser.line(b.arena, raw));
            try builder.finish();
            return b.new(phantom.Column(.{ .children = try builder.blocks.toOwnedSlice(b.arena) })).widget();
        }
    };
};

/// Turns parsed lines into block widgets. Everything lives in the build arena.
const Builder = struct {
    b: *phantom.BuildContext,
    td: *const theme_mod.ThemeData,
    on_link: *const fn (ctx: *anyopaque, url: []const u8) void,
    ctx: *anyopaque,
    blocks: std.ArrayList(Widget) = .empty,
    para: std.ArrayList(RichText.Span) = .empty,
    code: std.ArrayList(Widget) = .empty,
    in_code: bool = false,

    const RichOptions = struct { size: ?f32 = null, font: ?*Font = null };

    fn line(self: *Builder, l: parse.Line) !void {
        switch (l.block) {
            .paragraph => {
                if (self.para.items.len > 0) try self.para.append(self.b.arena, .{ .text = " " });
                try self.appendSpans(&self.para, l.spans);
            },
            .blank => try self.flush(),
            .heading => {
                try self.flush();
                const scale: f32 = switch (l.level) {
                    1 => 1.6,
                    2 => 1.35,
                    3 => 1.15,
                    else => 1,
                };
                var spans: std.ArrayList(RichText.Span) = .empty;
                try self.appendSpans(&spans, l.spans);
                if (l.level >= 4) for (spans.items) |*sp| {
                    sp.style.strong = true;
                };
                try self.push(self.rich(spans.items, .{
                    .size = self.td.text_size * scale,
                    .font = if (l.level <= 3) self.td.heading_font else null,
                }));
            },
            .bullet, .numbered => {
                try self.flush();
                const marker = if (l.block == .bullet) "\u{2022}" else try std.fmt.allocPrint(self.b.arena, "{d}.", .{l.number});
                var spans: std.ArrayList(RichText.Span) = .empty;
                try self.appendSpans(&spans, l.spans);
                const gutter = self.td.text_size * 1.5;
                const indent = gutter * @as(f32, @floatFromInt(l.level));
                const mark_spans = try self.b.arena.alloc(RichText.Span, 1);
                mark_spans[0] = .{ .text = marker };
                const mark = self.b.new(phantom.SizedBox{ .width = gutter, .child = self.rich(mark_spans, .{}) });
                const body = self.b.new(phantom.Expanded(.{ .child = self.rich(spans.items, .{}) }));
                const row = self.b.new(phantom.Row(.{
                    .main_size = .max,
                    .children = self.b.newSlice(Widget, &.{ mark.widget(), body.widget() }),
                }));
                try self.push(self.b.new(phantom.Padding{ .insets = .{ .left = indent }, .child = row.widget() }).widget());
            },
            .rule => {
                try self.flush();
                const bar = self.b.new(phantom.ColoredBox{ .color = self.td.colors.fg_muted });
                try self.push(self.b.new(phantom.SizedBox{ .height = 1, .child = bar.widget() }).widget());
            },
            .fence => {
                if (self.in_code) {
                    try self.closeCode();
                } else {
                    try self.flush();
                    self.in_code = true;
                }
            },
            .code => {
                const spans = try self.b.arena.alloc(RichText.Span, 1);
                spans[0] = .{ .text = l.spans[0].text, .style = .{ .code = true } };
                try self.code.append(self.b.arena, self.b.new(RichText{
                    .spans = spans,
                    .wrap = false,
                    .code_background = false,
                    .on_link = self.on_link,
                    .ctx = self.ctx,
                }).widget());
            },
        }
    }

    fn appendSpans(self: *Builder, out: *std.ArrayList(RichText.Span), spans: []const parse.Span) !void {
        try out.ensureUnusedCapacity(self.b.arena, spans.len);
        for (spans) |sp| out.appendAssumeCapacity(.{
            .text = sp.text,
            .style = .{ .strong = sp.style.strong, .em = sp.style.em, .code = sp.style.code },
            .url = sp.url,
        });
    }

    fn rich(self: *Builder, spans: []const RichText.Span, opts: RichOptions) Widget {
        return self.b.new(RichText{
            .spans = spans,
            .size = opts.size,
            .font = opts.font,
            .on_link = self.on_link,
            .ctx = self.ctx,
        }).widget();
    }

    /// Adds a block, with a half line of space above every block but the first.
    fn push(self: *Builder, block: Widget) !void {
        if (self.blocks.items.len == 0) return self.blocks.append(self.b.arena, block);
        const gap = self.td.text_size * 0.5;
        try self.blocks.append(self.b.arena, self.b.new(phantom.Padding{ .insets = .{ .top = gap }, .child = block }).widget());
    }

    fn flush(self: *Builder) !void {
        if (self.para.items.len == 0) return;
        const spans = try self.para.toOwnedSlice(self.b.arena);
        try self.push(self.rich(spans, .{}));
    }

    fn closeCode(self: *Builder) !void {
        self.in_code = false;
        const col = self.b.new(phantom.Column(.{ .main_size = .min, .children = try self.code.toOwnedSlice(self.b.arena) }));
        const scroll = self.b.new(phantom.ScrollView{ .axis = .horizontal, .child = col.widget() });
        const pad = self.b.new(phantom.Padding{ .insets = phantom.geometry.LogicalEdgeInsets.all(8), .child = scroll.widget() });
        try self.push(self.b.new(phantom.DecoratedBox{ .color = self.td.code_background, .radius = 4, .child = pad.widget() }).widget());
    }

    /// Ends the text. A fence with no closing line closes here.
    fn finish(self: *Builder) !void {
        try self.flush();
        if (self.in_code) try self.closeCode();
    }
};

fn runs(h: *testing.Harness, out: *std.ArrayList(dl.TextRun)) !void {
    try h.pump();
    for (h.canvas.list.primitives.items) |p| if (p == .text) try out.append(h.gpa, p.text);
}

test "every block kind builds, and a fence keeps its lines raw" {
    const gpa = std.testing.allocator;
    const src =
        \\# Title
        \\
        \\Some **bold** text
        \\that joins.
        \\
        \\- one
        \\  - nested
        \\1. first
        \\
        \\---
        \\```zig
        \\const a = **b**;
        \\```
    ;
    const md = Markdown{ .text = src };
    var h = try testing.mount(gpa, md.widget());
    defer h.deinit();
    var got: std.ArrayList(dl.TextRun) = .empty;
    defer got.deinit(gpa);
    try runs(&h, &got);
    var raw_code = false;
    var title = false;
    for (got.items) |run| {
        if (std.mem.eql(u8, run.text, "const a = **b**;")) raw_code = true;
        if (std.mem.eql(u8, run.text, "Title")) title = true;
    }
    try std.testing.expect(raw_code);
    try std.testing.expect(title);
    try std.testing.expect(got.items.len >= 8);
    try h.expectNoFaults();
}

test "two source lines of one paragraph join on one row" {
    const gpa = std.testing.allocator;
    const md = Markdown{ .text = "first\nsecond" };
    var h = try testing.mount(gpa, md.widget());
    defer h.deinit();
    var got: std.ArrayList(dl.TextRun) = .empty;
    defer got.deinit(gpa);
    try runs(&h, &got);
    try std.testing.expect(got.items.len >= 2);
    try std.testing.expectEqual(got.items[0].origin.y, got.items[got.items.len - 1].origin.y);
}

test "a link with no on_link opens through the platform in a new tab" {
    const gpa = std.testing.allocator;
    const Spy = struct {
        var seen: ?phantom.OpenMode = null;
        fn open(_: *anyopaque, _: []const u8, mode: phantom.OpenMode) bool {
            seen = mode;
            return true;
        }
    };
    var dummy: u8 = 0;
    const md = Markdown{ .text = "[docs](https://x.dev)" };
    var h = try testing.mountWithPlatform(gpa, md.widget(), .{ .ctx = &dummy, .open_url = Spy.open });
    defer h.deinit();
    try h.pump();
    var at: ?phantom.PhysicalOffset = null;
    for (h.canvas.list.primitives.items) |p| if (p == .text and std.mem.eql(u8, p.text.text, "docs")) {
        at = .{ .x = p.text.origin.x + 2, .y = p.text.origin.y + 2 };
    };
    h.tapAt(at.?);
    try std.testing.expectEqual(phantom.OpenMode.new_tab, Spy.seen.?);
}

fn codeBoxHeight(h: *testing.Harness) !f32 {
    try h.pump();
    const bg = phantom.theme.defaultTheme(h.owner).code_background;
    for (h.canvas.list.primitives.items) |p| if (p == .rrect and std.meta.eql(p.rrect.color, bg)) return p.rrect.rect.height;
    return error.NoCodeBlock;
}

test "a code block is as tall as its lines, in a bounded and an unbounded column" {
    const gpa = std.testing.allocator;
    const md = Markdown{ .text = "```\na\nb\n```" };
    var h = try testing.mount(gpa, md.widget());
    defer h.deinit();
    const bounded = try codeBoxHeight(&h);
    try std.testing.expect(bounded > 0 and bounded < 200);

    const sv = phantom.ScrollView{ .child = md.widget() };
    var h2 = try testing.mount(gpa, sv.widget());
    defer h2.deinit();
    try std.testing.expectEqual(bounded, try codeBoxHeight(&h2));
}

test "a link calls on_link with its url when one is given" {
    const gpa = std.testing.allocator;
    const Spy = struct {
        url: [32]u8 = undefined,
        len: usize = 0,
        fn onLink(ctx: *anyopaque, url: []const u8) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(s.url[0..url.len], url);
            s.len = url.len;
        }
    };
    var spy = Spy{};
    const md = Markdown{ .text = "- see [docs](https://x.dev)", .on_link = Spy.onLink, .ctx = &spy };
    var h = try testing.mount(gpa, md.widget());
    defer h.deinit();
    try h.pump();
    var at: ?phantom.PhysicalOffset = null;
    for (h.canvas.list.primitives.items) |p| if (p == .text and std.mem.eql(u8, p.text.text, "docs")) {
        at = .{ .x = p.text.origin.x + 2, .y = p.text.origin.y + 2 };
    };
    h.tapAt(at.?);
    try std.testing.expectEqualStrings("https://x.dev", spy.url[0..spy.len]);
    try h.expectNoFaults();
}
