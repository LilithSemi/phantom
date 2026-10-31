//! Android host support. Lattice owns the native window lifecycle and Prism
//! presents the rendered display list through a Vulkan swapchain.
const std = @import("std");
const phantom = @import("../phantom.zig");
const lattice = @import("lattice");

/// Framework-requested visibility for shell-owned Android system surfaces.
/// The shell may return a different `SystemBarsVisibility` when its design
/// deliberately handles a request through another surface or gesture affordance.
pub const SystemBarsState = struct {
    status_requested_visible: bool,
    navigation_requested_visible: bool,
    status_transient: bool,
    navigation_transient: bool,
    behavior: i32,

    pub fn effectiveVisibility(self: SystemBarsState) SystemBarsVisibility {
        return .{
            .status = self.status_requested_visible or self.status_transient,
            .navigation = self.navigation_requested_visible or self.navigation_transient,
        };
    }
};

pub const SystemBarsVisibility = struct {
    status: bool,
    navigation: bool,
};
const Settings = @import("platform/zon_settings.zig").Store;

/// Process-wide state supplied by the Java host. Android may render several
/// Phantom surfaces for one shell, but PackageManager, radios and the
/// notification shade are device services shared by all of them.
pub const HostBridge = struct {
    const Action = enum(i32) {
        none = 0,
        launch_application = 1,
        wifi_enabled = 2,
        bluetooth_enabled = 3,
        bluetooth_discovery = 4,
        dismiss_notification = 5,
        clear_notifications = 6,
        invoke_notification = 7,
        wifi_scan = 8,
        wifi_connect = 9,
        wifi_disconnect = 10,
        cellular_enabled = 11,
        audio = 12,
        brightness = 13,
    };

    var application_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    var notification_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    var wifi_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    var identity_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    var applications: []phantom.Application = &.{};
    var notifications: []phantom.SystemNotification = &.{};
    var wifi_networks: []phantom.WifiNetwork = &.{};
    var connectivity: ?phantom.Connectivity = null;
    var bluetooth: ?phantom.Bluetooth = null;
    var power: ?phantom.Power = null;
    var audio: ?phantom.Audio = null;
    var brightness: ?phantom.Brightness = null;
    var identity: ?phantom.Identity = null;
    var action: Action = .none;
    var action_value: bool = false;
    var action_number: f32 = 0;
    var action_text: std.ArrayList(u8) = .empty;

    pub fn beginApplications(count: usize) bool {
        _ = application_arena.reset(.retain_capacity);
        applications = application_arena.allocator().alloc(phantom.Application, count) catch return false;
        @memset(applications, .{ .id = "", .name = "" });
        return true;
    }

    pub fn beginApplication(index: usize, id_len: usize, name_len: usize, icon_len: usize, preview_len: usize, running: bool) bool {
        if (index >= applications.len) return false;
        const a = application_arena.allocator();
        applications[index] = .{
            .id = a.alloc(u8, id_len) catch return false,
            .name = a.alloc(u8, name_len) catch return false,
            .icon_png = a.alloc(u8, icon_len) catch return false,
            .preview_png = a.alloc(u8, preview_len) catch return false,
            .running = running,
        };
        return true;
    }

    pub fn applicationByte(index: usize, field: usize, offset: usize, value: u8) void {
        if (index >= applications.len) return;
        const dest: []const u8 = switch (field) {
            0 => applications[index].id,
            1 => applications[index].name,
            2 => applications[index].icon_png,
            3 => applications[index].preview_png,
            else => return,
        };
        if (offset < dest.len) @constCast(dest)[offset] = value;
    }

    pub fn beginNotifications(count: usize) bool {
        _ = notification_arena.reset(.retain_capacity);
        notifications = notification_arena.allocator().alloc(phantom.SystemNotification, count) catch return false;
        @memset(notifications, .{ .key = "", .app_name = "", .title = "", .body = "", .posted_ms = 0 });
        return true;
    }

    pub fn beginNotification(index: usize, lengths: [4]usize, posted_ms: i64, clearable: bool) bool {
        if (index >= notifications.len) return false;
        const a = notification_arena.allocator();
        notifications[index] = .{
            .key = a.alloc(u8, lengths[0]) catch return false,
            .app_name = a.alloc(u8, lengths[1]) catch return false,
            .title = a.alloc(u8, lengths[2]) catch return false,
            .body = a.alloc(u8, lengths[3]) catch return false,
            .posted_ms = posted_ms,
            .clearable = clearable,
        };
        return true;
    }

    pub fn notificationByte(index: usize, field: usize, offset: usize, value: u8) void {
        if (index >= notifications.len) return;
        const dest: []const u8 = switch (field) {
            0 => notifications[index].key,
            1 => notifications[index].app_name,
            2 => notifications[index].title,
            3 => notifications[index].body,
            else => return,
        };
        if (offset < dest.len) @constCast(dest)[offset] = value;
    }

    pub fn setConnectivity(value: phantom.Connectivity) void {
        connectivity = value;
    }

    pub fn setBluetooth(value: phantom.Bluetooth) void {
        bluetooth = value;
    }

    pub fn setPower(value: phantom.Power) void {
        power = value;
    }

    pub fn setAudio(value: phantom.Audio) void {
        audio = value;
    }

    pub fn setBrightness(value: phantom.Brightness) void {
        brightness = value;
    }

    pub fn beginIdentity(user_name_len: usize, display_name_len: usize, system_name_len: usize) bool {
        _ = identity_arena.reset(.retain_capacity);
        const a = identity_arena.allocator();
        identity = .{
            .user_name = a.alloc(u8, user_name_len) catch return false,
            .display_name = if (display_name_len > 0) a.alloc(u8, display_name_len) catch return false else null,
            .system_name = a.alloc(u8, system_name_len) catch return false,
        };
        return true;
    }

    pub fn identityByte(field: usize, offset: usize, value: u8) void {
        const current = identity orelse return;
        const dest: []const u8 = switch (field) {
            0 => current.user_name,
            1 => current.display_name orelse return,
            2 => current.system_name,
            else => return,
        };
        if (offset < dest.len) @constCast(dest)[offset] = value;
    }

    pub fn beginWifiNetworks(count: usize) bool {
        _ = wifi_arena.reset(.retain_capacity);
        wifi_networks = wifi_arena.allocator().alloc(phantom.WifiNetwork, count) catch return false;
        @memset(wifi_networks, .{ .id = "", .ssid = "", .strength = 0, .security = .open });
        return true;
    }

    pub fn beginWifiNetwork(index: usize, id_len: usize, ssid_len: usize, strength: u8, secured: bool, connected: bool) bool {
        if (index >= wifi_networks.len) return false;
        const a = wifi_arena.allocator();
        wifi_networks[index] = .{
            .id = a.alloc(u8, id_len) catch return false,
            .ssid = a.alloc(u8, ssid_len) catch return false,
            .strength = strength,
            .security = if (secured) .secured else .open,
            .connected = connected,
        };
        return true;
    }

    pub fn wifiNetworkByte(index: usize, field: usize, offset: usize, value: u8) void {
        if (index >= wifi_networks.len) return;
        const dest = if (field == 0) wifi_networks[index].id else if (field == 1) wifi_networks[index].ssid else return;
        if (offset < dest.len) @constCast(dest)[offset] = value;
    }

    fn queue(next: Action, text: []const u8, value: bool) bool {
        if (action != .none) return false;
        action_text.clearRetainingCapacity();
        action_text.appendSlice(std.heap.c_allocator, text) catch return false;
        action_value = value;
        action = next;
        return true;
    }

    fn queueNumber(next: Action, number: f32, value: bool) bool {
        if (action != .none) return false;
        action_text.clearRetainingCapacity();
        action_number = number;
        action_value = value;
        action = next;
        return true;
    }

    pub fn takeAction() i32 {
        const result: i32 = @backingInt(action);
        action = .none;
        return result;
    }

    pub fn actionTextLength() usize {
        return action_text.items.len;
    }
    pub fn actionTextByte(index: usize) ?u8 {
        return if (index < action_text.items.len) action_text.items[index] else null;
    }
    pub fn actionValue() bool {
        return action_value;
    }
    pub fn actionNumber() f32 {
        return action_number;
    }
};

