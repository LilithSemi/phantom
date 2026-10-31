const std = @import("std");
const display_list = @import("../display_list.zig");
const geometry = @import("../geometry.zig");
const vdom = @import("vdom.zig");
const dom = @import("dom.zig");
const text = @import("../text.zig");
const image_mod = @import("../image/Image.zig");
const pointer = @import("../pointer.zig");
const platform = @import("../platform.zig");
const web_net = @import("../web_net.zig");
const FaultSink = @import("../FaultSink.zig");

/// The namespace an `<svg>` and its children must be created in. `createElement`
/// puts an element in the HTML namespace whatever its name is, and an `svg` in
/// the HTML namespace is an unknown element that a browser lays out but never
/// paints. Only `createElementNS` reaches the SVG namespace.
pub const svg_ns = "http://www.w3.org/2000/svg";

/// A vtable of DOM operations, implemented by the web entry (via the generated
/// webidl dom module) or by a recording mock in tests. Every fn takes ctx so
/// the implementation carries its state (handles / a recorder) without globals.
pub const DomOps = struct {
    ctx: *anyopaque,
    create_element: *const fn (ctx: *anyopaque, tag: []const u8) u32,
    /// Namespaced element creation, for the `<svg>` an icon draws into. Null
    /// falls back to `create_element`, which keeps every existing host
    /// compiling; a host that leaves it null renders no icons, because an
    /// `svg` in the HTML namespace paints nothing.
    create_element_ns: ?*const fn (ctx: *anyopaque, ns: []const u8, tag: []const u8) u32 = null,
    create_text_node: *const fn (ctx: *anyopaque, data: []const u8) u32,
    set_attribute: *const fn (ctx: *anyopaque, node: u32, name: []const u8, value: []const u8) void,
    set_text_content: *const fn (ctx: *anyopaque, node: u32, textv: []const u8) void,
    append_child: *const fn (ctx: *anyopaque, parent: u32, child: u32) void,
    clear_children: *const fn (ctx: *anyopaque, node: u32) void,
    body: u32,
    head: u32,
    /// The path the site is served at. It starts and ends with '/'. Font urls
    /// go under it. See `dom.FontUrl`.
    base: []const u8 = "/",
    /// Opens a URL in a new tab. Null on a host that has no browser.
    /// Opens `url` in `mode`, and reports whether it WAS opened. A browser hands
    /// back nothing when it refuses a popup, and that has to reach the caller:
    /// see `platform.OpenMode`.
    open_url: ?*const fn (ctx: *anyopaque, url: []const u8, mode: platform.OpenMode) bool = null,
    /// Writes the current route into `buf` and returns the written part, or
    /// null when the real route is longer than `buf` can hold. A truncated
    /// route is a different, shorter one than the browser actually shows, so
    /// the caller must refuse it rather than take the shortened copy.
    read_location: ?*const fn (ctx: *anyopaque, buf: []u8) ?[]const u8 = null,
    /// Writes the query string, with no leading "?", into `buf` and returns the
    /// written part. Null when it does not fit, on the same rule
    /// `read_location` follows. Null on a host with no address to read.
    read_query: ?*const fn (ctx: *anyopaque, buf: []u8) ?[]const u8 = null,
    /// Writes the host the page is served from, with no port on it. Null when it
    /// does not fit. An application needs it to name its own server in a URL.
    read_host: ?*const fn (ctx: *anyopaque, buf: []u8) ?[]const u8 = null,
    /// Applies a whole `name:value;name:value` declaration to a node through
    /// the CSSOM, one property at a time.
    ///
    /// A `style` ATTRIBUTE is markup, and a Content Security Policy without
    /// `'unsafe-inline'` refuses every one of them: a page positioned this way
    /// draws nothing and fills the console. Assigning through the style object
    /// instead is not refused, because `script-src` already stopped an attacker
    /// running any script at all, so the CSSOM adds no way in. Same result, same
    /// declaration, and a policy nobody has to loosen.
    ///
    /// The declaration replaces the one the node had before.
    ///
    /// Null falls back to `set_attribute`, which keeps a host written before this
    /// existed working, at the cost of needing `'unsafe-inline'`.
    set_style: ?*const fn (ctx: *anyopaque, node: u32, decl: []const u8) void = null,
    /// Adds CSS rules to the page WITHOUT a `<style>` element anywhere.
    ///
    /// This takes no node, and that is the whole point. A `<style>` element is
    /// markup, and `style-src 'self'` refuses the ELEMENT ITSELF the moment it
    /// enters the document, before a single rule is in it: a browser reports the
    /// refusal against `style-src-elem` and names the hash of the EMPTY string,
    /// which is what an empty style element hashes to. A refused element gets no
    /// `.sheet`, so adding rules to it through the CSSOM never runs either. There
    /// is no way to use one under a strict policy.
    ///
    /// A constructable sheet, `new CSSStyleSheet()` adopted by the document, has
    /// no element for a policy to refuse.
    ///
    /// Null falls back to a `<style>` element, which works and needs
    /// `'unsafe-inline'`.
    add_rule: ?*const fn (ctx: *anyopaque, css: []const u8) void = null,
    /// Registers one font face, WITHOUT a stylesheet of any kind: the `FontFace`
    /// constructor and `document.fonts`. `src` is the CSS source descriptor, so
    /// `url("/fonts/X.otf")` for a font served as a file and a `data:` URL for one
    /// that is not.
    ///
    /// Separate from `add_rule` because a font that fails to register fails in a
    /// way nothing else does: layout was measured against it, the browser
    /// substitutes another, and the glyphs a person sees stop lining up with the
    /// rectangles their taps are tested against.
    ///
    /// Null falls back to an `@font-face` rule through `add_rule`.
    add_font: ?*const fn (ctx: *anyopaque, family: []const u8, src: []const u8) void = null,
    /// Fills `buf` with cryptographically secure random bytes and reports
    /// whether it managed to. This is `crypto.getRandomValues` on a browser.
    ///
    /// A host that leaves it null has no random source at all, which is not the
    /// same as a source that returns zeros: `std.Io.failing`'s `noRandom` zeroes
    /// the buffer AND reports success, so a caller drawing a key from it gets a
    /// key of zeros and no error. Everything downstream of this hook exists to
    /// stop that particular lie.
    fill_random: ?*const fn (ctx: *anyopaque, buf: []u8) bool = null,
    /// Runs one HTTP request. See `web_net.Hook.send`. Null on a host with no
    /// network, where every request fails as a transport failure.
    http_send: ?*const fn (ctx: *anyopaque, gpa: std.mem.Allocator, req: web_net.Request) ?[]u8 = null,
    /// Opens an `EventSource` on `url` that the page knows by `id`. `types` is
    /// the extra event types to listen for, one on each line. Returns false
    /// when the browser refuses the URL.
    open_event_source: ?*const fn (ctx: *anyopaque, id: u32, url: []const u8, types: []const u8) bool = null,
    close_event_source: ?*const fn (ctx: *anyopaque, id: u32) void = null,
    read_setting: ?*const fn (ctx: *anyopaque, key: []const u8, buf: []u8) platform.SettingsError!?[]const u8 = null,
    write_setting: ?*const fn (ctx: *anyopaque, key: []const u8, value: []const u8) platform.SettingsError!void = null,
    remove_setting: ?*const fn (ctx: *anyopaque, key: []const u8) platform.SettingsError!void = null,
    pick_file: ?*const fn (ctx: *anyopaque, app: usize, accept: []const u8) bool = null,
    notification_permission: ?*const fn (ctx: *anyopaque) platform.NotificationPermission = null,
    request_notification_permission: ?*const fn (ctx: *anyopaque, app: usize) bool = null,
    show_notification: ?*const fn (ctx: *anyopaque, notification: platform.Notification) bool = null,
    read_clipboard: ?*const fn (ctx: *anyopaque, app: usize) bool = null,
    write_clipboard: ?*const fn (ctx: *anyopaque, text: []const u8) bool = null,
    /// Puts `path` in the address bar without loading a new page, in `mode`.
    write_location: ?*const fn (ctx: *anyopaque, path: []const u8, mode: platform.WriteMode) void = null,
    /// Reads a scroll region's current offset (scrollLeft/scrollTop) from the
    /// host. Null on a host that cannot read it back. A view then does not
    /// learn an offset that the browser scrolled to before its event came.
    read_scroll_offset: ?*const fn (ctx: *anyopaque, node: u32) geometry.PhysicalOffset = null,
    /// Sets a scroll region's offset on the host. Null on a host that cannot
    /// write it. A region then stays where the browser has it.
    write_scroll_offset: ?*const fn (ctx: *anyopaque, node: u32, offset: geometry.PhysicalOffset) void = null,
    /// Drops the host's reference to a node handle. The node stays in the
    /// document. Null on a host that keeps no handle table.
    release: ?*const fn (ctx: *anyopaque, node: u32) void = null,
    /// Takes `child` out of `parent`. The handle stays valid until it is
    /// released. Null, or a null `insert_before`, makes `render` build the
    /// whole body again on each frame.
    remove_child: ?*const fn (ctx: *anyopaque, parent: u32, child: u32) void = null,
    /// Puts `child` into `parent` just before `ref`, and moves it there when
    /// it is already in the document.
    insert_before: ?*const fn (ctx: *anyopaque, parent: u32, child: u32, ref: u32) void = null,
    /// Null falls back to setting the attribute to an empty value.
    remove_attribute: ?*const fn (ctx: *anyopaque, node: u32, name: []const u8) void = null,
    /// The first element child of `node`, or 0 when it has none. Text nodes
    /// are skipped. The caller owns the handle. Null on a host that cannot
    /// walk the page, which then builds a server page again. See `hydrate`.
    first_child: ?*const fn (ctx: *anyopaque, node: u32) u32 = null,
    /// The next element sibling of `node`, or 0 when it has none. The caller
    /// owns the handle.
    next_sibling: ?*const fn (ctx: *anyopaque, node: u32) u32 = null,
    /// The kind and local name of element `node`, with the name in `buf`.
    /// Null when the name does not fit, or the namespace is not HTML or SVG.
    read_element: ?*const fn (ctx: *anyopaque, node: u32, buf: []u8) ?ElementName = null,
    /// Writes the value of attribute `name` of `node` into `buf`. Null when
    /// the node does not have it or the value does not fit.
    read_attribute: ?*const fn (ctx: *anyopaque, node: u32, name: []const u8, buf: []u8) ?[]const u8 = null,

    pub const ElementName = struct { kind: vdom.Kind, tag: []const u8 };

    pub fn createElement(self: DomOps, tag: []const u8) u32 {
        return self.create_element(self.ctx, tag);
    }
    pub fn createElementNs(self: DomOps, ns: []const u8, tag: []const u8) u32 {
        const f = self.create_element_ns orelse return self.create_element(self.ctx, tag);
        return f(self.ctx, ns, tag);
    }
    pub fn createTextNode(self: DomOps, data: []const u8) u32 {
        return self.create_text_node(self.ctx, data);
    }
    pub fn setAttribute(self: DomOps, node: u32, name: []const u8, value: []const u8) void {
        self.set_attribute(self.ctx, node, name, value);
    }
    /// Apply a style declaration. Prefers the CSSOM hook, which a strict Content
    /// Security Policy permits, and falls back to the `style` attribute, which it
    /// does not. See `set_style`.
    pub fn setStyle(self: DomOps, node: u32, decl: []const u8) void {
        const f = self.set_style orelse return self.setAttribute(node, "style", decl);
        f(self.ctx, node, decl);
    }
    /// Add CSS to the page. Prefers the elementless hook, which a strict policy
    /// permits, and falls back to a `<style>` element, which it does not. See
    /// `add_rule`.
    ///
    /// The fallback element goes in the head, because `render` can clear the
    /// body and a rule is added only once for the page.
    pub fn addRule(self: DomOps, css: []const u8) void {
        if (self.add_rule) |f| return f(self.ctx, css);
        const node = self.createElement("style");
        self.setTextContent(node, css);
        self.appendChild(self.head, node);
        self.releaseNode(node);
    }
    /// Register one font face. Prefers the elementless hook; falls back to an
    /// `@font-face` rule, which goes wherever `addRule` goes. `buf` holds the
    /// fallback rule and needs room for the family and the source.
    pub fn addFont(self: DomOps, buf: []u8, family: []const u8, src: []const u8) void {
        if (self.add_font) |f| return f(self.ctx, family, src);
        const rule = std.fmt.bufPrint(buf, "@font-face{{font-family:{s};src:{s}}}", .{ family, src }) catch return;
        self.addRule(rule);
    }
    pub fn setTextContent(self: DomOps, node: u32, textv: []const u8) void {
        self.set_text_content(self.ctx, node, textv);
    }
    pub fn appendChild(self: DomOps, parent: u32, child: u32) void {
        self.append_child(self.ctx, parent, child);
    }
    pub fn clearChildren(self: DomOps, node: u32) void {
        self.clear_children(self.ctx, node);
    }
    /// Null when the host has no read hook, so a caller cannot tell "no host
    /// support" from "the offset is zero" and must treat both the same way:
    /// there is no offset to keep.
    pub fn readScrollOffset(self: DomOps, node: u32) ?geometry.PhysicalOffset {
        const f = self.read_scroll_offset orelse return null;
        return f(self.ctx, node);
    }
    pub fn writeScrollOffset(self: DomOps, node: u32, offset: geometry.PhysicalOffset) void {
        const f = self.write_scroll_offset orelse return;
        f(self.ctx, node, offset);
    }
    pub fn releaseNode(self: DomOps, node: u32) void {
        const f = self.release orelse return;
        f(self.ctx, node);
    }
    pub fn removeChild(self: DomOps, parent: u32, child: u32) void {
        const f = self.remove_child orelse return;
        f(self.ctx, parent, child);
    }
    pub fn insertBefore(self: DomOps, parent: u32, child: u32, ref: u32) void {
        const f = self.insert_before orelse return self.appendChild(parent, child);
        f(self.ctx, parent, child, ref);
    }
    pub fn removeAttribute(self: DomOps, node: u32, name: []const u8) void {
        const f = self.remove_attribute orelse return self.setAttribute(node, name, "");
        f(self.ctx, node, name);
    }
    pub fn firstChild(self: DomOps, node: u32) u32 {
        const f = self.first_child orelse return 0;
        return f(self.ctx, node);
    }
    pub fn nextSibling(self: DomOps, node: u32) u32 {
        const f = self.next_sibling orelse return 0;
        return f(self.ctx, node);
    }
    pub fn readElement(self: DomOps, node: u32, buf: []u8) ?ElementName {
        const f = self.read_element orelse return null;
        return f(self.ctx, node, buf);
    }
    pub fn readAttribute(self: DomOps, node: u32, name: []const u8, buf: []u8) ?[]const u8 {
        const f = self.read_attribute orelse return null;
        return f(self.ctx, node, name, buf);
    }
};

/// The CSS family name for a font. See `vdom.fontFamily`.
pub const fontFamily = vdom.fontFamily;
pub const family_len = vdom.family_len;

/// The CSS source descriptor for a font: what goes after `src:` in an
/// `@font-face` rule, and what the `FontFace` constructor takes as its second
/// argument. Caller owns the returned slice.
///
/// A font that says where it is served from is referenced by its url, under
/// `base`. `no_url` chooses for one that does not. See `NoUrl`.
pub fn fontSrc(gpa: std.mem.Allocator, base: []const u8, font_ptr: *const text.Font, no_url: NoUrl) ![]u8 {
    if (font_ptr.url != null or no_url == .file) {
        return gpa.print("url(\"{f}\") format(\"opentype\")", .{dom.fontUrl(base, font_ptr)});
    }
    const enc = std.base64.standard.Encoder;
    const b64 = try gpa.alloc(u8, enc.calcSize(font_ptr.bytes.len));
    defer gpa.free(b64);
    _ = enc.encode(b64, font_ptr.bytes);
    return gpa.print("url(data:font/otf;base64,{s}) format(\"opentype\")", .{b64});
}

