//! An http server for one web app. A request for a file in the dist directory
//! gets that file. Any other path under the base is a page: the server renders
//! it with `ssr.render` at the size the browser reports. The stylesheet and
//! font files a render names stay in memory, so the browser can fetch them
//! after the page.
//!
//! Every request renders fresh, also for a route the build prerendered. A
//! prerendered page has the default size only, and a fresh page has the size,
//! query and host of the request.

const std = @import("std");
const phantom = @import("../../phantom.zig");
const ssr = @import("../ssr.zig");
const dom = @import("../backend/dom.zig");
const Server = @This();

const Io = std.Io;
const Request = std.http.Server.Request;

gpa: std.mem.Allocator,
io: Io,
opts: Options,
mutex: Io.Mutex = .init,
styles: Cache = .{ .max = max_styles },
fonts: Cache = .{ .max = max_fonts },
log_mutex: Io.Mutex = .init,
connections: std.atomic.Value(u32) = .init(0),
/// Connections closed early because the server was full or could not start a
/// task for them.
refused: std.atomic.Value(u64) = .init(0),

pub const Options = struct {
    root: phantom.Root,
    /// The page shell `addApp` writes, with no prerendered content in it.
    shell: []const u8,
    dist: Io.Dir,
    base: []const u8 = "/",
    /// The page size for a request with no viewport hint, in phantom px.
    default_size: phantom.PhysicalSize,
    /// The Content-Security-Policy of every answer.
    csp: []const u8 = default_csp,
    /// The time one request can take, from the wait for its head to the last
    /// byte of the answer. A keep-alive connection that stays idle this long
    /// closes.
    timeout: Io.Duration = .fromSeconds(10),
    max_connections: u32 = 256,
    /// The app keeps its route after the '#', which a server never receives,
    /// so every page renders the base route.
    hash_routes: bool = false,
    /// Gets one line for each answer. It is written from more than one thread
    /// under a lock.
    log: ?*Io.Writer = null,
};

/// The policy the `addApp` page holds to: every script, style, font and
/// request from the site itself, and the wasm compiled from it.
pub const default_csp = "default-src 'self'; style-src 'self'; script-src 'self' 'wasm-unsafe-eval'; " ++
    "font-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'";

/// The largest request head. A longer head gets 431.
pub const max_head = 8 * 1024;
pub const max_headers = 64;
/// Longer paths get 414.
pub const max_path = 2048;
const max_styles = 256;
const max_fonts = 64;
const max_requests_per_connection = 1000;

/// The viewport hint is in css px. Bounds keep a false hint from asking for a
/// huge layout.
pub const min_width = 240;
pub const max_width = 7680;

pub fn init(gpa: std.mem.Allocator, io: Io, opts: Options) error{InvalidBase}!Server {
    if (!dom.validBase(opts.base)) return error.InvalidBase;
    std.debug.assert(opts.default_size.width > 0 and opts.default_size.height > 0);
    return .{ .gpa = gpa, .io = io, .opts = opts };
}

pub fn deinit(self: *Server) void {
    self.styles.deinit(self.gpa);
    self.fonts.deinit(self.gpa);
    self.* = undefined;
}

/// Accept connections on `listener` until the task is canceled. Each
/// connection runs as its own task on `self.io`.
pub fn serve(self: *Server, listener: *Io.net.Server) Io.Cancelable!void {
    var group: Io.Group = .init;
    defer group.cancel(self.io);
    while (true) {
        const stream = listener.accept(self.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.ConnectionAborted, error.BlockedByFirewall, error.ProtocolFailure, error.WouldBlock => continue,
            // Out of descriptors or memory: wait for a connection to close.
            else => {
                _ = self.refused.fetchAdd(1, .monotonic);
                try self.io.sleep(.fromMilliseconds(100), .awake);
                continue;
            },
        };
        if (self.connections.fetchAdd(1, .monotonic) >= self.opts.max_connections) {
            self.refuse(stream);
            continue;
        }
        group.concurrent(self.io, serveConnection, .{ self, stream }) catch self.refuse(stream);
    }
}

fn refuse(self: *Server, stream: Io.net.Stream) void {
    _ = self.connections.fetchSub(1, .monotonic);
    _ = self.refused.fetchAdd(1, .monotonic);
    stream.close(self.io);
}

