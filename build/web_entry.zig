//! The root module of every Phantom web application.
//!
//! `addWebApp` compiles THIS file as the wasm entry point and imports the
//! consumer's own source as `app_root`, so a web application writes a `root`
//! function and nothing else. Everything a browser has to be told about lives
//! here: how a display list reaches the DOM, how the address bar is read and
//! written, how a tap and a key get in, and what a panic says on the way out.
//!
//! It used to be a string inside `build.zig`. A real file is checked by the
//! compiler, formatted by `zig fmt` and read with no brace escaping, which a
//! 300 line template in a `b.fmt` call is none of.
//!
//! Only `build_options` varies per build, so everything else here is ordinary
//! Zig that a reader follows without knowing it is generated into place.

const std = @import("std");
const phantom = @import("phantom");
const dom = @import("dom");
const webidl = @import("webidl");
const app_root = @import("app_root");

/// Whether the build chose the hash url strategy (`/#/gallery`) over the path
/// one (`/gallery`). This file cannot work it out for itself, so the build
/// passes it in.
const strategy_is_hash = @import("build_options").strategy_is_hash;
/// The path the site is served at, from `base_path` of `addApp`.
const base_path = @import("build_options").base_path;
const app_id = @import("build_options").app_id;

const DomCtx = struct { doc: u32, window: u32 };
var dom_ctx: DomCtx = undefined;
/// False until `init` fills `dom_ctx` in. A panic before that has no window
/// handle to report through, and reporting through an undefined one would
/// replace the message with a second, worse crash.
var dom_ready: bool = false;
/// Set on the way into the report, and never cleared. A panic raised BY the
/// reporting path would otherwise re-enter it and never reach the trap.
var panicking: bool = false;

// `pub const panic` here, not in `phantom.zig`: Zig looks for that
// declaration in the ROOT MODULE OF THE COMPILATION, and an imported
// module's own does not count. This file IS that root, the same as the
// generated native entry, so it is the one place that reaches every web
// consumer with no action on their part.
//
// Without it a panic reaches a developer as "RuntimeError: unreachable",
// with no message, no file and no line: wasm traps and the trap carries
// nothing. Every failed bounds check, every `unreachable` and every
// `@panic` in the tree lands here, so this is the whole diagnostic story
// on the web path.
pub const panic = std.debug.FullPanic(webPanic);

fn webPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    // No stack trace to unwind on this target: the browser's own console
    // shows the wasm frames, and the address alone names nothing a reader
    // can look up.
    _ = first_trace_addr;
    if (dom_ready and !panicking) {
        panicking = true;
        var buf: [512]u8 = undefined;
        // The bare message when it does not fit. A truncated sentence still
        // says more than a trap does.
        const line = std.fmt.bufPrint(&buf, "phantom panic: {s}", .{msg}) catch msg;
        const win = dom.Window{ .handle = dom_ctx.window };
        win.reportError(line);
    }
    @trap();
}

