//! Server rendering. Runs an application at one route and size with no
//! browser, and gives the page that the browser would draw on its first frame.
//!
//! The tree mounts, lays out and paints through the same `web.WebApp` code the
//! page uses, and prints through `dom.renderPage`. Only the first frame is
//! drawn. No timer fires, because nothing ticks the scheduler. No request,
//! event stream or location write goes out, because those hooks are null.
//! The random hook is null too, so a tree that draws random bytes while it
//! mounts gets `error.EntropyUnavailable`, or a panic from `std.Io.random`.

const std = @import("std");
const phantom = @import("../phantom.zig");
const web = @import("web.zig");
const dom = @import("backend/dom.zig");
const dom_calls = @import("backend/dom_calls.zig");
const vdom = @import("backend/vdom.zig");

pub const Options = struct {
    root: phantom.Root,
    /// The path of the request, such as "/docs/intro", with no query. A router
    /// reads it as a `.path` location.
    path: []const u8,
    /// The size to lay out at, in phantom px.
    viewport: phantom.PhysicalSize,
    /// The path the site is served at. It starts and ends with '/'. The font
    /// and stylesheet urls go under it.
    base: []const u8 = "/",
};

pub const Document = struct {
    /// The body content: the container element and its subtree.
    html: []u8,
    css: []u8,
    /// Where the server serves `css`, under `base`. The name is a hash of the
    /// css, so a browser can keep it.
    css_path: []u8,
    /// The fonts the server serves under `base`. Each file owns its bytes.
    fonts: []dom.FontFile,
    /// The size the page was laid out at, in phantom px.
    size: phantom.PhysicalSize,
    base: []u8,

    pub fn deinit(self: *Document, gpa: std.mem.Allocator) void {
        for (self.fonts) |file| {
            gpa.free(file.path);
            gpa.free(file.bytes);
        }
        gpa.free(self.fonts);
        gpa.free(self.base);
        gpa.free(self.css_path);
        gpa.free(self.css);
        gpa.free(self.html);
        self.* = undefined;
    }

    /// Write the whole page. `shell` is the index.html of the application
    /// that `addApp` writes. The page keeps the shell and its boot script, and
    /// gets a link to the stylesheet, the body content first in the body, and
    /// the layout size in `data-phantom-size`. A shell with no `<base>` gets
    /// one, so its relative urls resolve on a nested route.
    pub fn writeHtml(self: Document, w: *std.Io.Writer, shell: []const u8) WriteError!void {
        const head_end = std.mem.indexOf(u8, shell, "</head>") orelse return error.InvalidShell;
        const body_at = std.mem.indexOfPos(u8, shell, head_end, "<body") orelse return error.InvalidShell;
        const body_end = std.mem.indexOfScalarPos(u8, shell, body_at, '>') orelse return error.InvalidShell;
        if (shell[body_end - 1] == '/') return error.InvalidShell;

        try w.writeAll(shell[0..head_end]);
        if (std.mem.indexOf(u8, shell[0..head_end], "<base") == null) {
            try w.print("<base href=\"{s}\" />", .{self.base});
        }
        try w.print("<link rel=\"stylesheet\" href=\"{s}{s}\" />", .{ self.base, self.css_path });
        try w.writeAll(shell[head_end..body_end]);
        try w.print(" data-phantom-size=\"{d}x{d}\">", .{ self.size.width, self.size.height });
        try w.writeAll(self.html);
        try w.writeAll(shell[body_end + 1 ..]);
    }

    pub const WriteError = std.Io.Writer.Error || error{InvalidShell};
};

/// Render the application in `opts` to a page. The caller owns the result.
pub fn render(gpa: std.mem.Allocator, opts: Options) !Document {
    if (!dom.validBase(opts.base)) return error.InvalidBase;
    var host: Host = .{ .path = opts.path };
    const app = try mount(gpa, &host, opts);
    defer app.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const tree = try firstTree(arena_state.allocator(), app);
    var page = try dom.renderPage(gpa, tree, opts.base);
    defer page.deinit(gpa);

    // The fonts belong to the application, which is gone when this returns.
    const fonts = try gpa.alloc(dom.FontFile, page.fonts.len);
    var copied: usize = 0;
    errdefer {
        for (fonts[0..copied]) |file| {
            gpa.free(file.path);
            gpa.free(file.bytes);
        }
        gpa.free(fonts);
    }
    for (page.fonts, fonts) |src, *dst| {
        const path = try gpa.dupe(u8, src.path);
        errdefer gpa.free(path);
        dst.* = .{ .path = path, .bytes = try gpa.dupe(u8, src.bytes) };
        copied += 1;
    }
    const html = try gpa.dupe(u8, page.html);
    errdefer gpa.free(html);
    const css = try gpa.dupe(u8, page.css);
    errdefer gpa.free(css);
    const css_path = try gpa.print("page-{x:0>16}.css", .{std.hash.Wyhash.hash(0, css)});
    errdefer gpa.free(css_path);
    return .{
        .html = html,
        .css = css,
        .css_path = css_path,
        .fonts = fonts,
        .size = opts.viewport,
        .base = try gpa.dupe(u8, opts.base),
    };
}

