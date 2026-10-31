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
const properties_interface = "org.freedesktop.DBus.Properties";
const nm_name = "org.freedesktop.NetworkManager";
const nm_path = "/org/freedesktop/NetworkManager";
const nm_interface = "org.freedesktop.NetworkManager";
const nm_device_interface = "org.freedesktop.NetworkManager.Device";
const nm_wireless_interface = "org.freedesktop.NetworkManager.Device.Wireless";
const nm_ap_interface = "org.freedesktop.NetworkManager.AccessPoint";
const upower_name = "org.freedesktop.UPower";
const upower_display_path = "/org/freedesktop/UPower/devices/DisplayDevice";
const upower_device_interface = "org.freedesktop.UPower.Device";
const accounts_name = "org.freedesktop.Accounts";
const accounts_path = "/org/freedesktop/Accounts";
const accounts_interface = "org.freedesktop.Accounts";
const account_user_interface = "org.freedesktop.Accounts.User";
const login_name = "org.freedesktop.login1";
const login_path = "/org/freedesktop/login1";
const login_interface = "org.freedesktop.login1.Manager";
const login_session_interface = "org.freedesktop.login1.Session";
const hardware_cache_ns = 2 * std.time.ns_per_s;

const SettingValue = union(enum) { string: []const u8 };
const SettingEntry = struct { key: []const u8, value: SettingValue };

fn writeSettingSection(writer: *dbus.Writer, name: []const u8, entries: []const SettingEntry) !void {
    try writer.beginStruct();
    try writer.string(name);
    const values = try writer.beginArray(dbus.types.alignmentOf(.dict_begin));
    for (entries) |entry| {
        try writer.beginStruct();
        try writer.string(entry.key);
        switch (entry.value) {
            .string => |value| {
                try writer.beginVariant("s");
                try writer.string(value);
            },
        }
    }
    writer.endArray(values);
}