const OpenUrlRequest = struct {
    bytes: std.ArrayList(u8) = .empty,
    mode: phantom.OpenMode = .new_tab,
    pending: bool = false,

    fn deinit(self: *OpenUrlRequest, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
    }

    fn queue(self: *OpenUrlRequest, gpa: std.mem.Allocator, url: []const u8, mode: phantom.OpenMode) bool {
        self.pending = false;
        self.bytes.clearRetainingCapacity();
        self.bytes.appendSlice(gpa, url) catch return false;
        self.mode = mode;
        self.pending = true;
        return true;
    }

    fn clear(self: *OpenUrlRequest) void {
        self.pending = false;
        self.bytes.clearRetainingCapacity();
    }
};

const NotificationRequest = struct {
    id: std.ArrayList(u8) = .empty,
    title: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,
    pending: bool = false,

    fn deinit(self: *NotificationRequest, gpa: std.mem.Allocator) void {
        self.id.deinit(gpa);
        self.title.deinit(gpa);
        self.body.deinit(gpa);
    }

    fn queue(self: *NotificationRequest, gpa: std.mem.Allocator, value: phantom.Notification) bool {
        self.pending = false;
        self.id.clearRetainingCapacity();
        self.title.clearRetainingCapacity();
        self.body.clearRetainingCapacity();
        self.id.appendSlice(gpa, value.id) catch return false;
        self.title.appendSlice(gpa, value.title) catch return false;
        self.body.appendSlice(gpa, value.body) catch return false;
        self.pending = true;
        return true;
    }
};

const FilePickerRequest = struct {
    accept: std.ArrayList(u8) = .empty,
    sink: ?phantom.FilePickerSink = null,
    pending: bool = false,
    name: std.ArrayList(u8) = .empty,
    media_type: std.ArrayList(u8) = .empty,
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(self: *FilePickerRequest, gpa: std.mem.Allocator) void {
        self.accept.deinit(gpa);
        self.name.deinit(gpa);
        self.media_type.deinit(gpa);
        self.bytes.deinit(gpa);
    }
};

const ClipboardRequest = struct {
    write: std.ArrayList(u8) = .empty,
    write_pending: bool = false,
    read_sink: ?phantom.ClipboardReadSink = null,
    read_pending: bool = false,
    result: std.ArrayList(u8) = .empty,

    fn deinit(self: *ClipboardRequest, gpa: std.mem.Allocator) void {
        self.write.deinit(gpa);
        self.result.deinit(gpa);
    }
};

