//! The hooks a backend fills in for the things a widget tree cannot do by
//! itself: open a URL, and read or write the address of the page, its query
//! string included. Native backends leave page-address hooks null; Linux fills
//! the URL hook through the desktop portal. A widget that finds a null hook does
//! nothing rather than guessing.

const std = @import("std");
const http_mod = @import("http.zig");
pub const system = @import("platform/system.zig");
pub const Connectivity = system.Connectivity;
pub const WifiNetwork = system.WifiNetwork;
pub const Power = system.Power;
pub const Audio = system.Audio;
pub const Brightness = system.Brightness;
pub const SessionCapabilities = system.SessionCapabilities;
pub const Identity = system.Identity;

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

/// Failures common to the small persistent key/value store exposed by each
/// host. Values are opaque bytes; applications can put ZON (or any other
/// encoding) inside them without the platform layer interpreting it.
pub const SettingsError = error{
    Unsupported,
    InvalidKey,
    BufferTooSmall,
    StorageFailure,
};

/// A file selected by a person. All slices are borrowed and valid only for the
/// duration of `FilePickerSink.on_result`; copy anything retained afterwards.
pub const PickedFile = struct {
    name: []const u8,
    media_type: []const u8 = "application/octet-stream",
    bytes: []const u8,
};

pub const FilePickerResult = union(enum) {
    selected: PickedFile,
    cancelled,
    failed,
};

pub const FilePickerOptions = struct {
    /// Comma-separated MIME types and extensions, using the HTML `accept`
    /// grammar (for example `image/*,.svg`). Native hosts translate it.
    accept: []const u8 = "",
};

pub const FilePickerSink = struct {
    ctx: *anyopaque,
    on_result: *const fn (ctx: *anyopaque, result: FilePickerResult) void,
};

pub const Notification = struct {
    /// Stable application-defined id. Reusing it replaces the prior notice.
    id: []const u8,
    title: []const u8,
    body: []const u8,
};

pub const NotificationPermission = enum { granted, denied, prompt, unsupported };