pub const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    session_bus_address: ?[]const u8,
    settings: ?Settings = null,
    connectivity_cache: ?platform.Connectivity = null,
    connectivity_checked_ns: i96 = std.math.minInt(i96),
    wifi_networks: [32]platform.WifiNetwork = undefined,
    wifi_ssids: [32][32]u8 = undefined,
    wifi_paths: [32][256]u8 = undefined,
    wifi_count: usize = 0,
    wifi_device: [256]u8 = undefined,
    wifi_device_len: usize = 0,
    wifi_checked_ns: i96 = std.math.minInt(i96),
    power_cache: ?platform.Power = null,
    power_checked_ns: i96 = std.math.minInt(i96),
    audio_cache: ?platform.Audio = null,
    audio_checked_ns: i96 = std.math.minInt(i96),
    brightness_cache: ?platform.Brightness = null,
    brightness_checked_ns: i96 = std.math.minInt(i96),
    backlight_name: [256]u8 = undefined,
    backlight_name_len: usize = 0,
    backlight_max: u32 = 0,
    session_cache: ?platform.SessionCapabilities = null,
    session_checked_ns: i96 = std.math.minInt(i96),
    login_session_path: [512]u8 = undefined,
    login_session_path_len: usize = 0,
    user_name: ?[]u8 = null,
    display_name: ?[]u8 = null,
    avatar: ?[]u8 = null,
    system_name: ?[]u8 = null,
    account_checked: bool = false,

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
        var host = Host{
            .gpa = gpa,
            .io = io,
            .session_bus_address = session_bus_address,
            .settings = try Settings.initXdg(gpa, io, environ, app_id),
        };
        errdefer host.settings.?.deinit();
        errdefer if (host.user_name) |value| gpa.free(value);
        errdefer if (host.display_name) |value| gpa.free(value);
        errdefer if (host.avatar) |value| gpa.free(value);
        errdefer if (host.system_name) |value| gpa.free(value);
        try host.loadIdentity(environ);
        host.account_checked = true;
        host.queryAccountIdentity() catch {};
        return host;
    }

    pub fn deinit(self: *Host) void {
        if (self.settings) |*settings| settings.deinit();
        if (self.user_name) |value| self.gpa.free(value);
        if (self.display_name) |value| self.gpa.free(value);
        if (self.avatar) |value| self.gpa.free(value);
        if (self.system_name) |value| self.gpa.free(value);
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
            .read_connectivity = readConnectivity,
            .set_networking_enabled = setNetworkingEnabled,
            .set_wifi_enabled = setWifiEnabled,
            .set_cellular_enabled = setCellularEnabled,
            .read_wifi_networks = readWifiNetworks,
            .request_wifi_scan = requestWifiScan,
            .connect_wifi = connectWifi,
            .disconnect_wifi = disconnectWifi,
            .read_power = readPower,
            .read_audio = readAudio,
            .set_audio = setAudio,
            .read_brightness = readBrightness,
            .set_brightness = setBrightness,
            .session_capabilities = sessionCapabilities,
            .lock_session = lockSession,
            .logout_session = logoutSession,
            .suspend_session = suspendSession,
            .restart_system = restartSystem,
            .power_off_system = powerOffSystem,
            .read_identity = readIdentity,
        };
    }

    fn loadIdentity(self: *Host, environ: *const std.process.Environ.Map) !void {
        const user = environ.get("USER") orelse environ.get("LOGNAME");
        if (user) |value| self.user_name = try self.gpa.dupe(u8, value);

        const contents = std.Io.Dir.cwd().readFileAlloc(self.io, "/etc/os-release", self.gpa, .limited(64 * 1024)) catch return;
        defer self.gpa.free(contents);
        const display = osReleaseValue(contents, "PRETTY_NAME") orelse osReleaseValue(contents, "NAME") orelse return;
        self.system_name = try self.gpa.dupe(u8, display);
    }

    fn readIdentity(ctx: *anyopaque) ?platform.Identity {
        const self: *Host = @ptrCast(@alignCast(ctx));
        if (!self.account_checked) {
            self.account_checked = true;
            self.queryAccountIdentity() catch {};
        }
        if (self.user_name == null and self.system_name == null) return null;
        return .{
            .user_name = self.user_name orelse "User",
            .display_name = self.display_name,
            .avatar = self.avatar,
            .system_name = self.system_name orelse "Linux",
        };
    }

    fn queryAccountIdentity(self: *Host) !void {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();
        const bus = try self.connectSystem(&loop);
        defer bus.deinit();

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var writer = dbus.Writer.init(self.gpa, &body, bus.conn.endian);
        try writer.int64(@intCast(std.os.linux.getuid()));
        var user_reply = RequestPathReply{};
        _ = try bus.call(.{
            .msg_type = .method_call,
            .serial = 0,
            .path = accounts_path,
            .interface = accounts_interface,
            .member = "FindUserById",
            .destination = accounts_name,
            .body_signature = "x",
            .body = body.items,
        }, RequestPathReply.onReply, &user_reply);
        var attempts: usize = 0;
        while (!user_reply.done and attempts < 40) : (attempts += 1) _ = loop.dispatch(25);
        if (user_reply.path_len == 0) return error.InvalidReply;
        const user_path = user_reply.path[0..user_reply.path_len];

        if (try self.getProperty(bus, &loop, accounts_name, user_path, account_user_interface, "UserName")) |value| {
            if (value.asString()) |name| if (name.len > 0) {
                const owned = try self.gpa.dupe(u8, name);
                if (self.user_name) |old| self.gpa.free(old);
                self.user_name = owned;
            };
        }
        if (try self.getProperty(bus, &loop, accounts_name, user_path, account_user_interface, "RealName")) |value| {
            if (value.asString()) |name| {
                if (name.len > 0) self.display_name = try self.gpa.dupe(u8, name);
            }
        }
        if (try self.getProperty(bus, &loop, accounts_name, user_path, account_user_interface, "IconFile")) |value| {
            if (value.asString()) |icon| {
                if (icon.len > 0) self.avatar = try self.gpa.dupe(u8, icon);
            }
        }
    }

    fn readConnectivity(ctx: *anyopaque) ?platform.Connectivity {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const now = std.Io.Clock.now(.awake, self.io).nanoseconds;
        if (self.connectivity_cache == null or self.connectivity_checked_ns == std.math.minInt(i96) or now - self.connectivity_checked_ns >= hardware_cache_ns) {
            self.connectivity_checked_ns = now;
            self.connectivity_cache = self.queryConnectivity() catch null;
        }
        return self.connectivity_cache;
    }

    fn setNetworkingEnabled(ctx: *anyopaque, enabled: bool) bool {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const changed = self.callNetworkManagerBoolMethod("Enable", enabled) catch false;
        if (changed) self.invalidateConnectivity();
        return changed;
    }

    fn setWifiEnabled(ctx: *anyopaque, enabled: bool) bool {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const changed = self.setNetworkManagerBoolProperty("WirelessEnabled", enabled) catch false;
        if (changed) self.invalidateConnectivity();
        return changed;
    }

    fn setCellularEnabled(ctx: *anyopaque, enabled: bool) bool {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const changed = self.setNetworkManagerBoolProperty("WwanEnabled", enabled) catch false;
        if (changed) self.invalidateConnectivity();
        return changed;
    }

    fn invalidateConnectivity(self: *Host) void {
        self.connectivity_cache = null;
        self.connectivity_checked_ns = std.math.minInt(i96);
    }

    fn readWifiNetworks(ctx: *anyopaque) ?[]const platform.WifiNetwork {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const now = std.Io.Clock.now(.real, self.io).nanoseconds;
        // `minInt` is the invalid-cache sentinel. Subtracting it first wraps
        // in release builds, which used to make the initial empty cache look
        // fresh and prevented NetworkManager from ever being queried.
        if (self.wifi_checked_ns == std.math.minInt(i96) or now - self.wifi_checked_ns >= hardware_cache_ns) {
            self.queryWifiNetworks() catch return null;
            self.wifi_checked_ns = now;
        }
        return self.wifi_networks[0..self.wifi_count];
    }

    fn requestWifiScan(ctx: *anyopaque) bool {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const result = self.scanWifi() catch false;
        if (result) self.wifi_checked_ns = std.math.minInt(i96);
        return result;
    }

    fn connectWifi(ctx: *anyopaque, id: []const u8, password: []const u8) bool {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const result = self.activateWifi(id, password) catch false;
        if (result) {
            self.invalidateConnectivity();
            self.wifi_checked_ns = std.math.minInt(i96);
        }
        return result;
    }

    fn disconnectWifi(ctx: *anyopaque, _: []const u8) bool {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const result = self.disconnectWifiDevice() catch false;
        if (result) {
            self.invalidateConnectivity();
            self.wifi_checked_ns = std.math.minInt(i96);
        }
        return result;
    }

    fn readPower(ctx: *anyopaque) ?platform.Power {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const now = std.Io.Clock.now(.awake, self.io).nanoseconds;
        if (self.power_cache == null or self.power_checked_ns == std.math.minInt(i96) or now - self.power_checked_ns >= hardware_cache_ns) {
            self.power_checked_ns = now;
            self.power_cache = self.queryPower() catch null;
        }
        return self.power_cache;
    }

    fn readAudio(ctx: *anyopaque) ?platform.Audio {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const now = std.Io.Clock.now(.awake, self.io).nanoseconds;
        if (self.audio_checked_ns == std.math.minInt(i96) or now - self.audio_checked_ns >= hardware_cache_ns) {
            self.audio_checked_ns = now;
            self.audio_cache = self.queryAudio() catch null;
        }
        return self.audio_cache;
    }

    fn setAudio(ctx: *anyopaque, state: platform.Audio) bool {
        const self: *Host = @ptrCast(@alignCast(ctx));
        var volume_buf: [32]u8 = undefined;
        const volume = std.fmt.bufPrint(&volume_buf, "{d:.3}", .{state.output_volume}) catch return false;
        if (!self.runSuccessful(&.{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", volume })) return false;
        if (!self.runSuccessful(&.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", if (state.muted) "1" else "0" })) return false;
        self.audio_cache = state;
        self.audio_checked_ns = std.Io.Clock.now(.awake, self.io).nanoseconds;
        return true;
    }

    fn readBrightness(ctx: *anyopaque) ?platform.Brightness {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const now = std.Io.Clock.now(.awake, self.io).nanoseconds;
        if (self.brightness_checked_ns == std.math.minInt(i96) or now - self.brightness_checked_ns >= hardware_cache_ns) {
            self.brightness_checked_ns = now;
            self.brightness_cache = self.queryBrightness() catch null;
        }
        return self.brightness_cache;
    }

    fn setBrightness(ctx: *anyopaque, state: platform.Brightness) bool {
        const self: *Host = @ptrCast(@alignCast(ctx));
        if (self.backlight_name_len == 0 or self.backlight_max == 0) _ = self.queryBrightness() catch return false;
        const raw: u32 = @intFromFloat(@round(state.level * @as(f32, @floatFromInt(self.backlight_max))));
        if (!(self.callSessionSetBrightness(self.backlight_name[0..self.backlight_name_len], raw) catch false)) return false;
        self.brightness_cache = state;
        self.brightness_checked_ns = std.Io.Clock.now(.awake, self.io).nanoseconds;
        return true;
    }

    fn sessionCapabilities(ctx: *anyopaque) platform.SessionCapabilities {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const now = std.Io.Clock.now(.awake, self.io).nanoseconds;
        if (self.session_cache == null or self.session_checked_ns == std.math.minInt(i96) or now - self.session_checked_ns >= hardware_cache_ns) {
            self.session_checked_ns = now;
            self.session_cache = self.querySessionCapabilities() catch .{};
        }
        return self.session_cache.?;
    }

    fn lockSession(ctx: *anyopaque) bool {
        return (@as(*Host, @ptrCast(@alignCast(ctx)))).callCurrentSession("Lock") catch false;
    }

    fn logoutSession(ctx: *anyopaque) bool {
        return (@as(*Host, @ptrCast(@alignCast(ctx)))).callCurrentSession("Terminate") catch false;
    }

    fn suspendSession(ctx: *anyopaque) bool {
        return (@as(*Host, @ptrCast(@alignCast(ctx)))).callLoginBool("Suspend", true) catch false;
    }

    fn restartSystem(ctx: *anyopaque) bool {
        return (@as(*Host, @ptrCast(@alignCast(ctx)))).callLoginBool("Reboot", true) catch false;
    }

    fn powerOffSystem(ctx: *anyopaque) bool {
        return (@as(*Host, @ptrCast(@alignCast(ctx)))).callLoginBool("PowerOff", true) catch false;
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

    fn connectSystem(self: *Host, loop: *dbus.event_loop.EventLoop) !*dbus.client.Bus {
        return dbus.client.Bus.connectUnix(
            self.gpa,
            loop,
            self.io,
            "/run/dbus/system_bus_socket",
            false,
            std.os.linux.getuid(),
        );
    }

    fn callPaths(self: *Host, bus: *dbus.client.Bus, loop: *dbus.event_loop.EventLoop, path: []const u8, interface: []const u8, member: []const u8) !PathListReply {
        var reply = PathListReply{};
        _ = try bus.call(.{ .msg_type = .method_call, .serial = 0, .path = path, .interface = interface, .member = member, .destination = nm_name }, PathListReply.onReply, &reply);
        var attempts: usize = 0;
        while (!reply.done and attempts < 40) : (attempts += 1) _ = loop.dispatch(25);
        if (!reply.done) return error.InvalidReply;
        _ = self;
        return reply;
    }

    fn findWifiDevice(self: *Host, bus: *dbus.client.Bus, loop: *dbus.event_loop.EventLoop) ![]const u8 {
        if (self.wifi_device_len > 0) return self.wifi_device[0..self.wifi_device_len];
        const devices = try self.callPaths(bus, loop, nm_path, nm_interface, "GetDevices");
        for (devices.paths[0..devices.count]) |candidate| {
            const path = candidate.bytes[0..candidate.len];
            const kind = (try self.getProperty(bus, loop, nm_name, path, nm_device_interface, "DeviceType")) orelse continue;
            if ((kind.asU32() orelse 0) != 2) continue;
            if (path.len > self.wifi_device.len) return error.InvalidReply;
            @memcpy(self.wifi_device[0..path.len], path);
            self.wifi_device_len = path.len;
            return self.wifi_device[0..path.len];
        }
        return error.NoWifiDevice;
    }

    fn queryWifiNetworks(self: *Host) !void {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();
        const bus = try self.connectSystem(&loop);
        defer bus.deinit();
        const device = try self.findWifiDevice(bus, &loop);
        const active_value = try self.getProperty(bus, &loop, nm_name, device, nm_wireless_interface, "ActiveAccessPoint");
        const active = if (active_value) |*value| value.asString() orelse "/" else "/";
        const access_points = try self.callPaths(bus, &loop, device, nm_wireless_interface, "GetAllAccessPoints");
        self.wifi_count = 0;
        for (access_points.paths[0..access_points.count]) |candidate| {
            if (self.wifi_count == self.wifi_networks.len) break;
            const path = candidate.bytes[0..candidate.len];
            const ssid_value = (try self.getProperty(bus, &loop, nm_name, path, nm_ap_interface, "Ssid")) orelse continue;
            const ssid = ssid_value.asBytes() orelse continue;
            if (ssid.len == 0) continue;
            const strength_value = (try self.getProperty(bus, &loop, nm_name, path, nm_ap_interface, "Strength")) orelse continue;
            const flags_value = try self.getProperty(bus, &loop, nm_name, path, nm_ap_interface, "Flags");
            const wpa_value = try self.getProperty(bus, &loop, nm_name, path, nm_ap_interface, "WpaFlags");
            const rsn_value = try self.getProperty(bus, &loop, nm_name, path, nm_ap_interface, "RsnFlags");
            const index = self.wifi_count;
            const ssid_len = @min(ssid.len, self.wifi_ssids[index].len);
            const path_len = @min(path.len, self.wifi_paths[index].len);
            @memcpy(self.wifi_ssids[index][0..ssid_len], ssid[0..ssid_len]);
            @memcpy(self.wifi_paths[index][0..path_len], path[0..path_len]);
            const secured = (if (flags_value) |value| value.asU32() orelse 0 else 0) != 0 or
                (if (wpa_value) |value| value.asU32() orelse 0 else 0) != 0 or
                (if (rsn_value) |value| value.asU32() orelse 0 else 0) != 0;
            self.wifi_networks[index] = .{
                .id = self.wifi_paths[index][0..path_len],
                .ssid = self.wifi_ssids[index][0..ssid_len],
                .strength = strength_value.asByte() orelse 0,
                .security = if (secured) .secured else .open,
                .connected = std.mem.eql(u8, active, path),
            };
            self.wifi_count += 1;
        }
        std.mem.sort(platform.WifiNetwork, self.wifi_networks[0..self.wifi_count], {}, struct {
            fn less(_: void, a: platform.WifiNetwork, b: platform.WifiNetwork) bool {
                return a.strength > b.strength;
            }
        }.less);
    }

    fn scanWifi(self: *Host) !bool {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();
        const bus = try self.connectSystem(&loop);
        defer bus.deinit();
        const device = try self.findWifiDevice(bus, &loop);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var writer = dbus.Writer.init(self.gpa, &body, bus.conn.endian);
        const options = try writer.beginArray(dbus.types.alignmentOf(.dict_begin));
        writer.endArray(options);
        return self.callEmpty(bus, &loop, .{ .msg_type = .method_call, .serial = 0, .path = device, .interface = nm_wireless_interface, .member = "RequestScan", .destination = nm_name, .body_signature = "a{sv}", .body = body.items });
    }

    fn activateWifi(self: *Host, access_point: []const u8, password: []const u8) !bool {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();
        const bus = try self.connectSystem(&loop);
        defer bus.deinit();
        const device = try self.findWifiDevice(bus, &loop);
        var ssid: []const u8 = "";
        var secured = false;
        for (self.wifi_networks[0..self.wifi_count]) |network| if (std.mem.eql(u8, network.id, access_point)) {
            ssid = network.ssid;
            secured = network.security == .secured;
            break;
        };
        if (ssid.len == 0 or (secured and password.len == 0)) return false;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var writer = dbus.Writer.init(self.gpa, &body, bus.conn.endian);
        const settings = try writer.beginArray(dbus.types.alignmentOf(.dict_begin));
        try writeSettingSection(&writer, "connection", &.{
            .{ .key = "id", .value = .{ .string = ssid } },
            .{ .key = "type", .value = .{ .string = "802-11-wireless" } },
        });
        try writer.beginStruct();
        try writer.string("802-11-wireless");
        const wireless = try writer.beginArray(dbus.types.alignmentOf(.dict_begin));
        try writer.beginStruct();
        try writer.string("ssid");
        try writer.beginVariant("ay");
        const ssid_array = try writer.beginArray(dbus.types.alignmentOf(.byte));
        for (ssid) |byte| try writer.byte(byte);
        writer.endArray(ssid_array);
        try writer.beginStruct();
        try writer.string("mode");
        try writer.beginVariant("s");
        try writer.string("infrastructure");
        if (secured) {
            try writer.beginStruct();
            try writer.string("security");
            try writer.beginVariant("s");
            try writer.string("802-11-wireless-security");
        }
        writer.endArray(wireless);
        if (secured) try writeSettingSection(&writer, "802-11-wireless-security", &.{
            .{ .key = "key-mgmt", .value = .{ .string = "wpa-psk" } },
            .{ .key = "psk", .value = .{ .string = password } },
        });
        writer.endArray(settings);
        try writer.objectPath(device);
        try writer.objectPath(access_point);
        return self.callEmpty(bus, &loop, .{ .msg_type = .method_call, .serial = 0, .path = nm_path, .interface = nm_interface, .member = "AddAndActivateConnection", .destination = nm_name, .body_signature = "a{sa{sv}}oo", .body = body.items });
    }

    fn disconnectWifiDevice(self: *Host) !bool {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();
        const bus = try self.connectSystem(&loop);
        defer bus.deinit();
        const device = try self.findWifiDevice(bus, &loop);
        return self.callEmpty(bus, &loop, .{ .msg_type = .method_call, .serial = 0, .path = device, .interface = nm_device_interface, .member = "Disconnect", .destination = nm_name });
    }

    fn queryConnectivity(self: *Host) !platform.Connectivity {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();
        const bus = try self.connectSystem(&loop);
        defer bus.deinit();

        const state = (try self.getProperty(bus, &loop, nm_name, nm_path, nm_interface, "State")) orelse return error.InvalidReply;
        const networking = (try self.getProperty(bus, &loop, nm_name, nm_path, nm_interface, "NetworkingEnabled")) orelse return error.InvalidReply;
        const wifi = (try self.getProperty(bus, &loop, nm_name, nm_path, nm_interface, "WirelessEnabled")) orelse return error.InvalidReply;
        const cellular_hardware = (try self.getProperty(bus, &loop, nm_name, nm_path, nm_interface, "WwanHardwareEnabled")) orelse return error.InvalidReply;
        const cellular = (try self.getProperty(bus, &loop, nm_name, nm_path, nm_interface, "WwanEnabled")) orelse return error.InvalidReply;
        const primary = (try self.getProperty(bus, &loop, nm_name, nm_path, nm_interface, "PrimaryConnection")) orelse return error.InvalidReply;

        var result = platform.Connectivity{
            .networking_enabled = networking.asBool() orelse return error.InvalidReply,
            .wifi_enabled = wifi.asBool() orelse return error.InvalidReply,
            .cellular_available = cellular_hardware.asBool() orelse return error.InvalidReply,
            .cellular_enabled = cellular.asBool() orelse return error.InvalidReply,
            .reachability = reachability(state.asU32() orelse return error.InvalidReply),
        };
        const path = primary.asString() orelse return error.InvalidReply;
        if (path.len == 0 or std.mem.eql(u8, path, "/")) return result;
        const connection_type = (try self.getProperty(bus, &loop, nm_name, path, "org.freedesktop.NetworkManager.Connection.Active", "Type")) orelse return result;
        const kind = connection_type.asString() orelse return result;
        result.transport = if (std.mem.eql(u8, kind, "802-3-ethernet"))
            .ethernet
        else if (std.mem.eql(u8, kind, "802-11-wireless"))
            .wifi
        else if (std.mem.eql(u8, kind, "gsm") or std.mem.eql(u8, kind, "cdma") or std.mem.eql(u8, kind, "bluetooth"))
            .cellular
        else
            .none;
        if (result.transport == .wifi) {
            const access_point = try self.getProperty(bus, &loop, nm_name, path, "org.freedesktop.NetworkManager.Connection.Active", "SpecificObject");
            if (access_point) |ap_value| if (ap_value.asString()) |ap_path| {
                if (ap_path.len > 1) {
                    const strength = try self.getProperty(bus, &loop, nm_name, ap_path, "org.freedesktop.NetworkManager.AccessPoint", "Strength");
                    if (strength) |value| result.strength = value.asByte();
                }
            };
        }
        return result;
    }

    fn callNetworkManagerBoolMethod(self: *Host, member: []const u8, value: bool) !bool {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();
        const bus = try self.connectSystem(&loop);
        defer bus.deinit();

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var writer = dbus.Writer.init(self.gpa, &body, bus.conn.endian);
        try writer.boolean(value);
        return self.callEmpty(bus, &loop, .{
            .msg_type = .method_call,
            .serial = 0,
            .path = nm_path,
            .interface = nm_interface,
            .member = member,
            .destination = nm_name,
            .body_signature = "b",
            .body = body.items,
        });
    }

    fn setNetworkManagerBoolProperty(self: *Host, property: []const u8, value: bool) !bool {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();
        const bus = try self.connectSystem(&loop);
        defer bus.deinit();

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var writer = dbus.Writer.init(self.gpa, &body, bus.conn.endian);
        try writer.string(nm_interface);
        try writer.string(property);
        try writer.beginVariant("b");
        try writer.boolean(value);
        return self.callEmpty(bus, &loop, .{
            .msg_type = .method_call,
            .serial = 0,
            .path = nm_path,
            .interface = properties_interface,
            .member = "Set",
            .destination = nm_name,
            .body_signature = "ssv",
            .body = body.items,
        });
    }

    fn callEmpty(
        self: *Host,
        bus: *dbus.client.Bus,
        loop: *dbus.event_loop.EventLoop,
        message: dbus.Message,
    ) !bool {
        _ = self;
        var reply: PortalReply = .{};
        _ = try bus.call(message, PortalReply.onEmptyReply, &reply);
        var attempts: usize = 0;
        while (!reply.done and attempts < 40) : (attempts += 1) _ = loop.dispatch(25);
        return reply.accepted;
    }

    fn queryAudio(self: *Host) !platform.Audio {
        const result = try std.process.run(self.gpa, self.io, .{
            .argv = &.{ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" },
            .stdout_limit = .limited(512),
            .stderr_limit = .limited(512),
        });
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (!result.term.success()) return error.AudioUnavailable;
        return parseWpctlVolume(result.stdout) orelse error.InvalidReply;
    }

    fn queryBrightness(self: *Host) !platform.Brightness {
        var root = try std.Io.Dir.openDirAbsolute(self.io, "/sys/class/backlight", .{ .iterate = true });
        defer root.close(self.io);
        var iterator = root.iterate();
        var best_score: u8 = 0;
        var best_level: ?platform.Brightness = null;
        self.backlight_name_len = 0;
        self.backlight_max = 0;
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .directory and entry.kind != .sym_link) continue;
            if (entry.name.len > self.backlight_name.len) continue;
            var device = root.openDir(self.io, entry.name, .{}) catch continue;
            defer device.close(self.io);
            const maximum = readSysfsInt(self, device, "max_brightness") orelse continue;
            if (maximum == 0) continue;
            const current = readSysfsInt(self, device, "actual_brightness") orelse readSysfsInt(self, device, "brightness") orelse continue;
            const kind_owned = readSysfsText(self, device, "type");
            defer if (kind_owned) |kind| self.gpa.free(kind);
            const kind = kind_owned orelse "";
            const score: u8 = if (std.mem.eql(u8, kind, "raw")) 3 else if (std.mem.eql(u8, kind, "platform")) 2 else 1;
            if (best_level != null and score <= best_score) continue;
            @memcpy(self.backlight_name[0..entry.name.len], entry.name);
            self.backlight_name_len = entry.name.len;
            self.backlight_max = maximum;
            best_score = score;
            best_level = .{ .level = @max(0, @min(1, @as(f32, @floatFromInt(current)) / @as(f32, @floatFromInt(maximum)))) };
        }
        return best_level orelse error.BrightnessUnavailable;
    }

    fn readSysfsText(self: *Host, dir: std.Io.Dir, name: []const u8) ?[]u8 {
        const bytes = dir.readFileAlloc(self.io, name, self.gpa, .limited(128)) catch return null;
        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        if (trimmed.ptr == bytes.ptr and trimmed.len == bytes.len) return bytes;
        const result = self.gpa.dupe(u8, trimmed) catch {
            self.gpa.free(bytes);
            return null;
        };
        self.gpa.free(bytes);
        return result;
    }

    fn readSysfsInt(self: *Host, dir: std.Io.Dir, name: []const u8) ?u32 {
        const bytes = self.readSysfsText(dir, name) orelse return null;
        defer self.gpa.free(bytes);
        return std.fmt.parseInt(u32, bytes, 10) catch null;
    }

    fn runSuccessful(self: *Host, argv: []const []const u8) bool {
        const result = std.process.run(self.gpa, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(512),
            .stderr_limit = .limited(512),
        }) catch return false;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        return result.term.success();
    }

    fn querySessionCapabilities(self: *Host) !platform.SessionCapabilities {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();
        const bus = try self.connectSystem(&loop);
        defer bus.deinit();
        const has_session = (try self.queryCurrentSession(bus, &loop)) != null;
        return .{
            .lock = has_session,
            .logout = has_session,
            .can_suspend = try self.loginCapability(bus, &loop, "CanSuspend"),
            .restart = try self.loginCapability(bus, &loop, "CanReboot"),
            .power_off = try self.loginCapability(bus, &loop, "CanPowerOff"),
        };
    }

    fn queryCurrentSession(self: *Host, bus: *dbus.client.Bus, loop: *dbus.event_loop.EventLoop) !?[]const u8 {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var writer = dbus.Writer.init(self.gpa, &body, bus.conn.endian);
        try writer.uint32(@intCast(std.os.linux.getpid()));
        var reply = RequestPathReply{};
        _ = try bus.call(.{
            .msg_type = .method_call,
            .serial = 0,
            .path = login_path,
            .interface = login_interface,
            .member = "GetSessionByPID",
            .destination = login_name,
            .body_signature = "u",
            .body = body.items,
        }, RequestPathReply.onReply, &reply);
        var attempts: usize = 0;
        while (!reply.done and attempts < 40) : (attempts += 1) _ = loop.dispatch(25);
        if (reply.path_len == 0) {
            self.login_session_path_len = 0;
            return null;
        }
        @memcpy(self.login_session_path[0..reply.path_len], reply.path[0..reply.path_len]);
        self.login_session_path_len = reply.path_len;
        return self.login_session_path[0..self.login_session_path_len];
    }

    fn loginCapability(self: *Host, bus: *dbus.client.Bus, loop: *dbus.event_loop.EventLoop, member: []const u8) !bool {
        _ = self;
        var reply = StringReply{};
        _ = try bus.call(.{
            .msg_type = .method_call,
            .serial = 0,
            .path = login_path,
            .interface = login_interface,
            .member = member,
            .destination = login_name,
        }, StringReply.onReply, &reply);
        var attempts: usize = 0;
        while (!reply.done and attempts < 40) : (attempts += 1) _ = loop.dispatch(25);
        const answer = reply.value[0..reply.value_len];
        return std.mem.eql(u8, answer, "yes") or std.mem.eql(u8, answer, "challenge");
    }

    fn callLoginBool(self: *Host, member: []const u8, interactive: bool) !bool {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();
        const bus = try self.connectSystem(&loop);
        defer bus.deinit();
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var writer = dbus.Writer.init(self.gpa, &body, bus.conn.endian);
        try writer.boolean(interactive);
        return self.callEmpty(bus, &loop, .{
            .msg_type = .method_call,
            .serial = 0,
            .path = login_path,
            .interface = login_interface,
            .member = member,
            .destination = login_name,
            .body_signature = "b",
            .body = body.items,
        });
    }

    fn callCurrentSession(self: *Host, member: []const u8) !bool {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();
        const bus = try self.connectSystem(&loop);
        defer bus.deinit();
        const path = (try self.queryCurrentSession(bus, &loop)) orelse return false;
        return self.callEmpty(bus, &loop, .{
            .msg_type = .method_call,
            .serial = 0,
            .path = path,
            .interface = login_session_interface,
            .member = member,
            .destination = login_name,
        });
    }

    fn callSessionSetBrightness(self: *Host, name: []const u8, value: u32) !bool {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();
        const bus = try self.connectSystem(&loop);
        defer bus.deinit();
        const path = (try self.queryCurrentSession(bus, &loop)) orelse return false;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var writer = dbus.Writer.init(self.gpa, &body, bus.conn.endian);
        try writer.string("backlight");
        try writer.string(name);
        try writer.uint32(value);
        return self.callEmpty(bus, &loop, .{
            .msg_type = .method_call,
            .serial = 0,
            .path = path,
            .interface = login_session_interface,
            .member = "SetBrightness",
            .destination = login_name,
            .body_signature = "ssu",
            .body = body.items,
        });
    }

    fn queryPower(self: *Host) !platform.Power {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();
        const bus = try self.connectSystem(&loop);
        defer bus.deinit();

        const present_value = (try self.getProperty(bus, &loop, upower_name, upower_display_path, upower_device_interface, "IsPresent")) orelse return error.InvalidReply;
        const present = present_value.asBool() orelse return error.InvalidReply;
        if (!present) return .{ .present = false };
        const percentage = (try self.getProperty(bus, &loop, upower_name, upower_display_path, upower_device_interface, "Percentage")) orelse return error.InvalidReply;
        const state = (try self.getProperty(bus, &loop, upower_name, upower_display_path, upower_device_interface, "State")) orelse return error.InvalidReply;
        const empty = try self.getProperty(bus, &loop, upower_name, upower_display_path, upower_device_interface, "TimeToEmpty");
        const full = try self.getProperty(bus, &loop, upower_name, upower_display_path, upower_device_interface, "TimeToFull");
        const raw_percent = percentage.asDouble() orelse return error.InvalidReply;
        return .{
            .present = true,
            .percent = @intFromFloat(@max(0, @min(100, @round(raw_percent)))),
            .status = powerStatus(state.asU32() orelse return error.InvalidReply),
            .time_to_empty_s = if (empty) |value| value.asU64() else null,
            .time_to_full_s = if (full) |value| value.asU64() else null,
        };
    }

    fn getProperty(
        self: *Host,
        bus: *dbus.client.Bus,
        loop: *dbus.event_loop.EventLoop,
        destination: []const u8,
        path: []const u8,
        interface: []const u8,
        property: []const u8,
    ) !?Scalar {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var writer = dbus.Writer.init(self.gpa, &body, bus.conn.endian);
        try writer.string(interface);
        try writer.string(property);
        var reply = PropertyReply{ .gpa = self.gpa };
        _ = try bus.call(.{
            .msg_type = .method_call,
            .serial = 0,
            .path = path,
            .interface = properties_interface,
            .member = "Get",
            .destination = destination,
            .body_signature = "ss",
            .body = body.items,
        }, PropertyReply.onReply, &reply);
        var attempts: usize = 0;
        while (!reply.done and attempts < 40) : (attempts += 1) _ = loop.dispatch(25);
        return reply.value;
    }
};

fn parseWpctlVolume(output: []const u8) ?platform.Audio {
    const marker = "Volume:";
    const start = std.mem.indexOf(u8, output, marker) orelse return null;
    var tokens = std.mem.tokenizeAny(u8, output[start + marker.len ..], " \t\r\n");
    const raw = tokens.next() orelse return null;
    const volume = std.fmt.parseFloat(f32, raw) catch return null;
    return .{
        .output_volume = @max(0, @min(1, volume)),
        .muted = std.mem.indexOf(u8, output, "[MUTED]") != null,
    };
}

test "wpctl volume parsing preserves mute and clamps the normalized level" {
    const audio = parseWpctlVolume("Volume: 1.25 [MUTED]\n").?;
    try std.testing.expectEqual(@as(f32, 1), audio.output_volume);
    try std.testing.expect(audio.muted);
}

fn osReleaseValue(contents: []const u8, wanted: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, line[0..separator], wanted)) continue;
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t\r");
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\'')))
            return value[1 .. value.len - 1];
        return value;
    }
    return null;
}