/// Mount the application the way the page does, with only the location hook.
fn mount(gpa: std.mem.Allocator, host: *Host, opts: Options) !*web.WebApp {
    const size: phantom.LogicalSize = .{ .width = opts.viewport.width, .height = opts.viewport.height };
    return web.mount(gpa, host.ops(opts.base), opts.root, size, 1.0, .path);
}

/// The tree of the first frame. Its strings are in `arena`.
fn firstTree(arena: std.mem.Allocator, app: *web.WebApp) !vdom.Tree {
    var canvas = phantom.Canvas.init(app.gpa);
    canvas.sink = app.sink;
    defer canvas.deinit();
    _ = app.frame(&canvas);
    return vdom.build(arena, canvas.list, app.viewport(), web.background, app.sink);
}

/// The DOM a server has: nothing but the address. The tree never calls the
/// DOM operations, because `web.mount` draws nothing.
const Host = struct {
    path: []const u8,

    fn ops(self: *Host, base: []const u8) dom_calls.DomOps {
        return .{
            .ctx = self,
            .create_element = createElement,
            .create_text_node = createElement,
            .set_attribute = setAttribute,
            .set_text_content = setTextContent,
            .append_child = appendChild,
            .clear_children = clearChildren,
            .body = 0,
            .head = 0,
            .base = base,
            .read_location = readLocation,
        };
    }

    fn readLocation(ctx: *anyopaque, buf: []u8) ?[]const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        if (self.path.len > buf.len) return null;
        @memcpy(buf[0..self.path.len], self.path);
        return buf[0..self.path.len];
    }

    fn createElement(_: *anyopaque, _: []const u8) u32 {
        return 0;
    }
    fn setAttribute(_: *anyopaque, _: u32, _: []const u8, _: []const u8) void {}
    fn setTextContent(_: *anyopaque, _: u32, _: []const u8) void {}
    fn appendChild(_: *anyopaque, _: u32, _: u32) void {}
    fn clearChildren(_: *anyopaque, _: u32) void {}
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn homePage(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.ColoredBox{ .color = phantom.Color.rgb(1, 0, 0) }).widget();
}

fn aboutPage(b: *phantom.BuildContext) phantom.Widget {
    const box = b.new(phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) });
    return b.new(phantom.Padding{ .insets = .all(10), .child = box.widget() }).widget();
}

fn textPage(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Text{ .text = "hi" }).widget();
}

fn missingPage(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.ColoredBox{ .color = phantom.Color.rgb(0, 1, 0) }).widget();
}

const test_routes = [_]phantom.Route{
    .{ .path = "/", .build = homePage },
    .{ .path = "/about", .build = aboutPage },
    .{ .path = "/docs/text", .build = textPage },
};

fn routerRoot(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Router{ .routes = &test_routes, .initial = "/", .not_found = missingPage }).widget();
}

const test_size: phantom.PhysicalSize = .{ .width = 120, .height = 80 };

fn renderAt(path: []const u8, base: []const u8) !Document {
    return render(std.testing.allocator, .{
        .root = phantom.Root.plain(routerRoot),
        .path = path,
        .viewport = test_size,
        .base = base,
    });
}

test "each route renders to its own markup" {
    const gpa = std.testing.allocator;
    var home = try renderAt("/", "/");
    defer home.deinit(gpa);
    try std.testing.expectEqualStrings("<div class=\"p0\"><div class=\"p1\"></div></div>", home.html);
    try std.testing.expectEqualStrings("html,body{margin:0;background:rgb(26,27,38)}" ++
        ".p0{position:relative;width:7.5rem;height:5rem;background:rgb(26,27,38)}" ++
        ".p1{position:absolute;left:0;top:0;width:7.5rem;height:5rem;border-radius:0;background:rgba(255,0,0,1)}", home.css);
    try std.testing.expectEqual(@as(usize, 0), home.fonts.len);

    var about = try renderAt("/about", "/");
    defer about.deinit(gpa);
    try std.testing.expectEqualStrings("<div class=\"p0\"><div class=\"p1\"></div></div>", about.html);
    try std.testing.expectEqualStrings("html,body{margin:0;background:rgb(26,27,38)}" ++
        ".p0{position:relative;width:7.5rem;height:5rem;background:rgb(26,27,38)}" ++
        ".p1{position:absolute;left:0.625rem;top:0.625rem;width:6.25rem;height:3.75rem;border-radius:0;background:rgba(0,0,255,1)}", about.css);

    try std.testing.expect(!std.mem.eql(u8, home.css_path, about.css_path));
    try std.testing.expect(std.mem.startsWith(u8, home.css_path, "page-"));
    try std.testing.expect(std.mem.endsWith(u8, home.css_path, ".css"));
}

