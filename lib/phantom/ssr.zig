//! Server rendering. Runs an application at one route and size with no
//! browser, and gives the page that the browser would draw on its first frame.
//!
//! The tree mounts, lays out and paints through the same `web.WebApp` code the
//! page uses, and prints through `dom.renderPage`. Only the first frame is
//! drawn: no timer fires, because nothing ticks the scheduler, and no request,
//! event stream or location write goes out, because those hooks are null. A
//! fetch an `initState` starts fails at once with `error.NetworkDown`, so an
//! app that shows an error state for a failed fetch renders that error state
//! on the server too.

const std = @import("std");
const phantom = @import("../phantom.zig");
const web = @import("web.zig");
const dom = @import("backend/dom.zig");
const dom_calls = @import("backend/dom_calls.zig");
const vdom = @import("backend/vdom.zig");

pub const Options = struct {
    root: phantom.Root,
    /// The path of the request, such as "/docs/intro", with no query. Reaches
    /// the router as a `.path` location: the same full pathname the live
    /// `.path` strategy reads from the browser, which includes a non-root
    /// `base`. A site served under "/app/" gets "/app/docs/intro" here, not
    /// "/docs/intro".
    path: []const u8,
    /// The size to lay out at, in phantom px: logical px after the browser's
    /// root-font scaling. The live client (`build/web_entry.zig`'s `init`)
    /// passes `web.CssScale.fromCss` of `innerWidth`/`innerHeight`, not the
    /// raw CSS pixel size, so a caller matching the browser exactly applies
    /// that same scaling first.
    viewport: phantom.PhysicalSize,
    /// The path the site is served at. It starts and ends with '/'. The font
    /// and stylesheet urls go under it.
    base: []const u8 = "/",
    /// Device pixels for one phantom px. The live client does not pass the
    /// browser's raw `devicePixelRatio`: it passes it through
    /// `web.CssScale.toCss`, which multiplies by the root-font ratio, the
    /// same scaling `viewport` divides out. Stored for widgets to read.
    /// Layout never scales by it.
    dpr: f32 = 1.0,
    /// The query string of the request, with no leading '?'. Null reads the
    /// same as a request that carries none.
    query: ?[]const u8 = null,
    /// The host the request named, with no port, lowercase: the live client
    /// reads `location.hostname`, which a browser already lowercases and
    /// IDNA-encodes to ASCII. Null reads the same as a request that carries
    /// none.
    host: ?[]const u8 = null,
    /// The randomness source a mounted app's `initState` can draw from, the
    /// same `std.Io` phantom threads through elsewhere (`window.open`,
    /// `Term.init`). A server that renders often should open one and pass it
    /// to every render.
    io: std.Io,
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
    /// the layout size in `data-phantom-size`. No `<base>` is added: a policy
    /// with `base-uri 'none'` refuses it, so the shell must use root-absolute
    /// urls to boot on a nested route. The `addApp` shell does.
    ///
    /// `shell` must be plain, lowercase HTML: this finds `</head>` and `<body`
    /// by a literal text search, not by parsing markup, so neither tag name
    /// may be upper or mixed case and no comment or string may hide one.
    pub fn writeHtml(self: Document, w: *std.Io.Writer, shell: []const u8) WriteError!void {
        const head_end = std.mem.indexOf(u8, shell, "</head>") orelse return error.InvalidShell;
        const body_at = std.mem.indexOfPos(u8, shell, head_end, "<body") orelse return error.InvalidShell;
        const body_end = std.mem.indexOfScalarPos(u8, shell, body_at, '>') orelse return error.InvalidShell;
        if (shell[body_end - 1] == '/') return error.InvalidShell;

        try w.writeAll(shell[0..head_end]);
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

    var host: Host = .{ .path = opts.path, .query = opts.query, .host = opts.host, .io = opts.io };
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

/// The paths `writePage` wrote, relative to its `out` directory, each once.
pub const Written = struct {
    paths: std.StringArrayHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *Written, gpa: std.mem.Allocator) void {
        for (self.paths.keys()) |path| gpa.free(path);
        self.paths.deinit(gpa);
        self.* = undefined;
    }

    fn add(self: *Written, gpa: std.mem.Allocator, path: []const u8) !void {
        if (self.paths.contains(path)) return;
        const owned = try gpa.dupe(u8, path);
        errdefer gpa.free(owned);
        try self.paths.put(gpa, owned, {});
    }
};

/// Render `opts` and write the page, its stylesheet and its font files under
/// `out`, each at the path the page uses for it under `opts.base`. The page of
/// "/app/docs/intro" with base "/app/" goes to "docs/intro/index.html", and
/// the page of the base itself to "index.html". Each path goes into `written`
/// too. This is how `addApp` writes its prerendered routes.
pub fn writePage(gpa: std.mem.Allocator, out: std.Io.Dir, shell: []const u8, opts: Options, written: *Written) !void {
    if (!dom.validBase(opts.base)) return error.InvalidBase;
    if (!std.mem.startsWith(u8, opts.path, opts.base) and !std.mem.eql(u8, opts.path, opts.base[0 .. opts.base.len - 1])) {
        return error.PathOutsideBase;
    }
    const dir = std.mem.trim(u8, opts.path[@min(opts.path.len, opts.base.len)..], "/");
    var parts = std.mem.splitScalar(u8, dir, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.PathOutsideBase;
    }

    var doc = try render(gpa, opts);
    defer doc.deinit(gpa);

    var page: std.Io.Writer.Allocating = .init(gpa);
    defer page.deinit();
    try doc.writeHtml(&page.writer, shell);

    const page_path = try std.fs.path.join(gpa, &.{ dir, "index.html" });
    defer gpa.free(page_path);
    try writeFile(opts.io, out, page_path, page.written());
    try written.add(gpa, page_path);
    try writeFile(opts.io, out, doc.css_path, doc.css);
    try written.add(gpa, doc.css_path);
    for (doc.fonts) |font| {
        try writeFile(opts.io, out, font.path, font.bytes);
        try written.add(gpa, font.path);
    }
}

fn writeFile(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try dir.createDirPath(io, parent);
    }
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

/// Mount the application the way the page does, with the location, query,
/// host and randomness hooks `host` carries.
fn mount(gpa: std.mem.Allocator, host: *Host, opts: Options) !*web.WebApp {
    const size: phantom.LogicalSize = .{ .width = opts.viewport.width, .height = opts.viewport.height };
    return web.mount(gpa, host.ops(opts.base), opts.root, size, opts.dpr, .path);
}

/// The tree of the first frame. Its strings are in `arena`.
fn firstTree(arena: std.mem.Allocator, app: *web.WebApp) !vdom.Tree {
    var canvas = phantom.Canvas.init(app.gpa);
    canvas.sink = app.sink;
    defer canvas.deinit();
    _ = app.frame(&canvas);
    return vdom.build(arena, canvas.list, app.viewport(), web.background, app.sink);
}

/// The DOM a server has: the address, the query, the host and a randomness
/// source. The tree never calls the element operations, because `web.mount`
/// draws nothing.
const Host = struct {
    path: []const u8,
    query: ?[]const u8 = null,
    host: ?[]const u8 = null,
    io: std.Io,

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
            .read_query = readQuery,
            .read_host = readHost,
            .fill_random = fillRandom,
        };
    }

    fn readLocation(ctx: *anyopaque, buf: []u8) ?[]const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        return copyInto(buf, self.path);
    }

    /// Reads as an empty query when `self.query` is null, the same as a
    /// request with none, rather than as a host with no hook at all.
    fn readQuery(ctx: *anyopaque, buf: []u8) ?[]const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        return copyInto(buf, self.query orelse "");
    }

    /// Reads as an empty host when `self.host` is null, on the same rule as
    /// `readQuery`.
    fn readHost(ctx: *anyopaque, buf: []u8) ?[]const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        return copyInto(buf, self.host orelse "");
    }

    /// `randomSecure` can fail from a pending cancel alone, which happens
    /// when Chock cancels the request task, even though the source itself
    /// still works. This hook must never answer false for that, so a failed
    /// `randomSecure` falls back to `random`, which cannot fail.
    fn fillRandom(ctx: *anyopaque, buf: []u8) bool {
        const self: *Host = @ptrCast(@alignCast(ctx));
        std.Io.randomSecure(self.io, buf) catch std.Io.random(self.io, buf);
        return true;
    }

    fn createElement(_: *anyopaque, _: []const u8) u32 {
        return 0;
    }
    fn setAttribute(_: *anyopaque, _: u32, _: []const u8, _: []const u8) void {}
    fn setTextContent(_: *anyopaque, _: u32, _: []const u8) void {}
    fn appendChild(_: *anyopaque, _: u32, _: u32) void {}
    fn clearChildren(_: *anyopaque, _: u32) void {}
};