test "os-release identity prefers the exact requested display field" {
    const data = "NAME=NixOS\nPRETTY_NAME=\"NixOS 26.11 (Zokor)\"\nID=nixos\n";
    try std.testing.expectEqualStrings("NixOS 26.11 (Zokor)", osReleaseValue(data, "PRETTY_NAME").?);
    try std.testing.expectEqualStrings("NixOS", osReleaseValue(data, "NAME").?);
}

const Scalar = union(enum) {
    byte: u8,
    boolean: bool,
    uint32: u32,
    uint64: u64,
    double: f64,
    string: struct { bytes: [256]u8 = undefined, len: usize = 0 },
    bytes: struct { data: [256]u8 = undefined, len: usize = 0 },

    fn asBool(self: Scalar) ?bool {
        return switch (self) {
            .boolean => |v| v,
            else => null,
        };
    }
    fn asByte(self: Scalar) ?u8 {
        return switch (self) {
            .byte => |v| v,
            else => null,
        };
    }
    fn asU32(self: Scalar) ?u32 {
        return switch (self) {
            .uint32 => |v| v,
            else => null,
        };
    }
    fn asU64(self: Scalar) ?u64 {
        return switch (self) {
            .uint64 => |v| v,
            else => null,
        };
    }
    fn asDouble(self: Scalar) ?f64 {
        return switch (self) {
            .double => |v| v,
            else => null,
        };
    }
    fn asString(self: *const Scalar) ?[]const u8 {
        return switch (self.*) {
            .string => |*v| v.bytes[0..v.len],
            else => null,
        };
    }
    fn asBytes(self: *const Scalar) ?[]const u8 {
        return switch (self.*) {
            .bytes => |*v| v.data[0..v.len],
            else => null,
        };
    }
};