/// Where a font with no url comes from.
pub const NoUrl = enum {
    /// Its bytes go into a `data:` URL, which `font-src 'self'` refuses. A
    /// page that no server rendered has no other place to get them.
    embed,
    /// The file `dom.fontFilePath` names, under the base. A server and a
    /// prerendered site serve it there.
    file,
};

/// Build the `@font-face` block for a list of fonts. Caller owns the slice.
///
/// This is the FALLBACK shape, for a host with no `add_font` hook: a rule needs
/// a stylesheet, and under a strict Content Security Policy there is nowhere to
/// put one. `add_font` exists because of that, and this stays for hosts that
/// predate it.
pub fn fontFaceCss(gpa: std.mem.Allocator, base: []const u8, fonts: []const *text.Font) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (fonts) |font_ptr| {
        var fam: [family_len]u8 = undefined;
        const src = try fontSrc(gpa, base, font_ptr, .embed);
        defer gpa.free(src);
        try buf.print(gpa, "@font-face{{font-family:{s};src:{s}}}", .{ fontFamily(&fam, font_ptr), src });
    }
    return buf.toOwnedSlice(gpa);
}

pub const max_region_depth = vdom.max_region_depth;

/// How many scroll regions `render` tracks in one frame. Unlike
/// `max_region_depth`, this counts every open region in one frame, also
/// sibling regions that do not nest. A page past the limit still renders.
/// The regions past it get no offset sync, and a fault is reported rather
/// than writing past a fixed array.
pub const max_scroll_regions = 32;

/// The scroll regions of the last frame, by the index the page reports a
/// scroll with. A caller (`WebApp`) owns one instance for the life of the page
/// and passes a pointer to every `render` call. A null pointer turns off the
/// scroll offset sync.
pub const ScrollMemory = struct {
    /// The outer div handle of each region.
    handles: [max_scroll_regions]u32 = undefined,
    /// The scroll handlers of the render object behind each region, at the
    /// same index. Valid until the tree next rebuilds.
    targets: [max_scroll_regions]?*pointer.PointerHandlers = undefined,
    count: usize = 0,
    /// True when the last `render` moved a view to the offset that its div
    /// shows. The caller then paints again, so that a list can ask for the
    /// rows at that offset.
    synced: bool = false,
};

/// The DOM handle of each node of a tree, in the same shape as the tree.
const Handles = struct {
    handle: u32 = 0,
    children: []Handles = &.{},
    /// Diff state on a node of the last tree: it has a match in the new
    /// tree, and it is already at its new place among its siblings.
    matched: bool = false,
    placed: bool = false,
    /// Diff state on a node of the new tree: the index of the last tree
    /// sibling it matched.
    from: ?usize = null,
};

/// One `Handles` for each node of `root`, all in one allocation.
fn allocHandles(arena: std.mem.Allocator, root: vdom.Node, count: usize) !*Handles {
    const flat = try arena.alloc(Handles, count);
    var next: usize = 1;
    shapeHandles(flat, &next, &flat[0], root, 0);
    std.debug.assert(next == count);
    return &flat[0];
}

fn shapeHandles(flat: []Handles, next: *usize, h: *Handles, node: vdom.Node, depth: usize) void {
    std.debug.assert(depth < vdom.max_tree_depth);
    h.* = .{ .children = flat[next.*..][0..node.children.len] };
    next.* += node.children.len;
    for (node.children, h.children) |child, *ch| shapeHandles(flat, next, ch, child, depth + 1);
}

/// The last tree that `render` put on the page, and the handle of each node.
const Retained = struct { root: vdom.Node, handles: *Handles };

/// Host state that `render` keeps between frames. A caller (`WebApp`) owns one
/// for the life of the page and passes it to every `render` call with the
/// same allocator. A null pointer turns off the diff: each render then
/// clears the body and builds it again, and keeps no handle to release.
pub const PageState = struct {
    /// The hashes of the interactive rules the page sheet already holds.
    rules: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// One arena holds the last tree. The next render builds into the other.
    arenas: [2]std.heap.ArenaAllocator.State = .{ .init, .init },
    /// The index of the arena that holds `last`.
    live: u1 = 0,
    last: ?Retained = null,

    pub fn deinit(self: *PageState, gpa: std.mem.Allocator) void {
        self.rules.deinit(gpa);
        for (self.arenas) |state| state.promote(gpa).deinit();
    }
};

fn findAttr(attrs: []const vdom.Attr, name: []const u8) ?[]const u8 {
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr.name, name)) return attr.value;
    }
    return null;
}

fn sameElement(a: vdom.Node, b: vdom.Node) bool {
    return a.kind == b.kind and std.mem.eql(u8, a.tag, b.tag);
}

/// Pairs the children of one parent. A keyed node matches the last node with
/// the same key wherever it was. The other nodes match in order, skipping the
/// keyed ones, and only when kind and tag agree.
fn matchChildren(old: []const vdom.Node, old_h: []Handles, new: []const vdom.Node, new_h: []Handles) void {
    var next_unkeyed: usize = 0;
    for (new, new_h) |node, *h| {
        h.from = null;
        if (node.key) |key| {
            for (old, old_h, 0..) |o, *oh, j| {
                const old_key = o.key orelse continue;
                if (oh.matched or old_key != key or !sameElement(o, node)) continue;
                oh.matched = true;
                h.from = j;
                break;
            }
            continue;
        }
        while (next_unkeyed < old.len and old[next_unkeyed].key != null) next_unkeyed += 1;
        if (next_unkeyed == old.len) continue;
        if (sameElement(old[next_unkeyed], node)) {
            old_h[next_unkeyed].matched = true;
            h.from = next_unkeyed;
        }
        next_unkeyed += 1;
    }
}

/// A scroll region found in this frame. `old` is null for a new div.
const Step = struct { outer: u32, old: ?vdom.Scroll, new: vdom.Scroll };

/// The DOM work of one render. It does no allocation, so once it starts the
/// render cannot fail.
const Patch = struct {
    ops: DomOps,
    mem: ?*ScrollMemory,
    sink: ?*FaultSink,
    steps: [max_scroll_regions]Step = undefined,

    fn begin(self: *Patch) void {
        const m = self.mem orelse return;
        m.count = 0;
        m.synced = false;
    }

    /// Records a region in the order regions open, which is the index the
    /// page reports a scroll with.
    fn region(self: *Patch, outer: u32, old: ?vdom.Scroll, new: vdom.Scroll) void {
        const m = self.mem orelse return;
        if (m.count >= max_scroll_regions) {
            if (self.sink) |s| s.report(.region_overflow, "scroll region count exceeded max_scroll_regions, offset not tracked");
            return;
        }
        m.handles[m.count] = outer;
        m.targets[m.count] = new.handlers;
        self.steps[m.count] = .{ .outer = outer, .old = old, .new = new };
        m.count += 1;
    }

    /// Gives each region its offset, after the whole tree is in place. A div
    /// that stays keeps the offset the browser has, because the visitor can
    /// be in the middle of a scroll. Phantom's offset wins for a region that
    /// phantom moved since the last frame, and for a new div. After a
    /// navigation every other region goes to the top. The view then takes
    /// the offset that the div shows.
    fn finish(self: *Patch, reset_scroll: bool) void {
        const m = self.mem orelse return;
        for (self.steps[0..m.count]) |step| {
            var shown: ?geometry.PhysicalOffset = null;
            if (step.old) |old| {
                if (step.new.handlers != null and old.moved != step.new.moved) {
                    self.ops.writeScrollOffset(step.outer, step.new.offset);
                    shown = step.new.offset;
                } else if (reset_scroll) {
                    self.ops.writeScrollOffset(step.outer, .zero);
                    shown = .zero;
                } else {
                    shown = self.ops.readScrollOffset(step.outer);
                }
            } else if (reset_scroll) {
                shown = .zero;
            } else if (step.new.offset.x != 0 or step.new.offset.y != 0) {
                self.ops.writeScrollOffset(step.outer, step.new.offset);
            }
            const to = shown orelse continue;
            const h = step.new.handlers orelse continue;
            const scroll_to = h.on_scroll_to orelse continue;
            if (scroll_to(h.ctx, to.x, to.y)) m.synced = true;
        }
    }

    fn insert(self: *Patch, parent: u32, child: u32, before: ?u32) void {
        if (before) |ref| return self.ops.insertBefore(parent, child, ref);
        self.ops.appendChild(parent, child);
    }

    /// Creates `node` and its subtree, parent first, and puts it in `parent`
    /// before `before`. Each node goes into the page as soon as it exists, so
    /// a scroll div has its size by the time `finish` writes its offset.
    fn create(self: *Patch, node: vdom.Node, h: *Handles, parent: u32, before: ?u32, depth: usize) void {
        std.debug.assert(depth < vdom.max_tree_depth);
        h.handle = switch (node.kind) {
            .element => self.ops.createElement(node.tag),
            .element_svg => self.ops.createElementNs(svg_ns, node.tag),
        };
        for (node.attrs) |attr| self.ops.setAttribute(h.handle, attr.name, attr.value);
        if (node.style.len > 0) self.ops.setStyle(h.handle, node.style);
        if (node.text.len > 0) self.ops.setTextContent(h.handle, node.text);
        self.insert(parent, h.handle, before);
        if (node.scroll) |s| self.region(h.handle, null, s);
        for (node.children, h.children) |child, *ch| self.create(child, ch, h.handle, null, depth + 1);
    }

    /// Sends only what differs between a node of the last tree and the node
    /// of the new tree that matched it.
    fn update(self: *Patch, old: vdom.Node, old_h: *const Handles, node: vdom.Node, h: *Handles, depth: usize) void {
        std.debug.assert(depth < vdom.max_tree_depth);
        h.handle = old_h.handle;
        for (node.attrs) |attr| {
            if (findAttr(old.attrs, attr.name)) |value| {
                const same = if (node.src_hash != 0 and std.mem.eql(u8, attr.name, "src"))
                    old.src_hash == node.src_hash
                else
                    std.mem.eql(u8, value, attr.value);
                if (same) continue;
            }
            self.ops.setAttribute(h.handle, attr.name, attr.value);
        }
        for (old.attrs) |attr| {
            if (findAttr(node.attrs, attr.name) == null) self.ops.removeAttribute(h.handle, attr.name);
        }
        if (!std.mem.eql(u8, old.style, node.style)) self.ops.setStyle(h.handle, node.style);
        // Text replaces every child. So it is cleared before new children
        // come in, and set after the old children went out.
        const text_changed = !std.mem.eql(u8, old.text, node.text);
        if (text_changed and node.text.len == 0) self.ops.setTextContent(h.handle, "");
        if (node.scroll) |s| self.region(h.handle, old.scroll, s);
        self.children(h.handle, old.children, old_h.children, node.children, h.children, depth + 1);
        if (text_changed and node.text.len > 0) self.ops.setTextContent(h.handle, node.text);
    }

    /// Makes the children of `parent` match `new`. Unmatched old children go
    /// first. Then each new child is either kept, moved, or created in place.
    fn children(self: *Patch, parent: u32, old: []const vdom.Node, old_h: []Handles, new: []const vdom.Node, new_h: []Handles, depth: usize) void {
        matchChildren(old, old_h, new, new_h);
        for (old_h) |*oh| {
            if (!oh.matched) self.remove(parent, oh);
        }
        // `at` is the first old child still in its old place. Every new
        // child before it is already in order.
        var at: usize = 0;
        for (new, new_h) |node, *h| {
            while (at < old_h.len and (!old_h[at].matched or old_h[at].placed)) at += 1;
            const before: ?u32 = if (at < old_h.len) old_h[at].handle else null;
            const j = h.from orelse {
                self.create(node, h, parent, before, depth);
                continue;
            };
            if (j != at) self.move(parent, old[j], &old_h[j], before);
            old_h[j].placed = true;
            self.update(old[j], &old_h[j], node, h, depth);
        }
    }

    /// A browser sets the scroll offset of each element in a moved subtree
    /// to zero. So each scroll div in the subtree gets its offset back.
    fn move(self: *Patch, parent: u32, old: vdom.Node, old_h: *const Handles, before: ?u32) void {
        var saved: Saved = .{};
        self.save(&saved, old, old_h, 0);
        self.insert(parent, old_h.handle, before);
        for (saved.entries[0..saved.count]) |entry| self.ops.writeScrollOffset(entry.handle, entry.offset);
    }

    const Saved = struct {
        entries: [max_scroll_regions]struct { handle: u32, offset: geometry.PhysicalOffset } = undefined,
        count: usize = 0,
    };

    fn save(self: *Patch, saved: *Saved, node: vdom.Node, h: *const Handles, depth: usize) void {
        std.debug.assert(depth < vdom.max_tree_depth);
        if (saved.count == max_scroll_regions) return;
        if (node.scroll != null) {
            const offset = self.ops.readScrollOffset(h.handle) orelse return;
            if (offset.x != 0 or offset.y != 0) {
                saved.entries[saved.count] = .{ .handle = h.handle, .offset = offset };
                saved.count += 1;
            }
        }
        for (node.children, h.children) |child, *ch| self.save(saved, child, ch, depth + 1);
    }

    fn remove(self: *Patch, parent: u32, h: *const Handles) void {
        self.ops.removeChild(parent, h.handle);
        self.release(h, 0);
    }

    fn release(self: *Patch, h: *const Handles, depth: usize) void {
        std.debug.assert(depth < vdom.max_tree_depth);
        for (h.children) |*ch| self.release(ch, depth + 1);
        self.ops.releaseNode(h.handle);
    }
};