/// Runtime passed to an application-supplied Android background-service
/// module. The module's `run` function executes on a dedicated thread and must
/// return after `shouldStop` becomes true. Blocking implementations may also
/// export `stop(*BackgroundService)`, which Phantom calls before joining the
/// worker so the module can close a socket or otherwise wake `run`.
pub const BackgroundService = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    files_dir: []u8,
    stopping: std.atomic.Value(bool) = .init(false),
    notification_mutex: std.Io.Mutex = .init,
    notification_request: NotificationRequest = .{},

    pub fn create(gpa: std.mem.Allocator, files_dir: []const u8) !*BackgroundService {
        const self = try gpa.create(BackgroundService);
        errdefer gpa.destroy(self);
        const owned_files_dir = try gpa.dupe(u8, files_dir);
        errdefer gpa.free(owned_files_dir);
        self.* = .{
            .gpa = gpa,
            .threaded = std.Io.Threaded.init(gpa, .{}),
            .files_dir = owned_files_dir,
        };
        return self;
    }

    pub fn destroy(self: *BackgroundService) void {
        self.notification_request.deinit(self.gpa);
        self.threaded.deinit();
        self.gpa.free(self.files_dir);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn allocator(self: *BackgroundService) std.mem.Allocator {
        return self.gpa;
    }

    pub fn io(self: *BackgroundService) std.Io {
        return self.threaded.io();
    }

    pub fn filesDir(self: *const BackgroundService) []const u8 {
        return self.files_dir;
    }

    pub fn shouldStop(self: *const BackgroundService) bool {
        return self.stopping.load(.acquire);
    }

    pub fn requestStop(self: *BackgroundService) void {
        self.stopping.store(true, .release);
    }

    /// Queues one Android notification. False means the Java host has not yet
    /// consumed the previous one; callers can retry without losing ownership
    /// of any slices passed here.
    pub fn showNotification(self: *BackgroundService, notification: phantom.Notification) bool {
        self.notification_mutex.lockUncancelable(self.threaded.io());
        defer self.notification_mutex.unlock(self.threaded.io());
        if (self.notification_request.pending) return false;
        return self.notification_request.queue(self.gpa, notification);
    }

    pub fn pendingNotificationLength(self: *BackgroundService, field: u32) ?usize {
        self.notification_mutex.lockUncancelable(self.threaded.io());
        defer self.notification_mutex.unlock(self.threaded.io());
        if (!self.notification_request.pending) return null;
        return switch (field) {
            0 => self.notification_request.id.items.len,
            1 => self.notification_request.title.items.len,
            2 => self.notification_request.body.items.len,
            else => null,
        };
    }

    pub fn pendingNotificationByte(self: *BackgroundService, field: u32, index: usize) ?u8 {
        self.notification_mutex.lockUncancelable(self.threaded.io());
        defer self.notification_mutex.unlock(self.threaded.io());
        if (!self.notification_request.pending) return null;
        const bytes = switch (field) {
            0 => self.notification_request.id.items,
            1 => self.notification_request.title.items,
            2 => self.notification_request.body.items,
            else => return null,
        };
        return if (index < bytes.len) bytes[index] else null;
    }

    pub fn clearPendingNotification(self: *BackgroundService) void {
        self.notification_mutex.lockUncancelable(self.threaded.io());
        defer self.notification_mutex.unlock(self.threaded.io());
        self.notification_request.pending = false;
    }
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    sink: phantom.FaultSink,
    owner: phantom.BuildOwner,
    focus: phantom.FocusManager,
    dispatcher: phantom.input.Dispatcher,
    el: *phantom.Element,
    canvas: phantom.Canvas,
    threaded: std.Io.Threaded,
    settings: Settings,
    host: *lattice.backends.Android,
    surface: lattice.Surface,
    renderer: phantom.backend.PrismBackend,
    scale: f32,
    text_scale: f32,
    active_pointer: ?u32 = null,
    pointer_position: phantom.PhysicalOffset = .zero,
    touch_scroll: phantom.input.TouchScrollRecognizer = .{},
    preedit_buffer: std.ArrayList(u8) = .empty,
    open_url_request: OpenUrlRequest = .{},
    notification_request: NotificationRequest = .{},
    notification_permission: phantom.NotificationPermission,
    notification_permission_sink: ?phantom.NotificationPermissionSink = null,
    notification_permission_request: bool = false,
    file_picker_request: FilePickerRequest = .{},
    clipboard_request: ClipboardRequest = .{},
    lifecycle_state: phantom.LifecycleState = .foreground,
    lifecycle_sink: ?phantom.LifecycleSink = null,
    transparent_background: bool,

    pub fn create(
        gpa: std.mem.Allocator,
        root: phantom.Root,
        width: u32,
        height: u32,
        density: f32,
        text_scale: f32,
        system_insets: phantom.PhysicalEdgeInsets,
        files_dir: []const u8,
        notification_permission: phantom.NotificationPermission,
        transparent_background: bool,
    ) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);

        self.gpa = gpa;
        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        self.sink = .{};
        self.owner = .{ .gpa = gpa, .sink = &self.sink };
        errdefer self.owner.deinit();
        self.focus = .{};
        errdefer self.focus.deinit(gpa);
        self.dispatcher = .{};
        self.owner.focus = &self.focus;
        self.owner.dispatcher = &self.dispatcher;
        self.threaded = std.Io.Threaded.init(gpa, .{});
        errdefer self.threaded.deinit();
        self.owner.io = self.threaded.io();
        const settings_path = try std.fs.path.join(gpa, &.{ files_dir, "settings.zon" });
        defer gpa.free(settings_path);
        self.settings = try Settings.initPath(gpa, self.threaded.io(), settings_path);
        errdefer self.settings.deinit();
        self.owner.platform = .{
            .ctx = self,
            .open_url = queueOpenUrl,
            .read_setting = readSetting,
            .write_setting = writeSetting,
            .remove_setting = removeSetting,
            .notification_permission = getNotificationPermission,
            .request_notification_permission = requestNotificationPermission,
            .show_notification = showNotification,
            .pick_file = pickFile,
            .read_connectivity = readConnectivity,
            .set_wifi_enabled = setWifiEnabled,
            .set_cellular_enabled = setCellularEnabled,
            .read_wifi_networks = readWifiNetworks,
            .request_wifi_scan = requestWifiScan,
            .connect_wifi = connectWifi,
            .disconnect_wifi = disconnectWifi,
            .read_bluetooth = readBluetooth,
            .set_bluetooth_enabled = setBluetoothEnabled,
            .request_bluetooth_discovery = requestBluetoothDiscovery,
            .read_power = readPower,
            .read_audio = readAudio,
            .set_audio = setAudio,
            .read_brightness = readBrightness,
            .set_brightness = setBrightness,
            .read_identity = readIdentity,
            .read_applications = readApplications,
            .launch_application = launchApplication,
            .read_system_notifications = readSystemNotifications,
            .dismiss_system_notification = dismissSystemNotification,
            .clear_system_notifications = clearSystemNotifications,
            .invoke_system_notification = invokeSystemNotification,
            .read_clipboard = readClipboard,
            .write_clipboard = writeClipboard,
            .lifecycle_state = getLifecycleState,
            .set_lifecycle_sink = setLifecycleSink,
        };
        self.scale = validDensity(density);
        self.text_scale = validTextScale(text_scale);
        self.preedit_buffer = .empty;
        self.open_url_request = .{};
        self.notification_request = .{};
        self.notification_permission = notification_permission;
        self.notification_permission_sink = null;
        self.notification_permission_request = false;
        self.file_picker_request = .{};
        self.clipboard_request = .{};
        self.lifecycle_state = .foreground;
        self.lifecycle_sink = null;
        self.transparent_background = transparent_background;

        _ = try phantom.View.open(&self.owner, .{
            .title = "Android",
            .size = logicalSize(width, height, self.scale * self.text_scale),
            .dpr = self.scale,
            .text_scale = self.text_scale,
            .view_padding = logicalInsets(system_insets, self.scale * self.text_scale),
        });
        const view = self.owner.activeView().?;
        var bctx = phantom.BuildContext{ .arena = self.arena.allocator(), .owner = &self.owner };
        const root_widget = root.call(&bctx);
        var mq = phantom.MediaQuery{ .data = &view.metrics, .child = root_widget };
        self.el = if (self.sink.ok())
            try mq.widget().mount(&bctx, null)
        else eb: {
            const error_box = phantom.ErrorBox{};
            break :eb try error_box.widget().mount(&bctx, null);
        };
        errdefer self.el.deinit(gpa);
        self.canvas = phantom.Canvas.init(gpa);
        errdefer self.canvas.deinit();

        self.host = try lattice.backends.Android.init(gpa, self.threaded.io());
        errdefer self.host.backend().deinit();
        self.surface = try self.host.backend().createSurface(.{
            .title = "Android",
            .width = width,
            .height = height,
            .color = lattice.ColorConfig.sdr(if (transparent_background) .argb8888 else .xrgb8888),
        });
        self.renderer = try phantom.backend.PrismBackend.init(self.host.device, gpa);
        errdefer self.renderer.deinit();
        self.renderer.flip_y = true;
        return self;
    }

    pub fn destroy(self: *Session) void {
        self.renderer.deinit();
        self.host.backend().deinit();
        self.canvas.deinit();
        self.el.deinit(self.gpa);
        self.focus.deinit(self.gpa);
        self.owner.deinit();
        self.arena.deinit();
        self.threaded.deinit();
        self.settings.deinit();
        self.preedit_buffer.deinit(self.gpa);
        self.open_url_request.deinit(self.gpa);
        self.notification_request.deinit(self.gpa);
        self.file_picker_request.deinit(self.gpa);
        self.clipboard_request.deinit(self.gpa);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn attachNativeWindow(self: *Session, window: *anyopaque, width: u32, height: u32, density: f32) !void {
        try self.host.attachNativeWindow(self.surface.id, window, width, height, density);
    }

    pub fn detachNativeWindow(self: *Session) void {
        self.host.detachNativeWindow(self.surface.id);
    }

    pub fn render(
        self: *Session,
        width: u32,
        height: u32,
        density: f32,
        text_scale: f32,
        system_insets: phantom.PhysicalEdgeInsets,
        frame_nanos: i64,
    ) !void {
        try self.host.resize(self.surface.id, width, height, density);
        try self.drainEvents();
        const target = try self.host.backend().surfaceRenderTarget(self.surface.id);
        self.scale = validDensity(density);
        self.text_scale = validTextScale(text_scale);
        const effective_scale = self.scale * self.text_scale;
        const physical = phantom.PhysicalSize{
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        };
        self.owner.setActiveViewMetrics(.{
            .size = logicalSize(width, height, effective_scale),
            .dpr = self.scale,
            .text_scale = self.text_scale,
            .view_padding = logicalInsets(system_insets, effective_scale),
        });

        self.owner.scheduler.tick(@intCast(frame_nanos));
        var bctx = phantom.BuildContext{ .arena = self.arena.allocator(), .owner = &self.owner };
        self.owner.flushDirty(&bctx);
        try self.focus.collect(self.gpa, self.el);
        self.canvas.clear();
        const ro = self.el.renderObject() orelse return error.NoRootRenderObject;
        _ = ro.layout(phantom.BoxConstraints.tightScaled(physical, effective_scale));
        try ro.paint(&self.canvas, phantom.PhysicalOffset.zero);
        const background = if (self.transparent_background)
            phantom.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }
        else
            phantom.Color.rgb(26.0 / 255.0, 27.0 / 255.0, 38.0 / 255.0);
        try self.renderer.render(
            target.context.*,
            target.target,
            physical,
            self.canvas.list,
            background,
        );
        try self.host.backend().commitFrame(self.surface.id);
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn touch(self: *Session, action: i32, pointer_id: u32, x: f32, y: f32) !bool {
        switch (action) {
            0 => try self.host.touchDown(self.surface.id, pointer_id, x, y),
            1 => try self.host.touchMove(self.surface.id, pointer_id, x, y),
            2 => try self.host.touchUp(self.surface.id, pointer_id, x, y),
            3 => try self.host.touchCancel(self.surface.id, pointer_id, x, y),
            else => {},
        }
        try self.drainEvents();
        const enabled = self.focus.acceptsTextInput();
        self.host.backend().setTextInput(self.surface.id, if (enabled) .{} else null) catch {};
        return enabled;
    }

    pub fn commitCodepoint(self: *Session, codepoint: u21) !void {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(codepoint, &buf);
        try self.host.commitText(self.surface.id, buf[0..len]);
        try self.drainEvents();
    }

    pub fn beginPreedit(self: *Session) void {
        self.preedit_buffer.clearRetainingCapacity();
    }

    pub fn appendPreeditCodepoint(self: *Session, codepoint: u21) !void {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(codepoint, &buf);
        try self.preedit_buffer.appendSlice(self.gpa, buf[0..len]);
    }

    pub fn endPreedit(self: *Session) !void {
        try self.host.preeditText(self.surface.id, self.preedit_buffer.items, null);
        try self.drainEvents();
    }

    pub fn finishPreedit(self: *Session) !void {
        try self.host.finishPreedit(self.surface.id);
        try self.drainEvents();
    }

    pub fn deleteFromIme(self: *Session, before: bool) !void {
        try self.host.key(self.surface.id, .{
            .keycode = 0,
            .state = .pressed,
            .keysym = if (before) 0xff08 else 0xffff,
        });
        try self.drainEvents();
    }

    pub fn imeAction(self: *Session, platform_action: i32) !void {
        const action: lattice.text_input.Action = switch (platform_action) {
            2 => .go,
            3 => .search,
            4 => .send,
            5 => .next,
            6 => .done,
            7 => .previous,
            else => .none,
        };
        try self.host.inputAction(self.surface.id, action);
        try self.drainEvents();
    }

    /// Dispatch a physical Android key without routing it through the IME.
    /// Named keys arrive as X11 keysyms; printable keys carry a Unicode
    /// codepoint and are folded with the same rule as Wayland/xkbcommon.
    pub fn key(self: *Session, platform_keysym: i32, codepoint: i32, modifier_bits: i32, platform_action: i32) bool {
        const named = androidKeysym(platform_keysym, codepoint);
        if (named == .no_symbol) return false;

        const mods = androidModifiers(modifier_bits);
        const action = androidKeyAction(platform_action);
        var encoded: [4]u8 = undefined;
        const text: ?[]const u8 = if (action != .release and !mods.ctrl and !mods.alt and !mods.super and validAndroidCodepoint(codepoint)) blk: {
            const len = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch break :blk null;
            break :blk encoded[0..len];
        } else null;
        return self.focus.dispatch(.{ .keysym = named, .text = text, .mods = mods, .action = action });
    }

    pub fn pointerMove(self: *Session, x: f32, y: f32) void {
        self.pointer_position = .{ .x = x, .y = y };
        self.dispatcher.move(self.el, self.pointer_position);
    }

    pub fn pointerScroll(self: *Session, x: f32, y: f32, horizontal: f32, vertical: f32) void {
        self.pointer_position = .{ .x = x, .y = y };
        self.dispatcher.scroll(self.el, self.pointer_position, horizontal, vertical);
    }

    pub fn pendingClipboardWriteLength(self: *const Session) ?usize {
        return if (self.clipboard_request.write_pending) self.clipboard_request.write.items.len else null;
    }

    pub fn pendingClipboardWriteByte(self: *const Session, index: usize) ?u8 {
        if (!self.clipboard_request.write_pending or index >= self.clipboard_request.write.items.len) return null;
        return self.clipboard_request.write.items[index];
    }

    pub fn clearClipboardWrite(self: *Session) void {
        self.clipboard_request.write_pending = false;
    }

    pub fn takeClipboardRead(self: *Session) bool {
        const pending = self.clipboard_request.read_pending;
        self.clipboard_request.read_pending = false;
        return pending;
    }

    pub fn beginClipboardResult(self: *Session, length: usize) !void {
        try self.clipboard_request.result.resize(self.gpa, length);
    }

    pub fn setClipboardResultByte(self: *Session, index: usize, value: u8) void {
        if (index < self.clipboard_request.result.items.len) self.clipboard_request.result.items[index] = value;
    }

    pub fn finishClipboardRead(self: *Session, success: bool) void {
        const sink = self.clipboard_request.read_sink orelse return;
        self.clipboard_request.read_sink = null;
        sink.on_text(sink.ctx, if (success) self.clipboard_request.result.items else null);
    }

    pub fn setLifecycleState(self: *Session, state: phantom.LifecycleState) void {
        if (self.lifecycle_state == state) return;
        self.lifecycle_state = state;
        if (self.lifecycle_sink) |sink| sink.on_state(sink.ctx, state);
    }

    pub fn pendingUrlLength(self: *const Session) ?usize {
        if (!self.open_url_request.pending) return null;
        return self.open_url_request.bytes.items.len;
    }

    pub fn pendingUrlByte(self: *const Session, index: usize) ?u8 {
        if (!self.open_url_request.pending or index >= self.open_url_request.bytes.items.len) return null;
        return self.open_url_request.bytes.items[index];
    }

    pub fn pendingUrlMode(self: *const Session) phantom.OpenMode {
        return self.open_url_request.mode;
    }

    pub fn clearPendingUrl(self: *Session) void {
        self.open_url_request.clear();
    }

    pub fn pendingNotificationLength(self: *const Session, field: u32) ?usize {
        if (!self.notification_request.pending) return null;
        return switch (field) {
            0 => self.notification_request.id.items.len,
            1 => self.notification_request.title.items.len,
            2 => self.notification_request.body.items.len,
            else => null,
        };
    }

    pub fn pendingNotificationByte(self: *const Session, field: u32, index: usize) ?u8 {
        const bytes = switch (field) {
            0 => self.notification_request.id.items,
            1 => self.notification_request.title.items,
            2 => self.notification_request.body.items,
            else => return null,
        };
        if (!self.notification_request.pending or index >= bytes.len) return null;
        return bytes[index];
    }

    pub fn clearPendingNotification(self: *Session) void {
        self.notification_request.pending = false;
    }

    pub fn takeNotificationPermissionRequest(self: *Session) bool {
        const pending = self.notification_permission_request;
        self.notification_permission_request = false;
        return pending;
    }

    pub fn setNotificationPermission(self: *Session, permission: phantom.NotificationPermission) void {
        self.notification_permission = permission;
        if (self.notification_permission_sink) |sink| {
            self.notification_permission_sink = null;
            sink.on_result(sink.ctx, permission);
        }
    }

    pub fn pendingFilePickerLength(self: *const Session) ?usize {
        if (!self.file_picker_request.pending) return null;
        return self.file_picker_request.accept.items.len;
    }

    pub fn pendingFilePickerByte(self: *const Session, index: usize) ?u8 {
        if (!self.file_picker_request.pending or index >= self.file_picker_request.accept.items.len) return null;
        return self.file_picker_request.accept.items[index];
    }

    pub fn startFilePicker(self: *Session) void {
        self.file_picker_request.pending = false;
    }

    pub fn beginFilePickerResult(self: *Session, name_len: usize, type_len: usize, data_len: usize) !void {
        try self.file_picker_request.name.resize(self.gpa, name_len);
        try self.file_picker_request.media_type.resize(self.gpa, type_len);
        try self.file_picker_request.bytes.resize(self.gpa, data_len);
    }

    pub fn setFilePickerResultByte(self: *Session, field: u32, index: usize, value: u8) void {
        const bytes = switch (field) {
            0 => self.file_picker_request.name.items,
            1 => self.file_picker_request.media_type.items,
            2 => self.file_picker_request.bytes.items,
            else => return,
        };
        if (index < bytes.len) bytes[index] = value;
    }

    pub fn finishFilePicker(self: *Session, kind: u32) void {
        const sink = self.file_picker_request.sink orelse return;
        self.file_picker_request.sink = null;
        const result: phantom.FilePickerResult = switch (kind) {
            0 => .{ .selected = .{
                .name = self.file_picker_request.name.items,
                .media_type = self.file_picker_request.media_type.items,
                .bytes = self.file_picker_request.bytes.items,
            } },
            1 => .cancelled,
            else => .failed,
        };
        sink.on_result(sink.ctx, result);
    }

    fn drainEvents(self: *Session) !void {
        try self.host.backend().pump(0, handleEvent, self);
    }

    fn handleEvent(ctx: *anyopaque, queued: lattice.Event) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        switch (queued) {
            .input => |input_event| self.handleInput(input_event),
            .text_input => |text_event| if (text_event.surface == self.surface.id) self.handleTextInput(text_event.event),
            else => {},
        }
    }

    fn handleInput(self: *Session, input_event: lattice.InputEvent) void {
        switch (input_event) {
            .touch_down => |point_event| {
                if (self.active_pointer != null) return;
                self.active_pointer = point_event.id;
                const point = touchPoint(point_event);
                self.pointer_position = point;
                self.touch_scroll.down(point);
                if (phantom.input.hitTestFocus(self.el, point)) |handler| {
                    _ = self.focus.focusNode(handler);
                } else self.focus.clear();
                self.dispatcher.down(self.el, point);
            },
            .touch_motion => |point_event| {
                if (self.active_pointer != point_event.id) return;
                const point = touchPoint(point_event);
                self.pointer_position = point;
                switch (self.touch_scroll.move(point, 8 * self.scale)) {
                    .pending => self.dispatcher.move(self.el, point),
                    .begin => |delta| {
                        self.dispatcher.up(self.el, .{ .x = -1.0e9, .y = -1.0e9 });
                        self.dispatcher.scroll(self.el, self.touch_scroll.origin, delta.dx, delta.dy);
                    },
                    .scroll => |delta| self.dispatcher.scroll(
                        self.el,
                        self.touch_scroll.origin,
                        delta.dx,
                        delta.dy,
                    ),
                }
            },
            .touch_up => |point_event| {
                if (self.active_pointer != point_event.id) return;
                const point = touchPoint(point_event);
                self.pointer_position = point;
                if (!self.touch_scroll.finish()) self.dispatcher.up(self.el, point);
                self.active_pointer = null;
            },
            .touch_cancel => |point_event| {
                if (self.active_pointer != point_event.id) return;
                _ = self.touch_scroll.finish();
                self.dispatcher.up(self.el, .{ .x = -1.0e9, .y = -1.0e9 });
                self.active_pointer = null;
            },
            .pointer_axis => |axis| self.dispatcher.scroll(
                self.el,
                self.pointer_position,
                @floatCast(axis.horizontal),
                @floatCast(axis.vertical),
            ),
            .key => |key_event| _ = self.focus.dispatch(.{
                .keysym = @fromBackingInt(@intCast(key_event.keysym)),
                .text = key_event.text,
                .mods = .{ .shift = key_event.mods.shift, .ctrl = key_event.mods.ctrl, .alt = key_event.mods.alt, .super = key_event.mods.super },
                .action = if (key_event.state == .pressed) .press else .release,
            }),
            else => {},
        }
    }

    fn handleTextInput(self: *Session, input_event: lattice.text_input.Event) void {
        switch (input_event) {
            .commit => |text| _ = self.focus.dispatchTextInput(.{ .commit = text }),
            .preedit => |preedit| _ = self.focus.dispatchTextInput(.{ .preedit = .{
                .text = preedit.text,
                .selection = if (preedit.selection) |selection| .{
                    .start = selection.start,
                    .end = selection.end,
                } else null,
            } }),
            .finish_preedit => _ = self.focus.dispatchTextInput(.{ .finish_preedit = {} }),
            .delete_surrounding => |delete| {
                _ = self.focus.dispatchTextInput(.{ .delete_surrounding = .{
                    .before_bytes = delete.before_bytes,
                    .after_bytes = delete.after_bytes,
                } });
            },
            .action => |action| _ = self.focus.dispatchTextInput(.{ .action = switch (action) {
                .none => .none,
                .done => .done,
                .go => .go,
                .next => .next,
                .previous => .previous,
                .search => .search,
                .send => .send,
            } }),
        }
    }
};