/// Writes `s` into `buf` and returns the written part, or null when it does
/// not fit. The caller must refuse a null rather than take a truncated,
/// shorter value than the one it asked for.
fn copyInto(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

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
        .io = std.testing.io,
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
    const io = std.testing.io;

    for ([_][]const u8{ "/", "/about", "/docs/text", "/nowhere" }) |path| {
        var rec = dom_calls.Recorder{ .gpa = gpa };
        defer rec.deinit();
        rec.setLocation(path);
        const client = try web.init(gpa, rec.ops(), phantom.Root.plain(routerRoot), .{ .width = test_size.width, .height = test_size.height }, 1.0, .path);
        defer client.deinit();
        // `PageState.Retained` keeps only the root a real render sent to the
        // DOM, not the rules or the fonts, so those two still come from a
        // second tree built the same way the server's is.
        var client_arena = std.heap.ArenaAllocator.init(gpa);
        defer client_arena.deinit();
        const client_tree = try firstTree(client_arena.allocator(), client);

        var host: Host = .{ .path = path, .io = io };
        const server = try mount(gpa, &host, .{ .root = phantom.Root.plain(routerRoot), .path = path, .viewport = test_size, .io = io });
        defer server.deinit();
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const tree = try firstTree(arena_state.allocator(), server);

        try expectSameNode(client.page.last.?.root, tree.root);

        try std.testing.expectEqual(client_tree.rules.len, tree.rules.len);
        for (client_tree.rules, tree.rules) |a, b| {
            try std.testing.expectEqual(a.hash, b.hash);
            try std.testing.expectEqualStrings(a.css, b.css);
        }

        try std.testing.expectEqual(client_tree.fonts.len, tree.fonts.len);
        for (client_tree.fonts, tree.fonts) |a, b| try std.testing.expectEqual(a.id, b.id);

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
    var doc = try render(gpa, .{ .root = phantom.Root.of(Fixture, Fixture.build, &fixture), .path = "/", .viewport = test_size, .io = std.testing.io });
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
    \\    <script type="module" src="/app/boot.js"></script>
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
        \\  <link rel="stylesheet" href="/app/
        ,
        doc.css_path,
        \\" /></head>
        \\  <body data-phantom-size="120x80">
        ,
        doc.html,
        \\
        \\    <script type="module" src="/app/boot.js"></script>
        \\  </body>
        \\</html>
    });
    defer gpa.free(want);
    try std.testing.expectEqualStrings(want, out.written());
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<style") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "style=") == null);
}