/// Puts the display list on the page. `sink` records a fault when the display
/// list nests more clip/scroll regions than `max_region_depth`. Pass null
/// where no sink is wired up.
///
/// `page`, if given, keeps the tree between frames. Then each render compares
/// the new tree with the last one and sends only what changed. Nodes and
/// scroll divs that stay keep their DOM element, and each removed node's
/// handle is released. A host with no `insert_before` or `remove_child` gets
/// the body built again. The page also keeps each interactive rule once, so a
/// rule is added only for a new class. Pass the same `gpa` on every call.
///
/// Every step that can fail runs before the first DOM call. A render that
/// returns an error leaves the page, `page` and `mem` as they were. The
/// handlers in `mem` can then point at freed views, so the caller must drop
/// them. The error return covers Zig errors only. A JS exception in the middle
/// of a patch leaves the retained tree behind the DOM. That can occur only
/// when code outside phantom edits the body.
///
/// `mem`, if given, keeps the scroll regions in step with their views. See
/// `Patch.finish` for which offset wins. `reset_scroll` is true exactly once,
/// on the render that follows a navigation: the caller is expected to clear it
/// after that one call. A visitor arriving at a new route expects its top, not
/// wherever the previous route happened to be scrolled to. A view that
/// `render` had to move sets `mem.synced`.
pub fn render(gpa: std.mem.Allocator, ops: DomOps, list: display_list.DisplayList, viewport: geometry.PhysicalSize, bg: geometry.Color, sink: ?*FaultSink, mem: ?*ScrollMemory, page: ?*PageState, reset_scroll: bool) !void {
    const pg = page orelse return renderAll(gpa, ops, list, viewport, bg, sink, mem, reset_scroll);
    const next: u1 = 1 - pg.live;
    var arena_state = pg.arenas[next].promote(gpa);
    defer pg.arenas[next] = arena_state.state;
    errdefer _ = arena_state.reset(.retain_capacity);
    const arena = arena_state.allocator();

    const tree = try vdom.build(arena, list, viewport, bg, sink);
    const handles = try allocHandles(arena, tree.root, tree.count);
    // The rules of classes new to the page go to a sheet with no element. A
    // strict policy refuses a `<style>` element even while it is empty. See
    // `DomOps.add_rule`.
    var css: std.ArrayList(u8) = .empty;
    var fresh: usize = 0;
    for (tree.rules) |rule| {
        if (pg.rules.contains(rule.hash)) continue;
        try css.appendSlice(arena, rule.css);
        fresh += 1;
    }
    var remember = true;
    pg.rules.ensureUnusedCapacity(gpa, @intCast(fresh)) catch {
        if (sink) |s| s.report(.oom, "interactive rules were not remembered, so the next frame adds them again");
        remember = false;
    };

    var patch: Patch = .{ .ops = ops, .mem = mem, .sink = sink };
    patch.begin();
    const new_root = [1]vdom.Node{tree.root};
    if (pg.last) |last| {
        if (ops.insert_before != null and ops.remove_child != null) {
            const old_root = [1]vdom.Node{last.root};
            patch.children(ops.body, &old_root, last.handles[0..1], &new_root, handles[0..1], 0);
        } else {
            patch.release(last.handles, 0);
            ops.clearChildren(ops.body);
            patch.create(tree.root, handles, ops.body, null, 0);
        }
    } else {
        ops.clearChildren(ops.body);
        patch.create(tree.root, handles, ops.body, null, 0);
    }
    if (css.items.len > 0) ops.addRule(css.items);
    if (remember) {
        for (tree.rules) |rule| pg.rules.putAssumeCapacity(rule.hash, {});
    }
    patch.finish(reset_scroll);

    pg.last = .{ .root = tree.root, .handles = handles };
    var old_arena = pg.arenas[pg.live].promote(gpa);
    _ = old_arena.reset(.retain_capacity);
    pg.arenas[pg.live] = old_arena.state;
    pg.live = next;
}

/// Clears the body and builds it again, with no state kept between frames.
fn renderAll(gpa: std.mem.Allocator, ops: DomOps, list: display_list.DisplayList, viewport: geometry.PhysicalSize, bg: geometry.Color, sink: ?*FaultSink, mem: ?*ScrollMemory, reset_scroll: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try vdom.build(arena, list, viewport, bg, sink);
    const handles = try allocHandles(arena, tree.root, tree.count);
    var css: std.ArrayList(u8) = .empty;
    for (tree.rules) |rule| try css.appendSlice(arena, rule.css);

    var patch: Patch = .{ .ops = ops, .mem = mem, .sink = sink };
    patch.begin();
    ops.clearChildren(ops.body);
    patch.create(tree.root, handles, ops.body, null, 0);
    if (css.items.len > 0) ops.addRule(css.items);
    patch.finish(reset_scroll);
}

/// Takes the page a server rendered into the body as the last tree, so the
/// next `render` patches it in place. `list` is the first frame, at the size
/// the server rendered. Call it once, before the first `render`.
///
/// The walk matches each node to the element at its place by kind and tag,
/// and makes no element. Then each element gets the style, attributes and
/// text of its node, so its style moves from the `pN` rule of the server
/// sheet to the CSSOM and the `pN` class goes. A frame on the client can
/// differ from the frame on the server at the same shape, for example a
/// clock, and the retained tree must hold what the page shows. Each region
/// whose view is not at the top scrolls to its offset. The server sheet
/// already holds the interactive rules, so `page` records them as added.
///
/// Returns false and changes nothing when the body does not have the shape
/// of the tree: `sink` gets `hydrate_mismatch`, each handle the walk took is
/// released, and the next `render` builds the body again. Also false, with
/// no fault, on a host that cannot walk, patch or release.
pub fn hydrate(gpa: std.mem.Allocator, ops: DomOps, list: display_list.DisplayList, viewport: geometry.PhysicalSize, bg: geometry.Color, sink: ?*FaultSink, page: *PageState) !bool {
    std.debug.assert(page.last == null);
    if (ops.first_child == null or ops.next_sibling == null or ops.read_element == null) return false;
    if (ops.insert_before == null or ops.remove_child == null or ops.release == null) return false;
    const next: u1 = 1 - page.live;
    var arena_state = page.arenas[next].promote(gpa);
    defer page.arenas[next] = arena_state.state;
    errdefer _ = arena_state.reset(.retain_capacity);
    const arena = arena_state.allocator();

    const tree = try vdom.build(arena, list, viewport, bg, sink);
    const handles = try allocHandles(arena, tree.root, tree.count);
    try page.rules.ensureUnusedCapacity(gpa, @intCast(tree.rules.len));

    const walk: Walk = .{ .ops = ops };
    const first = ops.firstChild(ops.body);
    if (first == 0 or !walk.adopt(tree.root, handles, first, 0)) {
        walk.release(handles, 0);
        if (sink) |s| s.report(.hydrate_mismatch, "the server page does not match the first frame, so it is built again");
        _ = arena_state.reset(.retain_capacity);
        return false;
    }
    walk.restyle(tree.root, handles, 0);
    walk.scroll(tree.root, handles, 0);
    for (tree.rules) |rule| page.rules.putAssumeCapacity(rule.hash, {});
    page.last = .{ .root = tree.root, .handles = handles };
    page.live = next;
    return true;
}

/// The longest tag `vdom.build` makes, with room to spare.
const max_tag_len = 16;

const Walk = struct {
    ops: DomOps,

    /// Keeps `el` in `h`, then matches its element children to the children
    /// of `node` in order. False at the first kind, tag or count that differs.
    fn adopt(self: Walk, node: vdom.Node, h: *Handles, el: u32, depth: usize) bool {
        std.debug.assert(depth < vdom.max_tree_depth);
        h.handle = el;
        var buf: [max_tag_len]u8 = undefined;
        const name = self.ops.readElement(el, &buf) orelse return false;
        if (name.kind != node.kind or !std.mem.eql(u8, name.tag, node.tag)) return false;
        var child = self.ops.firstChild(el);
        for (node.children, h.children) |c, *ch| {
            if (child == 0) return false;
            if (!self.adopt(c, ch, child, depth + 1)) return false;
            child = self.ops.nextSibling(child);
        }
        if (child == 0) return true;
        self.ops.releaseNode(child);
        return false;
    }

    /// Gives each element the style, attributes and text of its node, so the
    /// page shows the client frame where it differs from the server frame.
    fn restyle(self: Walk, node: vdom.Node, h: *const Handles, depth: usize) void {
        std.debug.assert(depth < vdom.max_tree_depth);
        if (node.style.len > 0) self.ops.setStyle(h.handle, node.style);
        for (node.attrs) |attr| self.ops.setAttribute(h.handle, attr.name, attr.value);
        if (findAttr(node.attrs, "class") == null) self.ops.removeAttribute(h.handle, "class");
        const div = node.kind == .element and std.mem.eql(u8, node.tag, "div");
        // A div at the place of a server scroll region must not read as one.
        if (div and findAttr(node.attrs, "data-phantom-scroll") == null) {
            self.ops.removeAttribute(h.handle, "data-phantom-scroll");
        }
        // A box at the place of a server text div must lose the text.
        const leaf_div = div and node.children.len == 0;
        if (node.text.len > 0 or leaf_div) self.ops.setTextContent(h.handle, node.text);
        for (node.children, h.children) |child, *ch| self.restyle(child, ch, depth + 1);
    }

    /// Scrolls each region to the offset of its view. Runs after `restyle`,
    /// so each content div has its size and the offset is not clamped.
    fn scroll(self: Walk, node: vdom.Node, h: *const Handles, depth: usize) void {
        std.debug.assert(depth < vdom.max_tree_depth);
        if (node.scroll) |s| {
            if (s.offset.x != 0 or s.offset.y != 0) self.ops.writeScrollOffset(h.handle, s.offset);
        }
        for (node.children, h.children) |child, *ch| self.scroll(child, ch, depth + 1);
    }

    /// Releases each handle the walk kept. A node it did not reach has none.
    fn release(self: Walk, h: *const Handles, depth: usize) void {
        std.debug.assert(depth < vdom.max_tree_depth);
        for (h.children) |*ch| self.release(ch, depth + 1);
        if (h.handle != 0) self.ops.releaseNode(h.handle);
    }
};

