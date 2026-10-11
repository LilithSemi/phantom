const std = @import("std");
const dl = @import("../display_list.zig");
const geom = @import("../geometry.zig");
const text = @import("../text.zig");
const image_mod = @import("../image/Image.zig");
const vdom = @import("vdom.zig");

/// The CSS px in one rem when the user keeps the browser's default font size.
pub const px_per_rem = 16;

/// A length in phantom px, printed in rem with `{f}`. Zoom and the user's font
/// size then scale the whole page.
pub const Rem = struct {
    px: f32,

    /// Four decimals. One unit is 1/625 px, so whole px print exactly and
    /// other values round to the nearest unit. The same value always prints
    /// the same text.
    pub fn format(self: Rem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // A layout never gets near this size. The clamp keeps the cast below
        // in range when a value is not finite.
        const max_px = 1.0e9;
        const px: f64 = if (std.math.isNan(self.px)) 0 else std.math.clamp(self.px, -max_px, max_px);
        const units: i64 = @intFromFloat(@round(px * (10000.0 / px_per_rem)));
        if (units == 0) return w.writeByte('0');
        if (units < 0) try w.writeByte('-');
        const abs = @abs(units);
        try w.print("{d}", .{abs / 10000});
        const frac = abs % 10000;
        if (frac != 0) {
            var buf: [4]u8 = undefined;
            const digits = std.fmt.bufPrint(&buf, "{d:0>4}", .{frac}) catch unreachable;
            try w.print(".{s}", .{std.mem.trimEnd(u8, digits, "0")});
        }
        try w.writeAll("rem");
    }
};

pub fn rem(px: f32) Rem {
    return .{ .px = px };
}

pub fn ch(v: f32) u8 {
    const scaled = std.math.clamp(v, 0.0, 1.0) * 255.0;
    return @intFromFloat(@round(scaled));
}

/// Format a 0..1 alpha channel for CSS rgba(). Opaque prints "1" (keeps the common
/// case byte-stable), transparent prints "0", otherwise 2-decimal with trailing
/// zeros trimmed (0.3 rather than 0.30000001192092896 that a raw float print gives).
/// Writes into `buf` (>= 5 bytes) and returns the slice.
pub fn alpha(buf: []u8, v: f32) []const u8 {
    const hundredths: u32 = @intFromFloat(@round(std.math.clamp(v, 0.0, 1.0) * 100.0));
    if (hundredths >= 100) return "1";
    if (hundredths == 0) return "0";
    if (hundredths % 10 == 0) return std.fmt.bufPrint(buf, "0.{d}", .{hundredths / 10}) catch "0";
    return std.fmt.bufPrint(buf, "0.{d:0>2}", .{hundredths}) catch "0";
}

/// Collect distinct font pointers from the display list and return a slice of
/// them in insertion order. Caller owns the returned slice (gpa.free).
pub fn collectFonts(gpa: std.mem.Allocator, list: dl.DisplayList) ![]const *text.Font {
    var ptrs: std.ArrayList(*text.Font) = .empty;
    errdefer ptrs.deinit(gpa);
    for (list.primitives.items) |p| {
        switch (p) {
            .text => |run| {
                const font_ptr: *text.Font = @ptrCast(@alignCast(run.font));
                var found = false;
                for (ptrs.items) |existing| {
                    if (existing == font_ptr) {
                        found = true;
                        break;
                    }
                }
                if (!found) try ptrs.append(gpa, font_ptr);
            },
            else => {},
        }
    }
    return ptrs.toOwnedSlice(gpa);
}

/// Write `s` into buf with &, <, > and " escaped, so it is safe as text and as
/// a quoted attribute value.
fn appendEscaped(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    for (s) |byte| {
        switch (byte) {
            '&' => try buf.appendSlice(gpa, "&amp;"),
            '<' => try buf.appendSlice(gpa, "&lt;"),
            '>' => try buf.appendSlice(gpa, "&gt;"),
            '"' => try buf.appendSlice(gpa, "&quot;"),
            else => try buf.append(gpa, byte),
        }
    }
}

/// A page that a server can send under `style-src 'self'` and
/// `font-src 'self'`.
pub const Page = struct {
    /// The container element and its subtree. Each element has a class and
    /// no inline style.
    html: []u8,
    /// The stylesheet the page links: the page background, one `@font-face`
    /// for each font, one rule for each element with a style, and the hover
    /// rules.
    css: []u8,
    /// The fonts with no `text.Font.url`. The stylesheet gets each one from
    /// its `path`, so the server must serve the bytes there.
    fonts: []FontFile,

    pub fn deinit(self: *Page, gpa: std.mem.Allocator) void {
        for (self.fonts) |file| gpa.free(file.path);
        gpa.free(self.fonts);
        gpa.free(self.css);
        gpa.free(self.html);
        self.* = undefined;
    }
};

pub const FontFile = struct {
    /// Relative to the page base. See `fontFilePath`.
    path: []u8,
    /// Borrowed from the font.
    bytes: []const u8,
};

