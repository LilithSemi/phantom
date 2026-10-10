//! The hooks a backend fills in for the things a widget tree cannot do by
//! itself: open a URL, and read or write the address of the page, its query
//! string included. Native backends leave them null, and a widget that finds a
//! null hook does nothing rather than guessing.

const std = @import("std");
const http_mod = @import("http.zig");

pub const UrlStrategy = enum {
    /// `/#/gallery`. Works on any static host with no configuration.
    hash,
    /// `/gallery`. Needs the host to serve the application for an unknown
    /// path, or the build to write a copy of the page at each route.
    path,
};

/// How a location write should land in the browser's history.
///
/// `push` adds a new entry, so the browser's back button returns to the path
/// that was current before the write. `replace` rewrites the current entry in
/// place, so the back button skips over it, the same as if it had never been
/// visited. A backend with no history (the terminal, the window) has nothing
/// to push or replace, so it ignores this and does nothing either way.
pub const WriteMode = enum { push, replace };

/// Where a URL should open.
///
/// The two are not interchangeable and the wrong one fails in a way that is hard
/// to see. A sign in hop is the case that forces the distinction: it sends a
/// person to another origin and expects them BACK at a callback, so it has to be
/// a navigation. Done as a new tab it can be refused outright by a popup blocker,
/// which is most likely exactly when it matters, because a browser blocks a
/// window opened without a fresh user gesture and an application that awaited a
/// request first has already spent its one.
pub const OpenMode = enum {
    /// A new tab. Right for a link OUT of the application, documentation or a
    /// profile, where this page should still be there to come back to.
    new_tab,
    /// This tab, as a navigation. Right for a hop the application expects to
    /// return from, and the only one a popup blocker cannot refuse.
    same_tab,
};

/// One thing that happened on a server-sent event stream. The slices are valid
/// only for the call that receives them.
pub const ServerEvent = union(enum) {
    /// The connection is open, first time or after a reconnect.
    open,
    message: Message,
    /// The connection dropped and the browser tries again by itself.
    reconnecting,
    /// The browser stopped, for example after a status that is not 200 or a
    /// response that is not `text/event-stream`. No more events come.
    closed,

    pub const Message = struct {
        /// The `event:` field, or "message" when the server sent none.
        type: []const u8,
        data: []const u8,
        last_event_id: []const u8,
    };
};

/// Receives the events of one stream. `ctx` must stay valid until the stream
/// is closed.
pub const ServerEventSink = struct {
    ctx: *anyopaque,
    on_event: *const fn (ctx: *anyopaque, event: ServerEvent) void,
};

/// An open server-sent event stream. Close it with `Platform.closeEventSource`.
pub const EventSource = struct { id: u32 };

pub const Platform = struct {
    ctx: ?*anyopaque = null,
    /// The HTTP client of a backend that has its own, such as the page `fetch`
    /// on the web. Null on a backend that uses `std.http.Client`. Read it
    /// through `BuildOwner.http`.
    http: ?http_mod.Client = null,
    /// Opens a server-sent event stream on `url`. `types` names the event types
    /// to receive in addition to "message". Null when the stream cannot open.
    open_event_source: ?*const fn (*anyopaque, url: []const u8, types: []const []const u8, sink: ServerEventSink) ?EventSource = null,
    close_event_source: ?*const fn (*anyopaque, EventSource) void = null,
    /// Opens `url`, and reports whether the URL WAS opened rather than whether
    /// this hook exists. A browser refuses `window.open` when it decides the
    /// call is a popup, and it says so by handing back nothing; a hook that
    /// swallowed that would leave an application announcing a tab that is not
    /// there.
    open_url: ?*const fn (*anyopaque, []const u8, OpenMode) bool = null,
    /// Writes the current path into `buf` and returns the written part, or
    /// null when the real path is longer than `buf` can hold. A fixed buffer
    /// keeps the ownership on the caller's side, because the browser binding
    /// allocates the string and must free it again.
    read_location: ?*const fn (*anyopaque, []u8) ?[]const u8 = null,
    write_location: ?*const fn (*anyopaque, []const u8, WriteMode) void = null,
    /// Writes the query string into `buf`, without its leading "?", and returns
    /// the written part. Null when the query is longer than `buf` can hold, on
    /// the same rule `read_location` follows: half a query answers a different
    /// question than the whole one.
    ///
    /// Separate from `read_location` because the two are separate parts of the
    /// address and an application reads them for different reasons. The route
    /// decides what is built; the query carries what a redirect handed back.
    read_query: ?*const fn (*anyopaque, []u8) ?[]const u8 = null,
    /// Writes the host the page is served from, with no port and no scheme on it,
    /// and returns the written part. Null when it does not fit.
    ///
    /// An application needs this to talk to its own server: it has to name a host
    /// in the URL it asks for, and only the page knows what that is. A hard coded
    /// one works on the machine it was written on and nowhere else.
    read_host: ?*const fn (*anyopaque, []u8) ?[]const u8 = null,
    strategy: UrlStrategy = .hash,

    /// True when the URL was opened. False means NOTHING HAPPENED, and a caller
    /// should say so: no hook on this backend, or a browser that refused the
    /// call. Both leave a person looking at a page that did not react, so both
    /// deserve the same answer here.
    ///
    /// This used to return true whenever a hook existed, which read as success
    /// and was not: a popup a browser refused looked identical to a tab that
    /// opened, so `Link` reported nothing and the page appeared to ignore a tap.
    pub fn openUrl(self: Platform, url: []const u8, mode: OpenMode) bool {
        const f = self.open_url orelse return false;
        const c = self.ctx orelse return false;
        return f(c, url, mode);
    }

    pub fn readLocation(self: Platform, buf: []u8) ?[]const u8 {
        const f = self.read_location orelse return null;
        const c = self.ctx orelse return null;
        return f(c, buf);
    }

    /// The query string with no leading "?".
    ///
    /// An empty slice and null are different answers. Empty means the address
    /// carries no query, which is the ordinary case. Null means the query could
    /// not be read: no hook on this backend, or a query too long for `buf`.
    pub fn readQuery(self: Platform, buf: []u8) ?[]const u8 {
        const f = self.read_query orelse return null;
        const c = self.ctx orelse return null;
        return f(c, buf);
    }

    /// The host the page is served from, with no port on it.
    ///
    /// Null on a backend that is not a page, which is every native one. An
    /// application that finds null is not running in a browser and has no origin
    /// of its own to talk to.
    pub fn readHost(self: Platform, buf: []u8) ?[]const u8 {
        const f = self.read_host orelse return null;
        const c = self.ctx orelse return null;
        return f(c, buf);
    }

    pub fn writeLocation(self: Platform, path: []const u8, mode: WriteMode) void {
        const f = self.write_location orelse return;
        const c = self.ctx orelse return;
        f(c, path, mode);
    }

    /// Opens a server-sent event stream, such as a `text/event-stream` response.
    /// The page reads it with the browser's `EventSource`, so the stream can stay
    /// open, which a request through `std.http.Client` cannot do on the web.
    ///
    /// Null on a backend with no browser, and when no slot is free. Events go to
    /// `sink` between frames, never while the tree builds.
    pub fn openEventSource(self: Platform, url: []const u8, types: []const []const u8, sink: ServerEventSink) ?EventSource {
        const f = self.open_event_source orelse return null;
        const c = self.ctx orelse return null;
        return f(c, url, types, sink);
    }

    /// Closes a stream. No event reaches its sink after this returns.
    pub fn closeEventSource(self: Platform, source: EventSource) void {
        const f = self.close_event_source orelse return;
        const c = self.ctx orelse return;
        f(c, source);
    }
};