// Recording mock for tests. No global mutable state: each fn casts ctx to *Recorder.
// Exported so a test outside this file (a WebApp test with no browser) can
// drive one through `phantom.backend.dom_calls.Recorder`.
pub const Recorder = struct {
    gpa: std.mem.Allocator,
    log: std.ArrayList([]u8) = .empty,
    next_handle: u32 = 100,
    /// Mimics the address bar for `read_location` / `write_location`. Empty
    /// until a write happens, the same as a fresh page with nothing written
    /// to its history yet.
    location_buf: [location_cap]u8 = undefined,
    location_len: usize = 0,
    /// The query string `read_query` reports, with no leading "?". Empty until
    /// a test sets one, which is a page opened on an address with no query.
    search_buf: [location_cap]u8 = undefined,
    search_len: usize = 0,
    /// The host `read_host` reports. Empty until a test sets one, which reads as
    /// a page with no host, a thing no real browser produces; a test that cares
    /// calls `setHost` first.
    host_buf: [location_cap]u8 = undefined,
    host_len: usize = 0,
    /// Scroll offsets a test has set, simulating the browser. Bounded, like
    /// the rest of this mock; a test needs at most a handful of regions.
    scroll_offsets: [scroll_offsets_cap]ScrollEntry = undefined,
    scroll_offsets_len: usize = 0,
    /// The handles released so far, and how many calls used a handle after
    /// its release or released it again. A test expects zero.
    released: std.AutoHashMapUnmanaged(u32, void) = .empty,
    misuse: usize = 0,
    /// The parent of each node in the page. A browser sets the scroll offset
    /// of each element in a moved subtree to zero. This mock does the same,
    /// so it must know the subtree.
    parents: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Elements a server wrote into the page before the first render, in
    /// document order. `first_child`, `next_sibling` and `read_element` walk
    /// them. A test adds them with `addElement`.
    served: std.ArrayList(Served) = .empty,
    served_attrs: std.ArrayList(ServedAttr) = .empty,

    const Served = struct { handle: u32, parent: u32, kind: vdom.Kind, tag: []const u8 };
    const ServedAttr = struct { node: u32, name: []const u8, value: []const u8 };

    /// Comfortably past `router.max_path`, so a test can park a location here
    /// that is too long for the router's own buffer without touching this
    /// buffer's limit.
    pub const location_cap = 512;

    pub const scroll_offsets_cap = 8;

    const ScrollEntry = struct { node: u32, offset: geometry.PhysicalOffset };

    /// Sets the location `read_location` reports, without recording a call.
    /// Lets a test start a Recorder already parked at a given address, the
    /// same as a page freshly opened on a link somebody sent.
    pub fn setLocation(self: *Recorder, path: []const u8) void {
        @memcpy(self.location_buf[0..path.len], path);
        self.location_len = path.len;
    }

    fn readLocation(ctx: *anyopaque, buf: []u8) ?[]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.location_len > buf.len) return null;
        @memcpy(buf[0..self.location_len], self.location_buf[0..self.location_len]);
        return buf[0..self.location_len];
    }

    /// Sets the query string `readQuery` reports, with no leading "?", without
    /// recording a call. The browser keeps the query out of the path, so this is
    /// separate from `setLocation` rather than parsed back out of it.
    pub fn setSearch(self: *Recorder, query: []const u8) void {
        @memcpy(self.search_buf[0..query.len], query);
        self.search_len = query.len;
    }

    fn readQuery(ctx: *anyopaque, buf: []u8) ?[]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.search_len > buf.len) return null;
        @memcpy(buf[0..self.search_len], self.search_buf[0..self.search_len]);
        return buf[0..self.search_len];
    }

    /// Stands in for `crypto.getRandomValues`. Deterministic on purpose: a test
    /// needs to know what it got, and what is under test is that the bytes come
    /// from the host at all rather than from `noRandom`'s memset of zeros. The
    /// sequence starts at 1 so a filled buffer never looks like an empty one.
    fn fillRandom(ctx: *anyopaque, buf: []u8) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("fillRandom({d})", .{buf.len});
        for (buf, 0..) |*b, i| b.* = @truncate(i +% 1);
        return true;
    }

    /// Sets the host `readHost` reports, without recording a call.
    pub fn setHost(self: *Recorder, host: []const u8) void {
        @memcpy(self.host_buf[0..host.len], host);
        self.host_len = host.len;
    }

    fn readHost(ctx: *anyopaque, buf: []u8) ?[]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.host_len > buf.len) return null;
        @memcpy(buf[0..self.host_len], self.host_buf[0..self.host_len]);
        return buf[0..self.host_len];
    }

    fn writeLocation(ctx: *anyopaque, path: []const u8, mode: platform.WriteMode) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("writeLocation({s},{s})", .{ path, @tagName(mode) });
        self.setLocation(path);
    }

    /// Sets the offset `readScrollOffset` reports for `node`, without
    /// recording a call. Lets a test simulate the browser having scrolled a
    /// region, the same way `setLocation` simulates the address bar.
    pub fn setScrollOffset(self: *Recorder, node: u32, offset: geometry.PhysicalOffset) void {
        for (self.scroll_offsets[0..self.scroll_offsets_len]) |*e| {
            if (e.node == node) {
                e.offset = offset;
                return;
            }
        }
        self.scroll_offsets[self.scroll_offsets_len] = .{ .node = node, .offset = offset };
        self.scroll_offsets_len += 1;
    }

    fn readScrollOffset(ctx: *anyopaque, node: u32) geometry.PhysicalOffset {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.use(node);
        var off = geometry.PhysicalOffset.zero;
        for (self.scroll_offsets[0..self.scroll_offsets_len]) |e| {
            if (e.node == node) {
                off = e.offset;
                break;
            }
        }
        self.rec("readScrollOffset({d})->{d},{d}", .{ node, off.x, off.y });
        return off;
    }

    fn writeScrollOffset(ctx: *anyopaque, node: u32, offset: geometry.PhysicalOffset) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.use(node);
        self.rec("writeScrollOffset({d},{d},{d})", .{ node, offset.x, offset.y });
        self.setScrollOffset(node, offset);
    }

    /// Answers every request with an empty 200.
    fn httpSend(ctx: *anyopaque, gpa: std.mem.Allocator, req: web_net.Request) ?[]u8 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("httpSend({s},{s},{d},{s})", .{ req.method, req.host, req.port, req.target });
        return web_net.buildResponse(gpa, 200, "", "") catch null;
    }

    fn openEventSource(ctx: *anyopaque, id: u32, url: []const u8, types: []const u8) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("openEventSource({d},{s},{s})", .{ id, url, types });
        return true;
    }

    fn closeEventSource(ctx: *anyopaque, id: u32) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("closeEventSource({d})", .{id});
    }

    fn rec(self: *Recorder, comptime fmt: []const u8, args: anytype) void {
        const line = self.gpa.print(fmt, args) catch return;
        self.log.append(self.gpa, line) catch {};
    }

    pub fn deinit(self: *Recorder) void {
        for (self.log.items) |l| self.gpa.free(l);
        self.log.deinit(self.gpa);
        self.released.deinit(self.gpa);
        self.parents.deinit(self.gpa);
        self.served.deinit(self.gpa);
        self.served_attrs.deinit(self.gpa);
    }

    /// Puts an element the server wrote at the end of `parent`, without
    /// recording a call. `tag` must outlive the Recorder.
    pub fn addElement(self: *Recorder, parent: u32, kind: vdom.Kind, tag: []const u8) !u32 {
        self.next_handle += 1;
        try self.served.append(self.gpa, .{ .handle = self.next_handle, .parent = parent, .kind = kind, .tag = tag });
        try self.parents.put(self.gpa, self.next_handle, parent);
        return self.next_handle;
    }

    /// Gives a served element an attribute, without recording a call. Both
    /// strings must outlive the Recorder.
    pub fn addAttribute(self: *Recorder, node: u32, name: []const u8, value: []const u8) !void {
        try self.served_attrs.append(self.gpa, .{ .node = node, .name = name, .value = value });
    }

    /// Writes `root` into the body the way a server page has it: the tree in
    /// document order, then the boot script.
    pub fn serveTree(self: *Recorder, root: vdom.Node) !void {
        try self.serveNode(root, 1, 0);
        _ = try self.addElement(1, .element, "script");
    }

    fn serveNode(self: *Recorder, node: vdom.Node, parent: u32, depth: usize) !void {
        std.debug.assert(depth < vdom.max_tree_depth);
        const handle = try self.addElement(parent, node.kind, node.tag);
        for (node.children) |child| try self.serveNode(child, handle, depth + 1);
    }

    fn servedAfter(self: *Recorder, parent: u32, from: usize) u32 {
        for (self.served.items[from..]) |s| {
            if (s.parent == parent) return s.handle;
        }
        return 0;
    }

    fn firstChild(ctx: *anyopaque, node: u32) u32 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.use(node);
        const child = self.servedAfter(node, 0);
        self.rec("firstChild({d})->{d}", .{ node, child });
        return child;
    }

    fn nextSibling(ctx: *anyopaque, node: u32) u32 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.use(node);
        var next: u32 = 0;
        for (self.served.items, 0..) |s, i| {
            if (s.handle == node) {
                next = self.servedAfter(s.parent, i + 1);
                break;
            }
        }
        self.rec("nextSibling({d})->{d}", .{ node, next });
        return next;
    }

    fn readElement(ctx: *anyopaque, node: u32, buf: []u8) ?DomOps.ElementName {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.use(node);
        for (self.served.items) |s| {
            if (s.handle != node) continue;
            if (s.tag.len > buf.len) return null;
            @memcpy(buf[0..s.tag.len], s.tag);
            return .{ .kind = s.kind, .tag = buf[0..s.tag.len] };
        }
        return null;
    }

    fn readAttribute(ctx: *anyopaque, node: u32, name: []const u8, buf: []u8) ?[]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.use(node);
        for (self.served_attrs.items) |a| {
            if (a.node != node or !std.mem.eql(u8, a.name, name)) continue;
            if (a.value.len > buf.len) return null;
            @memcpy(buf[0..a.value.len], a.value);
            return buf[0..a.value.len];
        }
        return null;
    }

    /// Puts `child` under `parent`. A child that was in the page already
    /// moves, and each scroll offset in its subtree goes back to zero.
    fn place(self: *Recorder, parent: u32, child: u32) void {
        if (self.parents.contains(child)) self.zeroSubtree(child);
        self.parents.put(self.gpa, child, parent) catch {};
    }

    fn zeroSubtree(self: *Recorder, root: u32) void {
        for (self.scroll_offsets[0..self.scroll_offsets_len]) |*e| {
            var node = e.node;
            var depth: usize = 0;
            while (depth <= vdom.max_tree_depth) : (depth += 1) {
                if (node == root) {
                    e.offset = .zero;
                    break;
                }
                node = self.parents.get(node) orelse break;
            }
        }
    }

    fn use(self: *Recorder, node: u32) void {
        if (self.released.contains(node)) self.misuse += 1;
    }

    fn createElement(ctx: *anyopaque, tag: []const u8) u32 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.next_handle += 1;
        self.rec("createElement({s})->{d}", .{ tag, self.next_handle });
        return self.next_handle;
    }

    fn createElementNS(ctx: *anyopaque, ns: []const u8, tag: []const u8) u32 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.next_handle += 1;
        self.rec("createElementNS({s},{s})->{d}", .{ ns, tag, self.next_handle });
        return self.next_handle;
    }

    fn createTextNode(ctx: *anyopaque, data: []const u8) u32 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.next_handle += 1;
        self.rec("createTextNode({s})->{d}", .{ data, self.next_handle });
        return self.next_handle;
    }

    fn setAttribute(ctx: *anyopaque, node: u32, name: []const u8, value: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.use(node);
        self.rec("setAttribute({d},{s},{s})", .{ node, name, value });
    }

    /// Recorded under its own name, not as `setAttribute(n,style,...)`, because
    /// the difference between the two IS the thing under test: one is markup a
    /// Content Security Policy refuses and the other is not.
    fn setStyle(ctx: *anyopaque, node: u32, decl: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.use(node);
        self.rec("setStyle({d},{s})", .{ node, decl });
    }

    fn addRule(ctx: *anyopaque, css: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("addRule({s})", .{css});
    }

    fn addFont(ctx: *anyopaque, family: []const u8, src: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("addFont({s},{s})", .{ family, src });
    }

    fn setTextContent(ctx: *anyopaque, node: u32, textv: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.use(node);
        self.rec("setTextContent({d},{s})", .{ node, textv });
    }

    fn appendChild(ctx: *anyopaque, parent: u32, child: u32) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.use(parent);
        self.use(child);
        self.rec("appendChild({d},{d})", .{ parent, child });
        self.place(parent, child);
    }

    fn insertBefore(ctx: *anyopaque, parent: u32, child: u32, ref: u32) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.use(parent);
        self.use(child);
        self.use(ref);
        self.rec("insertBefore({d},{d},{d})", .{ parent, child, ref });
        self.place(parent, child);
    }

    fn removeChild(ctx: *anyopaque, parent: u32, child: u32) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.use(parent);
        self.use(child);
        self.rec("removeChild({d},{d})", .{ parent, child });
        self.zeroSubtree(child);
        _ = self.parents.remove(child);
    }

    fn removeAttribute(ctx: *anyopaque, node: u32, name: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.use(node);
        self.rec("removeAttribute({d},{s})", .{ node, name });
    }

    fn clearChildren(ctx: *anyopaque, node: u32) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.use(node);
        self.rec("clearChildren({d})", .{node});
    }

    fn release(ctx: *anyopaque, node: u32) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.use(node);
        self.released.put(self.gpa, node, {}) catch {};
        self.rec("release({d})", .{node});
    }

    pub fn ops(self: *Recorder) DomOps {
        return .{
            .ctx = self,
            .create_element = createElement,
            .create_element_ns = createElementNS,
            .create_text_node = createTextNode,
            .set_attribute = setAttribute,
            .set_text_content = setTextContent,
            .append_child = appendChild,
            .clear_children = clearChildren,
            .body = 1,
            .head = 2,
            .read_location = readLocation,
            .read_query = readQuery,
            .read_host = readHost,
            .set_style = setStyle,
            .add_rule = addRule,
            .add_font = addFont,
            .fill_random = fillRandom,
            .write_location = writeLocation,
            .read_scroll_offset = readScrollOffset,
            .write_scroll_offset = writeScrollOffset,
            .http_send = httpSend,
            .open_event_source = openEventSource,
            .close_event_source = closeEventSource,
            .release = release,
            .remove_child = removeChild,
            .insert_before = insertBefore,
            .remove_attribute = removeAttribute,
            .first_child = firstChild,
            .next_sibling = nextSibling,
            .read_element = readElement,
            .read_attribute = readAttribute,
        };
    }
};

fn contains(log: []const []u8, needle: []const u8) bool {
    for (log) |l| if (std.mem.indexOf(u8, l, needle) != null) return true;
    return false;
}

/// The class value of the `n`th recorded `class` attribute, or null.
fn classAt(log: []const []u8, n: usize) ?[]const u8 {
    var seen: usize = 0;
    for (log) |l| {
        const at = std.mem.indexOf(u8, l, ",class,") orelse continue;
        if (seen == n) return l[at + ",class,".len .. l.len - 1];
        seen += 1;
    }
    return null;
}

/// How many recorded lines hold `needle`.
fn countLines(log: []const []u8, needle: []const u8) usize {
    var n: usize = 0;
    for (log) |l| {
        if (std.mem.indexOf(u8, l, needle) != null) n += 1;
    }
    return n;
}

/// Index of the first recorded line holding `needle`, for tests that pin the
/// order of two calls and not only that both happened.
fn indexOfLine(log: []const []u8, needle: []const u8) ?usize {
    for (log, 0..) |l, i| if (std.mem.indexOf(u8, l, needle) != null) return i;
    return null;
}

test "dom_calls: fill rrect creates a styled div appended to the container" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 10, .y = 20, .width = 30, .height = 40 },
        .radius = 4,
        .color = geometry.Color.rgb(1, 0, 0),
    } });
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);
    // clears body, builds the container, then the rrect div with the right style + append.
    try std.testing.expect(contains(rec.log.items, "clearChildren(1)"));
    try std.testing.expect(contains(rec.log.items, "position:relative;width:12.5rem"));
    try std.testing.expect(contains(rec.log.items, "left:0.625rem;top:1.25rem;width:1.875rem;height:2.5rem;border-radius:0.25rem;background:rgba(255,0,0,1)"));
}

test "dom_calls: a text primitive names its font the same way the font-face does" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    const glyphs = [_]display_list.PositionedGlyph{.{ .cp = 'h', .x = 0, .y = 0 }};
    try list.append(gpa, .{ .text = .{
        .glyphs = &glyphs,
        .text = "<b>hi</b>",
        .font = &font,
        .size = 16,
        .color = geometry.Color.rgb(1, 1, 1),
        .origin = geometry.PhysicalOffset{ .x = 5, .y = 8 },
    } });
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);
    // The raw string is passed directly (browser handles escaping).
    try std.testing.expect(contains(rec.log.items, "setTextContent") and contains(rec.log.items, "<b>hi</b>"));
    // The family the run asks for must be the one the face was declared under.
    // Comparing the two rather than pinning a literal is the whole point: an
    // index satisfied a literal happily while naming a different font on any
    // frame whose text used a different set.
    var fam: [family_len]u8 = undefined;
    const family = fontFamily(&fam, &font);
    const decl = try fontFaceCss(gpa, "/", &.{&font});
    defer gpa.free(decl);
    try std.testing.expect(std.mem.indexOf(u8, decl, family) != null);

    var want: [family_len + 12]u8 = undefined;
    const asked = try std.fmt.bufPrint(&want, "font-family:{s}", .{family});
    try std.testing.expect(contains(rec.log.items, asked));
}

test "dom_calls: an italic underlined run asks the browser for both" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var font = try text.Font.load(gpa, text.builtin.mesmerize_rg_bytes);
    defer font.deinit(gpa);
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .text = .{
        .glyphs = &.{},
        .text = "em",
        .font = &font,
        .size = 16,
        .color = geometry.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
        .italic = true,
        .underline = true,
    } });
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);
    try std.testing.expect(contains(rec.log.items, "font-style:italic"));
    try std.testing.expect(contains(rec.log.items, "text-decoration:underline"));
}

test "dom_calls: stroke rrect records a border:...solid rgba style" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 5, .y = 10, .width = 60, .height = 30 },
        .radius = 3,
        .color = geometry.Color.rgb(0, 1, 0),
        .stroke_width = 2,
    } });
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);
    // Must have border-radius, box-sizing, and the border solid rgba style.
    try std.testing.expect(contains(rec.log.items, "box-sizing:border-box"));
    try std.testing.expect(contains(rec.log.items, "border:0.125rem solid rgba("));
    try std.testing.expect(contains(rec.log.items, "background:transparent"));
}

test "dom_calls: an interactive rrect gets its hover rule with no style element anywhere" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 80, .height = 40 },
        .radius = 4,
        .color = geometry.Color.rgb(0, 0, 1),
        .hover_color = geometry.Color.rgb(0, 0, 0.9),
        .active_color = geometry.Color.rgb(0, 0, 0.8),
    } });
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);
    // The div carries a class, and the hover rule names that class.
    const cls = classAt(rec.log.items, 0).?;
    try std.testing.expect(std.mem.startsWith(u8, cls, "pb-"));
    // No style element at all. A strict policy refuses one the moment it enters
    // the document, even while it is still empty, so the rule goes to a sheet
    // that has no element for a policy to refuse.
    try std.testing.expect(!contains(rec.log.items, "createElement(style)"));
    var want: [64]u8 = undefined;
    try std.testing.expect(contains(rec.log.items, try std.fmt.bufPrint(&want, ".{s}:hover{{background:", .{cls})));
}

test "an interactive rectangle gets a pointer cursor and a plain one does not" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    // One rectangle with a hover colour, and one without.
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .radius = 0,
        .color = geometry.Color.rgb(0, 0, 1),
        .hover_color = geometry.Color.rgb(0, 0, 0.5),
    } });
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 20, .width = 10, .height = 10 },
        .radius = 0,
        .color = geometry.Color.rgb(1, 0, 0),
    } });
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);
    const cls = classAt(rec.log.items, 0).?;
    var want: [64]u8 = undefined;
    try std.testing.expect(contains(rec.log.items, try std.fmt.bufPrint(&want, ".{s}{{cursor:pointer}}", .{cls})));
    try std.testing.expectEqual(@as(?[]const u8, null), classAt(rec.log.items, 1));
}

test "dom_calls: a wrapped paragraph's three text runs each set a different line, never the whole paragraph" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    // Narrow enough that "one", "two" and "three" each land on their own line.
    const source = "one two three";
    const m = text.mono.TextMetrics{ .mono = text.mono.Mono.fromCell(10, 20) };
    var p = try text.layout.layoutParagraph(gpa, &font, source, 14, m, 55);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), p.lines.len);

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    var y: f32 = 0;
    for (p.lines) |l| {
        try list.append(gpa, .{ .text = .{
            .glyphs = l.glyphs,
            .text = source[l.start..l.end],
            .font = &font,
            .size = 14,
            .color = geometry.Color.rgb(1, 1, 1),
            .origin = .{ .x = 0, .y = y },
        } });
        y += l.height;
    }
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);

    // Three distinct setTextContent calls, one per line, exactly matching the
    // line each was drawn for.
    try std.testing.expect(contains(rec.log.items, "setTextContent(102,one)"));
    try std.testing.expect(contains(rec.log.items, "setTextContent(103,two)"));
    try std.testing.expect(contains(rec.log.items, "setTextContent(104,three)"));
    // This is what a run holding `self.text` (the whole paragraph) would have
    // produced on every line, and is exactly what must never appear.
    try std.testing.expect(!contains(rec.log.items, source));
}