fn queueOpenUrl(ctx: *anyopaque, url: []const u8, mode: phantom.OpenMode) bool {
    const self: *Session = @ptrCast(@alignCast(ctx));
    return self.open_url_request.queue(self.gpa, url, mode);
}

fn readSetting(ctx: *anyopaque, key: []const u8, buf: []u8) phantom.SettingsError!?[]const u8 {
    const self: *Session = @ptrCast(@alignCast(ctx));
    return self.settings.read(key, buf);
}

fn writeSetting(ctx: *anyopaque, key: []const u8, value: []const u8) phantom.SettingsError!void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    return self.settings.write(key, value);
}

fn removeSetting(ctx: *anyopaque, key: []const u8) phantom.SettingsError!void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    return self.settings.remove(key);
}

fn getNotificationPermission(ctx: *anyopaque) phantom.NotificationPermission {
    const self: *Session = @ptrCast(@alignCast(ctx));
    return self.notification_permission;
}

fn requestNotificationPermission(ctx: *anyopaque, sink: phantom.NotificationPermissionSink) bool {
    const self: *Session = @ptrCast(@alignCast(ctx));
    if (self.notification_permission != .prompt) {
        sink.on_result(sink.ctx, self.notification_permission);
        return true;
    }
    if (self.notification_permission_sink != null) return false;
    self.notification_permission_sink = sink;
    self.notification_permission_request = true;
    return true;
}