fn serveConnection(self: *Server, stream: Io.net.Stream) Io.Cancelable!void {
    defer {
        stream.close(self.io);
        _ = self.connections.fetchSub(1, .monotonic);
    }
    var in_buf: [max_head]u8 = undefined;
    var out_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(self.io, &in_buf);
    var writer = stream.writer(self.io, &out_buf);
    var http: std.http.Server = .init(&reader.interface, &writer.interface);
    for (0..max_requests_per_connection) |_| {
        if (!try self.serveTimed(&http)) return;
    }
}

/// Serve one request, or give up when `opts.timeout` ends first. Returns
/// whether the connection stays open.
fn serveTimed(self: *Server, http: *std.http.Server) Io.Cancelable!bool {
    const Outcome = union(enum) { served: bool, expired: Io.Cancelable!void };
    var buf: [2]Outcome = undefined;
    var select: Io.Select(Outcome) = .init(self.io, &buf);
    defer select.cancelDiscard();
    select.concurrent(.served, serveOne, .{ self, http }) catch return self.noTask();
    select.concurrent(.expired, Io.sleep, .{ self.io, self.opts.timeout, .awake }) catch return self.noTask();
    return switch (try select.await()) {
        .served => |keep| keep,
        .expired => false,
    };
}

fn noTask(self: *Server) bool {
    _ = self.refused.fetchAdd(1, .monotonic);
    return false;
}

/// Read one request from `http` and answer it. Returns whether the
/// connection stays open.
pub fn serveOne(self: *Server, http: *std.http.Server) bool {
    var request = http.receiveHead() catch |err| {
        const status: std.http.Status = switch (err) {
            error.HttpHeadersOversize => .request_header_fields_too_large,
            error.HttpHeadersInvalid => .bad_request,
            error.HttpRequestTruncated, error.HttpConnectionClosing, error.ReadFailed => return false,
        };
        http.out.print("HTTP/1.1 {d} {s}\r\nconnection: close\r\ncontent-length: 0\r\n\r\n", .{
            @backingInt(status), status.phrase() orelse "",
        }) catch return false;
        http.out.flush() catch {};
        return false;
    };
    return self.handle(&request) catch false;
}

const Answer = struct {
    status: std.http.Status,
    content_type: []const u8,
    cache: []const u8 = no_cache,
    page: bool = false,
};

const no_cache = "no-cache";
const long_cache = "public, max-age=31536000, immutable";

/// Answer `request`. Returns whether the connection stays open.
pub fn handle(self: *Server, request: *Request) !bool {
    const head = request.head;
    const has_body = (head.content_length orelse 0) > 0 or head.transfer_encoding != .none;
    const keep = head.keep_alive and !has_body;

    var it = request.iterateHeaders();
    var count: usize = 0;
    var hint: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    while (it.next()) |h| {
        count += 1;
        if (std.ascii.eqlIgnoreCase(h.name, "sec-ch-viewport-width")) hint = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "host")) host = h.value;
    }
    if (count > max_headers) return self.plain(request, .request_header_fields_too_large, false);
    switch (head.method) {
        .GET, .HEAD => {},
        .POST, .PUT, .PATCH, .QUERY, .DELETE, .CONNECT, .OPTIONS, .TRACE => {
            return self.plain(request, .method_not_allowed, false);
        },
    }

    const target = head.target;
    if (target.len == 0 or target[0] != '/' or std.mem.indexOfScalar(u8, target, '#') != null) {
        return self.plain(request, .bad_request, keep);
    }
    const query_at = std.mem.indexOfScalar(u8, target, '?');
    const raw_path = target[0 .. query_at orelse target.len];
    const query: ?[]const u8 = if (query_at) |at| target[at + 1 ..] else null;
    if (raw_path.len > max_path) return self.plain(request, .uri_too_long, keep);

    var path_buf: [max_path]u8 = undefined;
    @memcpy(path_buf[0..raw_path.len], raw_path);
    const path = std.Uri.percentDecodeInPlace(path_buf[0..raw_path.len]);
    if (!safePath(path)) return self.plain(request, .bad_request, keep);

    const base = self.opts.base;
    const rel = if (std.mem.startsWith(u8, path, base))
        path[base.len..]
    else if (std.mem.eql(u8, path, base[0 .. base.len - 1]))
        ""
    else
        return self.plain(request, .not_found, keep);

    if (rel.len > 0 and rel[rel.len - 1] != '/') {
        if (try self.serveFile(request, rel, keep)) return keep;
        if (isStyle(rel)) return self.serveCached(request, &self.styles, rel, "text/css; charset=utf-8", keep);
        if (std.mem.startsWith(u8, rel, "fonts/pf-")) return self.serveCached(request, &self.fonts, rel, mimeOf(rel), keep);
    }

    var host_buf: [Io.net.HostName.max_len]u8 = undefined;
    return self.servePage(request, .{
        .path = if (self.opts.hash_routes) base else raw_path,
        .query = query,
        .host = if (host) |h| hostName(&host_buf, h) else null,
        .viewport = self.viewport(hint),
    }, keep);
}