const PropertyReply = struct {
    gpa: std.mem.Allocator,
    done: bool = false,
    value: ?Scalar = null,

    fn onReply(ctx: ?*anyopaque, _: *dbus.connection.Connection, reply: ?*const dbus.Message) void {
        const self: *PropertyReply = @ptrCast(@alignCast(ctx.?));
        defer self.done = true;
        const message = reply orelse return;
        if (message.msg_type != .method_return) return;
        var reader = dbus.Reader.init(message.body, message.endian);
        const dynamic = reader.readValue(self.gpa, "v") catch return;
        defer dbus.unmarshal.freeValue(self.gpa, dynamic);
        const inner = switch (dynamic) {
            .variant => |v| v.*,
            else => return,
        };
        self.value = switch (inner) {
            .byte => |v| .{ .byte = v },
            .boolean => |v| .{ .boolean = v },
            .uint32 => |v| .{ .uint32 = v },
            .uint64 => |v| .{ .uint64 = v },
            .double => |v| .{ .double = v },
            .string, .object_path => |v| blk: {
                if (v.len > 256) break :blk null;
                var result = Scalar{ .string = .{} };
                @memcpy(result.string.bytes[0..v.len], v);
                result.string.len = v.len;
                break :blk result;
            },
            .array => |items| blk: {
                if (items.len > 256) break :blk null;
                var result = Scalar{ .bytes = .{} };
                for (items, 0..) |item, index| result.bytes.data[index] = switch (item) {
                    .byte => |byte| byte,
                    else => break :blk null,
                };
                result.bytes.len = items.len;
                break :blk result;
            },
            else => null,
        };
    }
};