fn showNotification(ctx: *anyopaque, notification: phantom.Notification) bool {
    const self: *Session = @ptrCast(@alignCast(ctx));
    if (self.notification_permission != .granted or self.notification_request.pending) return false;
    return self.notification_request.queue(self.gpa, notification);
}

fn readConnectivity(_: *anyopaque) ?phantom.Connectivity {
    return HostBridge.connectivity;
}

fn setWifiEnabled(_: *anyopaque, enabled: bool) bool {
    return HostBridge.queue(.wifi_enabled, "", enabled);
}

fn setCellularEnabled(_: *anyopaque, enabled: bool) bool {
    return HostBridge.queue(.cellular_enabled, "", enabled);
}

fn readWifiNetworks(_: *anyopaque) ?[]const phantom.WifiNetwork {
    return HostBridge.wifi_networks;
}
fn requestWifiScan(_: *anyopaque) bool {
    return HostBridge.queue(.wifi_scan, "", false);
}
fn connectWifi(_: *anyopaque, id: []const u8, password: []const u8) bool {
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(std.heap.c_allocator);
    value.appendSlice(std.heap.c_allocator, id) catch return false;
    value.append(std.heap.c_allocator, 0) catch return false;
    value.appendSlice(std.heap.c_allocator, password) catch return false;
    return HostBridge.queue(.wifi_connect, value.items, false);
}
fn disconnectWifi(_: *anyopaque, id: []const u8) bool {
    return HostBridge.queue(.wifi_disconnect, id, false);
}

