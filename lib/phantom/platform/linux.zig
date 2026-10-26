//! Open a URI through the desktop portal on Linux.
//!
//! The portal is preferable to starting `xdg-open`: it works in sandboxed
//! applications, is native to Wayland desktops, and does not require a shell or
//! a child-process lifetime policy from the embedding application.

const std = @import("std");
const dbus = @import("dbus");
const platform = @import("../platform.zig");
pub const Settings = @import("zon_settings.zig").Store;

const portal_name = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const portal_interface = "org.freedesktop.portal.OpenURI";
const notification_interface = "org.freedesktop.portal.Notification";
const file_chooser_interface = "org.freedesktop.portal.FileChooser";

pub const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    session_bus_address: ?[]const u8,
    settings: ?Settings = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, session_bus_address: ?[]const u8) Host {
        return .{ .gpa = gpa, .io = io, .session_bus_address = session_bus_address };
    }

    pub fn initForApp(
        gpa: std.mem.Allocator,
        io: std.Io,
        session_bus_address: ?[]const u8,
        environ: *const std.process.Environ.Map,
        app_id: []const u8,
    ) !Host {
        return .{
            .gpa = gpa,
            .io = io,
            .session_bus_address = session_bus_address,
            .settings = try Settings.initXdg(gpa, io, environ, app_id),
        };
    }

    pub fn deinit(self: *Host) void {
        if (self.settings) |*settings| settings.deinit();
        self.* = undefined;
    }

    pub fn asPlatform(self: *Host) platform.Platform {
        return .{
            .ctx = self,
            .open_url = openUrl,
            .read_setting = if (self.settings != null) readSetting else null,
            .write_setting = if (self.settings != null) writeSetting else null,
            .remove_setting = if (self.settings != null) removeSetting else null,
            .notification_permission = notificationPermission,
            .show_notification = showNotification,
            .pick_file = pickFile,
        };
    }

    fn readSetting(ctx: *anyopaque, key: []const u8, buf: []u8) platform.SettingsError!?[]const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        return self.settings.?.read(key, buf);
    }

    fn writeSetting(ctx: *anyopaque, key: []const u8, value: []const u8) platform.SettingsError!void {
        const self: *Host = @ptrCast(@alignCast(ctx));
        return self.settings.?.write(key, value);
    }

    fn removeSetting(ctx: *anyopaque, key: []const u8) platform.SettingsError!void {
        const self: *Host = @ptrCast(@alignCast(ctx));
        return self.settings.?.remove(key);
    }

    fn notificationPermission(_: *anyopaque) platform.NotificationPermission {
        // The desktop portal mediates policy itself and has no separate
        // permission prompt/query pair.
        return .granted;
    }

    fn showNotification(ctx: *anyopaque, notification: platform.Notification) bool {
        const self: *Host = @ptrCast(@alignCast(ctx));
        return self.notify(notification) catch false;
    }

    fn openUrl(ctx: *anyopaque, url: []const u8, mode: platform.OpenMode) bool {
        const self: *Host = @ptrCast(@alignCast(ctx));
        // A native application has no tabs of its own. Both modes therefore
        // mean handing the URI to the user's browser; the distinction remains
        // meaningful on the web backend only.
        _ = mode;
        return self.open(url) catch false;
    }

    fn pickFile(ctx: *anyopaque, options: platform.FilePickerOptions, sink: platform.FilePickerSink) bool {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const result = self.chooseFile(options) catch return false;
        defer if (result) |selected| {
            self.gpa.free(selected.name);
            self.gpa.free(selected.bytes);
        };
        sink.on_result(sink.ctx, if (result) |selected| .{ .selected = .{
            .name = selected.name,
            .media_type = "application/octet-stream",
            .bytes = selected.bytes,
        } } else .cancelled);
        return true;
    }

    const SelectedFile = struct { name: []u8, bytes: []u8 };

    fn chooseFile(self: *Host, options: platform.FilePickerOptions) !?SelectedFile {
        _ = options; // Portal filter translation can be added without changing the API.
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();
        const bus = try self.connect(&loop);
        defer bus.deinit();

        var response = FileChooserResponse{ .gpa = self.gpa };
        defer response.deinit();
        try bus.addSignalHandler(.{
            .msg_type = .signal,
            .interface = "org.freedesktop.portal.Request",
            .member = "Response",
            .path_namespace = "/org/freedesktop/portal/desktop/request",
        }, FileChooserResponse.onSignal, &response);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var writer = dbus.Writer.init(self.gpa, &body, bus.conn.endian);
        try writer.string("");
        try writer.string("Open File");
        const options_array = try writer.beginArray(8);
        writer.endArray(options_array);

        var request = RequestPathReply{};
        _ = try bus.call(.{
            .msg_type = .method_call,
            .serial = 0,
            .path = portal_path,
            .interface = file_chooser_interface,
            .member = "OpenFile",
            .destination = portal_name,
            .body_signature = "ssa{sv}",
            .body = body.items,
        }, RequestPathReply.onReply, &request);
        while (!request.done) _ = loop.dispatch(50);
        if (request.path_len == 0) return error.PortalRejected;
        response.request_path = request.path[0..request.path_len];
        while (!response.done) _ = loop.dispatch(100);
        const uri = response.uri orelse return null;
        if (!std.mem.startsWith(u8, uri, "file://")) return error.UnsupportedUri;
        const encoded = uri[7..];
        const path_buf = try self.gpa.alloc(u8, encoded.len);
        defer self.gpa.free(path_buf);
        const path = std.Uri.percentDecodeBackwards(path_buf, encoded);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(64 * 1024 * 1024));
        errdefer self.gpa.free(bytes);
        return .{
            .name = try self.gpa.dupe(u8, std.fs.path.basename(path)),
            .bytes = bytes,
        };
    }

    fn open(self: *Host, url: []const u8) !bool {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();

        const bus = try self.connect(&loop);
        defer bus.deinit();

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        try marshalOpenUriBody(self.gpa, &body, bus.conn.endian, url);

        var reply: PortalReply = .{};
        _ = try bus.call(.{
            .msg_type = .method_call,
            .serial = 0,
            .path = portal_path,
            .interface = portal_interface,
            .member = "OpenURI",
            .destination = portal_name,
            .body_signature = "ssa{sv}",
            .body = body.items,
        }, PortalReply.onReply, &reply);

        // Calling the hook is synchronous, as it is on web and Android. Wait
        // for the portal to accept the request, but put a bound on a broken bus
        // so a click cannot freeze the application indefinitely.
        var attempts: usize = 0;
        while (!reply.done and attempts < 100) : (attempts += 1) {
            _ = loop.dispatch(50);
        }
        return reply.accepted;
    }

    fn notify(self: *Host, notification: platform.Notification) !bool {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();
        const bus = try self.connect(&loop);
        defer bus.deinit();

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        try marshalNotificationBody(self.gpa, &body, bus.conn.endian, notification);
        var reply: PortalReply = .{};
        _ = try bus.call(.{
            .msg_type = .method_call,
            .serial = 0,
            .path = portal_path,
            .interface = notification_interface,
            .member = "AddNotification",
            .destination = portal_name,
            .body_signature = "sa{sv}",
            .body = body.items,
        }, PortalReply.onEmptyReply, &reply);
        var attempts: usize = 0;
        while (!reply.done and attempts < 100) : (attempts += 1) _ = loop.dispatch(50);
        return reply.accepted;
    }

    fn connect(self: *Host, loop: *dbus.event_loop.EventLoop) !*dbus.client.Bus {
        const uid = std.os.linux.getuid();

        if (self.session_bus_address) |raw| {
            if (dbus.address.parse(self.gpa, raw)) |parsed| {
                var addresses = parsed;
                defer addresses.deinit(self.gpa);
                for (addresses.items) |address| {
                    if (address.kind != .unix) continue;
                    if (address.path) |path| {
                        if (dbus.client.Bus.connectUnix(self.gpa, loop, self.io, path, false, uid)) |bus| return bus else |_| {}
                    }
                    if (address.abstract) |name| {
                        if (dbus.client.Bus.connectUnix(self.gpa, loop, self.io, name, true, uid)) |bus| return bus else |_| {}
                    }
                }
            } else |_| {}
        }

        // This is the standard session-bus address when the environment did
        // not provide one (systemd user sessions use it).
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/run/user/{d}/bus", .{uid});
        return dbus.client.Bus.connectUnix(self.gpa, loop, self.io, path, false, uid);
    }
};