test "dom_calls: push_scroll creates outer+inner divs and adjusts child coords" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    // push_scroll: viewport x=10,y=20,w=100,h=50; content w=100,h=300
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 10, .y = 20, .width = 100, .height = 50 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
    } });
    // fillRRect at absolute x=10,y=120,w=80,h=20 -> after subtract origin (10,20): left=0,top=100
    try list.append(gpa, .{ .rrect = .{
        .rect = geometry.PhysicalRect{ .x = 10, .y = 120, .width = 80, .height = 20 },
        .radius = 0,
        .color = geometry.Color.rgb(1, 0, 0),
    } });
    try list.append(gpa, .{ .pop_scroll = {} });
    try render(gpa, rec.ops(), list, .{ .width = 300, .height = 200 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);
    // Outer div has overflow:scroll and the viewport position/size.
    try std.testing.expect(contains(rec.log.items, "overflow:scroll"));
    try std.testing.expect(contains(rec.log.items, "left:0.625rem;top:1.25rem;width:6.25rem;height:3.125rem;overflow:scroll"));
    // Inner div has position:relative and the content size.
    try std.testing.expect(contains(rec.log.items, "position:relative;width:6.25rem;height:18.75rem"));
    // The rrect is appended to the inner div with adjusted coords: left=0 (10-10), top=100 (120-20).
    try std.testing.expect(contains(rec.log.items, "left:0;top:6.25rem"));
}

test "dom_calls: a clip nested in a scroll positions itself relative to the scroll's origin, not the canvas" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 10, .y = 20, .width = 100, .height = 100 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
    } });
    // Clip at absolute x=30,y=50: nested inside the scroll, so its own div must
    // sit at (30-10, 50-20) relative to the scroll's inner div, not at (30,50).
    try list.append(gpa, .{ .push_clip = .{
        .rect = geometry.PhysicalRect{ .x = 30, .y = 50, .width = 40, .height = 40 },
        .radius = 0,
    } });
    try list.append(gpa, .{ .pop_clip = {} });
    try list.append(gpa, .{ .pop_scroll = {} });
    try render(gpa, rec.ops(), list, .{ .width = 300, .height = 200 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);
    try std.testing.expect(contains(rec.log.items, "left:1.25rem;top:1.875rem;width:2.5rem;height:2.5rem"));
    // The un-adjusted absolute position must not appear: that would place the
    // clip twice as far from the scroll's own corner as it should be.
    try std.testing.expect(!contains(rec.log.items, "left:1.875rem;top:3.125rem;width:2.5rem;height:2.5rem"));
}

test "dom_calls: after a clip inside a scroll pops, later primitives return to the scroll's own div and origin" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 10, .y = 20, .width = 100, .height = 100 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
    } });
    try list.append(gpa, .{ .push_clip = .{
        .rect = geometry.PhysicalRect{ .x = 5, .y = 5, .width = 50, .height = 50 },
        .radius = 0,
    } });
    try list.append(gpa, .{ .rrect = .{
        .rect = geometry.PhysicalRect{ .x = 10, .y = 10, .width = 8, .height = 8 },
        .radius = 0,
        .color = geometry.Color.rgb(1, 0, 0),
    } });
    try list.append(gpa, .{ .pop_clip = {} });
    // After the clip pops, this rrect is still inside the scroll: it must
    // append to the scroll's inner div (handle 103, not the container) and use
    // the scroll's origin (10,20), not the clip's or the canvas's absolute one.
    try list.append(gpa, .{ .rrect = .{
        .rect = geometry.PhysicalRect{ .x = 15, .y = 25, .width = 9, .height = 9 },
        .radius = 0,
        .color = geometry.Color.rgb(0, 1, 0),
    } });
    try list.append(gpa, .{ .pop_scroll = {} });
    try render(gpa, rec.ops(), list, .{ .width = 300, .height = 200 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);
    // container=101, scroll outer=102, scroll inner=103, clip div=104, first
    // rrect div=105, second rrect div=106.
    try std.testing.expect(contains(rec.log.items, "appendChild(103,106)"));
    try std.testing.expect(!contains(rec.log.items, "appendChild(101,106)"));
    try std.testing.expect(contains(rec.log.items, "left:0.3125rem;top:0.3125rem;width:0.5625rem;height:0.5625rem"));
}

test "dom_calls: after a scroll nested inside another scroll pops, later primitives return to the outer scroll's div and origin" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 10, .y = 20, .width = 200, .height = 200 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 200, .height = 400 },
    } });
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 30, .y = 40, .width = 50, .height = 50 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 50, .height = 150 },
    } });
    try list.append(gpa, .{ .rrect = .{
        .rect = geometry.PhysicalRect{ .x = 35, .y = 45, .width = 6, .height = 6 },
        .radius = 0,
        .color = geometry.Color.rgb(1, 0, 0),
    } });
    try list.append(gpa, .{ .pop_scroll = {} });
    // After the inner scroll pops, this rrect is still inside the outer one: it
    // must append to the outer's inner div (handle 103) with the outer's origin
    // (10,20), not the container with the inner scroll's or no origin at all.
    try list.append(gpa, .{ .rrect = .{
        .rect = geometry.PhysicalRect{ .x = 15, .y = 25, .width = 7, .height = 7 },
        .radius = 0,
        .color = geometry.Color.rgb(0, 1, 0),
    } });
    try list.append(gpa, .{ .pop_scroll = {} });
    try render(gpa, rec.ops(), list, .{ .width = 300, .height = 500 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);
    // container=101, outer scroll outer/inner=102/103, inner scroll outer/inner=104/105,
    // first rrect div=106, second rrect div=107.
    try std.testing.expect(contains(rec.log.items, "appendChild(103,107)"));
    try std.testing.expect(!contains(rec.log.items, "appendChild(101,107)"));
    try std.testing.expect(contains(rec.log.items, "left:0.3125rem;top:0.3125rem;width:0.4375rem;height:0.4375rem"));
}

test "dom_calls: a region nested past max_region_depth is skipped and reports a fault, without breaking the pops that follow" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var sink = FaultSink{};
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    // One more push than the cap allows.
    var i: usize = 0;
    while (i < max_region_depth + 1) : (i += 1) {
        try list.append(gpa, .{ .push_clip = .{
            .rect = geometry.PhysicalRect{ .x = 0, .y = 0, .width = 10, .height = 10 },
            .radius = 0,
        } });
    }
    i = 0;
    while (i < max_region_depth + 1) : (i += 1) {
        try list.append(gpa, .{ .pop_clip = {} });
    }
    // One more primitive after every push/pop balances out, to prove the stack
    // ended up back at the container rather than corrupted by the overflow.
    try list.append(gpa, .{ .rrect = .{
        .rect = geometry.PhysicalRect{ .x = 1, .y = 2, .width = 3, .height = 4 },
        .radius = 0,
        .color = geometry.Color.rgb(1, 0, 0),
    } });
    try render(gpa, rec.ops(), list, .{ .width = 300, .height = 200 }, geometry.Color.rgb(0, 0, 0), &sink, null, null, false);
    try std.testing.expect(!sink.ok());
    try std.testing.expectEqual(FaultSink.FaultCode.region_overflow, sink.first.?.code);
    // container=101, then one div per honoured push (max_region_depth of them,
    // handles 102..133); the refused push creates nothing. The trailing rrect's
    // div is handle 134 and must append to the container: every honoured push
    // was correctly unwound and the one refused push left nothing dangling for
    // its matching pop to (mis)restore.
    try std.testing.expect(contains(rec.log.items, "appendChild(101,134)"));
    try std.testing.expect(contains(rec.log.items, "left:0.0625rem;top:0.125rem;width:0.1875rem;height:0.25rem"));
}

test "dom_calls: image with encoded bytes emits createElement(img), style, and data URL src" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    // PNG magic bytes (8-byte signature) to trigger .png detection.
    const png_bytes = &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01 };
    var img = image_mod.Image.fromBytes(png_bytes, 10, 10);
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .image = .{
        .image = &img,
        .rect = .{ .x = 5, .y = 15, .width = 64, .height = 32 },
        .opacity = 1,
    } });
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);
    // A createElement("img") call must be recorded.
    try std.testing.expect(contains(rec.log.items, "createElement(img)"));
    // The style attribute must include left/top/width/height.
    try std.testing.expect(contains(rec.log.items, "left:0.3125rem;top:0.9375rem;width:4rem;height:2rem"));
    // The src attribute value must begin with the data URL prefix for PNG.
    var found_src = false;
    for (rec.log.items) |l| {
        if (std.mem.indexOf(u8, l, "setAttribute(") != null and
            std.mem.indexOf(u8, l, ",src,") != null and
            std.mem.indexOf(u8, l, "data:image/png;base64,") != null)
        {
            // Verify the base64 tail decodes back to the original bytes.
            // The Recorder format ends with ")" so strip the trailing paren.
            const prefix = "data:image/png;base64,";
            const src_start = std.mem.indexOf(u8, l, prefix).? + prefix.len;
            var b64_data = l[src_start..];
            if (b64_data.len > 0 and b64_data[b64_data.len - 1] == ')') {
                b64_data = b64_data[0 .. b64_data.len - 1];
            }
            const dec = std.base64.standard.Decoder;
            const decoded_len = try dec.calcSizeForSlice(b64_data);
            const decoded = try gpa.alloc(u8, decoded_len);
            defer gpa.free(decoded);
            try dec.decode(decoded, b64_data);
            try std.testing.expectEqualSlices(u8, png_bytes, decoded);
            found_src = true;
        }
    }
    try std.testing.expect(found_src);
}

test "dom_calls: an icon creates an svg in the SVG namespace holding one stroked path" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 40, .height = 40 },
        .color = geometry.Color.rgb(1, 0, 0),
        .origin = .{ .x = 6, .y = 9 },
    } });
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);

    // createElement("svg") builds an HTML unknown element that never paints, so
    // the namespaced call is the fact this pins.
    try std.testing.expect(contains(rec.log.items, "createElementNS(http://www.w3.org/2000/svg,svg)"));
    try std.testing.expect(contains(rec.log.items, "createElementNS(http://www.w3.org/2000/svg,path)"));
    // The viewBox is the grid. The size is the request, in the style below.
    try std.testing.expect(contains(rec.log.items, "viewBox,0 0 24 24"));
    try std.testing.expect(!contains(rec.log.items, ",width,"));
    // Through the CSSOM, not as a `style` attribute: the attribute form is what
    // a strict Content Security Policy refuses.
    try std.testing.expect(contains(rec.log.items, "setStyle(") and contains(rec.log.items, "position:absolute;left:0.375rem;top:0.5625rem;width:2.5rem;height:2.5rem"));
    // A stroked centreline, not a filled outline.
    try std.testing.expect(contains(rec.log.items, "fill,none"));
    try std.testing.expect(contains(rec.log.items, "stroke-width,1.7"));
    try std.testing.expect(contains(rec.log.items, "stroke-linecap,round"));
    try std.testing.expect(contains(rec.log.items, "stroke-linejoin,round"));
    try std.testing.expect(contains(rec.log.items, "stroke,rgba(255,0,0,1)"));
    try std.testing.expect(contains(rec.log.items, "d,M3.84 3.218Q12 4.887 20.16 3.218"));
}

test "dom_calls: a labelled icon appends a namespaced title node holding the name" {
    // The title is the accessible name of inline SVG. It is namespaced like the
    // svg and the path, because a title in the HTML namespace is a foreign child
    // that no reader picks up.
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geometry.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
        .label = "Genesis",
    } });
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);

    try std.testing.expect(contains(rec.log.items, "createElementNS(http://www.w3.org/2000/svg,title)"));
    try std.testing.expect(contains(rec.log.items, "setTextContent") and contains(rec.log.items, "Genesis"));
    // First child of the svg, before the path: a reader takes the first title it
    // meets, so a title appended last names nothing.
    const title_at = indexOfLine(rec.log.items, "createElementNS(http://www.w3.org/2000/svg,title)").?;
    const path_at = indexOfLine(rec.log.items, "createElementNS(http://www.w3.org/2000/svg,path)").?;
    try std.testing.expect(title_at < path_at);
}

test "dom_calls: an icon with no label creates no title node" {
    // An empty title takes the accessible name and announces nothing with it,
    // which silences the icon more thoroughly than leaving the name unset.
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geometry.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
    } });
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);
    try std.testing.expect(!contains(rec.log.items, ",title)"));
    // The svg is still built, so this is not passing because nothing was drawn.
    try std.testing.expect(contains(rec.log.items, "createElementNS(http://www.w3.org/2000/svg,path)"));
}

test "dom_calls: a host with no namespaced creator still builds the icon through createElement" {
    // Every existing DomOps leaves create_element_ns null. The fallback keeps
    // those hosts compiling and emitting the tree, at the cost of an svg the
    // browser will not paint until the host supplies createElementNS.
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geometry.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
    } });
    var ops = rec.ops();
    ops.create_element_ns = null;
    try render(gpa, ops, list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);
    try std.testing.expect(contains(rec.log.items, "createElement(svg)"));
    try std.testing.expect(contains(rec.log.items, "createElement(path)"));
    try std.testing.expect(!contains(rec.log.items, "createElementNS("));
}

test "dom_calls: image fromRgba (no encoded bytes) emits no img element" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    const rgba_pixels: [4 * 4 * 4]u8 = @splat(255); // 4x4 RGBA
    var img = image_mod.Image.fromRgba(&rgba_pixels, 4, 4);
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .image = .{
        .image = &img,
        .rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
        .opacity = 1,
    } });
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);
    // No img element should be created (fromRgba has no encoded bytes).
    try std.testing.expect(!contains(rec.log.items, "createElement(img)"));
}

test "a text run keeps its own spacing instead of letting the browser collapse it" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();

    var h = try @import("../testing.zig").mount(gpa, blk: {
        const t = @import("../widgets/text.zig").Text{ .text = "    indented", .size = 16 };
        break :blk t.widget();
    });
    defer h.deinit();
    try h.pump();

    try render(gpa, rec.ops(), h.canvas.list, .{ .width = 200, .height = 100 }, .{ .r = 0, .g = 0, .b = 0, .a = 1 }, null, null, null, false);

    // Without this rule a browser drops the leading spaces of a run and
    // collapses every other stretch of them, so indented source loses its
    // shape. This framework already placed the run, so the browser must not
    // re-space it.
    try std.testing.expect(contains(rec.log.items, "white-space:pre"));
    try std.testing.expect(contains(rec.log.items, "    indented"));
}

test "dom_calls: a scroll region's div and offset survive a second render" {
    // A tap renders again. The div the browser was scrolling stays, so a tap
    // never resets a region the visitor had scrolled.
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var mem = ScrollMemory{};
    var page: PageState = .{};
    defer page.deinit(gpa);

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 0, .y = 0, .width = 100, .height = 50 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
    } });
    try list.append(gpa, .{ .pop_scroll = {} });

    // First render: container=101, scroll outer=102, inner=103.
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &page, false);
    try std.testing.expectEqual(@as(usize, 1), mem.count);
    try std.testing.expectEqual(@as(u32, 102), mem.handles[0]);

    // The visitor scrolls. The browser owns this value, not the framework, so
    // the test moves it the same way the browser would: on the live node.
    rec.setScrollOffset(102, .{ .x = 0, .y = 77 });

    const start = rec.log.items.len;
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &page, false);
    try std.testing.expect(!contains(rec.log.items[start..], "createElement"));
    try std.testing.expect(!contains(rec.log.items[start..], "writeScrollOffset("));
    try std.testing.expectEqual(@as(u32, 102), mem.handles[0]);
    try std.testing.expectEqual(@as(f32, 77), rec.ops().readScrollOffset(102).?.y);
}