/// Where a page puts the fonts that have no url.
pub const font_dir = "fonts/";

/// The buffer `fontFilePath` needs.
pub const font_path_len = font_dir.len + vdom.family_len + ".otf".len;

/// The path, relative to the page base, where a page serves a font that has
/// no `text.Font.url`. The name is the font family, so it follows the font
/// bytes.
///
/// Only a first frame writes these files. A prerender writes the fonts of
/// its pages, and `ssr.Server` serves a font only after a render used it. A
/// font that the app uses first in a later frame can get 404 at this path.
pub fn fontFilePath(buf: *[font_path_len]u8, font_ptr: *const text.Font) []const u8 {
    var fam: [vdom.family_len]u8 = undefined;
    const family = vdom.fontFamily(&fam, font_ptr);
    return std.fmt.bufPrint(buf, font_dir ++ "{s}.otf", .{family}) catch unreachable;
}

/// True when `base` is a usable page base: it starts and ends with '/', and
/// carries none of `"`, `<`, `>`, `\` or a control character. A server
/// prints `base` straight into an HTML attribute (see
/// `ssr.Document.writeHtml`) and into a CSS `url("...")` (see `fontSrc`), so
/// any of those would let it break out of the attribute or the CSS string.
pub fn validBase(base: []const u8) bool {
    if (base.len == 0 or base[0] != '/' or base[base.len - 1] != '/') return false;
    for (base) |c| {
        if (c == '"' or c == '<' or c == '>' or c == '\\' or c < 0x20) return false;
    }
    return true;
}

/// The url a page fetches a font from, printed with `{f}`. A relative
/// `text.Font.url`, or the file of a font with no url, goes under `base`. The
/// linked stylesheet and the `FontFace` calls then fetch the same file on
/// every route.
pub const FontUrl = struct {
    base: []const u8,
    font: *const text.Font,

    pub fn format(self: FontUrl, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.font.url) |url| {
            if (!isRelative(url)) return w.writeAll(url);
            return w.print("{s}{s}", .{ self.base, url });
        }
        var buf: [font_path_len]u8 = undefined;
        try w.print("{s}{s}", .{ self.base, fontFilePath(&buf, self.font) });
    }
};

pub fn fontUrl(base: []const u8, font_ptr: *const text.Font) FontUrl {
    std.debug.assert(validBase(base));
    return .{ .base = base, .font = font_ptr };
}

/// False for a url with a scheme and for one that starts with '/'.
fn isRelative(url: []const u8) bool {
    if (url.len > 0 and url[0] == '/') return false;
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return true;
    const end = std.mem.indexOfAny(u8, url, "/?#") orelse return false;
    return end < colon;
}

const PageWriter = struct {
    gpa: std.mem.Allocator,
    html: std.ArrayList(u8) = .empty,
    css: std.ArrayList(u8) = .empty,
    /// The class number of the next element. Numbers go in tree order.
    next: usize = 0,

    /// Print `node` and its subtree. Recursion is bounded by
    /// `vdom.max_tree_depth`.
    fn node(self: *PageWriter, n: vdom.Node, depth: usize) !void {
        std.debug.assert(depth < vdom.max_tree_depth);
        const gpa = self.gpa;
        const id = self.next;
        self.next += 1;

        try self.html.print(gpa, "<{s} class=\"p{d}", .{ n.tag, id });
        for (n.attrs) |attr| {
            if (!std.mem.eql(u8, attr.name, "class")) continue;
            try self.html.append(gpa, ' ');
            try appendEscaped(&self.html, gpa, attr.value);
        }
        try self.html.append(gpa, '"');
        for (n.attrs) |attr| {
            if (std.mem.eql(u8, attr.name, "class")) continue;
            try self.html.print(gpa, " {s}=\"", .{attr.name});
            try appendEscaped(&self.html, gpa, attr.value);
            try self.html.append(gpa, '"');
        }
        if (n.style.len > 0) try self.css.print(gpa, ".p{d}{{{s}}}", .{ id, n.style });

        if (std.mem.eql(u8, n.tag, "img")) return self.html.append(gpa, '>');
        if (n.kind == .element_svg and n.children.len == 0 and n.text.len == 0) {
            return self.html.appendSlice(gpa, "/>");
        }
        try self.html.append(gpa, '>');
        try appendEscaped(&self.html, gpa, n.text);
        for (n.children) |child| try self.node(child, depth + 1);
        try self.html.print(gpa, "</{s}>", .{n.tag});
    }
};