test "writeHtml adds no base and keeps the attributes of the body" {
    const gpa = std.testing.allocator;
    var doc = try renderAt("/", "/");
    defer doc.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try doc.writeHtml(&out.writer, "<html><head></head><body class=\"x\"></body></html>");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<base") == null);
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

test "render refuses a base that could break out of the attribute or css string it is printed into" {
    try std.testing.expectError(error.InvalidBase, renderAt("/", "/a\"b/"));
    try std.testing.expectError(error.InvalidBase, renderAt("/", "/a<b/"));
    try std.testing.expectError(error.InvalidBase, renderAt("/", "/a>b/"));
    try std.testing.expectError(error.InvalidBase, renderAt("/", "/a\\b/"));
    try std.testing.expectError(error.InvalidBase, renderAt("/", "/a\nb/"));
}

fn alwaysFailsSecure(_: ?*anyopaque, _: []u8) std.Io.RandomSecureError!void {
    return error.EntropyUnavailable;
}

fn fillsWithOnes(_: ?*anyopaque, buf: []u8) void {
    @memset(buf, 1);
}

// A real pending cancel lives on `std.Io.Threaded`'s own per-thread status,
// set only through its async and group cancellation machinery, with no
// public hook a test can trip directly. This stands in for it with a source
// whose `randomSecure` always fails the same way a cancel would, and proves
// `fillRandom` falls back to `random` instead of answering false.
test "fillRandom falls back to the plain random source when randomSecure fails" {
    const vt: std.Io.VTable = blk: {
        var v = std.Io.failing.vtable.*;
        v.random = fillsWithOnes;
        v.randomSecure = alwaysFailsSecure;
        break :blk v;
    };
    var host: Host = .{ .path = "/", .io = .{ .userdata = null, .vtable = &vt } };
    var buf: [4]u8 = @splat(0);
    try std.testing.expect(Host.fillRandom(&host, &buf));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 1, 1, 1 }, &buf);
}