const PageRequest = struct {
    path: []const u8,
    query: ?[]const u8,
    host: ?[]const u8,
    viewport: phantom.PhysicalSize,
};

fn servePage(self: *Server, request: *Request, page: PageRequest, keep: bool) !bool {
    var doc = ssr.render(self.gpa, .{
        .root = self.opts.root,
        .path = page.path,
        .viewport = page.viewport,
        .base = self.opts.base,
        .query = page.query,
        .host = page.host,
        .io = self.io,
        .known_fonts = .{ .ctx = self, .contains = knownFont },
    }) catch return self.plain(request, .internal_server_error, false);
    defer doc.deinit(self.gpa);

    self.keepAsset(&self.styles, doc.css_path, doc.css);
    for (doc.fonts) |font| self.keepAsset(&self.fonts, font.path, font.bytes);

    var html: Io.Writer.Allocating = .init(self.gpa);
    defer html.deinit();
    doc.writeHtml(&html.writer, self.opts.shell) catch return self.plain(request, .internal_server_error, false);

    const status: std.http.Status = switch (doc.status) {
        .ok => .ok,
        .not_found => .not_found,
        .location_too_long => .uri_too_long,
        .failed => .internal_server_error,
    };
    return self.send(request, html.written(), .{ .status = status, .content_type = "text/html; charset=utf-8", .page = true }, keep);
}

/// Serve `rel` from the dist directory. Returns false when it is no file there.
fn serveFile(self: *Server, request: *Request, rel: []const u8, keep: bool) !bool {
    const file = self.opts.dist.openFile(self.io, rel, .{}) catch return false;
    defer file.close(self.io);
    const stat = file.stat(self.io) catch return false;
    if (stat.kind != .file) return false;

    const cache = if (isStyle(rel) or std.mem.startsWith(u8, rel, "fonts/pf-")) long_cache else no_cache;
    var fields: [6]std.http.Header = undefined;
    const answer: Answer = .{ .status = .ok, .content_type = mimeOf(rel), .cache = cache };
    const is_get = request.head.method == .GET;
    self.logAnswer(request, .ok);
    var out_buf: [4096]u8 = undefined;
    var body = try request.respondStreaming(&out_buf, .{
        .content_length = stat.size,
        .respond_options = .{ .keep_alive = keep, .extra_headers = self.headers(&fields, answer) },
    });
    if (!is_get) {
        try body.flush();
        return true;
    }
    var in_buf: [4096]u8 = undefined;
    var reader = file.reader(self.io, &in_buf);
    const sent = try body.writer.sendFileAll(&reader, .limited64(stat.size));
    // A file that shrank since the stat leaves the answer short of its
    // content-length, so the connection must close.
    if (sent != stat.size) return error.FileChanged;
    try body.end();
    return true;
}

fn serveCached(self: *Server, request: *Request, cache: *Cache, rel: []const u8, content_type: []const u8, keep: bool) !bool {
    const bytes = blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const held = cache.map.get(rel) orelse break :blk null;
        // A copy, so the lock is not held while a slow client reads.
        break :blk self.gpa.dupe(u8, held) catch null;
    } orelse return self.plain(request, .not_found, keep);
    defer self.gpa.free(bytes);
    return self.send(request, bytes, .{ .status = .ok, .content_type = content_type, .cache = long_cache }, keep);
}

fn knownFont(ctx: *anyopaque, path: []const u8) bool {
    const self: *Server = @ptrCast(@alignCast(ctx));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.fonts.map.contains(path);
}

