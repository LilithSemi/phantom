//! An http server for one web app. A request for a file in the dist directory
//! gets that file. Any other path under the base is a page: the server renders
//! it with `ssr.render` at the size the browser reports. A missing file with an
//! extension the server knows, such as "favicon.ico", gets 404 and no render.
//! So does a route that ends in ".html".
//!
//! Every request renders fresh, also for a route the build prerendered. A
//! prerendered page has the default size only, and a fresh page has the size,
//! query and host of the request.
//!
//! The stylesheet link of a page carries the inputs of its render in its
//! query: the width, the path and the query of the page. The server keeps
//! recent stylesheets in memory, and on a miss it renders the page again from
//! those inputs, so a page it sent never links to a missing stylesheet.
//!
//! The server follows symbolic links inside the dist directory, because that
//! directory is build output. Every answer carries `Options.csp`. The default
//! allows requests to the site itself only (`connect-src 'self'`), so an app
//! that talks to another origin must set its own policy.
//!
//! A widget that panics during a render stops the whole process. When the
//! server faces the internet, put it behind a reverse proxy and restart it
//! when it stops.

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
styles: Cache = .{ .max_bytes = max_style_bytes, .evict = true },
fonts: Cache = .{ .max_bytes = max_font_bytes, .evict = false },
/// The fonts the cache refused, so the log gets each one once.
unkept_fonts: std.StringArrayHashMapUnmanaged(void) = .empty,
log_mutex: Io.Mutex = .init,
connections: std.atomic.Value(u32) = .init(0),
/// Connections closed early because the server was full or could not start
/// a task for them.
refused: std.atomic.Value(u64) = .init(0),