/// A root whose state draws random bytes while it mounts, the way a session
/// token or a nonce would. Proves `render` wires a real source rather than
/// leaving `webRandom` to panic.
const RandomDraw = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        box: phantom.ColoredBox = undefined,

        pub fn initState(s: *@This(), _: *const RandomDraw) anyerror!void {
            var buf: [8]u8 = undefined;
            std.Io.random(s.base.io(), &buf);
        }

        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            _ = b;
            s.box = .{ .color = phantom.Color.rgb(0, 0, 0) };
            return s.box.widget();
        }
    };

    fn root(b: *phantom.BuildContext) phantom.Widget {
        return phantom.StatefulWidget(RandomDraw, b.new(RandomDraw{}));
    }
};

test "an app whose initState draws random bytes renders without panic" {
    const gpa = std.testing.allocator;
    var doc = try render(gpa, .{ .root = phantom.Root.plain(RandomDraw.root), .path = "/", .viewport = test_size, .io = std.testing.io });
    defer doc.deinit(gpa);
    try std.testing.expect(doc.html.len > 0);
}

fn queryPage(b: *phantom.BuildContext) phantom.Widget {
    var buf: [64]u8 = undefined;
    const q = b.owner.platform.readQuery(&buf) orelse "(unsupported)";
    return b.new(phantom.Text{ .text = b.newSlice(u8, q) }).widget();
}

test "a widget that reads the query renders it on the server" {
    const gpa = std.testing.allocator;
    var doc = try render(gpa, .{
        .root = phantom.Root.plain(queryPage),
        .path = "/",
        .viewport = test_size,
        .query = "tab=settings",
        .io = std.testing.io,
    });
    defer doc.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, doc.html, ">tab=settings<") != null);
}

test "a request with no query renders an empty one, not an unsupported hook" {
    const gpa = std.testing.allocator;
    var doc = try render(gpa, .{ .root = phantom.Root.plain(queryPage), .path = "/", .viewport = test_size, .io = std.testing.io });
    defer doc.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, doc.html, "(unsupported)") == null);
}

fn hostPage(b: *phantom.BuildContext) phantom.Widget {
    var buf: [64]u8 = undefined;
    const h = b.owner.platform.readHost(&buf) orelse "(unsupported)";
    return b.new(phantom.Text{ .text = b.newSlice(u8, h) }).widget();
}

test "a widget that reads the host renders it on the server" {
    const gpa = std.testing.allocator;
    var doc = try render(gpa, .{
        .root = phantom.Root.plain(hostPage),
        .path = "/",
        .viewport = test_size,
        .host = "example.com",
        .io = std.testing.io,
    });
    defer doc.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, doc.html, ">example.com<") != null);
}

/// A root whose state reads `MediaQuery.of`, the way a widget deep in a real
/// tree would. A plain root function runs before `web.mount` wraps it in the
/// `MediaQuery` ancestor, so reading it there would always see the default.
/// A stateful child's `build` runs after mounting and sees the real one.
const DprProbe = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        text: phantom.Text = undefined,

        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            const dpr = phantom.MediaQuery.of(b).dpr;
            s.text = .{ .text = if (dpr == 2) "2x" else "1x" };
            return s.text.widget();
        }
    };

    fn root(b: *phantom.BuildContext) phantom.Widget {
        return phantom.StatefulWidget(DprProbe, b.new(DprProbe{}));
    }
};

test "dpr reaches a mounted app the same way the browser's devicePixelRatio does" {
    const gpa = std.testing.allocator;
    var doc = try render(gpa, .{ .root = phantom.Root.plain(DprProbe.root), .path = "/", .viewport = test_size, .dpr = 2, .io = std.testing.io });
    defer doc.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, doc.html, ">2x<") != null);
}