test "an empty platform opens nothing and reports that it did not" {
    const p = Platform{};
    try std.testing.expect(!p.openUrl("https://example.com", .new_tab));
}

test "openUrl passes the url and the mode through, and answers what the hook answered" {
    const Spy = struct {
        seen: [64]u8 = undefined,
        len: usize = 0,
        seen_mode: ?OpenMode = null,
        answer: bool = true,
        fn open(ctx: *anyopaque, url: []const u8, mode: OpenMode) bool {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(s.seen[0..url.len], url);
            s.len = url.len;
            s.seen_mode = mode;
            return s.answer;
        }
    };
    var spy = Spy{};
    const p = Platform{ .ctx = &spy, .open_url = Spy.open };

    try std.testing.expect(p.openUrl("https://example.com", .same_tab));
    try std.testing.expectEqualStrings("https://example.com", spy.seen[0..spy.len]);
    // The mode has to survive the trip: the two are not interchangeable, and a
    // sign in hop sent to a new tab is the one a popup blocker refuses.
    try std.testing.expectEqual(OpenMode.same_tab, spy.seen_mode.?);

    try std.testing.expect(p.openUrl("https://example.com", .new_tab));
    try std.testing.expectEqual(OpenMode.new_tab, spy.seen_mode.?);

    // A browser that refused the call must reach the caller as a refusal. This
    // used to answer true whenever a hook existed, so a blocked popup and an
    // opened tab were the same answer.
    spy.answer = false;
    try std.testing.expect(!p.openUrl("https://example.com", .new_tab));
}

test "readLocation with no hook returns null" {
    const p = Platform{};
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), p.readLocation(&buf));
}

test "writeLocation passes the mode to the hook unchanged" {
    const Spy = struct {
        seen_mode: ?WriteMode = null,
        fn write(ctx: *anyopaque, path: []const u8, mode: WriteMode) void {
            _ = path;
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.seen_mode = mode;
        }
    };
    var spy = Spy{};
    const p = Platform{ .ctx = &spy, .write_location = Spy.write };

    p.writeLocation("/gallery", .push);
    try std.testing.expectEqual(WriteMode.push, spy.seen_mode.?);

    p.writeLocation("/gallery", .replace);
    try std.testing.expectEqual(WriteMode.replace, spy.seen_mode.?);
}

test "readQuery with no hook returns null, which is not the same answer as an empty query" {
    // A backend with no query to read and a page whose address carries no query
    // must not look alike: one of them can never answer, the other answered
    // "there is none".
    const p = Platform{};
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), p.readQuery(&buf));

    const Spy = struct {
        fn read(_: *anyopaque, b: []u8) ?[]const u8 {
            return b[0..0];
        }
    };
    var ctx: u8 = 0;
    const q = Platform{ .ctx = &ctx, .read_query = Spy.read };
    try std.testing.expectEqualStrings("", q.readQuery(&buf).?);
}