/// Keep a copy of a hashed asset. Out of memory only means the browser gets
/// 404 for it, and `refused` does not count it, so it goes to the log.
fn keepAsset(self: *Server, cache: *Cache, path: []const u8, bytes: []const u8) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    cache.put(self.gpa, path, bytes) catch self.logLine("asset {s} not kept: out of memory", .{path});
}

/// The page size for a viewport hint. The hint is in css px and phantom
/// lays out in phantom px, css px times 16 over the root font size. The
/// server cannot know the root font size, so it takes the default of 16 and
/// the two are equal. The height keeps the ratio of `opts.default_size`.
fn viewport(self: *const Server, hint: ?[]const u8) phantom.PhysicalSize {
    const default = self.opts.default_size;
    const text = std.mem.trim(u8, hint orelse return default, " \t");
    if (text.len == 0 or text.len > 5) return default;
    const css = std.fmt.parseInt(u32, text, 10) catch return default;
    const width: f32 = @floatFromInt(std.math.clamp(css, min_width, max_width));
    return .{ .width = width, .height = @round(width * default.height / default.width) };
}

fn plain(self: *Server, request: *Request, status: std.http.Status, keep: bool) !bool {
    const text = status.phrase() orelse "";
    return self.send(request, text, .{ .status = status, .content_type = "text/plain; charset=utf-8" }, keep);
}

fn send(self: *Server, request: *Request, body: []const u8, answer: Answer, keep: bool) !bool {
    var fields: [6]std.http.Header = undefined;
    self.logAnswer(request, answer.status);
    try request.respond(body, .{
        .status = answer.status,
        .keep_alive = keep,
        .extra_headers = self.headers(&fields, answer),
    });
    return keep;
}

fn headers(self: *const Server, buf: []std.http.Header, answer: Answer) []const std.http.Header {
    var n: usize = 0;
    for ([_]std.http.Header{
        .{ .name = "content-type", .value = answer.content_type },
        .{ .name = "cache-control", .value = answer.cache },
        .{ .name = "content-security-policy", .value = self.opts.csp },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    }) |h| {
        buf[n] = h;
        n += 1;
    }
    if (answer.page) {
        buf[n] = .{ .name = "accept-ch", .value = "Sec-CH-Viewport-Width" };
        buf[n + 1] = .{ .name = "vary", .value = "Sec-CH-Viewport-Width" };
        n += 2;
    }
    return buf[0..n];
}

fn logAnswer(self: *Server, request: *const Request, status: std.http.Status) void {
    self.logLine("{s} {s} {d}", .{ @tagName(request.head.method), request.head.target, @backingInt(status) });
}

fn logLine(self: *Server, comptime fmt: []const u8, args: anytype) void {
    const w = self.opts.log orelse return;
    self.log_mutex.lockUncancelable(self.io);
    defer self.log_mutex.unlock(self.io);
    w.print(fmt ++ "\n", args) catch {};
    w.flush() catch {};
}

/// False for a path that could leave the dist directory once decoded: a "."
/// or ".." segment, an empty segment, a '\' or a NUL byte.
fn safePath(path: []const u8) bool {
    if (std.mem.indexOfAny(u8, path, "\\\x00") != null) return false;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        if (part.len == 0 and parts.index != null) return false;
    }
    return true;
}

fn isStyle(rel: []const u8) bool {
    return std.mem.startsWith(u8, rel, "page-") and std.mem.endsWith(u8, rel, ".css") and std.mem.indexOfScalar(u8, rel, '/') == null;
}

/// The host as `location.hostname` gives it: no port, lowercase. Null for a
/// value that is no host name.
fn hostName(buf: []u8, value: []const u8) ?[]const u8 {
    const name = if (value.len > 0 and value[0] == '[')
        value[0 .. (std.mem.indexOfScalar(u8, value, ']') orelse return null) + 1]
    else
        value[0 .. std.mem.indexOfScalar(u8, value, ':') orelse value.len];
    if (name.len == 0 or name.len > buf.len) return null;
    for (name, buf[0..name.len]) |c, *out| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-.[]:", c) == null) return null;
        out.* = std.ascii.toLower(c);
    }
    return buf[0..name.len];
}