/// Equal in every part a page shows. `key` and the scroll handlers are
/// addresses in one run, so they are not compared.
fn expectSameNode(want: vdom.Node, got: vdom.Node) !void {
    try std.testing.expectEqual(want.kind, got.kind);
    try std.testing.expectEqualStrings(want.tag, got.tag);
    try std.testing.expectEqualStrings(want.style, got.style);
    try std.testing.expectEqualStrings(want.text, got.text);
    try std.testing.expectEqual(want.src_hash, got.src_hash);
    try std.testing.expectEqual(want.attrs.len, got.attrs.len);
    for (want.attrs, got.attrs) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqualStrings(a.value, b.value);
    }
    try std.testing.expectEqual(want.scroll == null, got.scroll == null);
    try std.testing.expectEqual(want.children.len, got.children.len);
    for (want.children, got.children) |a, b| try expectSameNode(a, b);
}

test "the server builds the tree the page builds on its first frame at the same size" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "/", "/about", "/docs/text", "/nowhere" }) |path| {
        var rec = dom_calls.Recorder{ .gpa = gpa };
        defer rec.deinit();
        rec.setLocation(path);
        const client = try web.init(gpa, rec.ops(), phantom.Root.plain(routerRoot), .{ .width = test_size.width, .height = test_size.height }, 1.0, .path);
        defer client.deinit();

        var host: Host = .{ .path = path };
        const server = try mount(gpa, &host, .{ .root = phantom.Root.plain(routerRoot), .path = path, .viewport = test_size });
        defer server.deinit();
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const tree = try firstTree(arena_state.allocator(), server);

        try expectSameNode(client.page.last.?.root, tree.root);
        try std.testing.expectEqual(client.sink.ok(), server.sink.ok());
    }
}

test "text fetches its font from under the base, never from a data url" {
    const gpa = std.testing.allocator;
    var doc = try renderAt("/docs/text", "/app/");
    defer doc.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, doc.html, ">hi</div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc.css, "src:url(\"/app/fonts/") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc.css, "data:") == null);
}

test "a font with no url is a file the document owns" {
    const gpa = std.testing.allocator;
    const Fixture = struct {
        font: phantom.text.Font,

        fn build(b: *phantom.BuildContext, self: *@This()) phantom.Widget {
            return b.new(phantom.Text{ .text = "hi", .font = &self.font }).widget();
        }
    };
    var fixture: Fixture = .{ .font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes) };
    defer fixture.font.deinit(gpa);
    var doc = try render(gpa, .{ .root = phantom.Root.of(Fixture, Fixture.build, &fixture), .path = "/", .viewport = test_size });
    defer doc.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), doc.fonts.len);
    try std.testing.expectEqualStrings("fonts/pf-0b107d216918b3e5.otf", doc.fonts[0].path);
    try std.testing.expectEqualSlices(u8, phantom.text.builtin.neuropol_bytes, doc.fonts[0].bytes);
    try std.testing.expect(doc.fonts[0].bytes.ptr != phantom.text.builtin.neuropol_bytes.ptr);
    try std.testing.expect(std.mem.indexOf(u8, doc.css, "src:url(\"/fonts/pf-0b107d216918b3e5.otf\")") != null);
}

const test_shell =
    \\<!DOCTYPE html>
    \\<html>
    \\  <head>
    \\    <meta charset="utf-8" />
    \\    <title>t</title>
    \\  </head>
    \\  <body>
    \\    <script type="module" src="./boot.js"></script>
    \\  </body>
    \\</html>
;

test "writeHtml puts the page in the shell and keeps the boot script" {
    const gpa = std.testing.allocator;
    var doc = try renderAt("/about", "/app/");
    defer doc.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try doc.writeHtml(&out.writer, test_shell);

    const want = try std.mem.concat(gpa, u8, &.{
        \\<!DOCTYPE html>
        \\<html>
        \\  <head>
        \\    <meta charset="utf-8" />
        \\    <title>t</title>
        \\  <base href="/app/" /><link rel="stylesheet" href="/app/
        ,
        doc.css_path,
        \\" /></head>
        \\  <body data-phantom-size="120x80">
        ,
        doc.html,
        \\
        \\    <script type="module" src="./boot.js"></script>
        \\  </body>
        \\</html>
    });
    defer gpa.free(want);
    try std.testing.expectEqualStrings(want, out.written());
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<style") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "style=") == null);
}

test "writeHtml keeps the base of a shell that has one" {
    const gpa = std.testing.allocator;
    var doc = try renderAt("/", "/");
    defer doc.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try doc.writeHtml(&out.writer, "<html><head><base href=\"/\" /></head><body class=\"x\"></body></html>");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "<base"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<body class=\"x\" data-phantom-size=\"120x80\"><div class=\"p0\">") != null);
}

test "writeHtml refuses a shell with no head end or no body" {
    const gpa = std.testing.allocator;
    var doc = try renderAt("/", "/");
    defer doc.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectError(error.InvalidShell, doc.writeHtml(&out.writer, "<html><body></body></html>"));
    try std.testing.expectError(error.InvalidShell, doc.writeHtml(&out.writer, "<html><head></head></html>"));
}

test "render refuses a base that does not start and end with a slash" {
    try std.testing.expectError(error.InvalidBase, renderAt("/", "app/"));
    try std.testing.expectError(error.InvalidBase, renderAt("/", "/app"));
}