fn writeAt(out: std.Io.Dir, root: phantom.Root, path: []const u8, base: []const u8) !void {
    var written: Written = .{};
    defer written.deinit(std.testing.allocator);
    try writePage(std.testing.allocator, out, test_shell, .{ .root = root, .path = path, .viewport = test_size, .base = base, .io = std.testing.io }, &written);
}

fn readAt(dir: std.Io.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1 << 20));
}

test "writePage puts each route where a static host finds it, with its stylesheet" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = phantom.Root.plain(routerRoot);

    for ([_][]const u8{ "/app/", "/app/about", "/app/docs/text/" }) |path| {
        try writeAt(tmp.dir, root, path, "/app/");
    }
    for ([_][]const u8{ "index.html", "about/index.html", "docs/text/index.html" }) |page_path| {
        const page = try readAt(tmp.dir, page_path);
        defer gpa.free(page);
        const link = "<link rel=\"stylesheet\" href=\"/app/";
        const at = (std.mem.indexOf(u8, page, link) orelse return error.TestNoLink) + link.len;
        const end = std.mem.indexOfScalarPos(u8, page, at, '"') orelse return error.TestNoLink;
        const css = try readAt(tmp.dir, page[at..end]);
        defer gpa.free(css);
        try std.testing.expect(std.mem.startsWith(u8, css, "html,body{"));
        try std.testing.expect(std.mem.indexOf(u8, page, "<script type=\"module\" src=\"/app/boot.js\">") != null);
    }
    const about = try readAt(tmp.dir, "about/index.html");
    defer gpa.free(about);
    var doc = try renderAt("/app/about", "/app/");
    defer doc.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, about, doc.html) != null);
}

test "writePage writes the font files the stylesheet names" {
    const gpa = std.testing.allocator;
    const Fixture = struct {
        font: phantom.text.Font,

        fn build(b: *phantom.BuildContext, self: *@This()) phantom.Widget {
            return b.new(phantom.Text{ .text = "hi", .font = &self.font }).widget();
        }
    };
    var fixture: Fixture = .{ .font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes) };
    defer fixture.font.deinit(gpa);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeAt(tmp.dir, phantom.Root.of(Fixture, Fixture.build, &fixture), "/", "/");
    const font = try readAt(tmp.dir, "fonts/pf-0b107d216918b3e5.otf");
    defer gpa.free(font);
    try std.testing.expectEqualSlices(u8, phantom.text.builtin.neuropol_bytes, font);
}

test "writePage refuses a path outside the base" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = phantom.Root.plain(routerRoot);
    try std.testing.expectError(error.PathOutsideBase, writeAt(tmp.dir, root, "/other/about", "/app/"));
    try std.testing.expectError(error.PathOutsideBase, writeAt(tmp.dir, root, "/app/../x", "/app/"));
    try std.testing.expectError(error.InvalidBase, writeAt(tmp.dir, root, "/", ""));
}

test "writePage lists each page, stylesheet and font file it writes, once" {
    const gpa = std.testing.allocator;
    const Fixture = struct {
        font: phantom.text.Font,

        fn build(b: *phantom.BuildContext, self: *@This()) phantom.Widget {
            return b.new(phantom.Text{ .text = "hi", .font = &self.font }).widget();
        }
    };
    var fixture: Fixture = .{ .font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes) };
    defer fixture.font.deinit(gpa);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var written: Written = .{};
    defer written.deinit(gpa);

    const root = phantom.Root.of(Fixture, Fixture.build, &fixture);
    for ([_][]const u8{ "/", "/about" }) |path| {
        try writePage(gpa, tmp.dir, test_shell, .{ .root = root, .path = path, .viewport = test_size, .io = std.testing.io }, &written);
    }
    const paths = written.paths.keys();
    try std.testing.expectEqual(@as(usize, 4), paths.len);
    try std.testing.expectEqualStrings("index.html", paths[0]);
    try std.testing.expect(std.mem.startsWith(u8, paths[1], "page-"));
    try std.testing.expectEqualStrings("fonts/pf-0b107d216918b3e5.otf", paths[2]);
    try std.testing.expectEqualStrings("about/index.html", paths[3]);
    for (paths) |path| {
        const bytes = try readAt(tmp.dir, path);
        gpa.free(bytes);
    }
}