/// Compatibility name for code that used the URL-only Linux host.
pub const Opener = Host;

/// A persistent settings store at
/// `$XDG_CONFIG_HOME/<app-id>/settings.zon` (falling back to
/// `$HOME/.config`). The file is ordinary, human-readable ZON and is replaced
/// atomically, so a process interruption cannot leave a half-written setting.
const PortalReply = struct {
    done: bool = false,
    accepted: bool = false,

    fn onReply(ctx: ?*anyopaque, conn: *dbus.connection.Connection, reply: ?*const dbus.Message) void {
        _ = conn;
        const self: *PortalReply = @ptrCast(@alignCast(ctx.?));
        defer self.done = true;
        const message = reply orelse return;
        if (message.msg_type != .method_return) return;

        // OpenURI returns the object path of its Request. Parsing it also
        // rejects a malformed method return instead of reporting success merely
        // because some message arrived.
        var reader = dbus.Reader.init(message.body, message.endian);
        const request_path = reader.objectPath() catch return;
        self.accepted = request_path.len != 0 and request_path[0] == '/';
    }

    fn onEmptyReply(ctx: ?*anyopaque, conn: *dbus.connection.Connection, reply: ?*const dbus.Message) void {
        _ = conn;
        const self: *PortalReply = @ptrCast(@alignCast(ctx.?));
        defer self.done = true;
        self.accepted = if (reply) |message| message.msg_type == .method_return else false;
    }
};