/// Print `tree` as a page. The same tree gives the same bytes on every target.
/// `Page.fonts` borrows from the fonts in the tree. Font urls go under `base`,
/// the path the site is served at. See `FontUrl`.
pub fn renderPage(gpa: std.mem.Allocator, tree: vdom.Tree, base: []const u8) !Page {
    var w: PageWriter = .{ .gpa = gpa };
    defer w.html.deinit(gpa);
    defer w.css.deinit(gpa);
    var fonts: std.ArrayList(FontFile) = .empty;
    defer {
        for (fonts.items) |file| gpa.free(file.path);
        fonts.deinit(gpa);
    }

    // The background fills the window to its edges.
    const bg = tree.background;
    try w.css.print(gpa, "html,body{{margin:0;background:rgb({d},{d},{d})}}", .{ ch(bg.r), ch(bg.g), ch(bg.b) });
    for (tree.fonts) |font_ptr| {
        var fam: [vdom.family_len]u8 = undefined;
        const family = vdom.fontFamily(&fam, font_ptr);
        if (font_ptr.url == null) {
            var buf: [font_path_len]u8 = undefined;
            try fonts.ensureUnusedCapacity(gpa, 1);
            const path = try gpa.dupe(u8, fontFilePath(&buf, font_ptr));
            fonts.appendAssumeCapacity(.{ .path = path, .bytes = font_ptr.bytes });
        }
        try w.css.print(gpa, "@font-face{{font-family:{s};src:url(\"{f}\") format(\"opentype\")}}", .{ family, fontUrl(base, font_ptr) });
    }
    try w.node(tree.root, 0);
    for (tree.rules) |rule| try w.css.appendSlice(gpa, rule.css);

    const html = try w.html.toOwnedSlice(gpa);
    errdefer gpa.free(html);
    const css = try w.css.toOwnedSlice(gpa);
    errdefer gpa.free(css);
    return .{ .html = html, .css = css, .fonts = try fonts.toOwnedSlice(gpa) };
}

/// The stylesheet and then the markup of the page for `list`, as one string
/// for a test to search.
fn testPage(gpa: std.mem.Allocator, list: dl.DisplayList, viewport: geom.PhysicalSize) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const tree = try vdom.build(arena_state.allocator(), list, viewport, geom.Color.rgb(0, 0, 0), null);
    var page = try renderPage(gpa, tree, "/");
    defer page.deinit(gpa);
    return std.mem.concat(gpa, u8, &.{ page.css, page.html });
}

test "renderPage emits an @font-face and a positioned text div" {
    const gpa = std.testing.allocator;
    var font = try @import("../text.zig").Font.load(gpa, @import("../text.zig").builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    const glyphs = [_]dl.PositionedGlyph{.{ .cp = 'H', .x = 0, .y = 0 }};
    try list.append(gpa, .{ .text = .{ .glyphs = &glyphs, .text = "Hello", .font = &font, .size = 24, .color = geom.Color.rgb(1, 1, 1), .origin = geom.PhysicalOffset{ .x = 12, .y = 34 } } });
    const html = try testPage(gpa, list, geom.PhysicalSize{ .width = 200, .height = 100 });
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "@font-face") != null);
    var fam: [vdom.family_len]u8 = undefined;
    var want: [vdom.family_len + 32]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, html, try std.fmt.bufPrint(&want, "@font-face{{font-family:{s};", .{vdom.fontFamily(&fam, &font)})) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, try std.fmt.bufPrint(&want, ";font-family:{s};", .{vdom.fontFamily(&fam, &font)})) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data:") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, ">Hello<") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "left:0.75rem") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "font-size:1.5rem") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "background:rgb(0,0,0)") != null);
}