const PathListReply = struct {
    const Path = struct { bytes: [256]u8 = undefined, len: usize = 0 };
    done: bool = false,
    paths: [64]Path = undefined,
    count: usize = 0,

    fn onReply(ctx: ?*anyopaque, _: *dbus.connection.Connection, reply: ?*const dbus.Message) void {
        const self: *PathListReply = @ptrCast(@alignCast(ctx.?));
        defer self.done = true;
        const message = reply orelse return;
        if (message.msg_type != .method_return) return;
        var reader = dbus.Reader.init(message.body, message.endian);
        const value = reader.readValue(std.heap.page_allocator, "ao") catch return;
        defer dbus.unmarshal.freeValue(std.heap.page_allocator, value);
        const paths = switch (value) {
            .array => |items| items,
            else => return,
        };
        for (paths) |item| {
            if (self.count == self.paths.len) break;
            const path = switch (item) {
                .object_path => |bytes| bytes,
                else => continue,
            };
            if (path.len > self.paths[self.count].bytes.len) continue;
            @memcpy(self.paths[self.count].bytes[0..path.len], path);
            self.paths[self.count].len = path.len;
            self.count += 1;
        }
    }
};

fn reachability(state: u32) platform.Connectivity.Reachability {
    return switch (state) {
        70 => .local,
        80 => .site,
        100 => .internet,
        else => .disconnected,
    };
}

fn powerStatus(state: u32) platform.Power.Status {
    return switch (state) {
        1 => .charging,
        2 => .discharging,
        3 => .empty,
        4 => .full,
        5, 6 => .pending,
        else => .unknown,
    };
}

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

const StringReply = struct {
    done: bool = false,
    value: [32]u8 = undefined,
    value_len: usize = 0,

    fn onReply(ctx: ?*anyopaque, _: *dbus.connection.Connection, reply: ?*const dbus.Message) void {
        const self: *StringReply = @ptrCast(@alignCast(ctx.?));
        defer self.done = true;
        const message = reply orelse return;
        if (message.msg_type != .method_return) return;
        var reader = dbus.Reader.init(message.body, message.endian);
        const value = reader.string() catch return;
        if (value.len > self.value.len) return;
        @memcpy(self.value[0..value.len], value);
        self.value_len = value.len;
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