pub const NotificationPermissionSink = struct {
    ctx: *anyopaque,
    on_result: *const fn (ctx: *anyopaque, result: NotificationPermission) void,
};

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
    /// True when the host draws its own scrollbars, as a browser does. Scroll
    /// views then draw none.
    native_scrollbars: bool = false,
    /// Persistent application settings. Keys are portable path components:
    /// non-empty UTF-8 without '/', '\\', NUL, or `..`. A read returns null
    /// when the key has never been written and `BufferTooSmall` rather than a
    /// truncated value. Linux stores these in an XDG ZON file; browser and
    /// Android hosts map them to their platform stores.
    read_setting: ?*const fn (*anyopaque, key: []const u8, buf: []u8) SettingsError!?[]const u8 = null,
    write_setting: ?*const fn (*anyopaque, key: []const u8, value: []const u8) SettingsError!void = null,
    remove_setting: ?*const fn (*anyopaque, key: []const u8) SettingsError!void = null,
    pick_file: ?*const fn (*anyopaque, FilePickerOptions, FilePickerSink) bool = null,
    notification_permission: ?*const fn (*anyopaque) NotificationPermission = null,
    request_notification_permission: ?*const fn (*anyopaque, NotificationPermissionSink) bool = null,
    show_notification: ?*const fn (*anyopaque, Notification) bool = null,
    /// Host-wide hardware/session state. A missing hook means the backend does
    /// not expose that capability; a returned value such as `Power.present =
    /// false` is a successful answer and must not be confused with missing
    /// support.
    read_connectivity: ?*const fn (*anyopaque) ?Connectivity = null,
    set_networking_enabled: ?*const fn (*anyopaque, bool) bool = null,
    set_wifi_enabled: ?*const fn (*anyopaque, bool) bool = null,
    set_cellular_enabled: ?*const fn (*anyopaque, bool) bool = null,
    read_wifi_networks: ?*const fn (*anyopaque) ?[]const WifiNetwork = null,
    request_wifi_scan: ?*const fn (*anyopaque) bool = null,
    connect_wifi: ?*const fn (*anyopaque, id: []const u8, password: []const u8) bool = null,
    disconnect_wifi: ?*const fn (*anyopaque, id: []const u8) bool = null,
    read_power: ?*const fn (*anyopaque) ?Power = null,
    read_audio: ?*const fn (*anyopaque) ?Audio = null,
    set_audio: ?*const fn (*anyopaque, Audio) bool = null,
    read_brightness: ?*const fn (*anyopaque) ?Brightness = null,
    set_brightness: ?*const fn (*anyopaque, Brightness) bool = null,
    session_capabilities: ?*const fn (*anyopaque) SessionCapabilities = null,
    lock_session: ?*const fn (*anyopaque) bool = null,
    logout_session: ?*const fn (*anyopaque) bool = null,
    suspend_session: ?*const fn (*anyopaque) bool = null,
    restart_system: ?*const fn (*anyopaque) bool = null,
    power_off_system: ?*const fn (*anyopaque) bool = null,
    read_identity: ?*const fn (*anyopaque) ?Identity = null,

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

    pub fn readSetting(self: Platform, key: []const u8, buf: []u8) SettingsError!?[]const u8 {
        const f = self.read_setting orelse return error.Unsupported;
        const c = self.ctx orelse return error.Unsupported;
        return f(c, key, buf);
    }

    pub fn writeSetting(self: Platform, key: []const u8, value: []const u8) SettingsError!void {
        const f = self.write_setting orelse return error.Unsupported;
        const c = self.ctx orelse return error.Unsupported;
        return f(c, key, value);
    }

    pub fn removeSetting(self: Platform, key: []const u8) SettingsError!void {
        const f = self.remove_setting orelse return error.Unsupported;
        const c = self.ctx orelse return error.Unsupported;
        return f(c, key);
    }

    pub fn pickFile(self: Platform, options: FilePickerOptions, sink: FilePickerSink) bool {
        const f = self.pick_file orelse return false;
        const c = self.ctx orelse return false;
        return f(c, options, sink);
    }

    pub fn notificationPermission(self: Platform) NotificationPermission {
        const f = self.notification_permission orelse return .unsupported;
        const c = self.ctx orelse return .unsupported;
        return f(c);
    }

    pub fn requestNotificationPermission(self: Platform, sink: NotificationPermissionSink) bool {
        const f = self.request_notification_permission orelse return false;
        const c = self.ctx orelse return false;
        return f(c, sink);
    }

    pub fn showNotification(self: Platform, notification: Notification) bool {
        const f = self.show_notification orelse return false;
        const c = self.ctx orelse return false;
        return f(c, notification);
    }

    pub fn readConnectivity(self: Platform) ?Connectivity {
        const f = self.read_connectivity orelse return null;
        return f(self.ctx orelse return null);
    }

    pub fn setNetworkingEnabled(self: Platform, enabled: bool) bool {
        const f = self.set_networking_enabled orelse return false;
        return f(self.ctx orelse return false, enabled);
    }

    pub fn setWifiEnabled(self: Platform, enabled: bool) bool {
        const f = self.set_wifi_enabled orelse return false;
        return f(self.ctx orelse return false, enabled);
    }

    pub fn readWifiNetworks(self: Platform) ?[]const WifiNetwork {
        const f = self.read_wifi_networks orelse return null;
        const c = self.ctx orelse return null;
        return f(c);
    }

    pub fn requestWifiScan(self: Platform) bool {
        const f = self.request_wifi_scan orelse return false;
        const c = self.ctx orelse return false;
        return f(c);
    }

    pub fn connectWifi(self: Platform, id: []const u8, password: []const u8) bool {
        const f = self.connect_wifi orelse return false;
        const c = self.ctx orelse return false;
        return f(c, id, password);
    }

    pub fn disconnectWifi(self: Platform, id: []const u8) bool {
        const f = self.disconnect_wifi orelse return false;
        const c = self.ctx orelse return false;
        return f(c, id);
    }

    pub fn setCellularEnabled(self: Platform, enabled: bool) bool {
        const f = self.set_cellular_enabled orelse return false;
        return f(self.ctx orelse return false, enabled);
    }

    pub fn readPower(self: Platform) ?Power {
        const f = self.read_power orelse return null;
        return f(self.ctx orelse return null);
    }

    pub fn readAudio(self: Platform) ?Audio {
        const f = self.read_audio orelse return null;
        return f(self.ctx orelse return null);
    }

    pub fn setAudio(self: Platform, state: Audio) bool {
        const f = self.set_audio orelse return false;
        return f(self.ctx orelse return false, .{
            .output_volume = @max(0, @min(1, state.output_volume)),
            .muted = state.muted,
        });
    }

    pub fn readBrightness(self: Platform) ?Brightness {
        const f = self.read_brightness orelse return null;
        return f(self.ctx orelse return null);
    }

    pub fn setBrightness(self: Platform, state: Brightness) bool {
        const f = self.set_brightness orelse return false;
        return f(self.ctx orelse return false, .{ .level = @max(0, @min(1, state.level)) });
    }

    pub fn sessionCapabilities(self: Platform) SessionCapabilities {
        const f = self.session_capabilities orelse return .{};
        return f(self.ctx orelse return .{});
    }

    pub fn lockSession(self: Platform) bool {
        const f = self.lock_session orelse return false;
        return f(self.ctx orelse return false);
    }

    pub fn logoutSession(self: Platform) bool {
        const f = self.logout_session orelse return false;
        return f(self.ctx orelse return false);
    }

    pub fn suspendSession(self: Platform) bool {
        const f = self.suspend_session orelse return false;
        return f(self.ctx orelse return false);
    }

    pub fn restartSystem(self: Platform) bool {
        const f = self.restart_system orelse return false;
        return f(self.ctx orelse return false);
    }

    pub fn powerOffSystem(self: Platform) bool {
        const f = self.power_off_system orelse return false;
        return f(self.ctx orelse return false);
    }

    pub fn readIdentity(self: Platform) ?Identity {
        const f = self.read_identity orelse return null;
        return f(self.ctx orelse return null);
    }
};