fn mimeOf(path: []const u8) []const u8 {
    const types = [_]struct { []const u8, []const u8 }{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript" },
        .{ ".wasm", "application/wasm" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".otf", "font/otf" },
        .{ ".ttf", "font/ttf" },
        .{ ".woff2", "font/woff2" },
    };
    for (types) |t| {
        if (std.mem.endsWith(u8, path, t[0])) return t[1];
    }
    return "application/octet-stream";
}

/// Hashed files by path, oldest first. The oldest goes when it is full.
const Cache = struct {
    max: usize,
    map: std.StringArrayHashMapUnmanaged([]u8) = .empty,

    fn put(self: *Cache, gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
        if (self.map.contains(path)) return;
        if (self.map.count() >= self.max) {
            const oldest = self.map.keys()[0];
            const old_bytes = self.map.values()[0];
            self.map.orderedRemoveAt(0);
            gpa.free(oldest);
            gpa.free(old_bytes);
        }
        const key = try gpa.dupe(u8, path);
        errdefer gpa.free(key);
        const value = try gpa.dupe(u8, bytes);
        errdefer gpa.free(value);
        try self.map.put(gpa, key, value);
    }

    fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
        for (self.map.keys(), self.map.values()) |key, value| {
            gpa.free(key);
            gpa.free(value);
        }
        self.map.deinit(gpa);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_shell =
    \\<!DOCTYPE html>
    \\<html>
    \\  <head>
    \\    <meta charset="utf-8" />
    \\  </head>
    \\  <body>
    \\    <script type="module" src="/boot.js"></script>
    \\  </body>
    \\</html>
;

fn homePage(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.ColoredBox{ .color = phantom.Color.rgb(1, 0, 0) }).widget();
}

fn textPage(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Text{ .text = "hello" }).widget();
}

fn missingPage(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Text{ .text = "no such page" }).widget();
}

const test_routes = [_]phantom.Route{
    .{ .path = "/", .build = homePage },
    .{ .path = "/text", .build = textPage },
};

fn routerRoot(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Router{ .routes = &test_routes, .initial = "/", .not_found = missingPage }).widget();
}

const boot_js = "console.log('boot');";
const font_bytes = "not a real font";

const TestSite = struct {
    tmp: std.testing.TmpDir,
    server: Server,

    fn init(self: *TestSite, root: phantom.Root) !void {
        const io = std.testing.io;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.writeFile(io, .{ .sub_path = "boot.js", .data = boot_js });
        try self.tmp.dir.createDirPath(io, "fonts");
        try self.tmp.dir.writeFile(io, .{ .sub_path = "fonts/Mesmerize Rg.otf", .data = font_bytes });
        try self.tmp.dir.writeFile(io, .{ .sub_path = "secret", .data = "secret" });
        try self.tmp.dir.createDirPath(io, "text");
        try self.tmp.dir.writeFile(io, .{ .sub_path = "text/index.html", .data = "prerendered" });
        self.server = try .init(std.testing.allocator, io, .{
            .root = root,
            .shell = test_shell,
            .dist = self.tmp.dir,
            .default_size = .{ .width = 1280, .height = 800 },
        });
    }

    fn deinit(self: *TestSite) void {
        self.server.deinit();
        self.tmp.cleanup();
    }

    /// Send `head` as one request and return the whole answer.
    fn ask(self: *TestSite, head: []const u8) !Reply {
        var in: Io.Reader = .fixed(head);
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        errdefer out.deinit();
        var http: std.http.Server = .init(&in, &out.writer);
        _ = self.server.serveOne(&http);
        return .{ .raw = try out.toOwnedSlice() };
    }

    fn get(self: *TestSite, target: []const u8) !Reply {
        var buf: [4096]u8 = undefined;
        return self.ask(try std.fmt.bufPrint(&buf, "GET {s} HTTP/1.1\r\nhost: localhost\r\n\r\n", .{target}));
    }
};