fn readBluetooth(_: *anyopaque) ?phantom.Bluetooth {
    return HostBridge.bluetooth;
}

fn setBluetoothEnabled(_: *anyopaque, enabled: bool) bool {
    return HostBridge.queue(.bluetooth_enabled, "", enabled);
}

fn requestBluetoothDiscovery(_: *anyopaque) bool {
    return HostBridge.queue(.bluetooth_discovery, "", false);
}

fn readPower(_: *anyopaque) ?phantom.Power {
    return HostBridge.power;
}

fn readAudio(_: *anyopaque) ?phantom.Audio {
    return HostBridge.audio;
}

fn setAudio(_: *anyopaque, state: phantom.Audio) bool {
    const normalized = phantom.Audio{ .output_volume = @max(0, @min(1, state.output_volume)), .muted = state.muted };
    if (!HostBridge.queueNumber(.audio, normalized.output_volume, normalized.muted)) return false;
    HostBridge.setAudio(normalized);
    return true;
}

fn readBrightness(_: *anyopaque) ?phantom.Brightness {
    return HostBridge.brightness;
}

fn setBrightness(_: *anyopaque, state: phantom.Brightness) bool {
    const normalized = phantom.Brightness{ .level = @max(0, @min(1, state.level)) };
    if (!HostBridge.queueNumber(.brightness, normalized.level, false)) return false;
    HostBridge.setBrightness(normalized);
    return true;
}