test "dom_calls: a region that phantom moved gets phantom's offset, once" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var mem = ScrollMemory{};
    var target: u8 = 0;
    var handlers = pointer.PointerHandlers{ .ctx = &target };

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 0, .y = 0, .width = 100, .height = 50 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
        .handlers = &handlers,
    } });
    try list.append(gpa, .{ .pop_scroll = {} });

    var page: PageState = .{};
    defer page.deinit(gpa);

    // Container 101, outer 102. The browser then scrolls to 77.
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &page, false);
    rec.setScrollOffset(102, .{ .x = 0, .y = 77 });

    // Phantom moves the region to 120.
    list.primitives.items[0].push_scroll.offset.y = 120;
    list.primitives.items[0].push_scroll.moved = 1;
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &page, false);
    try std.testing.expectEqual(@as(usize, 1), countLines(rec.log.items, "writeScrollOffset(102,0,120)"));

    // No new phantom move, so the browser's offset wins and stays.
    rec.setScrollOffset(102, .{ .x = 0, .y = 90 });
    const start = rec.log.items.len;
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &page, false);
    try std.testing.expect(!contains(rec.log.items[start..], "writeScrollOffset("));
    try std.testing.expectEqual(@as(f32, 90), rec.ops().readScrollOffset(102).?.y);
}

test "dom_calls: a phantom move in the same render as a navigation wins over the reset" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var mem = ScrollMemory{};
    var target: u8 = 0;
    var handlers = pointer.PointerHandlers{ .ctx = &target };

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 0, .y = 0, .width = 100, .height = 50 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
        .handlers = &handlers,
    } });
    try list.append(gpa, .{ .pop_scroll = {} });

    var page: PageState = .{};
    defer page.deinit(gpa);

    // Container 101, outer 102.
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &page, false);

    // Phantom moves the region to 120 in the same render as a navigation.
    list.primitives.items[0].push_scroll.offset.y = 120;
    list.primitives.items[0].push_scroll.moved = 1;
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &page, true);

    // The move wins: the div gets phantom's offset, not the navigation's zero.
    try std.testing.expect(contains(rec.log.items, "writeScrollOffset(102,0,120)"));
    try std.testing.expect(!contains(rec.log.items, "writeScrollOffset(102,0,0)"));
}

test "dom_calls: a navigation clears a scroll region's offset instead of carrying it to the new page" {
    // A visitor who follows a link expects the top of the new page, exactly
    // like a browser gives them on any ordinary navigation. `reset_scroll`
    // is how a caller tells `render` this rebuild is that kind, not a tap.
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var mem = ScrollMemory{};

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 0, .y = 0, .width = 100, .height = 50 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
    } });
    try list.append(gpa, .{ .pop_scroll = {} });

    var page: PageState = .{};
    defer page.deinit(gpa);

    // First render: outer=102. The visitor scrolls it.
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &page, false);
    rec.setScrollOffset(102, .{ .x = 0, .y = 77 });

    // A navigation that keeps the div: the old offset is never read back,
    // and the div goes to the top, like following a link to any other page.
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &page, true);
    try std.testing.expect(!contains(rec.log.items, "readScrollOffset(102)"));
    try std.testing.expect(contains(rec.log.items, "writeScrollOffset(102,0,0)"));
    try std.testing.expectEqual(@as(f32, 0), rec.ops().readScrollOffset(102).?.y);
}

test "dom_calls: a navigation leaves a new scroll div where a new element starts" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var mem = ScrollMemory{};
    var page: PageState = .{};
    defer page.deinit(gpa);
    var view = TestView{ .offset = .{ .x = 0, .y = 40 } };
    view.init();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, testRegion(&view));
    try list.append(gpa, .{ .pop_scroll = {} });

    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &page, true);
    try std.testing.expect(!contains(rec.log.items, "writeScrollOffset("));
    try std.testing.expectEqual(@as(f32, 0), view.offset.y);
    try std.testing.expect(mem.synced);
}

/// A view for the tests below: it takes any offset that `render` gives it.
const TestView = struct {
    offset: geometry.PhysicalOffset = .zero,
    handlers: pointer.PointerHandlers = undefined,

    fn init(self: *TestView) void {
        self.handlers = .{ .ctx = self, .on_scroll_to = scrollTo };
    }

    fn scrollTo(ctx: *anyopaque, x: f32, y: f32) bool {
        const self: *TestView = @ptrCast(@alignCast(ctx));
        if (self.offset.x == x and self.offset.y == y) return false;
        self.offset = .{ .x = x, .y = y };
        return true;
    }
};

fn testRegion(view: *TestView) display_list.Primitive {
    return .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 0, .y = 0, .width = 100, .height = 50 },
        .offset = view.offset,
        .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
        .handlers = &view.handlers,
    } };
}

test "dom_calls: a region keeps its offset when a new region comes before it" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var mem = ScrollMemory{};
    var page = TestView{};
    page.init();
    var added = TestView{};
    added.init();

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, testRegion(&page));
    try list.append(gpa, .{ .pop_scroll = {} });

    var state: PageState = .{};
    defer state.deinit(gpa);

    // Container 101, outer 102. The browser scrolls it and tells the view.
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &state, false);
    rec.setScrollOffset(102, .{ .x = 0, .y = 77 });
    page.offset.y = 77;

    // Another region now comes first: outer 104 for it, before the page's
    // div, which stays and takes index 1.
    list.primitives.clearRetainingCapacity();
    for ([_]*TestView{ &added, &page }) |v| {
        try list.append(gpa, testRegion(v));
        try list.append(gpa, .{ .pop_scroll = {} });
    }
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &state, false);
    try std.testing.expect(contains(rec.log.items, "insertBefore(101,104,102)"));
    try std.testing.expect(contains(rec.log.items, "setAttribute(102,data-phantom-scroll,1)"));
    try std.testing.expect(!contains(rec.log.items, "writeScrollOffset("));
    try std.testing.expectEqual(@as(f32, 77), page.offset.y);
    try std.testing.expectEqual(@as(f32, 0), added.offset.y);
    try std.testing.expect(!mem.synced);
    try std.testing.expectEqual(@as(?*pointer.PointerHandlers, &page.handlers), mem.targets[1]);
    try std.testing.expectEqual(@as(u32, 102), mem.handles[1]);
}

test "dom_calls: a view that the browser scrolled before its event came takes the browser's offset" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var mem = ScrollMemory{};
    var page = TestView{};
    page.init();

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, testRegion(&page));
    try list.append(gpa, .{ .pop_scroll = {} });

    var state: PageState = .{};
    defer state.deinit(gpa);

    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &state, false);
    rec.setScrollOffset(102, .{ .x = 0, .y = 77 });
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &state, false);
    try std.testing.expectEqual(@as(f32, 77), page.offset.y);
    try std.testing.expect(mem.synced);
}

test "dom_calls: a navigation moves a view that stays on the page back to the top" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var mem = ScrollMemory{};
    var page = TestView{};
    page.init();

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, testRegion(&page));
    try list.append(gpa, .{ .pop_scroll = {} });

    var state: PageState = .{};
    defer state.deinit(gpa);

    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &state, false);
    rec.setScrollOffset(102, .{ .x = 0, .y = 77 });
    page.offset.y = 77;
    list.primitives.items[0].push_scroll.offset.y = 77;

    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, &state, true);
    try std.testing.expect(contains(rec.log.items, "writeScrollOffset(102,0,0)"));
    try std.testing.expectEqual(@as(f32, 0), rec.ops().readScrollOffset(102).?.y);
    try std.testing.expectEqual(@as(f32, 0), page.offset.y);
    try std.testing.expect(mem.synced);
}

test "dom_calls: a region new to the page shows the offset its view already has" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var mem = ScrollMemory{};
    var page = TestView{ .offset = .{ .x = 0, .y = 40 } };
    page.init();

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, testRegion(&page));
    try list.append(gpa, .{ .pop_scroll = {} });

    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, null, false);
    try std.testing.expect(contains(rec.log.items, "writeScrollOffset(102,0,40)"));
    try std.testing.expect(!mem.synced);
}

test "dom_calls: a host with no scroll offset hooks still renders a scroll region" {
    // Every existing DomOps leaves these two hooks null, the same as
    // create_element_ns before this fix. Rendering must degrade to today's
    // behaviour (no carried offset) rather than fail.
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var mem = ScrollMemory{};
    var ops = rec.ops();
    ops.read_scroll_offset = null;
    ops.write_scroll_offset = null;

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 0, .y = 0, .width = 100, .height = 50 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
    } });
    try list.append(gpa, .{ .pop_scroll = {} });

    try render(gpa, ops, list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, null, false);

    // The region still builds normally.
    try std.testing.expect(contains(rec.log.items, "overflow:scroll"));
    // Neither hook exists, so neither is ever called.
    try std.testing.expect(!contains(rec.log.items, "readScrollOffset("));
    try std.testing.expect(!contains(rec.log.items, "writeScrollOffset("));
    // The region is still remembered, so a host that gains the hooks later
    // starts carrying its offset from the very next render.
    try std.testing.expectEqual(@as(usize, 1), mem.count);
}

test "dom_calls: each scroll region div names its index, and the memory keeps its handlers" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var mem = ScrollMemory{};
    var first: u8 = 0;
    var second: u8 = 0;
    var first_handlers = pointer.PointerHandlers{ .ctx = &first };
    var second_handlers = pointer.PointerHandlers{ .ctx = &second };

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    for ([_]*pointer.PointerHandlers{ &first_handlers, &second_handlers }) |h| {
        try list.append(gpa, .{ .push_scroll = .{
            .viewport = geometry.PhysicalRect{ .x = 0, .y = 0, .width = 100, .height = 50 },
            .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
            .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
            .handlers = h,
        } });
        try list.append(gpa, .{ .pop_scroll = {} });
    }

    // Container 101, then outer 102 and inner 103, then outer 104 and inner 105.
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, null, false);
    try std.testing.expect(contains(rec.log.items, "setAttribute(102,data-phantom-scroll,0)"));
    try std.testing.expect(contains(rec.log.items, "setAttribute(104,data-phantom-scroll,1)"));
    try std.testing.expect(!contains(rec.log.items, "setAttribute(103,data-phantom-scroll"));
    try std.testing.expectEqual(@as(usize, 2), mem.count);
    try std.testing.expectEqual(@as(?*pointer.PointerHandlers, &first_handlers), mem.targets[0]);
    try std.testing.expectEqual(@as(?*pointer.PointerHandlers, &second_handlers), mem.targets[1]);
}

test "dom_calls: a rendered frame sets no style ATTRIBUTE anywhere, because a strict policy refuses every one" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 1, .y = 2, .width = 3, .height = 4 },
        .radius = 0,
        .color = geometry.Color.rgb(1, 0, 0),
        .hover_color = geometry.Color.rgb(0, 1, 0),
    } });
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);

    // The whole point of the change, stated as the thing that must not happen.
    // A single one of these blanks the page under `style-src` without
    // `'unsafe-inline'`, so the assertion is on the absence, not on a sample.
    for (rec.log.items) |line| {
        try std.testing.expect(std.mem.indexOf(u8, line, "setAttribute(") == null or
            std.mem.indexOf(u8, line, ",style,") == null);
    }
    // And the positioning really did happen, so the loop above is not passing
    // because nothing was drawn.
    try std.testing.expect(contains(rec.log.items, "setStyle("));
    try std.testing.expect(contains(rec.log.items, "position:absolute"));
    // The interactive rule went through the sheet rather than the element text.
    try std.testing.expect(contains(rec.log.items, "addRule("));
    try std.testing.expect(!contains(rec.log.items, "setTextContent"));
}

test "dom_calls: a host with no CSSOM hooks still renders, through the attribute it can use" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var ops_no_cssom = rec.ops();
    // A host written before these hooks existed. It needs `'unsafe-inline'`, and
    // that is its choice to make, but it must not stop drawing.
    ops_no_cssom.set_style = null;
    ops_no_cssom.add_rule = null;

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 1, .y = 2, .width = 3, .height = 4 },
        .radius = 0,
        .color = geometry.Color.rgb(1, 0, 0),
        .hover_color = geometry.Color.rgb(0, 1, 0),
    } });
    try render(gpa, ops_no_cssom, list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);

    try std.testing.expect(contains(rec.log.items, ",style,position:absolute"));
    try std.testing.expect(contains(rec.log.items, "setTextContent"));
    try std.testing.expect(!contains(rec.log.items, "setStyle("));
}

test "dom_calls: a font that is served as a file is referenced by url, never embedded" {
    const gpa = std.testing.allocator;
    var font = try text.builtin.neuropol(gpa);
    defer font.deinit(gpa);

    const css = try fontFaceCss(gpa, "/", &.{&font});
    defer gpa.free(css);

    // `font-src 'self'` refuses a `data:` URL however the rule reached the
    // document, and a refused font is not a cosmetic problem: layout was
    // measured against this font, so the glyphs a person sees and the rectangles
    // taps are tested against stop agreeing.
    try std.testing.expect(std.mem.indexOf(u8, css, "data:") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, "url(\"/fonts/Neuropol.otf\")") != null);
}

test "dom_calls: a font with nowhere to be fetched from still works, embedded" {
    const gpa = std.testing.allocator;
    // What an application's own font looks like: loaded from bytes, served from
    // nowhere. It needs `font-src data:`, and that is the application's call.
    var font = try text.Font.load(gpa, text.builtin.mesmerize_rg_bytes);
    defer font.deinit(gpa);
    try std.testing.expectEqual(@as(?[]const u8, null), font.url);

    const css = try fontFaceCss(gpa, "/", &.{&font});
    defer gpa.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, "data:font/otf;base64,") != null);
}

test "dom_calls: two fonts get two different families, so neither can answer for the other" {
    const gpa = std.testing.allocator;
    var a = try text.builtin.neuropol(gpa);
    defer a.deinit(gpa);
    var b = try text.builtin.mesmerize_rg(gpa);
    defer b.deinit(gpa);

    var fam_a: [family_len]u8 = undefined;
    var fam_b: [family_len]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, fontFamily(&fam_a, &a), fontFamily(&fam_b, &b)));

    // And the order they are declared in does not change what either is called,
    // which is exactly what an index could not promise.
    const one = try fontFaceCss(gpa, "/", &.{ &a, &b });
    defer gpa.free(one);
    const other = try fontFaceCss(gpa, "/", &.{ &b, &a });
    defer gpa.free(other);
    try std.testing.expect(std.mem.indexOf(u8, one, fontFamily(&fam_a, &a)) != null);
    try std.testing.expect(std.mem.indexOf(u8, other, fontFamily(&fam_a, &a)) != null);
}

/// The handle a recorded `createElement` or `createElementNS` line returned.
fn createdHandle(line: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, line, "createElement")) return null;
    const at = std.mem.lastIndexOf(u8, line, "->") orelse return null;
    return std.fmt.parseInt(u32, line[at + 2 ..], 10) catch null;
}

/// An interactive rrect, then a scroll region holding a clip that holds a
/// labelled icon. On a first render the handles are: container 101, rrect
/// 102, scroll outer 103 and inner 104, clip 105, svg 106, title 107, path 108.
fn appendMixed(gpa: std.mem.Allocator, list: *display_list.DisplayList) !void {
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .radius = 0,
        .color = geometry.Color.rgb(1, 0, 0),
        .hover_color = geometry.Color.rgb(0, 1, 0),
    } });
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = .{ .x = 0, .y = 20, .width = 50, .height = 50 },
        .offset = .{ .x = 0, .y = 0 },
        .content = .{ .width = 50, .height = 200 },
    } });
    try list.append(gpa, .{ .push_clip = .{ .rect = .{ .x = 0, .y = 20, .width = 20, .height = 20 }, .radius = 2 } });
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 16, .height = 16 },
        .color = geometry.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 20 },
        .label = "Gate",
    } });
    try list.append(gpa, .{ .pop_clip = {} });
    try list.append(gpa, .{ .pop_scroll = {} });
}