const RequestPathReply = struct {
    done: bool = false,
    path: [512]u8 = undefined,
    path_len: usize = 0,

    fn onReply(ctx: ?*anyopaque, _: *dbus.connection.Connection, reply: ?*const dbus.Message) void {
        const self: *RequestPathReply = @ptrCast(@alignCast(ctx.?));
        defer self.done = true;
        const message = reply orelse return;
        if (message.msg_type != .method_return) return;
        var reader = dbus.Reader.init(message.body, message.endian);
        const path = reader.objectPath() catch return;
        if (path.len > self.path.len) return;
        @memcpy(self.path[0..path.len], path);
        self.path_len = path.len;
    }
};

const FileChooserResponse = struct {
    gpa: std.mem.Allocator,
    request_path: []const u8 = "",
    uri: ?[]u8 = null,
    done: bool = false,

    fn deinit(self: *FileChooserResponse) void {
        if (self.uri) |uri| self.gpa.free(uri);
    }

    fn onSignal(ctx: ?*anyopaque, _: *dbus.client.Bus, signal: *const dbus.Message) void {
        const self: *FileChooserResponse = @ptrCast(@alignCast(ctx.?));
        if (!std.mem.eql(u8, signal.path orelse return, self.request_path)) return;
        defer self.done = true;
        var reader = dbus.Reader.init(signal.body, signal.endian);
        const code = reader.uint32() catch return;
        if (code != 0) return;
        const results = reader.readValue(self.gpa, "a{sv}") catch return;
        defer dbus.unmarshal.freeValue(self.gpa, results);
        for (results.array) |entry| {
            if (!std.mem.eql(u8, entry.dict_entry[0].string, "uris")) continue;
            const uris = entry.dict_entry[1].variant.array;
            if (uris.len == 0) return;
            self.uri = self.gpa.dupe(u8, uris[0].string) catch null;
            return;
        }
    }
};