test "renderPage emits a positioned div with border-radius" {
    var list = dl.DisplayList{};
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, .{ .rrect = .{
        .rect = geom.PhysicalRect{ .x = 40, .y = 40, .width = 720, .height = 520 },
        .radius = 16,
        .color = geom.Color.rgb(0.15, 0.35, 0.85),
    } });

    const html = try testPage(std.testing.allocator, list, geom.PhysicalSize{ .width = 800, .height = 600 });
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "left:2.5rem") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "top:2.5rem") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "border-radius:1rem") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "width:45rem") != null);
    // verify the float->0..255 channel conversion (0.15,0.35,0.85 -> 38,89,217)
    try std.testing.expect(std.mem.indexOf(u8, html, "rgba(38,89,217,1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "background:rgb(0,0,0)") != null);
}

test "renderPage escapes special characters in text content" {
    const gpa = std.testing.allocator;
    var font = try @import("../text.zig").Font.load(gpa, @import("../text.zig").builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    const glyphs = [_]dl.PositionedGlyph{.{ .cp = '<', .x = 0, .y = 0 }};
    try list.append(gpa, .{ .text = .{ .glyphs = &glyphs, .text = "<b>&", .font = &font, .size = 16, .color = geom.Color.rgb(1, 1, 1), .origin = geom.PhysicalOffset{ .x = 0, .y = 0 } } });
    const html = try testPage(gpa, list, geom.PhysicalSize{ .width = 100, .height = 100 });
    defer gpa.free(html);
    // Escaped form must be present.
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;b&gt;&amp;") != null);
    // Raw injection vectors must be absent.
    try std.testing.expect(std.mem.indexOf(u8, html, "<b>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<script>") == null);
}

test "renderPage: filled rrect uses background and no border; stroked rrect uses border and transparent" {
    var list = dl.DisplayList{};
    defer list.deinit(std.testing.allocator);
    // Filled rrect: red at x=10,y=20,w=100,h=50,r=5
    try list.append(std.testing.allocator, .{ .rrect = .{
        .rect = geom.PhysicalRect{ .x = 10, .y = 20, .width = 100, .height = 50 },
        .radius = 5,
        .color = geom.Color.rgb(1, 0, 0),
    } });
    // Stroked rrect: green at x=60,y=70,w=80,h=40,r=8, stroke 3px
    try list.append(std.testing.allocator, .{ .rrect = .{
        .rect = geom.PhysicalRect{ .x = 60, .y = 70, .width = 80, .height = 40 },
        .radius = 8,
        .color = geom.Color.rgb(0, 0.502, 0),
        .stroke_width = 3,
    } });
    const html = try testPage(std.testing.allocator, list, geom.PhysicalSize{ .width = 300, .height = 200 });
    defer std.testing.allocator.free(html);

    // (a) Filled div: background present, no border property.
    try std.testing.expect(std.mem.indexOf(u8, html, "background:rgba(255,0,0,1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "left:0.625rem") != null);

    // (b) Stroked div: border + box-sizing + transparent background + stroke color.
    try std.testing.expect(std.mem.indexOf(u8, html, "border:0.1875rem solid rgba(") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "box-sizing:border-box") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "background:transparent") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "left:3.75rem") != null);

    // (c) The whole rule of the filled div, so it has no border property.
    const expected_filled = ".p1{position:absolute;left:0.625rem;top:1.25rem;width:6.25rem;height:3.125rem;border-radius:0.3125rem;background:rgba(255,0,0,1)}";
    try std.testing.expect(std.mem.indexOf(u8, html, expected_filled) != null);
}

test "renderPage: plain filled rrect has its own class and no pb style" {
    var list = dl.DisplayList{};
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, .{ .rrect = .{
        .rect = geom.PhysicalRect{ .x = 10, .y = 20, .width = 100, .height = 50 },
        .radius = 5,
        .color = geom.Color.rgb(1, 0, 0),
    } });
    const html = try testPage(std.testing.allocator, list, geom.PhysicalSize{ .width = 300, .height = 200 });
    defer std.testing.allocator.free(html);

    // A plain rrect has only its own class and its own rule.
    const expected_filled = ".p1{position:absolute;left:0.625rem;top:1.25rem;width:6.25rem;height:3.125rem;border-radius:0.3125rem;background:rgba(255,0,0,1)}";
    try std.testing.expect(std.mem.indexOf(u8, html, expected_filled) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<div class=\"p1\"></div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "pb-") == null);
}

test "renderPage: fillRRectStates emits class and hover/active style rules" {
    var cv = @import("../canvas.zig").Canvas.init(std.testing.allocator);
    defer cv.deinit();
    try cv.fillRRectStates(
        geom.PhysicalRect{ .x = 0, .y = 0, .width = 80, .height = 40 },
        4,
        geom.Color.rgb(0, 0, 1), // base: blue
        geom.Color.rgb(0, 0, 0.9), // hover: slightly darker blue
        geom.Color.rgb(0, 0, 0.8), // active: darker blue
    );
    const html = try testPage(std.testing.allocator, cv.list, geom.PhysicalSize{ .width = 200, .height = 100 });
    defer std.testing.allocator.free(html);

    // The div carries a class, and the stylesheet names it.
    const cls = classOf(html).?;
    try std.testing.expect(std.mem.startsWith(u8, cls, "pb-"));
    try std.testing.expect(std.mem.indexOf(u8, html, "<style") == null);
    var want: [64]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, html, try std.fmt.bufPrint(&want, ".{s}:hover{{background:rgba(", .{cls})) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, try std.fmt.bufPrint(&want, ".{s}:active{{background:rgba(", .{cls})) != null);
    // No border-color in style rules (this is a fill).
    try std.testing.expect(std.mem.indexOf(u8, html, "border-color") == null);
}

test "renderPage: strokeRRectStates emits border-color hover/active style rules" {
    var cv = @import("../canvas.zig").Canvas.init(std.testing.allocator);
    defer cv.deinit();
    try cv.strokeRRectStates(
        geom.PhysicalRect{ .x = 0, .y = 0, .width = 80, .height = 40 },
        4,
        2,
        geom.Color{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0.3 }, // base
        geom.Color{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0.5 }, // hover
        geom.Color{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0.7 }, // active
    );
    const html = try testPage(std.testing.allocator, cv.list, geom.PhysicalSize{ .width = 200, .height = 100 });
    defer std.testing.allocator.free(html);

    const cls = classOf(html).?;
    try std.testing.expect(std.mem.startsWith(u8, cls, "pb-"));
    var want: [64]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, html, try std.fmt.bufPrint(&want, ".{s}:hover{{border-color:rgba(", .{cls})) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, try std.fmt.bufPrint(&want, ".{s}:active{{border-color:rgba(", .{cls})) != null);
    // No background in style rules (this is a stroke).
    try std.testing.expect(std.mem.indexOf(u8, html, ":hover{background") == null);
}