test "dom_calls: a second render of the same frame changes nothing in the page" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var mem = ScrollMemory{};
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try appendMixed(gpa, &list);
    const size: geometry.PhysicalSize = .{ .width = 100, .height = 100 };

    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, &mem, &page, false);
    try std.testing.expectEqual(@as(usize, 8), countLines(rec.log.items, "createElement"));

    // Only the read of the scroll div's offset, which its view takes.
    var start = rec.log.items.len;
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, &mem, &page, false);
    try std.testing.expectEqual(@as(usize, 1), rec.log.items.len - start);
    try std.testing.expectEqualStrings("readScrollOffset(103)->0,0", rec.log.items[start]);

    start = rec.log.items.len;
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, null, &page, false);
    try std.testing.expectEqual(start, rec.log.items.len);
    try std.testing.expectEqual(@as(usize, 0), rec.misuse);
}

test "dom_calls: a changed text run costs one setTextContent" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    for ([_][]const u8{ "one", "two" }, 0..) |s, i| {
        try list.append(gpa, .{ .text = .{
            .glyphs = &.{},
            .text = s,
            .font = &font,
            .size = 16,
            .color = geometry.Color.rgb(1, 1, 1),
            .origin = .{ .x = 0, .y = @floatFromInt(i * 20) },
        } });
    }
    const size: geometry.PhysicalSize = .{ .width = 100, .height = 100 };
    // Container 101, runs 102 and 103.
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, null, &page, false);

    list.primitives.items[1].text.text = "three";
    const start = rec.log.items.len;
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, null, &page, false);
    try std.testing.expectEqual(@as(usize, 1), rec.log.items.len - start);
    try std.testing.expectEqualStrings("setTextContent(103,three)", rec.log.items[start]);
}

test "dom_calls: a removed subtree leaves in one call and each of its nodes is released once" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try appendMixed(gpa, &list);
    const size: geometry.PhysicalSize = .{ .width = 100, .height = 100 };
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, null, &page, false);
    try std.testing.expectEqual(@as(usize, 0), countLines(rec.log.items, "release("));

    // Only the rrect stays.
    list.primitives.shrinkRetainingCapacity(1);
    var start = rec.log.items.len;
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, null, &page, false);
    var after = rec.log.items[start..];
    try std.testing.expectEqual(@as(usize, 1), countLines(after, "removeChild("));
    const removed = indexOfLine(after, "removeChild(101,103)").?;
    var buf: [32]u8 = undefined;
    for (103..109) |h| {
        const line = try std.fmt.bufPrint(&buf, "release({d})", .{h});
        try std.testing.expectEqual(@as(usize, 1), countLines(after, line));
        try std.testing.expect(indexOfLine(after, line).? > removed);
    }
    try std.testing.expectEqual(@as(usize, 6), countLines(after, "release("));
    try std.testing.expectEqual(@as(usize, 0), countLines(after, "createElement"));

    // The region comes back as new nodes, and nothing is released.
    list.primitives.clearRetainingCapacity();
    try appendMixed(gpa, &list);
    start = rec.log.items.len;
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, null, &page, false);
    after = rec.log.items[start..];
    try std.testing.expectEqual(@as(usize, 6), countLines(after, "createElement"));
    try std.testing.expectEqual(@as(usize, 0), countLines(after, "release("));
    try std.testing.expect(contains(after, "appendChild(101,109)"));

    try std.testing.expectEqual(@as(usize, 0), rec.misuse);
    for (rec.log.items) |l| {
        try std.testing.expect(!std.mem.eql(u8, l, "release(1)"));
        try std.testing.expect(!std.mem.eql(u8, l, "release(2)"));
    }
}

test "dom_calls: a node whose tag changes is replaced at its place" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    const box: display_list.Primitive = .{ .rrect = .{ .rect = .{ .x = 0, .y = 0, .width = 5, .height = 5 }, .radius = 0, .color = geometry.Color.rgb(1, 0, 0) } };
    try list.append(gpa, .{ .icon = .{ .id = .torii, .size = .{ .width = 16, .height = 16 }, .color = geometry.Color.rgb(1, 1, 1), .origin = .{ .x = 0, .y = 0 } } });
    try list.append(gpa, box);
    const size: geometry.PhysicalSize = .{ .width = 100, .height = 100 };
    // Container 101, svg 102, path 103, rrect 104.
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, null, &page, false);

    list.primitives.items[0] = box;
    const start = rec.log.items.len;
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, null, &page, false);
    const after = rec.log.items[start..];
    try std.testing.expect(contains(after, "removeChild(101,102)"));
    try std.testing.expectEqual(@as(usize, 1), countLines(after, "release(102)"));
    try std.testing.expectEqual(@as(usize, 1), countLines(after, "release(103)"));
    try std.testing.expect(contains(after, "createElement(div)->105"));
    try std.testing.expect(contains(after, "insertBefore(101,105,104)"));
    try std.testing.expect(!contains(after, "release(104)"));
    try std.testing.expectEqual(@as(usize, 0), rec.misuse);
}

test "dom_calls: a text div that becomes a box loses its text, and a box that stops responding loses its class" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .text = .{ .glyphs = &.{}, .text = "hi", .font = &font, .size = 16, .color = geometry.Color.rgb(1, 1, 1), .origin = .{ .x = 0, .y = 0 } } });
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 20, .width = 10, .height = 10 },
        .radius = 0,
        .color = geometry.Color.rgb(0, 0, 1),
        .hover_color = geometry.Color.rgb(0, 1, 0),
    } });
    const size: geometry.PhysicalSize = .{ .width = 100, .height = 100 };
    // Container 101, text 102, button 103.
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, null, &page, false);

    list.primitives.items[0] = .{ .rrect = .{ .rect = .{ .x = 0, .y = 0, .width = 5, .height = 5 }, .radius = 0, .color = geometry.Color.rgb(1, 0, 0) } };
    list.primitives.items[1].rrect.hover_color = null;
    const start = rec.log.items.len;
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, null, &page, false);
    const after = rec.log.items[start..];
    try std.testing.expect(contains(after, "setTextContent(102,)"));
    try std.testing.expect(contains(after, "removeAttribute(103,class)"));
    try std.testing.expectEqual(@as(usize, 0), countLines(after, "createElement"));
}

test "dom_calls: an image is sent again only when its bytes change" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var bytes = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01 };
    var img = image_mod.Image.fromBytes(&bytes, 10, 10);
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .image = .{ .image = &img, .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 } } });
    const size: geometry.PhysicalSize = .{ .width = 100, .height = 100 };
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, null, &page, false);

    var start = rec.log.items.len;
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, null, &page, false);
    try std.testing.expectEqual(start, rec.log.items.len);

    bytes[9] = 0x02;
    start = rec.log.items.len;
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, null, &page, false);
    try std.testing.expectEqual(@as(usize, 1), rec.log.items.len - start);
    try std.testing.expect(std.mem.startsWith(u8, rec.log.items[start], "setAttribute(102,src,data:image/png;base64,"));
}

test "dom_calls: a ListView window move keeps the scroll div and releases the rows that went" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var mem = ScrollMemory{};
    var view = TestView{};
    view.init();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    const size: geometry.PhysicalSize = .{ .width = 200, .height = 100 };

    // Rows 0 to 4 in the window. Container 101, outer 102, inner 103, rows 104 to 108.
    try list.append(gpa, testRegion(&view));
    for (0..5) |i| {
        try list.append(gpa, .{ .rrect = .{ .rect = .{ .x = 0, .y = @floatFromInt(i * 20), .width = 100, .height = 20 }, .radius = 0, .color = geometry.Color.rgb(0, 0, 1) } });
    }
    try list.append(gpa, .{ .pop_scroll = {} });
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, &mem, &page, false);
    const outer = mem.handles[0];
    try std.testing.expectEqual(@as(u32, 102), outer);

    // The browser scrolls, and the window is now rows 3 to 6.
    rec.setScrollOffset(outer, .{ .x = 0, .y = 60 });
    view.offset.y = 60;
    list.primitives.clearRetainingCapacity();
    try list.append(gpa, testRegion(&view));
    for (3..7) |i| {
        try list.append(gpa, .{ .rrect = .{ .rect = .{ .x = 0, .y = @floatFromInt(i * 20), .width = 100, .height = 20 }, .radius = 0, .color = geometry.Color.rgb(0, 0, 1) } });
    }
    try list.append(gpa, .{ .pop_scroll = {} });
    const start = rec.log.items.len;
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, &mem, &page, false);
    const after = rec.log.items[start..];

    try std.testing.expectEqual(outer, mem.handles[0]);
    try std.testing.expectEqual(@as(usize, 0), countLines(after, "createElement"));
    try std.testing.expect(!contains(after, "writeScrollOffset("));
    try std.testing.expectEqual(@as(usize, 1), countLines(after, "removeChild(103,108)"));
    try std.testing.expectEqual(@as(usize, 1), countLines(after, "release("));
    try std.testing.expectEqual(@as(usize, 1), countLines(after, "release(108)"));
    try std.testing.expectEqual(@as(f32, 60), view.offset.y);
    try std.testing.expect(!mem.synced);
    try std.testing.expectEqual(@as(usize, 0), rec.misuse);
}

test "dom_calls: a keyed scroll region that moves keeps its div, its offset, and a new index" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var mem = ScrollMemory{};
    var a = TestView{};
    a.init();
    var b = TestView{};
    b.init();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    const size: geometry.PhysicalSize = .{ .width = 200, .height = 100 };

    // Container 101, a: outer 102 and inner 103, b: outer 104 and inner 105.
    for ([_]*TestView{ &a, &b }) |v| {
        try list.append(gpa, testRegion(v));
        try list.append(gpa, .{ .pop_scroll = {} });
    }
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, &mem, &page, false);
    rec.setScrollOffset(104, .{ .x = 0, .y = 60 });
    b.offset.y = 60;

    list.primitives.clearRetainingCapacity();
    for ([_]*TestView{ &b, &a }) |v| {
        try list.append(gpa, testRegion(v));
        try list.append(gpa, .{ .pop_scroll = {} });
    }
    const start = rec.log.items.len;
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, &mem, &page, false);
    const after = rec.log.items[start..];

    try std.testing.expectEqual(@as(usize, 0), countLines(after, "createElement"));
    try std.testing.expectEqual(@as(usize, 0), countLines(after, "release("));
    const moved = indexOfLine(after, "insertBefore(101,104,102)").?;
    try std.testing.expect(indexOfLine(after, "readScrollOffset(104)").? < moved);
    try std.testing.expect(indexOfLine(after, "writeScrollOffset(104,0,60)").? > moved);
    try std.testing.expect(contains(after, "setAttribute(104,data-phantom-scroll,0)"));
    try std.testing.expect(contains(after, "setAttribute(102,data-phantom-scroll,1)"));
    try std.testing.expectEqual(@as(u32, 104), mem.handles[0]);
    try std.testing.expectEqual(@as(u32, 102), mem.handles[1]);
    try std.testing.expectEqual(@as(?*pointer.PointerHandlers, &b.handlers), mem.targets[0]);
    try std.testing.expectEqual(@as(f32, 60), b.offset.y);
    try std.testing.expectEqual(@as(usize, 0), rec.misuse);
}

test "dom_calls: a scroll region inside a moved node keeps its offset" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var mem = ScrollMemory{};
    var k = TestView{};
    k.init();
    var s = TestView{};
    s.init();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    const size: geometry.PhysicalSize = .{ .width = 200, .height = 100 };
    const clip: display_list.Primitive = .{ .push_clip = .{ .rect = .{ .x = 0, .y = 0, .width = 50, .height = 50 } } };

    try list.append(gpa, testRegion(&k));
    try list.append(gpa, .{ .pop_scroll = {} });
    try list.append(gpa, clip);
    try list.append(gpa, testRegion(&s));
    try list.append(gpa, .{ .pop_scroll = {} });
    try list.append(gpa, .{ .pop_clip = {} });
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, &mem, &page, false);
    const s_div = mem.handles[1];
    rec.setScrollOffset(s_div, .{ .x = 0, .y = 70 });
    s.offset.y = 70;

    // The clip that holds the region now comes before the keyed region.
    list.primitives.clearRetainingCapacity();
    try list.append(gpa, clip);
    try list.append(gpa, testRegion(&s));
    try list.append(gpa, .{ .pop_scroll = {} });
    try list.append(gpa, .{ .pop_clip = {} });
    try list.append(gpa, testRegion(&k));
    try list.append(gpa, .{ .pop_scroll = {} });
    const start = rec.log.items.len;
    try render(gpa, rec.ops(), list, size, geometry.Color.rgb(0, 0, 0), null, &mem, &page, false);
    const after = rec.log.items[start..];

    try std.testing.expect(contains(after, "insertBefore("));
    try std.testing.expectEqual(s_div, mem.handles[0]);
    try std.testing.expectEqual(@as(f32, 70), s.offset.y);
    try std.testing.expectEqual(@as(f32, 70), Recorder.readScrollOffset(&rec, s_div).y);
    try std.testing.expect(!mem.synced);
    try std.testing.expectEqual(@as(usize, 0), rec.misuse);
}

test "dom_calls: the same interactive colours add their rule once, and a new colour adds a second rule" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    const button: display_list.Primitive = .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 80, .height = 40 },
        .radius = 4,
        .color = geometry.Color.rgb(0, 0, 1),
        .hover_color = geometry.Color.rgb(0, 0, 0.9),
        .active_color = geometry.Color.rgb(0, 0, 0.8),
    } };
    // Two buttons of one colour in one frame share a class and a rule.
    try list.append(gpa, button);
    try list.append(gpa, button);

    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, &page, false);
    // A third button of that colour in a later frame reuses the rule.
    try list.append(gpa, button);
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, &page, false);
    try std.testing.expectEqual(@as(usize, 1), countLines(rec.log.items, "addRule("));
    try std.testing.expectEqual(@as(usize, 1), countLines(rec.log.items, ":hover{"));
    try std.testing.expectEqualStrings(classAt(rec.log.items, 0).?, classAt(rec.log.items, 2).?);

    var other = button;
    other.rrect.hover_color = geometry.Color.rgb(1, 0, 0);
    try list.append(gpa, other);
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, &page, false);
    try std.testing.expectEqual(@as(usize, 2), countLines(rec.log.items, "addRule("));
    try std.testing.expectEqual(@as(usize, 2), countLines(rec.log.items, ":hover{"));
    try std.testing.expect(!std.mem.eql(u8, classAt(rec.log.items, 0).?, classAt(rec.log.items, 3).?));
    try std.testing.expectEqual(@as(u32, 2), page.rules.count());
}

test "dom_calls: a stroke and a fill with the same state colours get different classes" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    const fill: display_list.Primitive = .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .radius = 0,
        .color = geometry.Color.rgb(0, 0, 1),
        .hover_color = geometry.Color.rgb(0, 1, 0),
    } };
    var stroke = fill;
    stroke.rrect.stroke_width = 1;
    try list.append(gpa, fill);
    try list.append(gpa, stroke);
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, null, false);
    try std.testing.expect(!std.mem.eql(u8, classAt(rec.log.items, 0).?, classAt(rec.log.items, 1).?));
    try std.testing.expect(contains(rec.log.items, ":hover{border-color:"));
    try std.testing.expect(contains(rec.log.items, ":hover{background:"));
}

/// The handles `createElement` lines in `log` returned, into `out`.
fn createdHandles(log: []const []u8, out: []u32) ![]u32 {
    var n: usize = 0;
    for (log) |l| {
        const h = createdHandle(l) orelse continue;
        if (n == out.len) return error.TooManyHandles;
        out[n] = h;
        n += 1;
    }
    return out[0..n];
}