fn readIdentity(_: *anyopaque) ?phantom.Identity {
    return HostBridge.identity;
}

fn readApplications(_: *anyopaque) ?[]const phantom.Application {
    return HostBridge.applications;
}

fn launchApplication(_: *anyopaque, id: []const u8) bool {
    return HostBridge.queue(.launch_application, id, false);
}

fn readSystemNotifications(_: *anyopaque) ?[]const phantom.SystemNotification {
    return HostBridge.notifications;
}

fn dismissSystemNotification(_: *anyopaque, key: []const u8) bool {
    return HostBridge.queue(.dismiss_notification, key, false);
}

fn clearSystemNotifications(_: *anyopaque) bool {
    return HostBridge.queue(.clear_notifications, "", false);
}

fn invokeSystemNotification(_: *anyopaque, key: []const u8) bool {
    return HostBridge.queue(.invoke_notification, key, false);
}

fn pickFile(ctx: *anyopaque, options: phantom.FilePickerOptions, sink: phantom.FilePickerSink) bool {
    const self: *Session = @ptrCast(@alignCast(ctx));
    if (self.file_picker_request.sink != null) return false;
    self.file_picker_request.accept.clearRetainingCapacity();
    self.file_picker_request.accept.appendSlice(self.gpa, options.accept) catch return false;
    self.file_picker_request.sink = sink;
    self.file_picker_request.pending = true;
    return true;
}