/// The first state class in a `class` attribute of `html`.
fn classOf(html: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, html, " pb-") orelse return null) + 1;
    const end = std.mem.indexOfScalarPos(u8, html, start, '"') orelse return null;
    return html[start..end];
}

test "alpha() formats CSS alpha compactly: opaque 1, transparent 0, fractional trimmed" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("1", alpha(&buf, 1.0));
    try std.testing.expectEqualStrings("0", alpha(&buf, 0.0));
    try std.testing.expectEqualStrings("0.3", alpha(&buf, 0.3));
    try std.testing.expectEqualStrings("0.5", alpha(&buf, 0.5));
    try std.testing.expectEqualStrings("0.7", alpha(&buf, 0.7));
    try std.testing.expectEqualStrings("0.15", alpha(&buf, 0.15));
}

test "rem prints px over 16 with at most four decimals and no trailing zeros" {
    var buf: [32]u8 = undefined;
    const cases = [_]struct { px: f32, want: []const u8 }{
        .{ .px = 0, .want = "0" },
        .{ .px = -0.0, .want = "0" },
        .{ .px = 16, .want = "1rem" },
        .{ .px = 10, .want = "0.625rem" },
        .{ .px = 1, .want = "0.0625rem" },
        .{ .px = 0.5, .want = "0.0313rem" },
        .{ .px = 1023.2, .want = "63.95rem" },
        .{ .px = -24, .want = "-1.5rem" },
        .{ .px = 1.0 / 3.0, .want = "0.0208rem" },
        .{ .px = std.math.nan(f32), .want = "0" },
        .{ .px = std.math.inf(f32), .want = "62500000rem" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c.want, try std.fmt.bufPrint(&buf, "{f}", .{rem(c.px)}));
    }
}

test "renderPage: fractional alpha is compact (no long float representation)" {
    var list = dl.DisplayList{};
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, .{ .rrect = .{
        .rect = geom.PhysicalRect{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .radius = 0,
        .color = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0.3 },
    } });
    const html = try testPage(std.testing.allocator, list, geom.PhysicalSize{ .width = 50, .height = 50 });
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, ",0.3)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "0.30000") == null);
}

test "renderPage: image with encoded bytes emits <img> tag with data URL" {
    const gpa = std.testing.allocator;
    const png_bytes = &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01 };
    var img = image_mod.Image.fromBytes(png_bytes, 20, 10);
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .image = .{
        .image = &img,
        .rect = .{ .x = 8, .y = 16, .width = 20, .height = 10 },
        .opacity = 1,
    } });
    const html = try testPage(gpa, list, geom.PhysicalSize{ .width = 200, .height = 100 });
    defer gpa.free(html);
    // Must contain an <img tag.
    try std.testing.expect(std.mem.indexOf(u8, html, "<img") != null);
    // Must contain the data URL prefix for PNG.
    try std.testing.expect(std.mem.indexOf(u8, html, "data:image/png;base64,") != null);
    // Must contain the positioned style values.
    try std.testing.expect(std.mem.indexOf(u8, html, "left:0.5rem") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "top:1rem") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "width:1.25rem") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "height:0.625rem") != null);
}

test "renderPage: image fromRgba (no encoded bytes) emits no img tag" {
    const gpa = std.testing.allocator;
    const rgba_pixels: [4 * 4 * 4]u8 = @splat(255);
    var img = image_mod.Image.fromRgba(&rgba_pixels, 4, 4);
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .image = .{
        .image = &img,
        .rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
        .opacity = 1,
    } });
    const html = try testPage(gpa, list, geom.PhysicalSize{ .width = 100, .height = 100 });
    defer gpa.free(html);
    // No img element should appear (fromRgba has no encoded bytes).
    try std.testing.expect(std.mem.indexOf(u8, html, "<img") == null);
}