test "dom_calls: a render that fails makes no DOM call and keeps the last tree" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var mem = ScrollMemory{};
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try appendMixed(gpa, &list);
    const size: geometry.PhysicalSize = .{ .width = 100, .height = 100 };
    const bg = geometry.Color.rgb(0, 0, 0);
    try render(gpa, rec.ops(), list, size, bg, null, &mem, &page, false);
    var first_buf: [16]u32 = undefined;
    const first = try createdHandles(rec.log.items, &first_buf);

    // The next frame has one more box, so a good render creates one node.
    try list.append(gpa, .{ .rrect = .{ .rect = .{ .x = 0, .y = 80, .width = 5, .height = 5 }, .radius = 0, .color = geometry.Color.rgb(1, 0, 0) } });
    var failed: usize = 0;
    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        // An empty arena and a rule new to the page make the render allocate
        // at each step.
        const next = 1 - page.live;
        page.arenas[next].promote(gpa).deinit();
        page.arenas[next] = .init;
        page.rules.clearAndFree(gpa);
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const start = rec.log.items.len;
        render(failing.allocator(), rec.ops(), list, size, bg, null, &mem, &page, false) catch {
            failed += 1;
            try std.testing.expectEqual(start, rec.log.items.len);
            try std.testing.expectEqual(@as(usize, 1), mem.count);
            continue;
        };
        break;
    }
    try std.testing.expect(fail_index < 256);
    try std.testing.expect(failed > 0);

    // The render that worked patched from the first tree: one new node, and
    // every first node kept.
    var all_buf: [16]u32 = undefined;
    const all = try createdHandles(rec.log.items, &all_buf);
    try std.testing.expectEqual(first.len + 1, all.len);
    try std.testing.expectEqual(@as(usize, 0), countLines(rec.log.items, "release("));
    try std.testing.expectEqual(@as(usize, 0), countLines(rec.log.items, "removeChild("));
    try std.testing.expectEqual(@as(usize, 0), rec.misuse);
}

/// The tree `render` builds for `list`, written into the body of `rec` the
/// way a server page has it.
fn servePage(rec: *Recorder, arena: std.mem.Allocator, list: display_list.DisplayList, size: geometry.PhysicalSize) !vdom.Tree {
    const tree = try vdom.build(arena, list, size, geometry.Color.rgb(0, 0, 0), null);
    try rec.serveTree(tree.root);
    return tree;
}

test "dom_calls: a server page at the size of the first frame is adopted and makes no element" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var mem = ScrollMemory{};
    var sink = FaultSink{};
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try appendMixed(gpa, &list);
    const size: geometry.PhysicalSize = .{ .width = 100, .height = 100 };
    const bg = geometry.Color.rgb(0, 0, 0);
    // Container 101, rrect 102, scroll outer 103 and inner 104, clip 105,
    // svg 106, title 107, path 108, script 109.
    const tree = try servePage(&rec, arena_state.allocator(), list, size);

    try std.testing.expect(try hydrate(gpa, rec.ops(), list, size, bg, &sink, &page));
    try std.testing.expectEqual(@as(usize, 0), countLines(rec.log.items, "createElement"));
    try std.testing.expectEqual(@as(usize, 0), countLines(rec.log.items, "release("));
    try std.testing.expectEqual(@as(usize, 0), sink.count);
    // The style of each node moves to the CSSOM, and the server class goes.
    var buf: [256]u8 = undefined;
    for (101..109) |h| {
        const class_set = try std.fmt.bufPrint(&buf, "setAttribute({d},class,", .{h});
        const removed = countLines(rec.log.items, class_set) + countLines(rec.log.items, try std.fmt.bufPrint(&buf, "removeAttribute({d},class)", .{h}));
        try std.testing.expectEqual(@as(usize, 1), removed);
    }
    try std.testing.expectEqualStrings(tree.root.children[0].attrs[0].value, classAt(rec.log.items, 0).?);
    try std.testing.expect(contains(rec.log.items, try std.fmt.bufPrint(&buf, "setStyle(101,{s})", .{tree.root.style})));
    try std.testing.expect(contains(rec.log.items, "setTextContent(107,Gate)"));
    try std.testing.expectEqual(@as(u32, 1), page.rules.count());

    // The first render at that size only reads the scroll offset, and adds
    // no rule the server sheet has.
    const start = rec.log.items.len;
    try render(gpa, rec.ops(), list, size, bg, &sink, &mem, &page, false);
    try std.testing.expectEqual(@as(usize, 1), rec.log.items.len - start);
    try std.testing.expectEqualStrings("readScrollOffset(103)->0,0", rec.log.items[start]);
    try std.testing.expectEqual(@as(u32, 103), mem.handles[0]);
    try std.testing.expectEqual(@as(usize, 0), rec.misuse);
}

test "dom_calls: a server page at another size is patched where the frame changed" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var mem = ScrollMemory{};
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try appendMixed(gpa, &list);
    const served: geometry.PhysicalSize = .{ .width = 100, .height = 100 };
    const bg = geometry.Color.rgb(0, 0, 0);
    _ = try servePage(&rec, arena_state.allocator(), list, served);
    try std.testing.expect(try hydrate(gpa, rec.ops(), list, served, bg, null, &page));

    // The window is wider and the box moved. Only the container and the box
    // change.
    list.primitives.items[0].rrect.rect.x = 30;
    const start = rec.log.items.len;
    try render(gpa, rec.ops(), list, .{ .width = 160, .height = 90 }, bg, null, &mem, &page, false);
    const after = rec.log.items[start..];
    try std.testing.expectEqual(@as(usize, 0), countLines(after, "createElement"));
    try std.testing.expectEqual(@as(usize, 0), countLines(after, "removeChild("));
    try std.testing.expectEqual(@as(usize, 0), countLines(after, "clearChildren("));
    try std.testing.expectEqual(@as(usize, 2), countLines(after, "setStyle("));
    try std.testing.expect(contains(after, "setStyle(101,position:relative;width:10rem;height:5.625rem;"));
    try std.testing.expect(contains(after, "setStyle(102,position:absolute;left:1.875rem;"));
    try std.testing.expectEqual(@as(usize, 0), rec.misuse);
}

test "dom_calls: a server page of another shape reports the mismatch and is built again" {
    const gpa = std.testing.allocator;
    const Case = enum { tag, missing, extra, empty };
    for ([_]Case{ .tag, .missing, .extra, .empty }) |case| {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        var rec = Recorder{ .gpa = gpa };
        defer rec.deinit();
        var page: PageState = .{};
        defer page.deinit(gpa);
        var sink = FaultSink{};
        var list = display_list.DisplayList{};
        defer list.deinit(gpa);
        try appendMixed(gpa, &list);
        const size: geometry.PhysicalSize = .{ .width = 100, .height = 100 };
        const bg = geometry.Color.rgb(0, 0, 0);
        switch (case) {
            // The server drew an image where the box is.
            .tag => {
                _ = try servePage(&rec, arena_state.allocator(), list, size);
                rec.served.items[1].tag = "img";
            },
            // The server drew no box.
            .missing => {
                _ = try servePage(&rec, arena_state.allocator(), list, size);
                _ = rec.served.orderedRemove(1);
            },
            // The server drew a second box after the region.
            .extra => {
                _ = try servePage(&rec, arena_state.allocator(), list, size);
                _ = try rec.addElement(101, .element, "div");
            },
            .empty => {},
        }

        try std.testing.expect(!try hydrate(gpa, rec.ops(), list, size, bg, &sink, &page));
        try std.testing.expectEqual(FaultSink.FaultCode.hydrate_mismatch, sink.first.?.code);
        try std.testing.expectEqual(@as(?Retained, null), page.last);
        try std.testing.expectEqual(@as(u32, 0), page.rules.count());
        // Each element handle the walk took is released once, and nothing
        // in the page changed.
        var taken: usize = 0;
        for (rec.log.items) |l| {
            if (!std.mem.startsWith(u8, l, "firstChild(") and !std.mem.startsWith(u8, l, "nextSibling(")) continue;
            if (!std.mem.endsWith(u8, l, "->0")) taken += 1;
        }
        try std.testing.expectEqual(taken, countLines(rec.log.items, "release("));
        try std.testing.expectEqual(@as(usize, 0), countLines(rec.log.items, "setStyle("));
        try std.testing.expectEqual(@as(usize, 0), countLines(rec.log.items, "class"));

        const start = rec.log.items.len;
        try render(gpa, rec.ops(), list, size, bg, null, null, &page, false);
        const after = rec.log.items[start..];
        try std.testing.expectEqualStrings("clearChildren(1)", after[0]);
        try std.testing.expectEqual(@as(usize, 8), countLines(after, "createElement"));
        try std.testing.expectEqual(@as(usize, 1), countLines(after, "addRule("));
        try std.testing.expectEqual(@as(usize, 0), rec.misuse);
    }
}

test "dom_calls: a host that cannot walk the page or release a handle builds it again with no fault" {
    const gpa = std.testing.allocator;
    for (0..2) |case| {
        var rec = Recorder{ .gpa = gpa };
        defer rec.deinit();
        var page: PageState = .{};
        defer page.deinit(gpa);
        var sink = FaultSink{};
        var list = display_list.DisplayList{};
        defer list.deinit(gpa);
        try appendMixed(gpa, &list);
        var ops = rec.ops();
        if (case == 0) ops.first_child = null else ops.release = null;
        try std.testing.expect(!try hydrate(gpa, ops, list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), &sink, &page));
        try std.testing.expectEqual(@as(usize, 0), rec.log.items.len);
        try std.testing.expectEqual(@as(usize, 0), sink.count);
    }
}

test "dom_calls: a client frame that differs from the server's at the same shape takes its attributes and text" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var bytes = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01 };
    var img = image_mod.Image.fromBytes(&bytes, 10, 10);
    const size: geometry.PhysicalSize = .{ .width = 100, .height = 100 };
    const bg = geometry.Color.rgb(0, 0, 0);
    const run: display_list.TextRun = .{ .glyphs = &.{}, .text = "12:00", .font = &font, .size = 16, .color = geometry.Color.rgb(1, 1, 1), .origin = .{ .x = 0, .y = 0 } };
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    // Container 101, clock 102, svg 103, path 104, img 105, label 106.
    try list.append(gpa, .{ .text = run });
    try list.append(gpa, .{ .icon = .{ .id = .torii, .size = .{ .width = 16, .height = 16 }, .color = geometry.Color.rgb(1, 0, 0), .origin = .{ .x = 0, .y = 20 } } });
    try list.append(gpa, .{ .image = .{ .image = &img, .rect = .{ .x = 0, .y = 40, .width = 10, .height = 10 } } });
    var label = run;
    label.text = "gone";
    label.origin.y = 60;
    try list.append(gpa, .{ .text = label });
    _ = try servePage(&rec, arena_state.allocator(), list, size);

    // The client draws a later time, another icon colour, other image bytes
    // and a box where the server drew a label.
    list.primitives.items[0].text.text = "12:01";
    list.primitives.items[1].icon.color = geometry.Color.rgb(0, 0, 1);
    bytes[9] = 0x02;
    list.primitives.items[3] = .{ .rrect = .{ .rect = .{ .x = 0, .y = 60, .width = 5, .height = 5 }, .radius = 0, .color = geometry.Color.rgb(1, 0, 0) } };
    try std.testing.expect(try hydrate(gpa, rec.ops(), list, size, bg, null, &page));
    try std.testing.expect(contains(rec.log.items, "setTextContent(102,12:01)"));
    try std.testing.expect(contains(rec.log.items, "setAttribute(104,stroke,rgba(0,0,255,1))"));
    try std.testing.expect(contains(rec.log.items, "setAttribute(105,src,data:image/png;base64,iVBORw0KGgoAAg==)"));
    try std.testing.expect(contains(rec.log.items, "setTextContent(106,)"));
    try std.testing.expectEqual(@as(usize, 0), countLines(rec.log.items, "createElement"));

    // The retained tree is what the page shows, so the same frame sends nothing.
    const start = rec.log.items.len;
    try render(gpa, rec.ops(), list, size, bg, null, null, &page, false);
    try std.testing.expectEqual(start, rec.log.items.len);
    try std.testing.expectEqual(@as(usize, 0), rec.misuse);
}

test "dom_calls: a region whose view is not at the top keeps its offset through hydration" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var mem = ScrollMemory{};
    var view = TestView{};
    view.init();
    // A jumpTo before the first frame.
    view.offset.y = 40;
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, testRegion(&view));
    try list.append(gpa, .{ .rrect = .{ .rect = .{ .x = 0, .y = 0, .width = 100, .height = 20 }, .radius = 0, .color = geometry.Color.rgb(0, 0, 1) } });
    try list.append(gpa, .{ .pop_scroll = {} });
    const size: geometry.PhysicalSize = .{ .width = 200, .height = 100 };
    const bg = geometry.Color.rgb(0, 0, 0);
    // Container 101, outer 102, inner 103, row 104.
    _ = try servePage(&rec, arena_state.allocator(), list, size);

    try std.testing.expect(try hydrate(gpa, rec.ops(), list, size, bg, null, &page));
    const written = indexOfLine(rec.log.items, "writeScrollOffset(102,0,40)").?;
    try std.testing.expect(written > indexOfLine(rec.log.items, "setStyle(103,").?);

    const start = rec.log.items.len;
    try render(gpa, rec.ops(), list, size, bg, null, &mem, &page, false);
    const after = rec.log.items[start..];
    try std.testing.expect(contains(after, "readScrollOffset(102)->0,40"));
    try std.testing.expect(!contains(after, "writeScrollOffset("));
    try std.testing.expectEqual(@as(f32, 40), view.offset.y);
    try std.testing.expect(!mem.synced);
}

test "dom_calls: a clip adopted at a server scroll region loses the region mark" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var page: PageState = .{};
    defer page.deinit(gpa);
    var view = TestView{};
    view.init();
    const row: display_list.Primitive = .{ .rrect = .{ .rect = .{ .x = 0, .y = 0, .width = 100, .height = 20 }, .radius = 0, .color = geometry.Color.rgb(0, 0, 1) } };
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, testRegion(&view));
    try list.append(gpa, row);
    try list.append(gpa, .{ .pop_scroll = {} });
    const size: geometry.PhysicalSize = .{ .width = 200, .height = 100 };
    const bg = geometry.Color.rgb(0, 0, 0);
    // Container 101, outer 102, inner 103, row 104.
    _ = try servePage(&rec, arena_state.allocator(), list, size);

    // The client draws two clips of the same shape.
    list.clear();
    const clip: display_list.Primitive = .{ .push_clip = .{ .rect = .{ .x = 0, .y = 0, .width = 100, .height = 50 } } };
    try list.append(gpa, clip);
    try list.append(gpa, clip);
    try list.append(gpa, row);
    try list.append(gpa, .{ .pop_clip = {} });
    try list.append(gpa, .{ .pop_clip = {} });
    try std.testing.expect(try hydrate(gpa, rec.ops(), list, size, bg, null, &page));
    try std.testing.expect(contains(rec.log.items, "removeAttribute(102,data-phantom-scroll)"));
    try std.testing.expectEqual(@as(usize, 0), countLines(rec.log.items, "setAttribute(102,data-phantom-scroll"));
    try std.testing.expectEqual(@as(usize, 0), countLines(rec.log.items, "createElement"));
    try std.testing.expectEqual(@as(usize, 0), rec.misuse);
}