fn marshalNotificationBody(
    gpa: std.mem.Allocator,
    body: *std.ArrayList(u8),
    endian: std.builtin.Endian,
    notification: platform.Notification,
) !void {
    var writer = dbus.Writer.init(gpa, body, endian);
    try writer.string(notification.id);
    const fields = try writer.beginArray(8);
    try writer.beginStruct();
    try writer.string("title");
    try writer.beginVariant("s");
    try writer.string(notification.title);
    try writer.beginStruct();
    try writer.string("body");
    try writer.beginVariant("s");
    try writer.string(notification.body);
    writer.endArray(fields);
}

fn marshalOpenUriBody(
    gpa: std.mem.Allocator,
    body: *std.ArrayList(u8),
    endian: std.builtin.Endian,
    url: []const u8,
) !void {
    var writer = dbus.Writer.init(gpa, body, endian);
    try writer.string(""); // No parent window identifier is portable here.
    try writer.string(url);
    const options = try writer.beginArray(8);
    writer.endArray(options); // No options.
}

test "OpenURI body contains an empty parent, the URL, and an empty options dictionary" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    try marshalOpenUriBody(std.testing.allocator, &body, .little, "https://example.com/docs?q=zig");

    var reader = dbus.Reader.init(body.items, .little);
    try std.testing.expectEqualStrings("", try reader.string());
    try std.testing.expectEqualStrings("https://example.com/docs?q=zig", try reader.string());
    const options = try reader.readValue(std.testing.allocator, "a{sv}");
    defer dbus.unmarshal.freeValue(std.testing.allocator, options);
    try std.testing.expectEqual(@as(usize, 0), options.array.len);
}

test "portal notification body carries stable id, title and body" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    try marshalNotificationBody(std.testing.allocator, &body, .little, .{
        .id = "download",
        .title = "Finished",
        .body = "report.pdf is ready",
    });
    var reader = dbus.Reader.init(body.items, .little);
    try std.testing.expectEqualStrings("download", try reader.string());
    const fields = try reader.readValue(std.testing.allocator, "a{sv}");
    defer dbus.unmarshal.freeValue(std.testing.allocator, fields);
    try std.testing.expectEqual(@as(usize, 2), fields.array.len);
    try std.testing.expectEqualStrings("title", fields.array[0].dict_entry[0].string);
    try std.testing.expectEqualStrings("Finished", fields.array[0].dict_entry[1].variant.string);
    try std.testing.expectEqualStrings("body", fields.array[1].dict_entry[0].string);
    try std.testing.expectEqualStrings("report.pdf is ready", fields.array[1].dict_entry[1].variant.string);
}

test "Linux settings persist deterministic ZON and distinguish missing from empty" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/nested/settings.zon", .{tmp.sub_path});
    defer gpa.free(path);

    var settings = try Settings.initPath(gpa, std.testing.io, path);
    try settings.write("theme", "dark");
    try settings.write("empty", "");
    try settings.write("alpha", "first");
    settings.deinit();

    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(4096));
    defer gpa.free(source);
    try std.testing.expect(std.mem.startsWith(u8, source, ".{"));
    const alpha_at = std.mem.indexOf(u8, source, "alpha") orelse return error.MissingAlpha;
    const theme_at = std.mem.indexOf(u8, source, "theme") orelse return error.MissingTheme;
    try std.testing.expect(alpha_at < theme_at);

    var loaded = try Settings.initPath(gpa, std.testing.io, path);
    defer loaded.deinit();
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("dark", (try loaded.read("theme", &buf)).?);
    try std.testing.expectEqualStrings("", (try loaded.read("empty", &buf)).?);
    try std.testing.expect((try loaded.read("missing", &buf)) == null);
    try std.testing.expectError(error.BufferTooSmall, loaded.read("theme", buf[0..2]));
    try loaded.remove("theme");
    try std.testing.expect((try loaded.read("theme", &buf)) == null);
}