test "renderPage: an icon emits an inline svg whose viewBox is the grid and whose size is the request" {
    const gpa = std.testing.allocator;
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 40, .height = 40 },
        .color = geom.Color.rgb(1, 0, 0),
        .origin = .{ .x = 6, .y = 9 },
    } });
    const html = try testPage(gpa, list, geom.PhysicalSize{ .width = 200, .height = 100 });
    defer gpa.free(html);

    // The two must differ: an svg sized at its viewBox would pass a test that
    // only looked at one of them, and would draw every icon at 24 pixels.
    try std.testing.expect(std.mem.indexOf(u8, html, "viewBox=\"0 0 24 24\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "width:2.5rem;height:2.5rem") != null);
    // Positioned like every other primitive, from the primitive's own origin.
    try std.testing.expect(std.mem.indexOf(u8, html, "position:absolute;left:0.375rem;top:0.5625rem") != null);
}

test "renderPage: an icon is a stroked centreline, not a filled shape" {
    const gpa = std.testing.allocator;
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geom.Color.rgb(0, 0.502, 1),
        .origin = .{ .x = 0, .y = 0 },
    } });
    const html = try testPage(gpa, list, geom.PhysicalSize{ .width = 100, .height = 100 });
    defer gpa.free(html);

    // fill="none" is the whole difference between a torii and a blue blob.
    try std.testing.expect(std.mem.indexOf(u8, html, "fill=\"none\"") != null);
    // The grammar's width, in grid units. The viewBox already scales it, so a
    // backend that multiplied by size/grid would print 1.7 here only by chance.
    try std.testing.expect(std.mem.indexOf(u8, html, "stroke-width=\"1.7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "stroke-linecap=\"round\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "stroke-linejoin=\"round\"") != null);
    // Tinted through the same channel conversion as every other primitive.
    try std.testing.expect(std.mem.indexOf(u8, html, "stroke=\"rgba(0,128,255,1)\"") != null);
    // The kasagi opens the mark, so the d attribute starts with the curve.
    try std.testing.expect(std.mem.indexOf(u8, html, "d=\"M3.84 3.218Q12 4.887 20.16 3.218") != null);
}

test "renderPage: an icon at twice the size reuses one path at a larger width" {
    // The point of handing the centreline to the browser: the geometry does not
    // change with size, only the box it is scaled into. A backend that baked the
    // size into the coordinates gives two different d strings here.
    const gpa = std.testing.allocator;
    var small = dl.DisplayList{};
    defer small.deinit(gpa);
    try small.append(gpa, .{ .icon = .{ .id = .torii, .size = .{ .width = 16, .height = 16 }, .color = geom.Color.rgb(1, 1, 1), .origin = .{ .x = 0, .y = 0 } } });
    var large = dl.DisplayList{};
    defer large.deinit(gpa);
    try large.append(gpa, .{ .icon = .{ .id = .torii, .size = .{ .width = 32, .height = 32 }, .color = geom.Color.rgb(1, 1, 1), .origin = .{ .x = 0, .y = 0 } } });

    const a = try testPage(gpa, small, geom.PhysicalSize{ .width = 100, .height = 100 });
    defer gpa.free(a);
    const b = try testPage(gpa, large, geom.PhysicalSize{ .width = 100, .height = 100 });
    defer gpa.free(b);

    const d_start = std.mem.indexOf(u8, a, "d=\"").? + 3;
    const d_end = std.mem.indexOfScalarPos(u8, a, d_start, '"').?;
    try std.testing.expect(std.mem.indexOf(u8, b, a[d_start..d_end]) != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "width:1rem") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "width:2rem") != null);
}

test "renderPage: a labelled icon carries an svg title, so it has an accessible name" {
    // A mark holds no text, so without a title a screen reader reads nothing
    // where an icon replaced a word. The title is the accessible name of inline
    // SVG, and it must come first, before the path.
    const gpa = std.testing.allocator;
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geom.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
        .label = "Genesis",
    } });
    const html = try testPage(gpa, list, geom.PhysicalSize{ .width = 100, .height = 100 });
    defer gpa.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, ">Genesis</title>") != null);
    const title_at = std.mem.indexOf(u8, html, "<title ").?;
    const path_at = std.mem.indexOf(u8, html, "<path ").?;
    try std.testing.expect(title_at < path_at);
}

test "renderPage: a label with markup in it is escaped, not written through" {
    // The label comes from the app, so it is arbitrary text. Written raw, a
    // name holding a bracket closes the title early and injects an element.
    const gpa = std.testing.allocator;
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geom.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
        .label = "<b>&</b>",
    } });
    const html = try testPage(gpa, list, geom.PhysicalSize{ .width = 100, .height = 100 });
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, ">&lt;b&gt;&amp;&lt;/b&gt;</title>") != null);
}

test "renderPage: an icon with no label emits no title element at all" {
    // An always-present title claims the accessible name and then announces an
    // empty string, which is worse than no title: with none, a reader falls back
    // on the surrounding text.
    const gpa = std.testing.allocator;
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geom.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
    } });
    const html = try testPage(gpa, list, geom.PhysicalSize{ .width = 100, .height = 100 });
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<title") == null);
    // The mark itself is still drawn: a backend that dropped the whole svg with
    // the title would also pass the line above.
    try std.testing.expect(std.mem.indexOf(u8, html, "<path ") != null);
}