pub const Options = struct {
    root: phantom.Root,
    /// The page shell `addApp` writes as shell.html, with no prerendered
    /// content in it. With "/" prerendered, index.html is a page and no shell.
    shell: []const u8,
    dist: Io.Dir,
    base: []const u8 = "/",
    /// The page size for a request with no viewport hint, in phantom px.
    default_size: phantom.PhysicalSize,
    /// The Content-Security-Policy of every answer.
    csp: []const u8 = default_csp,
    /// The time the server waits for the whole head of a request. On a
    /// keep-alive connection it starts again for each request, so an idle
    /// connection closes after this time.
    idle_timeout: Io.Duration = .fromSeconds(10),
    /// The time one write to the client can wait with no progress. It starts
    /// again on each write, so a slow client that keeps reading gets the whole
    /// answer. The render has no limit: it has no point where it can stop.
    write_timeout: Io.Duration = .fromSeconds(10),
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
const max_style_bytes = 16 * 1024 * 1024;
/// Fonts stay until the server stops, because a font url carries no render
/// inputs to make the file again. An app has a fixed set of fonts.
const max_font_bytes = 64 * 1024 * 1024;
const max_requests_per_connection = 1000;

/// The viewport hint is in css px. Bounds keep a false hint from asking for a
/// huge layout.
pub const min_width = 240;
pub const max_width = 7680;

pub fn init(gpa: std.mem.Allocator, io: Io, opts: Options) error{ InvalidBase, InvalidSize }!Server {
    if (!dom.validBase(opts.base)) return error.InvalidBase;
    const width = opts.default_size.width;
    const height = opts.default_size.height;
    if (!(width > 0 and height > 0 and std.math.isFinite(width) and std.math.isFinite(height))) {
        return error.InvalidSize;
    }
    return .{ .gpa = gpa, .io = io, .opts = opts };
}

pub fn deinit(self: *Server) void {
    self.styles.deinit(self.gpa);
    self.fonts.deinit(self.gpa);
    for (self.unkept_fonts.keys()) |path| self.gpa.free(path);
    self.unkept_fonts.deinit(self.gpa);
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

/// The connection task watches the deadline while a second task serves the
/// requests. When the deadline passes, the watcher cancels the server task,
/// which interrupts its blocked read or write.
fn serveConnection(self: *Server, stream: Io.net.Stream) Io.Cancelable!void {
    defer {
        stream.close(self.io);
        _ = self.connections.fetchSub(1, .monotonic);
    }
    var watch: Watch = .{};
    watch.extend(self.io, self.opts.idle_timeout);
    var work = self.io.concurrent(runConnection, .{ self, stream, &watch }) catch {
        _ = self.refused.fetchAdd(1, .monotonic);
        return;
    };
    defer work.cancel(self.io);
    while (!watch.done.isSet()) {
        const deadline = watch.deadline.load(.acquire);
        const now = Watch.now(self.io);
        if (deadline != Watch.never and now >= deadline) return;
        const wait = if (deadline == Watch.never) std.time.ns_per_s else deadline - now;
        watch.done.waitTimeout(self.io, .{ .duration = .{ .raw = .fromNanoseconds(wait), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
    }
}

fn runConnection(self: *Server, stream: Io.net.Stream, watch: *Watch) void {
    defer watch.done.set(self.io);
    var in_buf: [max_head]u8 = undefined;
    var out_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(self.io, &in_buf);
    var socket = stream.writer(self.io, &.{});
    var out: Progress = .{
        .interface = .{ .vtable = &.{ .drain = Progress.drain }, .buffer = &out_buf },
        .inner = &socket.interface,
        .watch = watch,
        .io = self.io,
        .timeout = self.opts.write_timeout,
    };
    var http: std.http.Server = .init(&reader.interface, &out.interface);
    for (0..max_requests_per_connection) |_| {
        watch.extend(self.io, self.opts.idle_timeout);
        if (!self.serveOne(&http, watch)) return;
    }
}

/// The time on the awake clock after which the watcher closes a connection.
const Watch = struct {
    deadline: std.atomic.Value(i64) = .init(never),
    done: Io.Event = .unset,

    const never = std.math.maxInt(i64);

    fn now(io: Io) i64 {
        return @intCast(Io.Clock.awake.now(io).toNanoseconds());
    }

    fn extend(self: *Watch, io: Io, duration: Io.Duration) void {
        self.deadline.store(now(io) +| @as(i64, @intCast(duration.toNanoseconds())), .release);
    }

    fn clear(self: *Watch) void {
        self.deadline.store(never, .release);
    }
};

/// A writer that moves the deadline on before each write to the socket.
const Progress = struct {
    interface: Io.Writer,
    inner: *Io.Writer,
    watch: *Watch,
    io: Io,
    timeout: Io.Duration,

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Progress = @alignCast(@fieldParentPtr("interface", w));
        self.watch.extend(self.io, self.timeout);
        const n = try self.inner.writeSplatHeader(w.buffered(), data, splat);
        return w.consume(n);
    }
};

/// Read one request from `http` and answer it. Returns whether the
/// connection stays open. With `watch`, the deadline stops once the head is
/// in, because the render has no limit, and the writes move it on.
fn serveOne(self: *Server, http: *std.http.Server, watch: ?*Watch) bool {
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
    if (watch) |w| w.clear();
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

/// The request inputs a page renders from.
const PageInputs = struct {
    /// The raw path of the request, still percent encoded, as
    /// `location.pathname` gives it.
    path: []const u8,
    query: ?[]const u8,
    host: ?[]const u8,
    width: u32,
};

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

    var host_buf: [Io.net.HostName.max_len]u8 = undefined;
    const host_name = if (host) |h| hostName(&host_buf, h) else null;

    if (rel.len > 0 and rel[rel.len - 1] != '/') {
        // A ':' can name a drive on Windows, so such a path is a page only.
        if (std.mem.indexOfScalar(u8, rel, ':') == null) {
            if (try self.serveFile(request, rel, keep)) return keep;
        }
        if (isStyle(rel)) return self.serveStyle(request, rel, query orelse "", host_name, keep);
        if (std.mem.startsWith(u8, rel, "fonts/pf-")) return self.serveFont(request, rel, keep);
        // A missing file of a known type, such as favicon.ico, is no page.
        // A route such as "/v1.2" renders.
        if (fileType(rel) != null) return self.plain(request, .not_found, keep);
    }

    return self.servePage(request, .{
        .path = if (self.opts.hash_routes) base else raw_path,
        .query = query,
        .host = host_name,
        .width = self.hintWidth(hint),
    }, keep);
}

fn render(self: *Server, inputs: PageInputs) !ssr.Document {
    return ssr.render(self.gpa, .{
        .root = self.opts.root,
        .path = inputs.path,
        .viewport = self.size(inputs.width),
        .base = self.opts.base,
        .query = inputs.query,
        .host = inputs.host,
        .io = self.io,
        .known_fonts = .{ .ctx = self, .contains = knownFont },
    });
}

fn servePage(self: *Server, request: *Request, inputs: PageInputs, keep: bool) !bool {
    var doc = self.render(inputs) catch return self.plain(request, .internal_server_error, false);
    defer doc.deinit(self.gpa);
    self.keepAssets(doc);

    var link: Io.Writer.Allocating = .init(self.gpa);
    defer link.deinit();
    var html: Io.Writer.Allocating = .init(self.gpa);
    defer html.deinit();
    writeStyleQuery(&link.writer, inputs) catch return self.plain(request, .internal_server_error, false);
    doc.writeHtmlQuery(&html.writer, self.opts.shell, link.written()) catch return self.plain(request, .internal_server_error, false);

    const status: std.http.Status = switch (doc.status) {
        .ok => .ok,
        .not_found => .not_found,
        .location_too_long => .uri_too_long,
        .failed => .internal_server_error,
    };
    return self.send(request, html.written(), .{ .status = status, .content_type = "text/html; charset=utf-8", .page = true }, keep);
}

/// The query of a stylesheet link: "w=<width>&p=<path>" and "&q=<query>"
/// when the page has one, each value percent encoded and each '&' written as
/// "&amp;" for the attribute.
fn writeStyleQuery(w: *Io.Writer, inputs: PageInputs) Io.Writer.Error!void {
    try w.print("w={d}&amp;p=", .{inputs.width});
    try writeEncoded(w, inputs.path);
    if (inputs.query) |q| {
        try w.writeAll("&amp;q=");
        try writeEncoded(w, q);
    }
}

fn writeEncoded(w: *Io.Writer, value: []const u8) Io.Writer.Error!void {
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~/", c) != null) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

/// Serve a page stylesheet. A miss renders the page again from the inputs in
/// `query` and the host of this request, and serves the result only when its
/// name is the one asked for.
fn serveStyle(self: *Server, request: *Request, rel: []const u8, query: []const u8, host: ?[]const u8, keep: bool) !bool {
    if (try self.serveCached(request, &self.styles, rel, "text/css; charset=utf-8", keep)) return keep;

    var width: ?u32 = null;
    var path: ?[]u8 = null;
    var page_query: ?[]u8 = null;
    defer if (path) |p| self.gpa.free(p);
    defer if (page_query) |q| self.gpa.free(q);
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = field[0..eq];
        const value = field[eq + 1 ..];
        if (std.mem.eql(u8, key, "w")) width = parseWidth(value);
        if (std.mem.eql(u8, key, "p") and path == null) path = try decoded(self.gpa, value);
        if (std.mem.eql(u8, key, "q") and page_query == null) page_query = try decoded(self.gpa, value);
    }
    const page_path = path orelse return self.plain(request, .not_found, keep);
    if (page_path.len == 0 or page_path[0] != '/' or page_path.len > max_path or !safePath(page_path)) {
        return self.plain(request, .not_found, keep);
    }

    var doc = self.render(.{
        .path = page_path,
        .query = page_query,
        .host = host,
        .width = width orelse return self.plain(request, .not_found, keep),
    }) catch return self.plain(request, .internal_server_error, false);
    defer doc.deinit(self.gpa);
    self.keepAssets(doc);
    if (!std.mem.eql(u8, doc.css_path, rel)) return self.plain(request, .not_found, keep);
    return self.send(request, doc.css, .{ .status = .ok, .content_type = "text/css; charset=utf-8", .cache = long_cache }, keep);
}

fn decoded(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    var buf: [max_head]u8 = undefined;
    if (value.len > buf.len) return error.TooLong;
    @memcpy(buf[0..value.len], value);
    return gpa.dupe(u8, std.Uri.percentDecodeInPlace(buf[0..value.len]));
}

fn serveFont(self: *Server, request: *Request, rel: []const u8, keep: bool) !bool {
    if (try self.serveCached(request, &self.fonts, rel, "font/otf", keep)) return keep;
    return self.plain(request, .not_found, keep);
}

/// Serve `rel` from the dist directory. Returns false when it is no file there.
fn serveFile(self: *Server, request: *Request, rel: []const u8, keep: bool) !bool {
    const file = self.opts.dist.openFile(self.io, rel, .{}) catch return false;
    defer file.close(self.io);
    const stat = file.stat(self.io) catch return false;
    if (stat.kind != .file) return false;

    const cache = if (isStyle(rel) or std.mem.startsWith(u8, rel, "fonts/pf-")) long_cache else no_cache;
    var fields: [7]std.http.Header = undefined;
    const answer: Answer = .{ .status = .ok, .content_type = fileType(rel) orelse "application/octet-stream", .cache = cache };
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

/// Serve `rel` from `cache`. Returns false on a miss.
fn serveCached(self: *Server, request: *Request, cache: *Cache, rel: []const u8, content_type: []const u8, keep: bool) !bool {
    const bytes = blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const held = cache.map.get(rel) orelse return false;
        // A copy, so the lock is not held while a slow client reads.
        break :blk self.gpa.dupe(u8, held) catch return false;
    };
    defer self.gpa.free(bytes);
    _ = try self.send(request, bytes, .{ .status = .ok, .content_type = content_type, .cache = long_cache }, keep);
    return true;
}

fn knownFont(ctx: *anyopaque, path: []const u8) bool {
    const self: *Server = @ptrCast(@alignCast(ctx));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.fonts.map.contains(path);
}

/// Keep the stylesheet and new fonts of `doc`. A stylesheet that is not kept
/// is made again on request. A font that is not kept goes to the log.
fn keepAssets(self: *Server, doc: ssr.Document) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.styles.put(self.gpa, doc.css_path, doc.css) catch {};
    for (doc.fonts) |font| {
        self.fonts.put(self.gpa, font.path, font.bytes) catch {
            if (self.unkept_fonts.contains(font.path)) continue;
            const path = self.gpa.dupe(u8, font.path) catch continue;
            self.unkept_fonts.put(self.gpa, path, {}) catch {
                self.gpa.free(path);
                continue;
            };
            self.logLine("font {s} not kept", .{font.path});
        };
    }
}

/// The width of a viewport hint, or the default width.
fn hintWidth(self: *const Server, hint: ?[]const u8) u32 {
    const default: u32 = @intFromFloat(self.opts.default_size.width);
    return parseWidth(std.mem.trim(u8, hint orelse return default, " \t")) orelse default;
}

/// A width of 1 to 5 decimal digits, clamped to the bounds.
fn parseWidth(text: []const u8) ?u32 {
    if (text.len == 0 or text.len > 5) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    const css = std.fmt.parseInt(u32, text, 10) catch return null;
    return std.math.clamp(css, min_width, max_width);
}

/// The page size for a width from the viewport hint. The hint is in css px
/// and phantom lays out in phantom px, css px times 16 over the root font
/// size. The server cannot know the root font size, so it takes the default
/// of 16 and the two are equal. The height keeps the ratio of
/// `opts.default_size`.
fn size(self: *const Server, width: u32) phantom.PhysicalSize {
    const default = self.opts.default_size;
    const w: f32 = @floatFromInt(width);
    return .{ .width = w, .height = @round(w * default.height / default.width) };
}

fn plain(self: *Server, request: *Request, status: std.http.Status, keep: bool) !bool {
    const text = status.phrase() orelse "";
    return self.send(request, text, .{ .status = status, .content_type = "text/plain; charset=utf-8" }, keep);
}

fn send(self: *Server, request: *Request, body: []const u8, answer: Answer, keep: bool) !bool {
    var fields: [7]std.http.Header = undefined;
    self.logAnswer(request, answer.status);
    try request.respond(body, .{
        .status = answer.status,
        .keep_alive = keep,
        .extra_headers = self.headers(&fields, answer),
    });
    return keep;
}

fn headers(self: *const Server, buf: []std.http.Header, answer: Answer) []const std.http.Header {
    const common = [_]std.http.Header{
        .{ .name = "content-type", .value = answer.content_type },
        .{ .name = "cache-control", .value = answer.cache },
        .{ .name = "content-security-policy", .value = self.opts.csp },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    };
    // Critical-CH makes Chromium load a first visit again with the hint.
    const page = [_]std.http.Header{
        .{ .name = "accept-ch", .value = "Sec-CH-Viewport-Width" },
        .{ .name = "critical-ch", .value = "Sec-CH-Viewport-Width" },
        .{ .name = "vary", .value = "Sec-CH-Viewport-Width" },
    };
    @memcpy(buf[0..common.len], &common);
    if (!answer.page) return buf[0..common.len];
    @memcpy(buf[common.len..][0..page.len], &page);
    return buf[0 .. common.len + page.len];
}

fn logAnswer(self: *Server, request: *const Request, status: std.http.Status) void {
    self.logLine("{s} {f} {d}", .{ @tagName(request.head.method), Escaped{ .bytes = request.head.target }, @backingInt(status) });
}

fn logLine(self: *Server, comptime fmt: []const u8, args: anytype) void {
    const w = self.opts.log orelse return;
    self.log_mutex.lockUncancelable(self.io);
    defer self.log_mutex.unlock(self.io);
    w.print(fmt ++ "\n", args) catch {};
    w.flush() catch {};
}

/// Prints bytes with each control or non-ASCII byte as `\xNN`, so a request
/// cannot write terminal escapes into the log.
const Escaped = struct {
    bytes: []const u8,

    pub fn format(self: Escaped, w: *Io.Writer) Io.Writer.Error!void {
        for (self.bytes) |c| {
            if (c < 0x20 or c >= 0x7f or c == '\\') {
                try w.print("\\x{x:0>2}", .{c});
            } else {
                try w.writeByte(c);
            }
        }
    }
};

/// False for a path that could leave the dist directory once decoded: a "."
/// or ".." segment, an empty segment, a '\' or a NUL byte. A ':' can name a
/// drive on Windows, so `handle` also keeps a path with one away from files.
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
/// value that is no host name: a name of letters, digits, '-' and '.', or an
/// IPv6 address in brackets, then an optional ':' and port digits.
fn hostName(buf: []u8, value: []const u8) ?[]const u8 {
    var name: []const u8 = undefined;
    if (value.len > 0 and value[0] == '[') {
        const close = std.mem.indexOfScalar(u8, value, ']') orelse return null;
        name = value[0 .. close + 1];
        if (name.len == 2) return null;
        for (name[1 .. name.len - 1]) |c| {
            if (!std.ascii.isHex(c) and c != ':' and c != '.') return null;
        }
    } else {
        name = value[0 .. std.mem.indexOfScalar(u8, value, ':') orelse value.len];
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '.') return null;
        }
    }
    const port = value[name.len..];
    if (port.len > 0) {
        if (port[0] != ':' or port.len == 1) return null;
        for (port[1..]) |c| if (!std.ascii.isDigit(c)) return null;
    }
    if (name.len == 0 or name.len > buf.len) return null;
    for (name, buf[0..name.len]) |c, *out| out.* = std.ascii.toLower(c);
    return buf[0..name.len];
}

/// The content type of a file name, or null for an extension this server
/// does not know. The case of the extension does not matter. A missing file
/// of a known type answers 404 with no render, so a route that ends in
/// ".html" answers 404.
fn fileType(path: []const u8) ?[]const u8 {
    const types = [_]struct { []const u8, []const u8 }{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript" },
        .{ ".mjs", "text/javascript" },
        .{ ".map", "application/json" },
        .{ ".wasm", "application/wasm" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".xml", "application/xml" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".ico", "image/x-icon" },
        .{ ".otf", "font/otf" },
        .{ ".ttf", "font/ttf" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
    };
    for (types) |t| {
        if (std.ascii.endsWithIgnoreCase(path, t[0])) return t[1];
    }
    return null;
}

/// Hashed files by path, oldest first, bounded by their total size. With
/// `evict` the oldest go to make room, else a new file is refused.
const Cache = struct {
    max_bytes: usize,
    evict: bool,
    bytes: usize = 0,
    map: std.StringArrayHashMapUnmanaged([]u8) = .empty,

    fn put(self: *Cache, gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
        if (self.map.contains(path)) return;
        if (bytes.len > self.max_bytes) return error.TooLarge;
        if (!self.evict and self.bytes + bytes.len > self.max_bytes) return error.Full;
        while (self.bytes + bytes.len > self.max_bytes) {
            const oldest = self.map.keys()[0];
            const old_bytes = self.map.values()[0];
            self.map.orderedRemoveAt(0);
            self.bytes -= old_bytes.len;
            gpa.free(oldest);
            gpa.free(old_bytes);
        }
        const key = try gpa.dupe(u8, path);
        errdefer gpa.free(key);
        const value = try gpa.dupe(u8, bytes);
        errdefer gpa.free(value);
        try self.map.put(gpa, key, value);
        self.bytes += value.len;
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
        _ = self.server.serveOne(&http, null);
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

    /// The stylesheet url the page links, with "&amp;" read as '&'.
    fn styleUrl(self: Reply, buf: []u8) ![]const u8 {
        const link = "<link rel=\"stylesheet\" href=\"";
        const at = (std.mem.indexOf(u8, self.body(), link) orelse return error.TestNoLink) + link.len;
        const end = std.mem.indexOfScalarPos(u8, self.body(), at, '"') orelse return error.TestNoLink;
        const n = std.mem.replace(u8, self.body()[at..end], "&amp;", "&", buf);
        return buf[0 .. end - at - n * 4];
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
    try std.testing.expectEqualStrings("Sec-CH-Viewport-Width", page.header("critical-ch").?);
    try std.testing.expectEqualStrings(no_cache, page.header("cache-control").?);
    try std.testing.expectEqualStrings(default_csp, page.header("content-security-policy").?);
    try std.testing.expect(std.mem.indexOf(u8, page.body(), "data-phantom-size=\"1280x800\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body(), ">hello</div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body(), "prerendered") == null);
    var url_buf: [1024]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try page.styleUrl(&url_buf), "/page-"));
}

test "the stylesheet a page links is served after the page with a long cache" {
    var site: TestSite = undefined;
    try site.init(.plain(routerRoot));
    defer site.deinit();
    const page = try site.get("/text");
    defer page.deinit();
    var url_buf: [1024]u8 = undefined;
    const css = try site.get(try page.styleUrl(&url_buf));
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
    // A drive is never a file, so these are pages.
    for ([_][]const u8{ "/C:/secret", "/C%3A/secret" }) |target| {
        const reply = try site.get(target);
        defer reply.deinit();
        try std.testing.expectEqual(@as(u16, 404), reply.status());
        try std.testing.expect(std.mem.indexOf(u8, reply.body(), ">no such page</div>") != null);
    }
}

fn pathPage(b: *phantom.BuildContext) phantom.Widget {
    var buf: [256]u8 = undefined;
    const path = b.owner.platform.readLocation(&buf) orelse "";
    return b.new(phantom.Text{ .text = b.arena.dupe(u8, path) catch "" }).widget();
}

test "a page path with a ':' or a '.' renders the page" {
    var site: TestSite = undefined;
    try site.init(.plain(pathPage));
    defer site.deinit();
    for ([_][]const u8{ "/time/12:00", "/v1.2", "/docs/v1.2", "/a.b/c" }) |target| {
        const reply = try site.get(target);
        defer reply.deinit();
        try std.testing.expectEqual(@as(u16, 200), reply.status());
        var want_buf: [64]u8 = undefined;
        const want = try std.fmt.bufPrint(&want_buf, ">{s}</div>", .{target});
        try std.testing.expect(std.mem.indexOf(u8, reply.body(), want) != null);
    }
}

test "a default size that is not positive and finite is refused" {
    const io = std.testing.io;
    for ([_]phantom.PhysicalSize{
        .{ .width = 0, .height = 800 },
        .{ .width = 1280, .height = -1 },
        .{ .width = std.math.nan(f32), .height = 800 },
        .{ .width = 1280, .height = std.math.inf(f32) },
    }) |default_size| {
        try std.testing.expectError(error.InvalidSize, Server.init(std.testing.allocator, io, .{
            .root = .plain(homePage),
            .shell = test_shell,
            .dist = std.Io.Dir.cwd(),
            .default_size = default_size,
        }));
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
        .{ "+600", "1280x800" },
        .{ "6_00", "1280x800" },
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
    var url_buf: [1024]u8 = undefined;
    _ = try reply.styleUrl(&url_buf);
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
        var url_buf: [1024]u8 = undefined;
        try std.testing.expect(std.mem.startsWith(u8, try page.styleUrl(&url_buf), "/app/page-"));
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
    try std.testing.expect(hostName(&buf, "[::1]x") == null);
    try std.testing.expect(hostName(&buf, "[::1]:") == null);
    try std.testing.expect(hostName(&buf, "a[b]") == null);
    try std.testing.expect(hostName(&buf, "a:b:c") == null);
    try std.testing.expect(hostName(&buf, "a:80x") == null);
    try std.testing.expect(hostName(&buf, "[g::1]") == null);
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

test "the stylesheet cache drops its oldest entries to stay under its size" {
    const gpa = std.testing.allocator;
    var cache: Cache = .{ .max_bytes = 4, .evict = true };
    defer cache.deinit(gpa);
    try cache.put(gpa, "a", "11");
    try cache.put(gpa, "b", "2");
    try cache.put(gpa, "a", "xx");
    try cache.put(gpa, "c", "33");
    try std.testing.expect(cache.map.get("a") == null);
    try std.testing.expectEqualStrings("2", cache.map.get("b").?);
    try std.testing.expectEqualStrings("33", cache.map.get("c").?);
    try std.testing.expectEqual(@as(usize, 3), cache.bytes);
    try std.testing.expectError(error.TooLarge, cache.put(gpa, "d", "55555"));

    var fonts: Cache = .{ .max_bytes = 4, .evict = false };
    defer fonts.deinit(gpa);
    try fonts.put(gpa, "a", "111");
    try std.testing.expectError(error.Full, fonts.put(gpa, "b", "22"));
    try std.testing.expect(fonts.map.get("a") != null);
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

test "a missing file with an extension answers 404 and renders no page" {
    var site: TestSite = undefined;
    try site.init(.plain(routerRoot));
    defer site.deinit();
    for ([_][]const u8{ "/favicon.ico", "/FAVICON.ICO", "/robots.txt", "/missing.js", "/fonts/none.otf", "/a/b.Png", "/x.wasm", "/C:/x.css", "/about.html" }) |target| {
        const reply = try site.get(target);
        defer reply.deinit();
        try std.testing.expectEqual(@as(u16, 404), reply.status());
        try std.testing.expectEqualStrings("text/plain; charset=utf-8", reply.header("content-type").?);
    }
}

test "a stylesheet that left the cache is made again from the inputs in its url" {
    var site: TestSite = undefined;
    try site.init(.plain(hostQueryPage));
    defer site.deinit();
    const page = try site.ask("GET /?tab=a%20b HTTP/1.1\r\nhost: example.com\r\nsec-ch-viewport-width: 600\r\n\r\n");
    defer page.deinit();
    var url_buf: [1024]u8 = undefined;
    const url = try page.styleUrl(&url_buf);
    try std.testing.expect(std.mem.indexOf(u8, url, "?w=600&p=/&q=tab%3Da%2520b") != null);

    const name = url[1..std.mem.indexOfScalar(u8, url, '?').?];
    const want = try std.testing.allocator.dupe(u8, site.server.styles.map.get(name).?);
    defer std.testing.allocator.free(want);
    site.server.styles.deinit(std.testing.allocator);
    site.server.styles = .{ .max_bytes = max_style_bytes, .evict = true };

    var head_buf: [1024]u8 = undefined;
    const again = try site.ask(try std.fmt.bufPrint(&head_buf, "GET {s} HTTP/1.1\r\nhost: example.com\r\n\r\n", .{url}));
    defer again.deinit();
    try std.testing.expectEqual(@as(u16, 200), again.status());
    try std.testing.expectEqualStrings(long_cache, again.header("cache-control").?);
    try std.testing.expectEqualStrings(want, again.body());

    // Other inputs make another stylesheet, so the name does not match.
    site.server.styles.deinit(std.testing.allocator);
    site.server.styles = .{ .max_bytes = max_style_bytes, .evict = true };
    const other = try site.ask(try std.fmt.bufPrint(&head_buf, "GET /{s}?w=900&p=/ HTTP/1.1\r\nhost: example.com\r\n\r\n", .{name}));
    defer other.deinit();
    try std.testing.expectEqual(@as(u16, 404), other.status());
}

test "a stylesheet miss with a bad width or page path answers 404" {
    var site: TestSite = undefined;
    try site.init(.plain(routerRoot));
    defer site.deinit();
    for ([_][]const u8{
        "/page-0000000000000000.css?w=600",
        "/page-0000000000000000.css?p=/text",
        "/page-0000000000000000.css?w=wide&p=/text",
        "/page-0000000000000000.css?w=600&p=text",
        "/page-0000000000000000.css?w=600&p=",
        "/page-0000000000000000.css?w=600&p=/../secret",
        "/page-0000000000000000.css?w=600&p=%2F..%2Fsecret",
        "/page-0000000000000000.css?w=600&p=/a//b",
        "/page-0000000000000000.css?w=600&p=/a%5Cb",
        "/page-0000000000000000.css?w=600&p=/a%00",
    }) |target| {
        const reply = try site.get(target);
        defer reply.deinit();
        try std.testing.expectEqual(@as(u16, 404), reply.status());
        try std.testing.expectEqualStrings("text/plain; charset=utf-8", reply.header("content-type").?);
    }
}

test "a font the cache refuses goes to the log once" {
    const gpa = std.testing.allocator;
    var fixture: FontPage = .{ .font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes) };
    defer fixture.font.deinit(gpa);
    var site: TestSite = undefined;
    try site.init(.of(FontPage, FontPage.build, &fixture));
    defer site.deinit();
    site.server.fonts.max_bytes = 1;
    var log: Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    site.server.opts.log = &log.writer;

    for (0..3) |_| {
        const page = try site.get("/");
        page.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), site.server.fonts.map.count());
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, log.written(), "not kept"));
}

test "the log prints control bytes of a target as escapes" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{Escaped{ .bytes = "/a\x1b[2Jb\\\x7f" }});
    try std.testing.expectEqualStrings("/a\\x1b[2Jb\\x5c\\x7f", out.written());
}