pub fn validSettingKey(key: []const u8) bool {
    if (key.len == 0 or std.mem.eql(u8, key, ".") or std.mem.eql(u8, key, "..")) return false;
    return std.mem.indexOfAny(u8, key, "/\\\x00") == null and std.unicode.utf8ValidateSlice(key);
}

test "an empty platform opens nothing and reports that it did not" {
    const p = Platform{};
    try std.testing.expect(!p.openUrl("https://example.com", .new_tab));
}

test "an empty platform reports settings as unsupported" {
    const p = Platform{};
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.Unsupported, p.readSetting("theme", &buf));
    try std.testing.expectError(error.Unsupported, p.writeSetting("theme", "dark"));
    try std.testing.expectError(error.Unsupported, p.removeSetting("theme"));
}

test "an empty platform reports interactive services as unsupported" {
    const Sink = struct {
        fn file(_: *anyopaque, _: FilePickerResult) void {}
        fn permission(_: *anyopaque, _: NotificationPermission) void {}
    };
    var context: u8 = 0;
    const p = Platform{};
    try std.testing.expect(!p.pickFile(.{}, .{ .ctx = &context, .on_result = Sink.file }));
    try std.testing.expectEqual(NotificationPermission.unsupported, p.notificationPermission());
    try std.testing.expect(!p.requestNotificationPermission(.{ .ctx = &context, .on_result = Sink.permission }));
    try std.testing.expect(!p.showNotification(.{ .id = "id", .title = "title", .body = "body" }));
    try std.testing.expectEqual(@as(?Connectivity, null), p.readConnectivity());
    try std.testing.expect(!p.setNetworkingEnabled(true));
    try std.testing.expect(!p.setWifiEnabled(true));
    try std.testing.expect(!p.setCellularEnabled(true));
    try std.testing.expectEqual(@as(?Power, null), p.readPower());
    try std.testing.expectEqual(@as(?Audio, null), p.readAudio());
    try std.testing.expectEqual(@as(?Brightness, null), p.readBrightness());
    try std.testing.expect(!p.sessionCapabilities().power_off);
    try std.testing.expect(!p.lockSession());
    try std.testing.expect(!p.logoutSession());
    try std.testing.expect(!p.suspendSession());
    try std.testing.expect(!p.restartSystem());
    try std.testing.expect(!p.powerOffSystem());
    try std.testing.expectEqual(@as(?Identity, null), p.readIdentity());
}

test "normalized hardware writes are clamped before reaching a host" {
    const Spy = struct {
        audio: Audio = .{ .output_volume = 0, .muted = false },
        brightness: Brightness = .{ .level = 0 },
        fn setAudio(ctx: *anyopaque, value: Audio) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.audio = value;
            return true;
        }
        fn setBrightness(ctx: *anyopaque, value: Brightness) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.brightness = value;
            return true;
        }
    };
    var spy = Spy{};
    const p = Platform{ .ctx = &spy, .set_audio = Spy.setAudio, .set_brightness = Spy.setBrightness };
    try std.testing.expect(p.setAudio(.{ .output_volume = 4, .muted = true }));
    try std.testing.expect(p.setBrightness(.{ .level = -2 }));
    try std.testing.expectEqual(@as(f32, 1), spy.audio.output_volume);
    try std.testing.expect(spy.audio.muted);
    try std.testing.expectEqual(@as(f32, 0), spy.brightness.level);
}

test "portable setting keys reject paths and malformed UTF-8" {
    try std.testing.expect(validSettingKey("theme.mode"));
    try std.testing.expect(validSettingKey("文字"));
    try std.testing.expect(!validSettingKey(""));
    try std.testing.expect(!validSettingKey("../secret"));
    try std.testing.expect(!validSettingKey("a/b"));
    try std.testing.expect(!validSettingKey("a\\b"));
    try std.testing.expect(!validSettingKey(&.{0xff}));
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