test "renderPage: an icon inside a scroll region is placed relative to the region" {
    const gpa = std.testing.allocator;
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geom.PhysicalRect{ .x = 10, .y = 20, .width = 100, .height = 50 },
        .offset = geom.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geom.PhysicalSize{ .width = 100, .height = 300 },
    } });
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geom.Color.rgb(1, 1, 1),
        .origin = .{ .x = 30, .y = 60 },
    } });
    try list.append(gpa, .{ .pop_scroll = {} });
    const html = try testPage(gpa, list, geom.PhysicalSize{ .width = 300, .height = 200 });
    defer gpa.free(html);
    // 30-10 and 60-20, the same subtraction every other primitive makes.
    try std.testing.expect(std.mem.indexOf(u8, html, "left:1.25rem;top:2.5rem") != null);
}

test "renderPage: push_scroll emits overflow:scroll containers and adjusts child coords" {
    var list = dl.DisplayList{};
    defer list.deinit(std.testing.allocator);

    // push_scroll: viewport x=10,y=20,w=100,h=50; content w=100,h=300
    try list.append(std.testing.allocator, .{ .push_scroll = .{
        .viewport = geom.PhysicalRect{ .x = 10, .y = 20, .width = 100, .height = 50 },
        .offset = geom.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geom.PhysicalSize{ .width = 100, .height = 300 },
    } });
    // fillRRect at absolute coords x=10,y=120,w=80,h=20
    // after coord adjustment: left = 10-10 = 0, top = 120-20 = 100
    try list.append(std.testing.allocator, .{ .rrect = .{
        .rect = geom.PhysicalRect{ .x = 10, .y = 120, .width = 80, .height = 20 },
        .radius = 0,
        .color = geom.Color.rgb(1, 0, 0),
    } });
    try list.append(std.testing.allocator, .{ .pop_scroll = {} });

    const html = try testPage(std.testing.allocator, list, geom.PhysicalSize{ .width = 300, .height = 200 });
    defer std.testing.allocator.free(html);

    // Outer scroll container at viewport position
    try std.testing.expect(std.mem.indexOf(u8, html, "overflow:scroll") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "left:0.625rem;top:1.25rem;width:6.25rem;height:3.125rem;overflow:scroll") != null);
    // Inner content div with content size
    try std.testing.expect(std.mem.indexOf(u8, html, "position:relative;width:6.25rem;height:18.75rem") != null);
    // Child rrect with adjusted coords: left=0 (10-10), top=100 (120-20)
    try std.testing.expect(std.mem.indexOf(u8, html, "left:0;top:6.25rem") != null);
    // Closing tags for both divs
    try std.testing.expect(std.mem.indexOf(u8, html, "</div></div>") != null);
}

test "renderPage: a mark in a box that is not square stretches instead of letterboxing" {
    // An svg keeps its viewBox aspect by default and centres it in the box,
    // which for a rule in a tall box redraws the short, gapped mark the box was
    // made tall to avoid. Only preserveAspectRatio="none" lets the two axes
    // scale apart.
    const gpa = std.testing.allocator;
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .rule_vertical,
        .size = .{ .width = 16, .height = 48 },
        .color = geom.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
    } });

    const html = try testPage(gpa, list, geom.PhysicalSize{ .width = 100, .height = 100 });
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "preserveAspectRatio=\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "width:1rem") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "height:3rem") != null);
    // The viewBox stays the authoring grid, so one centreline still serves
    // every size and the stroke width keeps its grid units.
    try std.testing.expect(std.mem.indexOf(u8, html, "viewBox=\"0 0 24 24\"") != null);
}

fn pageList(gpa: std.mem.Allocator, font: *text.Font) !dl.DisplayList {
    var list = dl.DisplayList{};
    errdefer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{ .rect = .{ .x = 0, .y = 0, .width = 32, .height = 16 }, .radius = 0, .color = geom.Color.rgb(1, 0, 0) } });
    try list.append(gpa, .{ .rrect = .{ .rect = .{ .x = 0, .y = 16, .width = 32, .height = 16 }, .radius = 4, .color = geom.Color.rgb(0, 0, 1), .hover_color = geom.Color.rgb(0, 1, 0) } });
    try list.append(gpa, .{ .text = .{ .glyphs = &.{}, .text = "a<b", .font = font, .size = 16, .color = geom.Color.rgb(1, 1, 1), .origin = .{ .x = 8, .y = 0 } } });
    return list;
}

fn buildPage(gpa: std.mem.Allocator, list: dl.DisplayList) !Page {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const tree = try vdom.build(arena_state.allocator(), list, .{ .width = 64, .height = 32 }, geom.Color.rgb(0, 0, 0), null);
    return renderPage(gpa, tree, "/");
}