/// A server on a port the system picks, served by a task of its own.
const LiveSite = struct {
    site: TestSite,
    listener: Io.net.Server,
    serving: Io.Future(Io.Cancelable!void),

    fn start(self: *LiveSite, timeout: Io.Duration) !void {
        const io = std.testing.io;
        try self.site.init(.plain(routerRoot));
        errdefer self.site.deinit();
        self.site.server.opts.idle_timeout = timeout;
        self.site.server.opts.write_timeout = timeout;
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        self.listener = try address.listen(io, .{});
        errdefer self.listener.deinit(io);
        self.serving = try io.concurrent(serve, .{ &self.site.server, &self.listener });
    }

    fn stop(self: *LiveSite) void {
        const io = std.testing.io;
        self.serving.cancel(io) catch {};
        self.listener.deinit(io);
        self.site.deinit();
    }

    fn connect(self: *LiveSite) !Io.net.Stream {
        return self.listener.socket.address.connect(std.testing.io, .{ .mode = .stream });
    }
};

fn sendAll(stream: Io.net.Stream, bytes: []const u8) !void {
    var buf: [256]u8 = undefined;
    var writer = stream.writer(std.testing.io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn elapsedMs(from: Io.Timestamp) i64 {
    return from.durationTo(Io.Clock.awake.now(std.testing.io)).toMilliseconds();
}

test "the server answers over a socket on a port the system picks" {
    var live: LiveSite = undefined;
    try live.start(.fromSeconds(10));
    defer live.stop();
    const stream = try live.connect();
    defer stream.close(std.testing.io);
    try sendAll(stream, "GET /text HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n");
    var in_buf: [4096]u8 = undefined;
    var reader = stream.reader(std.testing.io, &in_buf);
    const raw = try reader.interface.allocRemaining(std.testing.allocator, .limited(1 << 20));
    const reply: Reply = .{ .raw = raw };
    defer reply.deinit();
    try std.testing.expectEqual(@as(u16, 200), reply.status());
    try std.testing.expect(std.mem.indexOf(u8, reply.body(), ">hello</div>") != null);
}

test "a slow reader that keeps reading gets the whole answer" {
    const io = std.testing.io;
    var live: LiveSite = undefined;
    try live.start(.fromMilliseconds(300));
    defer live.stop();
    const big_len = 24 * 1024 * 1024;
    const big = try std.testing.allocator.alloc(u8, big_len);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try live.site.tmp.dir.writeFile(io, .{ .sub_path = "big.bin", .data = big });

    const stream = try live.connect();
    defer stream.close(io);
    const start = Io.Clock.awake.now(io);
    try sendAll(stream, "GET /big.bin HTTP/1.1\r\nconnection: close\r\n\r\n");
    var in_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var chunk: [256 * 1024]u8 = undefined;
    var total: usize = 0;
    var head_len: ?usize = null;
    while (true) {
        const n = try reader.interface.readSliceShort(&chunk);
        if (head_len == null) {
            try std.testing.expect(std.mem.startsWith(u8, chunk[0..n], "HTTP/1.1 200"));
            head_len = (std.mem.indexOf(u8, chunk[0..n], "\r\n\r\n") orelse return error.TestNoHead) + 4;
        }
        total += n;
        if (n < chunk.len) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try std.testing.expectEqual(head_len.? + big_len, total);
    // The answer took longer than one timeout, so a deadline for the whole
    // answer would have cut it.
    try std.testing.expect(elapsedMs(start) > 300);
}

test "a reader that stops reading is cut by the write timeout" {
    const io = std.testing.io;
    var live: LiveSite = undefined;
    try live.start(.fromMilliseconds(300));
    defer live.stop();
    const big_len = 32 * 1024 * 1024;
    const big = try std.testing.allocator.alloc(u8, big_len);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try live.site.tmp.dir.writeFile(io, .{ .sub_path = "big.bin", .data = big });

    const stream = try live.connect();
    defer stream.close(io);
    try sendAll(stream, "GET /big.bin HTTP/1.1\r\nconnection: close\r\n\r\n");
    const start = Io.Clock.awake.now(io);
    while (live.site.server.connections.load(.monotonic) == 0) {
        try std.testing.expect(elapsedMs(start) < 5000);
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    while (live.site.server.connections.load(.monotonic) > 0) {
        try std.testing.expect(elapsedMs(start) < 5000);
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(elapsedMs(start) >= 250);

    // The client gets what the socket held, then the end, short of the file.
    var in_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var chunk: [256 * 1024]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = reader.interface.readSliceShort(&chunk) catch break;
        total += n;
        if (n < chunk.len) break;
    }
    try std.testing.expect(total < big_len);
}

test "an idle connection closes after the idle timeout" {
    const io = std.testing.io;
    var live: LiveSite = undefined;
    try live.start(.fromMilliseconds(300));
    defer live.stop();

    const silent = try live.connect();
    defer silent.close(io);
    var start = Io.Clock.awake.now(io);
    var in_buf: [4096]u8 = undefined;
    var silent_reader = silent.reader(io, &in_buf);
    const nothing = try silent_reader.interface.allocRemaining(std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(nothing);
    try std.testing.expectEqual(@as(usize, 0), nothing.len);
    try std.testing.expect(elapsedMs(start) >= 250 and elapsedMs(start) < 3000);

    // A keep-alive connection gets the full idle time again after an answer.
    const kept = try live.connect();
    defer kept.close(io);
    try sendAll(kept, "HEAD /boot.js HTTP/1.1\r\n\r\n");
    start = Io.Clock.awake.now(io);
    var kept_reader = kept.reader(io, &in_buf);
    const raw = try kept_reader.interface.allocRemaining(std.testing.allocator, .limited(4096));
    const reply: Reply = .{ .raw = raw };
    defer reply.deinit();
    try std.testing.expectEqual(@as(u16, 200), reply.status());
    try std.testing.expect(reply.header("connection") == null);
    try std.testing.expect(elapsedMs(start) >= 250 and elapsedMs(start) < 3000);
}