const Reply = struct {
    raw: []u8,

    fn deinit(self: Reply) void {
        std.testing.allocator.free(self.raw);
    }

    fn status(self: Reply) u16 {
        return std.fmt.parseInt(u16, self.raw[9..12], 10) catch 0;
    }

    fn header(self: Reply, name: []const u8) ?[]const u8 {
        const end = std.mem.indexOf(u8, self.raw, "\r\n\r\n") orelse return null;
        var lines = std.mem.splitSequence(u8, self.raw[0..end], "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
        return null;
    }

    fn body(self: Reply) []const u8 {
        const end = std.mem.indexOf(u8, self.raw, "\r\n\r\n") orelse return "";
        return self.raw[end + 4 ..];
    }

    /// The stylesheet url the page links.
    fn styleUrl(self: Reply) ![]const u8 {
        const link = "<link rel=\"stylesheet\" href=\"";
        const at = (std.mem.indexOf(u8, self.body(), link) orelse return error.TestNoLink) + link.len;
        const end = std.mem.indexOfScalarPos(u8, self.body(), at, '"') orelse return error.TestNoLink;
        return self.body()[at..end];
    }
};

test "a page path renders the route with its stylesheet link, size and hint headers" {
    var site: TestSite = undefined;
    try site.init(.plain(routerRoot));
    defer site.deinit();
    const page = try site.get("/text");
    defer page.deinit();
    try std.testing.expectEqual(@as(u16, 200), page.status());
    try std.testing.expectEqualStrings("text/html; charset=utf-8", page.header("content-type").?);
    try std.testing.expectEqualStrings("Sec-CH-Viewport-Width", page.header("accept-ch").?);
    try std.testing.expectEqualStrings("Sec-CH-Viewport-Width", page.header("vary").?);
    try std.testing.expectEqualStrings(no_cache, page.header("cache-control").?);
    try std.testing.expectEqualStrings(default_csp, page.header("content-security-policy").?);
    try std.testing.expect(std.mem.indexOf(u8, page.body(), "data-phantom-size=\"1280x800\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body(), ">hello</div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body(), "prerendered") == null);
    try std.testing.expect(std.mem.startsWith(u8, try page.styleUrl(), "/page-"));
}

test "the stylesheet a page links is served after the page with a long cache" {
    var site: TestSite = undefined;
    try site.init(.plain(routerRoot));
    defer site.deinit();
    const page = try site.get("/text");
    defer page.deinit();
    const css = try site.get(try page.styleUrl());
    defer css.deinit();
    try std.testing.expectEqual(@as(u16, 200), css.status());
    try std.testing.expectEqualStrings("text/css; charset=utf-8", css.header("content-type").?);
    try std.testing.expectEqualStrings(long_cache, css.header("cache-control").?);
    try std.testing.expect(std.mem.startsWith(u8, css.body(), "html,body{"));

    const unknown = try site.get("/page-0000000000000000.css");
    defer unknown.deinit();
    try std.testing.expectEqual(@as(u16, 404), unknown.status());
}

test "a file in the dist directory is served as a file" {
    var site: TestSite = undefined;
    try site.init(.plain(routerRoot));
    defer site.deinit();
    const js = try site.get("/boot.js");
    defer js.deinit();
    try std.testing.expectEqual(@as(u16, 200), js.status());
    try std.testing.expectEqualStrings("text/javascript", js.header("content-type").?);
    try std.testing.expectEqualStrings(boot_js, js.body());

    const font = try site.get("/fonts/Mesmerize%20Rg.otf");
    defer font.deinit();
    try std.testing.expectEqual(@as(u16, 200), font.status());
    try std.testing.expectEqualStrings("font/otf", font.header("content-type").?);
    try std.testing.expectEqualStrings(font_bytes, font.body());
}

test "a path that could leave the dist directory is refused" {
    var site: TestSite = undefined;
    try site.init(.plain(routerRoot));
    defer site.deinit();
    for ([_][]const u8{
        "/../secret",
        "/fonts/../secret",
        "/%2e%2e/secret",
        "/fonts/%2E%2E%2Fsecret",
        "/fonts/..%5csecret",
        "//etc/passwd",
        "/%2Fetc/passwd",
        "/./secret",
        "/boot.js%00",
    }) |target| {
        const reply = try site.get(target);
        defer reply.deinit();
        try std.testing.expectEqual(@as(u16, 400), reply.status());
        try std.testing.expect(std.mem.indexOf(u8, reply.body(), "secret") == null);
    }
}

test "the viewport hint sets the page width and the default ratio sets its height" {
    var site: TestSite = undefined;
    try site.init(.plain(routerRoot));
    defer site.deinit();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "600", "600x375" },
        .{ "  800 ", "800x500" },
        .{ "12", "240x150" },
        .{ "99999", "7680x4800" },
        .{ "wide", "1280x800" },
        .{ "-5", "1280x800" },
        .{ "123456", "1280x800" },
    };
    for (cases) |case| {
        var buf: [256]u8 = undefined;
        const head = try std.fmt.bufPrint(&buf, "GET /text HTTP/1.1\r\nsec-ch-viewport-width: {s}\r\n\r\n", .{case[0]});
        const reply = try site.ask(head);
        defer reply.deinit();
        var want_buf: [64]u8 = undefined;
        const want = try std.fmt.bufPrint(&want_buf, "data-phantom-size=\"{s}\"", .{case[1]});
        try std.testing.expect(std.mem.indexOf(u8, reply.body(), want) != null);
    }
}