fn readClipboard(ctx: *anyopaque, sink: phantom.ClipboardReadSink) bool {
    const self: *Session = @ptrCast(@alignCast(ctx));
    if (self.clipboard_request.read_sink != null) return false;
    self.clipboard_request.read_sink = sink;
    self.clipboard_request.read_pending = true;
    return true;
}

fn writeClipboard(ctx: *anyopaque, text: []const u8) bool {
    const self: *Session = @ptrCast(@alignCast(ctx));
    if (self.clipboard_request.write_pending) return false;
    self.clipboard_request.write.clearRetainingCapacity();
    self.clipboard_request.write.appendSlice(self.gpa, text) catch return false;
    self.clipboard_request.write_pending = true;
    return true;
}

fn getLifecycleState(ctx: *anyopaque) phantom.LifecycleState {
    const self: *Session = @ptrCast(@alignCast(ctx));
    return self.lifecycle_state;
}

fn setLifecycleSink(ctx: *anyopaque, sink: ?phantom.LifecycleSink) void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    self.lifecycle_sink = sink;
    if (sink) |value| value.on_state(value.ctx, self.lifecycle_state);
}

fn touchPoint(touch: lattice.event.TouchPoint) phantom.PhysicalOffset {
    return .{ .x = @floatCast(touch.x), .y = @floatCast(touch.y) };
}

fn validDensity(density: f32) f32 {
    return if (std.math.isFinite(density) and density > 0) density else 1;
}

fn validTextScale(scale: f32) f32 {
    return if (std.math.isFinite(scale) and scale > 0) scale else 1;
}

fn validAndroidCodepoint(codepoint: i32) bool {
    return codepoint >= 0 and codepoint <= 0x10ffff and !(codepoint >= 0xd800 and codepoint <= 0xdfff);
}

fn androidKeysym(platform_keysym: i32, codepoint: i32) phantom.input.Keysym {
    if (platform_keysym > 0) return @fromBackingInt(@intCast(platform_keysym));
    if (validAndroidCodepoint(codepoint)) return phantom.input.Keysym.fromCodepoint(@intCast(codepoint));
    return .no_symbol;
}

fn androidModifiers(bits: i32) phantom.input.Mods {
    return .{
        .shift = bits & 1 != 0,
        .ctrl = bits & 2 != 0,
        .alt = bits & 4 != 0,
        .super = bits & 8 != 0,
    };
}

fn androidKeyAction(action: i32) phantom.input.KeyAction {
    return switch (action) {
        1 => .repeat,
        2 => .release,
        else => .press,
    };
}

fn logicalSize(width: u32, height: u32, density: f32) phantom.LogicalSize {
    return .{
        .width = @as(f32, @floatFromInt(width)) / density,
        .height = @as(f32, @floatFromInt(height)) / density,
    };
}

fn logicalInsets(insets: phantom.PhysicalEdgeInsets, scale: f32) phantom.LogicalEdgeInsets {
    return .{
        .left = @max(0, insets.left) / scale,
        .top = @max(0, insets.top) / scale,
        .right = @max(0, insets.right) / scale,
        .bottom = @max(0, insets.bottom) / scale,
    };
}

test "Android URL requests own their UTF-8 bytes until consumed" {
    var request = OpenUrlRequest{};
    defer request.deinit(std.testing.allocator);

    var source = [_]u8{ 'h', 't', 't', 'p', 's', ':', '/', '/', 'x' };
    try std.testing.expect(request.queue(std.testing.allocator, &source, .new_tab));
    source[8] = 'y';
    try std.testing.expectEqualStrings("https://x", request.bytes.items);
    try std.testing.expectEqual(phantom.OpenMode.new_tab, request.mode);
    try std.testing.expect(request.pending);

    request.clear();
    try std.testing.expect(!request.pending);
    try std.testing.expectEqual(@as(usize, 0), request.bytes.items.len);
}

test "Android display scales reject invalid density and font scale values" {
    try std.testing.expectEqual(@as(f32, 1), validDensity(0));
    try std.testing.expectEqual(@as(f32, 1), validTextScale(std.math.nan(f32)));
    try std.testing.expectEqual(@as(f32, 1.5), validTextScale(1.5));
    const size = logicalSize(1080, 2400, 3 * 1.5);
    try std.testing.expectEqual(@as(f32, 240), size.width);
    const insets = logicalInsets(.{ .top = 108, .bottom = 63 }, 3);
    try std.testing.expectEqual(@as(f32, 36), insets.top);
    try std.testing.expectEqual(@as(f32, 21), insets.bottom);
}

test "Android physical keys use the same keysyms and modifiers as Wayland" {
    try std.testing.expectEqual(phantom.input.Keysym.escape, androidKeysym(0xff1b, 0));
    try std.testing.expectEqual(phantom.input.Keysym.fromCodepoint('a'), androidKeysym(0, 'a'));
    try std.testing.expectEqual(phantom.input.Keysym.fromCodepoint(0x4e00), androidKeysym(0, 0x4e00));
    try std.testing.expectEqual(phantom.input.Keysym.no_symbol, androidKeysym(0, 0xd800));
    const mods = androidModifiers(1 | 2 | 8);
    try std.testing.expect(mods.shift);
    try std.testing.expect(mods.ctrl);
    try std.testing.expect(!mods.alt);
    try std.testing.expect(mods.super);
    try std.testing.expectEqual(phantom.input.KeyAction.repeat, androidKeyAction(1));
    try std.testing.expectEqual(phantom.input.KeyAction.release, androidKeyAction(2));
}