test "renderPage: a small tree gives this html and css, with no inline style" {
    const gpa = std.testing.allocator;
    var font = try text.builtin.neuropol(gpa);
    defer font.deinit(gpa);
    var list = try pageList(gpa, &font);
    defer list.deinit(gpa);
    var page = try buildPage(gpa, list);
    defer page.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, page.html, "style=") == null);
    try std.testing.expectEqualStrings("<div class=\"p0\"><div class=\"p1\"></div><div class=\"p2 pb-788763ab9d2ec3be\"></div><div class=\"p3\">a&lt;b</div></div>", page.html);
    try std.testing.expectEqualStrings("html,body{margin:0;background:rgb(0,0,0)}" ++
        "@font-face{font-family:pf-0b107d216918b3e5;src:url(\"/fonts/Neuropol.otf\") format(\"opentype\")}" ++
        ".p0{position:relative;width:4rem;height:2rem;background:rgb(0,0,0)}" ++
        ".p1{position:absolute;left:0;top:0;width:2rem;height:1rem;border-radius:0;background:rgba(255,0,0,1)}" ++
        ".p2{position:absolute;left:0;top:1rem;width:2rem;height:1rem;border-radius:0.25rem;background:rgba(0,0,255,1)}" ++
        ".p3{position:absolute;left:0.5rem;top:0;white-space:pre;font-family:pf-0b107d216918b3e5;font-size:1rem;color:rgba(255,255,255,1)}" ++
        ".pb-788763ab9d2ec3be:hover{background:rgba(0,255,0,1) !important}.pb-788763ab9d2ec3be{cursor:pointer}", page.css);
    try std.testing.expectEqual(@as(usize, 0), page.fonts.len);
}

test "renderPage: a font with no url is a file the page lists, never a data url" {
    const gpa = std.testing.allocator;
    var a = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer a.deinit(gpa);
    var b = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer b.deinit(gpa);
    var list = try pageList(gpa, &a);
    defer list.deinit(gpa);
    try list.append(gpa, .{ .text = .{ .glyphs = &.{}, .text = "c", .font = &b, .size = 16, .color = geom.Color.rgb(1, 1, 1), .origin = .{ .x = 0, .y = 0 } } });
    var page = try buildPage(gpa, list);
    defer page.deinit(gpa);

    // Two loads of one file are one face.
    try std.testing.expectEqual(@as(usize, 1), page.fonts.len);
    try std.testing.expectEqualStrings("fonts/pf-0b107d216918b3e5.otf", page.fonts[0].path);
    try std.testing.expectEqual(a.bytes.ptr, page.fonts[0].bytes.ptr);
    try std.testing.expect(std.mem.indexOf(u8, page.css, "@font-face{font-family:pf-0b107d216918b3e5;src:url(\"/fonts/pf-0b107d216918b3e5.otf\") format(\"opentype\")}") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, page.css, "@font-face"));
    try std.testing.expect(std.mem.indexOf(u8, page.css, "data:") == null);
}

test "a font url goes under the base unless it has a scheme or starts with a slash" {
    const gpa = std.testing.allocator;
    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var buf: [128]u8 = undefined;

    try std.testing.expectEqualStrings("/app/fonts/pf-0b107d216918b3e5.otf", try std.fmt.bufPrint(&buf, "{f}", .{fontUrl("/app/", &font)}));
    font.url = "fonts/Neuropol.otf";
    try std.testing.expectEqualStrings("/fonts/Neuropol.otf", try std.fmt.bufPrint(&buf, "{f}", .{fontUrl("/", &font)}));
    try std.testing.expectEqualStrings("/app/fonts/Neuropol.otf", try std.fmt.bufPrint(&buf, "{f}", .{fontUrl("/app/", &font)}));
    font.url = "/static/a.otf";
    try std.testing.expectEqualStrings("/static/a.otf", try std.fmt.bufPrint(&buf, "{f}", .{fontUrl("/app/", &font)}));
    font.url = "https://cdn.example.com/a.otf";
    try std.testing.expectEqualStrings("https://cdn.example.com/a.otf", try std.fmt.bufPrint(&buf, "{f}", .{fontUrl("/app/", &font)}));
    font.url = "a:b/c.otf";
    try std.testing.expectEqualStrings("a:b/c.otf", try std.fmt.bufPrint(&buf, "{f}", .{fontUrl("/", &font)}));
    font.url = "fonts/a:b.otf";
    try std.testing.expectEqualStrings("/fonts/a:b.otf", try std.fmt.bufPrint(&buf, "{f}", .{fontUrl("/", &font)}));
}

test "renderPage: one input gives the same bytes on every run" {
    const gpa = std.testing.allocator;
    var first_font = try text.builtin.neuropol(gpa);
    defer first_font.deinit(gpa);
    var first_list = try pageList(gpa, &first_font);
    defer first_list.deinit(gpa);
    var first = try buildPage(gpa, first_list);
    defer first.deinit(gpa);

    // A second font at a different address, so an address in the output shows.
    var second_font = try text.builtin.neuropol(gpa);
    defer second_font.deinit(gpa);
    var second_list = try pageList(gpa, &second_font);
    defer second_list.deinit(gpa);
    var second = try buildPage(gpa, second_list);
    defer second.deinit(gpa);

    try std.testing.expectEqualStrings(first.html, second.html);
    try std.testing.expectEqualStrings(first.css, second.css);
}