test "an unknown route answers 404 with the not found page" {
    var site: TestSite = undefined;
    try site.init(.plain(routerRoot));
    defer site.deinit();
    const reply = try site.get("/nowhere");
    defer reply.deinit();
    try std.testing.expectEqual(@as(u16, 404), reply.status());
    try std.testing.expect(std.mem.indexOf(u8, reply.body(), ">no such page</div>") != null);
    _ = try reply.styleUrl();
}

test "an address too long for the router answers 414, not the home page" {
    var site: TestSite = undefined;
    try site.init(.plain(routerRoot));
    defer site.deinit();
    const reply = try site.get("/" ++ @as([phantom.router.max_path]u8, @splat('a')));
    defer reply.deinit();
    try std.testing.expectEqual(@as(u16, 414), reply.status());

    const longest = try site.get("/" ++ @as([max_path]u8, @splat('a')));
    defer longest.deinit();
    try std.testing.expectEqual(@as(u16, 414), longest.status());
}

test "HEAD answers the headers of GET with no body" {
    var site: TestSite = undefined;
    try site.init(.plain(routerRoot));
    defer site.deinit();
    for ([_][]const u8{ "/text", "/boot.js" }) |target| {
        var buf: [128]u8 = undefined;
        const reply = try site.ask(try std.fmt.bufPrint(&buf, "HEAD {s} HTTP/1.1\r\n\r\n", .{target}));
        defer reply.deinit();
        try std.testing.expectEqual(@as(u16, 200), reply.status());
        try std.testing.expect(try std.fmt.parseInt(usize, reply.header("content-length").?, 10) > 0);
        try std.testing.expectEqual(@as(usize, 0), reply.body().len);
    }
}

test "a method other than GET or HEAD answers 405" {
    var site: TestSite = undefined;
    try site.init(.plain(routerRoot));
    defer site.deinit();
    const reply = try site.ask("POST /text HTTP/1.1\r\ncontent-length: 2\r\n\r\nhi");
    defer reply.deinit();
    try std.testing.expectEqual(@as(u16, 405), reply.status());
    try std.testing.expectEqualStrings("close", reply.header("connection").?);
}

test "a request with too many headers answers 431" {
    var site: TestSite = undefined;
    try site.init(.plain(routerRoot));
    defer site.deinit();
    var head: Io.Writer.Allocating = .init(std.testing.allocator);
    defer head.deinit();
    try head.writer.writeAll("GET /text HTTP/1.1\r\n");
    for (0..max_headers + 1) |i| try head.writer.print("x-{d}: 1\r\n", .{i});
    try head.writer.writeAll("\r\n");
    const reply = try site.ask(head.written());
    defer reply.deinit();
    try std.testing.expectEqual(@as(u16, 431), reply.status());
}

test "a path outside the base answers 404 and the base itself renders" {
    var site: TestSite = undefined;
    try site.init(.plain(homePage));
    defer site.deinit();
    site.server.opts.base = "/app/";
    const outside = try site.get("/other");
    defer outside.deinit();
    try std.testing.expectEqual(@as(u16, 404), outside.status());
    for ([_][]const u8{ "/app", "/app/" }) |target| {
        const page = try site.get(target);
        defer page.deinit();
        try std.testing.expectEqual(@as(u16, 200), page.status());
        try std.testing.expect(std.mem.startsWith(u8, try page.styleUrl(), "/app/page-"));
    }
}