fn createElement(ctx: *anyopaque, tag: []const u8) u32 {
    const c: *DomCtx = @ptrCast(@alignCast(ctx));
    const doc = dom.Document{ .handle = c.doc };
    return doc.createElement(tag).handle;
}
// An `svg` made by createElement lands in the HTML namespace, where a
// browser lays it out and never paints it. Only the namespaced call
// reaches the SVG namespace, so icons need this one.
fn createElementNS(ctx: *anyopaque, ns: []const u8, tag: []const u8) u32 {
    const c: *DomCtx = @ptrCast(@alignCast(ctx));
    const doc = dom.Document{ .handle = c.doc };
    return doc.createElementNS(ns, tag).handle;
}
fn createTextNode(ctx: *anyopaque, data: []const u8) u32 {
    const c: *DomCtx = @ptrCast(@alignCast(ctx));
    const doc = dom.Document{ .handle = c.doc };
    return doc.createTextNode(data).handle;
}
fn setAttribute(ctx: *anyopaque, node: u32, name: []const u8, value: []const u8) void {
    _ = ctx;
    const el = dom.Element{ .handle = node };
    el.setAttribute(name, value);
}
fn removeAttribute(ctx: *anyopaque, node: u32, name: []const u8) void {
    _ = ctx;
    const el = dom.Element{ .handle = node };
    el.removeAttribute(name);
}
fn removeChild(ctx: *anyopaque, parent: u32, child: u32) void {
    _ = ctx;
    const p = dom.Node{ .handle = parent };
    p.removeChild(.{ .handle = child }).unref();
}
fn insertBefore(ctx: *anyopaque, parent: u32, child: u32, ref: u32) void {
    _ = ctx;
    const p = dom.Node{ .handle = parent };
    p.insertBefore(.{ .handle = child }, .{ .handle = ref }).unref();
}
fn setTextContent(ctx: *anyopaque, node: u32, textv: []const u8) void {
    _ = ctx;
    const el = dom.Element{ .handle = node };
    el.set_textContent(textv);
}
// The walk over a page a server rendered. Each element handle goes to the
// caller, which keeps it or releases it.
fn firstChild(ctx: *anyopaque, node: u32) u32 {
    _ = ctx;
    const el = dom.Element{ .handle = node };
    const child = el.get_firstElementChild() orelse return 0;
    return child.handle;
}
fn nextSibling(ctx: *anyopaque, node: u32) u32 {
    _ = ctx;
    const el = dom.Element{ .handle = node };
    const next = el.get_nextElementSibling() orelse return 0;
    return next.handle;
}
const xhtml_ns = "http://www.w3.org/1999/xhtml";
fn readElement(ctx: *anyopaque, node: u32, buf: []u8) ?phantom.backend.dom_calls.DomOps.ElementName {
    _ = ctx;
    const el = dom.Element{ .handle = node };
    const ns = el.get_namespaceURI() orelse return null;
    defer webidl.rt.freeStr(ns);
    const kind: phantom.backend.vdom.Kind = if (std.mem.eql(u8, ns, xhtml_ns))
        .element
    else if (std.mem.eql(u8, ns, phantom.backend.dom_calls.svg_ns))
        .element_svg
    else
        return null;
    const name = el.get_localName();
    defer webidl.rt.freeStr(name);
    if (name.len > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    return .{ .kind = kind, .tag = buf[0..name.len] };
}
fn readAttribute(ctx: *anyopaque, node: u32, name: []const u8, buf: []u8) ?[]const u8 {
    _ = ctx;
    const el = dom.Element{ .handle = node };
    const value = el.getAttribute(name) orelse return null;
    defer webidl.rt.freeStr(value);
    if (value.len > buf.len) return null;
    @memcpy(buf[0..value.len], value);
    return buf[0..value.len];
}
fn release(ctx: *anyopaque, node: u32) void {
    _ = ctx;
    const n = dom.Node{ .handle = node };
    n.unref();
}

// Styling, through the CSSOM rather than through markup.
//
// A `style` ATTRIBUTE and the TEXT of a `<style>` element are both markup, and a
// Content Security Policy without `'unsafe-inline'` refuses both. Every node this
// backend draws is positioned with one, so under a strict policy the page draws
// nothing at all and fills the console with `style-src-attr` violations.
//
// Assigning through `element.style` and adding rules through a sheet are not
// refused, because `script-src` already stopped an attacker from running any
// script, so reaching the CSSOM adds no way in that script did not already have.
//
// These two are `phantom` imports rather than generated bindings because neither
// is one DOM call: each is a loop over a declaration the page has to parse. Doing
// that on the JS side also keeps it to ONE crossing per node, the same as the
// attribute it replaces, instead of one per property.
extern "phantom" fn __phantom_set_style(node: u32, ptr: [*]const u8, len: usize) void;
extern "phantom" fn __phantom_add_rule(ptr: [*]const u8, len: usize) void;
extern "phantom" fn __phantom_add_font(fam_ptr: [*]const u8, fam_len: usize, src_ptr: [*]const u8, src_len: usize) void;
extern "phantom" fn __phantom_setting_read(app_ptr: [*]const u8, app_len: usize, key_ptr: [*]const u8, key_len: usize, out_ptr: [*]u8, out_len: usize) i32;
extern "phantom" fn __phantom_setting_write(app_ptr: [*]const u8, app_len: usize, key_ptr: [*]const u8, key_len: usize, value_ptr: [*]const u8, value_len: usize) u32;
extern "phantom" fn __phantom_setting_remove(app_ptr: [*]const u8, app_len: usize, key_ptr: [*]const u8, key_len: usize) u32;
extern "phantom" fn __phantom_pick_file(app: usize, accept_ptr: [*]const u8, accept_len: usize) u32;
extern "phantom" fn __phantom_notification_permission() u32;
extern "phantom" fn __phantom_notification_permission_request(app: usize) u32;
extern "phantom" fn __phantom_notification_show(id_ptr: [*]const u8, id_len: usize, title_ptr: [*]const u8, title_len: usize, body_ptr: [*]const u8, body_len: usize) u32;
extern "phantom" fn __phantom_clipboard_read(app: usize) u32;
extern "phantom" fn __phantom_clipboard_write(ptr: [*]const u8, len: usize) u32;

fn setStyle(ctx: *anyopaque, node: u32, decl: []const u8) void {
    _ = ctx;
    __phantom_set_style(node, decl.ptr, decl.len);
}

fn addRule(ctx: *anyopaque, css: []const u8) void {
    _ = ctx;
    if (css.len == 0) return;
    __phantom_add_rule(css.ptr, css.len);
}

fn addFont(ctx: *anyopaque, family: []const u8, src: []const u8) void {
    _ = ctx;
    if (family.len == 0 or src.len == 0) return;
    __phantom_add_font(family.ptr, family.len, src.ptr, src.len);
}

fn readSetting(ctx: *anyopaque, key: []const u8, buf: []u8) phantom.SettingsError!?[]const u8 {
    _ = ctx;
    if (!phantom.platform.validSettingKey(key)) return error.InvalidKey;
    const result = __phantom_setting_read(app_id.ptr, app_id.len, key.ptr, key.len, buf.ptr, buf.len);
    if (result == -1) return null;
    if (result == -2) return error.BufferTooSmall;
    if (result < 0) return error.StorageFailure;
    return buf[0..@intCast(result)];
}

fn writeSetting(ctx: *anyopaque, key: []const u8, value: []const u8) phantom.SettingsError!void {
    _ = ctx;
    if (!phantom.platform.validSettingKey(key)) return error.InvalidKey;
    if (__phantom_setting_write(app_id.ptr, app_id.len, key.ptr, key.len, value.ptr, value.len) == 0) return error.StorageFailure;
}

fn removeSetting(ctx: *anyopaque, key: []const u8) phantom.SettingsError!void {
    _ = ctx;
    if (!phantom.platform.validSettingKey(key)) return error.InvalidKey;
    if (__phantom_setting_remove(app_id.ptr, app_id.len, key.ptr, key.len) == 0) return error.StorageFailure;
}

fn pickFile(ctx: *anyopaque, app: usize, accept: []const u8) bool {
    _ = ctx;
    return __phantom_pick_file(app, accept.ptr, accept.len) != 0;
}

fn permissionFromInt(value: u32) phantom.NotificationPermission {
    return switch (value) {
        0 => .granted,
        1 => .denied,
        2 => .prompt,
        else => .unsupported,
    };
}

fn notificationPermission(_: *anyopaque) phantom.NotificationPermission {
    return permissionFromInt(__phantom_notification_permission());
}

fn requestNotificationPermission(_: *anyopaque, app: usize) bool {
    return __phantom_notification_permission_request(app) != 0;
}

fn showNotification(_: *anyopaque, notification: phantom.Notification) bool {
    return __phantom_notification_show(notification.id.ptr, notification.id.len, notification.title.ptr, notification.title.len, notification.body.ptr, notification.body.len) != 0;
}

fn readClipboard(_: *anyopaque, app: usize) bool {
    return __phantom_clipboard_read(app) != 0;
}

fn writeClipboard(_: *anyopaque, text: []const u8) bool {
    return __phantom_clipboard_write(text.ptr, text.len) != 0;
}
fn appendChild(ctx: *anyopaque, parent: u32, child: u32) void {
    _ = ctx;
    const p = dom.Node{ .handle = parent };
    p.appendChild(.{ .handle = child }).unref();
}
fn clearChildren(ctx: *anyopaque, node: u32) void {
    _ = ctx;
    const el = dom.Element{ .handle = node };
    el.set_innerHTML("");
}
/// Every length that crosses between the browser and phantom in this file goes
/// through this scale. `init` and `resize` set it from the root font size.
var css_scale: phantom.web.CssScale = .{};

fn setRootFont(root_font: f64) void {
    css_scale = .fromRootFont(root_font);
}
fn fromCss(v: f64) f32 {
    return css_scale.fromCss(v);
}
fn toCss(v: f32) f32 {
    return css_scale.toCss(v);
}

// The browser owns the scroll position of a region. These two hooks read it
// for the view and write it when phantom moved the region.
fn readScrollOffset(ctx: *anyopaque, node: u32) phantom.PhysicalOffset {
    _ = ctx;
    const el = dom.Element{ .handle = node };
    return .{ .x = fromCss(el.get_scrollLeft()), .y = fromCss(el.get_scrollTop()) };
}
fn writeScrollOffset(ctx: *anyopaque, node: u32, offset: phantom.PhysicalOffset) void {
    _ = ctx;
    const el = dom.Element{ .handle = node };
    el.set_scrollLeft(toCss(offset.x));
    el.set_scrollTop(toCss(offset.y));
}

// Reads the address bar into buf, according to the build's url strategy. A
// hash strategy trims the leading '#' and reads an empty hash as "/", so a
// fresh page with no hash still resolves to the root route. Null when the
// address does not fit buf: the caller must refuse it rather than take a
// truncated, shorter route than the one the browser actually shows.
fn currentPath(win: dom.Window, buf: []u8) ?[]const u8 {
    const loc = win.get_location();
    defer loc.unref();
    const raw = if (strategy_is_hash) loc.get_hash() else loc.get_pathname();
    defer webidl.rt.freeStr(raw);
    var s = raw;
    if (strategy_is_hash) {
        if (s.len > 0 and s[0] == '#') s = s[1..];
        if (s.len == 0) s = "/";
    }
    if (s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// Fill `buf` from `crypto.getRandomValues`, the browser's secure random source.
///
/// The binding hands JS a VIEW over wasm memory rather than a copy, so the bytes
/// land straight in the caller's slice. This is what the webidl buffer boundary
/// exists for and it is what keeps `std.Io`'s `random` from being the zero-filling
/// stub that `std.Io.failing` supplies.
///
/// `getRandomValues` throws above 65536 bytes, which is the one limit a caller
/// can hit by accident, so the request is refused here rather than thrown across
/// the boundary.
fn fillRandom(ctx: *anyopaque, buf: []u8) bool {
    if (buf.len == 0) return true;
    if (buf.len > 65536) return false;
    const c: *DomCtx = @ptrCast(@alignCast(ctx));
    const win = dom.Window{ .handle = c.window };
    const crypto = win.get_crypto();
    defer crypto.unref();
    crypto.getRandomValues(buf);
    return true;
}

// ---------------------------------------------------------------------------
// HTTP, through the one call in this file that BLOCKS.
//
// The page supplies `__phantom_http_send` in two flavours and picks between them
// at instantiation. Where the browser has JSPI it is a suspending import, so the
// wasm stack parks and the page keeps running; where it does not, it is a
// synchronous XMLHttpRequest and the page freezes for the length of the request.
// This side cannot tell the two apart and does not need to.
//
// The import is in its own `phantom` module rather than in `env`: the webidl
// runtime checks that `env` holds exactly its own list and nothing else, so an
// extra name in there would be rejected as a mismatched host.
// ---------------------------------------------------------------------------

/// Where the page writes what came back. Five `u32`s, filled by the host before
/// the call returns. The two buffers are allocated by the page through
/// `webidl_rt_alloc`, so this side owns them and frees them.
const RawResponse = extern struct {
    status: u32 = 0,
    headers_ptr: u32 = 0,
    headers_len: u32 = 0,
    body_ptr: u32 = 0,
    body_len: u32 = 0,
};

extern "phantom" fn __phantom_http_send(
    method_ptr: [*]const u8,
    method_len: usize,
    url_ptr: [*]const u8,
    url_len: usize,
    headers_ptr: [*]const u8,
    headers_len: usize,
    body_ptr: [*]const u8,
    body_len: usize,
    out: *RawResponse,
) u32;

fn rawSlice(ptr: u32, len: u32) []const u8 {
    if (len == 0) return "";
    return @as([*]const u8, @ptrFromInt(ptr))[0..len];
}

/// Run one request and hand back the whole HTTP/1.1 response, or null when it
/// never arrived. This is the hook `web_net` blocks on.
fn httpSend(ctx: *anyopaque, gpa: std.mem.Allocator, req: phantom.web_net.Request) ?[]u8 {
    const c: *DomCtx = @ptrCast(@alignCast(ctx));
    const win = dom.Window{ .handle = c.window };
    const page_loc = win.get_location();
    defer page_loc.unref();
    const page_host = page_loc.get_hostname();
    defer webidl.rt.freeStr(page_host);

    const url = phantom.web_net.requestUrl(gpa, page_host, req) catch return null;
    defer gpa.free(url);

    var raw = RawResponse{};
    const ok = __phantom_http_send(
        req.method.ptr,
        req.method.len,
        url.ptr,
        url.len,
        req.headers.ptr,
        req.headers.len,
        req.body.ptr,
        req.body.len,
        &raw,
    );
    // Freed however this ends. The page allocated both buffers out of this
    // module's own heap, so leaving them would leak once per request.
    defer webidl.rt.freeStr(rawSlice(raw.headers_ptr, raw.headers_len));
    defer webidl.rt.freeStr(rawSlice(raw.body_ptr, raw.body_len));
    if (ok == 0) return null;

    return phantom.web_net.buildResponse(
        gpa,
        @intCast(raw.status),
        rawSlice(raw.headers_ptr, raw.headers_len),
        rawSlice(raw.body_ptr, raw.body_len),
    ) catch null;
}

/// Open `url`, and report whether the browser actually did it.
///
/// A new tab can be refused: a browser blocks `window.open` when it decides the
/// call is a popup, which is any call not tied to a fresh user gesture, and an
/// application that awaited a request before calling has already spent its one.
/// It says so by handing back null, and that has to reach the caller so a page
/// can offer the link instead of appearing to ignore the tap.
///
/// A same-tab navigation cannot be refused that way, because it is a navigation
/// and not a window. It is what a sign in hop wants: the person comes back to
/// the callback in the tab they left from.
fn openUrl(ctx: *anyopaque, url: []const u8, mode: phantom.OpenMode) bool {
    const c: *DomCtx = @ptrCast(@alignCast(ctx));
    const win = dom.Window{ .handle = c.window };
    switch (mode) {
        .same_tab => {
            win.get_location().assign(url);
            // The page is leaving. Nothing after this runs long enough to
            // report anything else.
            return true;
        },
        // Handle zero is the null the runtime maps a refused window to.
        .new_tab => return win.open(url, "_blank").handle != 0,
    }
}

fn readLocation(ctx: *anyopaque, buf: []u8) ?[]const u8 {
    const c: *DomCtx = @ptrCast(@alignCast(ctx));
    const win = dom.Window{ .handle = c.window };
    return currentPath(win, buf);
}

// The query string, with the leading "?" trimmed off, and empty when the
// address carries none. Null when it does not fit buf, on the same rule
// currentPath follows: the first bytes of a query are a different query.
//
// Read from the URL itself under BOTH strategies, and never out of the
// hash. A redirect that comes back carrying a state or an error puts it in
// the URL's own query, which is exactly the case this exists for.
// The host the page is served from, with no port on it. An application needs
// this to name its own server in a URL it asks for, and only the page knows what
// that is. Refused rather than truncated when it does not fit: the first bytes
// of a host name are a different machine, and this one is about to be handed
// credentials.
fn readHost(ctx: *anyopaque, buf: []u8) ?[]const u8 {
    const c: *DomCtx = @ptrCast(@alignCast(ctx));
    const win = dom.Window{ .handle = c.window };
    const loc = win.get_location();
    defer loc.unref();
    const raw = loc.get_hostname();
    defer webidl.rt.freeStr(raw);
    if (raw.len > buf.len) return null;
    @memcpy(buf[0..raw.len], raw);
    return buf[0..raw.len];
}

fn readQuery(ctx: *anyopaque, buf: []u8) ?[]const u8 {
    const c: *DomCtx = @ptrCast(@alignCast(ctx));
    const win = dom.Window{ .handle = c.window };
    const loc = win.get_location();
    defer loc.unref();
    const raw = loc.get_search();
    defer webidl.rt.freeStr(raw);
    var s = raw;
    if (s.len > 0 and s[0] == '?') s = s[1..];
    if (s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

// Puts path in the address bar, in the given mode: push adds a history
// entry, replace rewrites the current one. The guard that once skipped a
// redundant write here now lives in phantom.web, in the thunk that calls
// this function: it compares against the same read_location this file
// exposes, so it can be tested with no browser.
fn writeLocation(ctx: *anyopaque, path: []const u8, mode: phantom.WriteMode) void {
    const c: *DomCtx = @ptrCast(@alignCast(ctx));
    const win = dom.Window{ .handle = c.window };
    const hist = win.get_history();
    defer hist.unref();
    if (strategy_is_hash) {
        var url_buf: [phantom.router.max_path + 1]u8 = undefined;
        const n = @min(path.len, url_buf.len - 1);
        url_buf[0] = '#';
        @memcpy(url_buf[1 .. 1 + n], path[0..n]);
        switch (mode) {
            .push => hist.pushState("", "", url_buf[0 .. 1 + n]),
            .replace => hist.replaceState("", "", url_buf[0 .. 1 + n]),
        }
    } else {
        switch (mode) {
            .push => hist.pushState("", "", path),
            .replace => hist.replaceState("", "", path),
        }
    }
}

export fn init(doc_handle: u32, body_handle: u32, window_handle: u32, root_font: f64) usize {
    const win = dom.Window{ .handle = window_handle };
    setRootFont(root_font);
    const vw = fromCss(@floatFromInt(win.get_innerWidth()));
    const vh = fromCss(@floatFromInt(win.get_innerHeight()));
    const dpr: f32 = @floatCast(win.get_devicePixelRatio());
    dom_ctx = .{ .doc = doc_handle, .window = window_handle };
    // Every panic from here on has a window to report through.
    dom_ready = true;
    const _doc = dom.Document{ .handle = doc_handle };
    const head = _doc.get_head().handle;
    const ops = phantom.backend.dom_calls.DomOps{
        .ctx = &dom_ctx,
        .create_element = createElement,
        .create_element_ns = createElementNS,
        .create_text_node = createTextNode,
        .set_attribute = setAttribute,
        .set_text_content = setTextContent,
        .set_style = setStyle,
        .add_rule = addRule,
        .add_font = addFont,
        .append_child = appendChild,
        .clear_children = clearChildren,
        .body = body_handle,
        .head = head,
        .base = base_path,
        .open_url = openUrl,
        .read_location = readLocation,
        .read_query = readQuery,
        .read_host = readHost,
        .fill_random = fillRandom,
        .write_location = writeLocation,
        .read_scroll_offset = readScrollOffset,
        .write_scroll_offset = writeScrollOffset,
        .http_send = httpSend,
        .open_event_source = openEventSource,
        .close_event_source = closeEventSource,
        .read_setting = readSetting,
        .write_setting = writeSetting,
        .remove_setting = removeSetting,
        .pick_file = pickFile,
        .notification_permission = notificationPermission,
        .request_notification_permission = requestNotificationPermission,
        .show_notification = showNotification,
        .read_clipboard = readClipboard,
        .write_clipboard = writeClipboard,
        .release = release,
        .remove_child = removeChild,
        .insert_before = insertBefore,
        .remove_attribute = removeAttribute,
        .first_child = firstChild,
        .next_sibling = nextSibling,
        .read_element = readElement,
        .read_attribute = readAttribute,
    };
    const strategy: phantom.UrlStrategy = if (strategy_is_hash) .hash else .path;
    const app = phantom.web.init(std.heap.wasm_allocator, ops, phantom.Root.plain(app_root.root), .{ .width = vw, .height = vh }, toCss(dpr), strategy) catch return 0;
    return @intFromPtr(app);
}
export fn dispatchTap(app: usize, x: f32, y: f32) void {
    if (app == 0) return;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    a.dispatchTap(fromCss(x), fromCss(y));
}
export fn resize(app: usize, w: u32, h: u32, dpr: f64, root_font: f64) void {
    if (app == 0) return;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    setRootFont(root_font);
    a.resize(.{ .width = fromCss(@floatFromInt(w)), .height = fromCss(@floatFromInt(h)) }, toCss(@floatCast(dpr)));
}
// wall_ms is Date.now (settable, Unix epoch). mono_ms is the animation
// frame timestamp (monotonic, page time origin). Both are needed: the
// bar shows a time of day, the scheduler arms deadlines.
export fn tick(app: usize, wall_ms: f64, mono_ms: f64) void {
    if (app == 0) return;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    a.tick(wall_ms, mono_ms);
}
// The browser scrolled the region the page tagged with `index`.
export fn scrollChanged(app: usize, index: u32, x: f32, y: f32) void {
    if (app == 0) return;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    a.scrollChanged(index, fromCss(x), fromCss(y));
}
// The browser moved back or forward. The address bar already shows the new
// location, so this reads it back and tells the tree, rather than taking the
// new path as a string argument: a string argument would need the JS host to
// write into wasm memory, and reading the location back through the same
// DomOps hook the tree already uses needs no new plumbing.
export fn locationChanged(app: usize) void {
    if (app == 0) return;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    a.locationChanged();
}

/// `kind`: 0 selected, 1 cancelled, anything else failed. JS allocated all
/// three buffers from wasm and frees them after this borrowed callback returns.
export fn filePicked(app: usize, kind: u32, name_ptr: u32, name_len: u32, type_ptr: u32, type_len: u32, data_ptr: u32, data_len: u32) void {
    if (app == 0) return;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    const result: phantom.FilePickerResult = switch (kind) {
        0 => .{ .selected = .{
            .name = rawSlice(name_ptr, name_len),
            .media_type = rawSlice(type_ptr, type_len),
            .bytes = rawSlice(data_ptr, data_len),
        } },
        1 => .cancelled,
        else => .failed,
    };
    a.filePicked(result);
}

export fn notificationPermissionResult(app: usize, result: u32) void {
    if (app == 0) return;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    a.notificationPermissionResult(permissionFromInt(result));
}

export fn clipboardRead(app: usize, success: u32, ptr: u32, len: u32) void {
    if (app == 0) return;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    a.clipboardRead(if (success != 0) rawSlice(ptr, len) else null);
}

export fn lifecycleChanged(app: usize, foreground: u32) void {
    if (app == 0) return;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    a.lifecycleChanged(if (foreground != 0) .foreground else .background);
}

// The keyboard. A wasm export carries numbers only, so the page packs the
// modifiers into a bitfield and names the action by number.
//
// mods: 1 shift, 2 ctrl, 4 alt, 8 super. action: 0 press, 1 repeat, 2 release.
// Every entry answers 1 when the tree used the key, which the page turns into
// preventDefault: a key the tree took must not also scroll the page, move the
// browser's own focus ring off it, or go back a page on Backspace.
fn modsFrom(bits: u32) phantom.input.Mods {
    return .{
        .shift = bits & 1 != 0,
        .ctrl = bits & 2 != 0,
        .alt = bits & 4 != 0,
        .super = bits & 8 != 0,
    };
}
// An unknown number is a press. A host that sends one this file does not know
// must not have its keystroke turned into a release, which is the one action
// every handler drops on the floor.
fn actionFrom(bits: u32) phantom.input.KeyAction {
    return switch (bits) {
        1 => .repeat,
        2 => .release,
        else => .press,
    };
}

// A named key: `KeyboardEvent.key` held a word ("Backspace", "ArrowLeft") and
// the page mapped it to its X11 keysym, which is the number `input.Keysym`
// already carries. No keymap is needed on this side.
export fn dispatchKey(app: usize, keysym: u32, mods: u32, action: u32) u32 {
    if (app == 0) return 0;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    return @intFromBool(a.dispatchKey(.{
        .keysym = @fromBackingInt(@intCast(keysym)),
        .mods = modsFrom(mods),
        .action = actionFrom(action),
    }));
}

// A printable key, by the codepoint the browser resolved for it. The layout
// and the shift state are already folded into it.
export fn dispatchChar(app: usize, codepoint: u32, mods: u32, action: u32) u32 {
    if (app == 0 or codepoint > 0x10FFFF) return 0;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    return @intFromBool(a.dispatchChar(@intCast(codepoint), modsFrom(mods), actionFrom(action)));
}

// Whether anything in the tree currently holds the keyboard.
//
// Deliberately NOT wrapped for JSPI on the page side, and deliberately does no
// IO: `preventDefault` has to be called while the event is still being handled,
// and a suspending dispatch answers too late to decide with. This answers now.
export fn focusHeld(app: usize) u32 {
    if (app == 0) return 0;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    return @intFromBool(a.focus.current != null);
}

// Reserve `len` bytes for the page to write UTF-8 into and return the address,
// or zero when there is no room for it. The page writes the bytes and hands the
// same address straight back to `dispatchText`, which frees them; a caller that
// asks for a buffer and never dispatches it keeps the bytes for the life of the
// page, so the two calls belong together.
export fn textBuffer(len: usize) usize {
    if (len == 0) return 0;
    const buf = std.heap.wasm_allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(buf.ptr);
}

// A whole string at the focus, as one edit: this is the paste path and the IME
// path. Neither one arrives as keys, so neither reaches a page through the two
// entries above.
export fn dispatchText(app: usize, ptr: usize, len: usize) u32 {
    if (ptr == 0 or len == 0) return 0;
    const buf: [*]u8 = @ptrFromInt(ptr);
    defer std.heap.wasm_allocator.free(buf[0..len]);
    if (app == 0) return 0;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    return @intFromBool(a.dispatchText(buf[0..len]));
}

// ---------------------------------------------------------------------------
// Server-sent events. The page holds one `EventSource` for each open stream,
// keeps the events it receives, and hands them over between frames through
// `serverEvent`, so an event never arrives while the tree builds.
// ---------------------------------------------------------------------------

extern "phantom" fn __phantom_event_source_open(id: u32, url_ptr: [*]const u8, url_len: usize, types_ptr: [*]const u8, types_len: usize) u32;
extern "phantom" fn __phantom_event_source_close(id: u32) void;

fn openEventSource(_: *anyopaque, id: u32, url: []const u8, types: []const u8) bool {
    return __phantom_event_source_open(id, url.ptr, url.len, types.ptr, types.len) != 0;
}

fn closeEventSource(_: *anyopaque, id: u32) void {
    __phantom_event_source_close(id);
}

/// The page allocates the three strings through `webidl_rt_alloc`, and they
/// are freed here after the sink returns. `kind` is 0 for open, 1 for a
/// message, 2 for reconnecting and 3 for closed.
export fn serverEvent(
    app: usize,
    id: u32,
    kind: u32,
    type_ptr: u32,
    type_len: u32,
    data_ptr: u32,
    data_len: u32,
    last_id_ptr: u32,
    last_id_len: u32,
) void {
    const type_s = rawSlice(type_ptr, type_len);
    const data = rawSlice(data_ptr, data_len);
    const last_id = rawSlice(last_id_ptr, last_id_len);
    defer webidl.rt.freeStr(type_s);
    defer webidl.rt.freeStr(data);
    defer webidl.rt.freeStr(last_id);
    if (app == 0) return;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    const event: phantom.ServerEvent = switch (kind) {
        0 => .open,
        1 => .{ .message = .{ .type = type_s, .data = data, .last_event_id = last_id } },
        2 => .reconnecting,
        else => .closed,
    };
    a.serverEvent(id, event);
}