test "the host reads like location.hostname" {
    var buf: [Io.net.HostName.max_len]u8 = undefined;
    try std.testing.expectEqualStrings("example.com", hostName(&buf, "Example.COM:8080").?);
    try std.testing.expectEqualStrings("example.com", hostName(&buf, "example.com").?);
    try std.testing.expectEqualStrings("[::1]", hostName(&buf, "[::1]:8080").?);
    try std.testing.expect(hostName(&buf, "bad host") == null);
    try std.testing.expect(hostName(&buf, ":80") == null);
    try std.testing.expect(hostName(&buf, "[::1") == null);
}

fn hostQueryPage(b: *phantom.BuildContext) phantom.Widget {
    var host_buf: [64]u8 = undefined;
    var query_buf: [64]u8 = undefined;
    const host = b.owner.platform.readHost(&host_buf) orelse "";
    const query = b.owner.platform.readQuery(&query_buf) orelse "";
    const text = std.mem.concat(b.arena, u8, &.{ host, "|", query }) catch "";
    return b.new(phantom.Text{ .text = text }).widget();
}

test "the host and query of the request reach the tree" {
    var site: TestSite = undefined;
    try site.init(.plain(hostQueryPage));
    defer site.deinit();
    const reply = try site.ask("GET /?tab=2 HTTP/1.1\r\nHost: Example.COM:8080\r\n\r\n");
    defer reply.deinit();
    try std.testing.expect(std.mem.indexOf(u8, reply.body(), ">example.com|tab=2</div>") != null);
}

const FontPage = struct {
    font: phantom.text.Font,

    fn build(b: *phantom.BuildContext, self: *@This()) phantom.Widget {
        return b.new(phantom.Text{ .text = "hi", .font = &self.font }).widget();
    }
};

test "a font with no url is kept once and served from memory" {
    const gpa = std.testing.allocator;
    var fixture: FontPage = .{ .font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes) };
    defer fixture.font.deinit(gpa);
    var site: TestSite = undefined;
    try site.init(.of(FontPage, FontPage.build, &fixture));
    defer site.deinit();

    for (0..2) |_| {
        const page = try site.get("/");
        page.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), site.server.fonts.map.count());
    const path = site.server.fonts.map.keys()[0];
    try std.testing.expect(std.mem.startsWith(u8, path, "fonts/pf-"));

    var url_buf: [64]u8 = undefined;
    const font = try site.get(try std.fmt.bufPrint(&url_buf, "/{s}", .{path}));
    defer font.deinit();
    try std.testing.expectEqual(@as(u16, 200), font.status());
    try std.testing.expectEqualStrings(long_cache, font.header("cache-control").?);
    try std.testing.expectEqualSlices(u8, phantom.text.builtin.neuropol_bytes, font.body());
}

test "the stylesheet cache drops its oldest entry when full" {
    const gpa = std.testing.allocator;
    var cache: Cache = .{ .max = 2 };
    defer cache.deinit(gpa);
    try cache.put(gpa, "a", "1");
    try cache.put(gpa, "b", "2");
    try cache.put(gpa, "a", "x");
    try cache.put(gpa, "c", "3");
    try std.testing.expect(cache.map.get("a") == null);
    try std.testing.expectEqualStrings("2", cache.map.get("b").?);
    try std.testing.expectEqualStrings("3", cache.map.get("c").?);
}

test "the server answers over a socket on a port the system picks" {
    const io = std.testing.io;
    var site: TestSite = undefined;
    try site.init(.plain(routerRoot));
    defer site.deinit();

    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    var serving = try io.concurrent(serve, .{ &site.server, &listener });
    defer serving.cancel(io) catch {};

    const stream = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var out_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    try writer.interface.writeAll("GET /text HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n");
    try writer.interface.flush();
    var in_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    const raw = try reader.interface.allocRemaining(std.testing.allocator, .limited(1 << 20));
    const reply: Reply = .{ .raw = raw };
    defer reply.deinit();
    try std.testing.expectEqual(@as(u16, 200), reply.status());
    try std.testing.expect(std.mem.indexOf(u8, reply.body(), ">hello</div>") != null);
}

test "an app with hash routes renders the base route at every path" {
    var site: TestSite = undefined;
    try site.init(.plain(routerRoot));
    defer site.deinit();
    site.server.opts.hash_routes = true;
    const reply = try site.get("/text");
    defer reply.deinit();
    try std.testing.expectEqual(@as(u16, 200), reply.status());
    try std.testing.expect(std.mem.indexOf(u8, reply.body(), "hello") == null);
}
