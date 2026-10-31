const std = @import("std");
const phantom = @import("phantom");
const app = @import("app_root");
const background_module = @import("background_service");
const options = @import("android_options");

pub const std_options: std.Options = .{ .enable_segfault_handler = false };
extern "log" fn __android_log_write(priority: c_int, tag: [*:0]const u8, message: [*:0]const u8) c_int;

const Session = phantom.android.Session;
const gpa = std.heap.c_allocator;
const log_tag: [*:0]const u8 = "Phantom";
var files_dir: std.ArrayList(u8) = .empty;
var service_files_dir: std.ArrayList(u8) = .empty;
var background_service: ?*phantom.android.BackgroundService = null;
var background_thread: ?std.Thread = null;
var background_finished: std.atomic.Value(bool) = .init(true);

extern "android" fn ANativeWindow_fromSurface(env: ?*anyopaque, surface: ?*anyopaque) ?*anyopaque;

fn log(message: []const u8) void {
    var buffer: [1024]u8 = undefined;
    const len = @min(message.len, buffer.len - 1);
    @memcpy(buffer[0..len], message[0..len]);
    buffer[len] = 0;
    _ = __android_log_write(6, log_tag, @ptrCast(&buffer));
}

fn panicImpl(message: []const u8, _: ?usize) noreturn {
    log(message);
    std.process.abort();
}

pub const panic = std.debug.FullPanic(panicImpl);

fn session(handle: i64) ?*Session {
    if (handle == 0) return null;
    const address: u64 = @bitCast(handle);
    return @ptrFromInt(@as(usize, @intCast(address)));
}

export fn JNI_OnLoad(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    return 0x00010006;
}

fn nativeCreate(_: ?*anyopaque, _: ?*anyopaque, surface_role: c_int, width: c_int, height: c_int, density: f32, text_scale: f32, inset_left: c_int, inset_top: c_int, inset_right: c_int, inset_bottom: c_int, notification_permission: c_int) callconv(.c) i64 {
    if (width <= 0 or height <= 0) return 0;
    if (files_dir.items.len == 0) return 0;
    const root = if (comptime @hasDecl(app, "androidRoot"))
        app.androidRoot(surface_role)
    else
        phantom.Root.plain(app.root);
    const value = Session.create(gpa, root, @intCast(width), @intCast(height), density, text_scale, physicalInsets(inset_left, inset_top, inset_right, inset_bottom), files_dir.items, permissionFromInt(notification_permission), surface_role != 0) catch |err| {
        log(@errorName(err));
        return 0;
    };
    log("Prism renderer ready");
    return @bitCast(@as(u64, @intFromPtr(value)));
}

fn nativeTakeSystemAction(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    if (comptime @hasDecl(app, "takeAndroidSystemAction")) {
        return @intCast(app.takeAndroidSystemAction());
    }
    return 0;
}

fn nativeSystemBarsChanged(_: ?*anyopaque, _: ?*anyopaque, requested_visible_types: c_int, transient_types: c_int, behavior: c_int) callconv(.c) c_int {
    const status_type: c_int = 1;
    const navigation_type: c_int = 2;
    const state = phantom.android.SystemBarsState{
        .status_requested_visible = requested_visible_types & status_type != 0,
        .navigation_requested_visible = requested_visible_types & navigation_type != 0,
        .status_transient = transient_types & status_type != 0,
        .navigation_transient = transient_types & navigation_type != 0,
        .behavior = behavior,
    };
    const visibility = if (comptime @hasDecl(app, "androidSystemBarsChanged"))
        app.androidSystemBarsChanged(state)
    else
        state.effectiveVisibility();
    return (if (visibility.status) status_type else 0) |
        (if (visibility.navigation) navigation_type else 0);
}

fn nativeSystemShellState(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    if (comptime @hasDecl(app, "androidSystemShellState")) {
        return @intCast(app.androidSystemShellState());
    }
    return 0;
}

fn nativeHomeActivated(_: ?*anyopaque, _: ?*anyopaque, action: c_int) callconv(.c) void {
    if (comptime @hasDecl(app, "androidHomeActivated")) app.androidHomeActivated(action);
}

fn permissionFromInt(value: c_int) phantom.NotificationPermission {
    return switch (value) {
        0 => .granted,
        1 => .denied,
        2 => .prompt,
        else => .unsupported,
    };
}

fn nativeBeginFilesDir(_: ?*anyopaque, _: ?*anyopaque, length: c_int) callconv(.c) c_int {
    if (length <= 0) return 0;
    files_dir.resize(gpa, @intCast(length)) catch return 0;
    return 1;
}

fn nativeFilesDirByte(_: ?*anyopaque, _: ?*anyopaque, index: c_int, byte: c_int) callconv(.c) void {
    if (index < 0 or byte < 0 or byte > 255) return;
    const i: usize = @intCast(index);
    if (i < files_dir.items.len) files_dir.items[i] = @intCast(byte);
}

fn nativeDestroy(_: ?*anyopaque, _: ?*anyopaque, handle: i64) callconv(.c) void {
    if (session(handle)) |value| value.destroy();
}

fn nativeSurfaceCreated(env: ?*anyopaque, _: ?*anyopaque, handle: i64, java_surface: ?*anyopaque, width: c_int, height: c_int, density: f32) callconv(.c) c_int {
    const value = session(handle) orelse return 0;
    const window = ANativeWindow_fromSurface(env, java_surface) orelse return 0;
    value.attachNativeWindow(window, @intCast(width), @intCast(height), density) catch |err| {
        log(@errorName(err));
        return 0;
    };
    return 1;
}

fn nativeSurfaceDestroyed(_: ?*anyopaque, _: ?*anyopaque, handle: i64) callconv(.c) void {
    if (session(handle)) |value| value.detachNativeWindow();
}

fn nativeRender(_: ?*anyopaque, _: ?*anyopaque, handle: i64, width: c_int, height: c_int, density: f32, text_scale: f32, inset_left: c_int, inset_top: c_int, inset_right: c_int, inset_bottom: c_int, frame_nanos: i64) callconv(.c) c_int {
    const value = session(handle) orelse return 0;
    value.render(@intCast(width), @intCast(height), density, text_scale, physicalInsets(inset_left, inset_top, inset_right, inset_bottom), frame_nanos) catch |err| {
        log(@errorName(err));
        return 0;
    };
    return 1;
}

fn physicalInsets(left: c_int, top: c_int, right: c_int, bottom: c_int) phantom.PhysicalEdgeInsets {
    return .{
        .left = @floatFromInt(@max(0, left)),
        .top = @floatFromInt(@max(0, top)),
        .right = @floatFromInt(@max(0, right)),
        .bottom = @floatFromInt(@max(0, bottom)),
    };
}

fn nativeTouch(_: ?*anyopaque, _: ?*anyopaque, handle: i64, action: c_int, pointer_id: c_int, x: f32, y: f32) callconv(.c) c_int {
    const value = session(handle) orelse return 0;
    const wants_ime = value.touch(action, @intCast(pointer_id), x, y) catch |err| {
        log(@errorName(err));
        return 0;
    };
    return @intFromBool(wants_ime);
}

fn nativeCommitCodepoint(_: ?*anyopaque, _: ?*anyopaque, handle: i64, codepoint: c_int) callconv(.c) void {
    if (!validCodepoint(codepoint)) return;
    const value = session(handle) orelse return;
    value.commitCodepoint(@intCast(codepoint)) catch |err| log(@errorName(err));
}

fn nativeBeginPreedit(_: ?*anyopaque, _: ?*anyopaque, handle: i64) callconv(.c) void {
    if (session(handle)) |value| value.beginPreedit();
}

fn nativeAppendPreeditCodepoint(_: ?*anyopaque, _: ?*anyopaque, handle: i64, codepoint: c_int) callconv(.c) void {
    if (!validCodepoint(codepoint)) return;
    const value = session(handle) orelse return;
    value.appendPreeditCodepoint(@intCast(codepoint)) catch |err| log(@errorName(err));
}

fn nativeEndPreedit(_: ?*anyopaque, _: ?*anyopaque, handle: i64) callconv(.c) void {
    const value = session(handle) orelse return;
    value.endPreedit() catch |err| log(@errorName(err));
}

fn nativeFinishPreedit(_: ?*anyopaque, _: ?*anyopaque, handle: i64) callconv(.c) void {
    const value = session(handle) orelse return;
    value.finishPreedit() catch |err| log(@errorName(err));
}

fn validCodepoint(codepoint: c_int) bool {
    return codepoint >= 0 and codepoint <= 0x10ffff and !(codepoint >= 0xd800 and codepoint <= 0xdfff);
}

fn nativeDeleteFromIme(_: ?*anyopaque, _: ?*anyopaque, handle: i64, before: c_int) callconv(.c) void {
    const value = session(handle) orelse return;
    value.deleteFromIme(before != 0) catch |err| log(@errorName(err));
}

fn nativeImeAction(_: ?*anyopaque, _: ?*anyopaque, handle: i64, action: c_int) callconv(.c) void {
    const value = session(handle) orelse return;
    value.imeAction(action) catch |err| log(@errorName(err));
}

fn nativePendingUrlLength(_: ?*anyopaque, _: ?*anyopaque, handle: i64) callconv(.c) c_int {
    const value = session(handle) orelse return -1;
    const len = value.pendingUrlLength() orelse return -1;
    if (len > std.math.maxInt(c_int)) return -1;
    return @intCast(len);
}

fn nativePendingUrlByte(_: ?*anyopaque, _: ?*anyopaque, handle: i64, index: c_int) callconv(.c) c_int {
    if (index < 0) return -1;
    const value = session(handle) orelse return -1;
    return value.pendingUrlByte(@intCast(index)) orelse -1;
}

fn nativePendingUrlMode(_: ?*anyopaque, _: ?*anyopaque, handle: i64) callconv(.c) c_int {
    const value = session(handle) orelse return 0;
    return switch (value.pendingUrlMode()) {
        .new_tab => 0,
        .same_tab => 1,
    };
}

fn nativeClearPendingUrl(_: ?*anyopaque, _: ?*anyopaque, handle: i64) callconv(.c) void {
    if (session(handle)) |value| value.clearPendingUrl();
}

fn nativePendingNotificationLength(_: ?*anyopaque, _: ?*anyopaque, handle: i64, field: c_int) callconv(.c) c_int {
    if (field < 0) return -1;
    const value = session(handle) orelse return -1;
    const len = value.pendingNotificationLength(@intCast(field)) orelse return -1;
    return if (len <= std.math.maxInt(c_int)) @intCast(len) else -1;
}

fn nativePendingNotificationByte(_: ?*anyopaque, _: ?*anyopaque, handle: i64, field: c_int, index: c_int) callconv(.c) c_int {
    if (field < 0 or index < 0) return -1;
    const value = session(handle) orelse return -1;
    return value.pendingNotificationByte(@intCast(field), @intCast(index)) orelse -1;
}

fn nativeClearPendingNotification(_: ?*anyopaque, _: ?*anyopaque, handle: i64) callconv(.c) void {
    if (session(handle)) |value| value.clearPendingNotification();
}

fn nativeTakeNotificationPermissionRequest(_: ?*anyopaque, _: ?*anyopaque, handle: i64) callconv(.c) c_int {
    const value = session(handle) orelse return 0;
    return @intFromBool(value.takeNotificationPermissionRequest());
}

fn nativeNotificationPermission(_: ?*anyopaque, _: ?*anyopaque, handle: i64, permission: c_int) callconv(.c) void {
    if (session(handle)) |value| value.setNotificationPermission(permissionFromInt(permission));
}

fn nativePendingFilePickerLength(_: ?*anyopaque, _: ?*anyopaque, handle: i64) callconv(.c) c_int {
    const value = session(handle) orelse return -1;
    const len = value.pendingFilePickerLength() orelse return -1;
    return if (len <= std.math.maxInt(c_int)) @intCast(len) else -1;
}

fn nativePendingFilePickerByte(_: ?*anyopaque, _: ?*anyopaque, handle: i64, index: c_int) callconv(.c) c_int {
    if (index < 0) return -1;
    const value = session(handle) orelse return -1;
    return value.pendingFilePickerByte(@intCast(index)) orelse -1;
}

fn nativeStartFilePicker(_: ?*anyopaque, _: ?*anyopaque, handle: i64) callconv(.c) void {
    if (session(handle)) |value| value.startFilePicker();
}

fn nativeBeginFilePickerResult(_: ?*anyopaque, _: ?*anyopaque, handle: i64, name_len: c_int, type_len: c_int, data_len: c_int) callconv(.c) c_int {
    if (name_len < 0 or type_len < 0 or data_len < 0) return 0;
    const value = session(handle) orelse return 0;
    value.beginFilePickerResult(@intCast(name_len), @intCast(type_len), @intCast(data_len)) catch return 0;
    return 1;
}

fn nativeFilePickerResultByte(_: ?*anyopaque, _: ?*anyopaque, handle: i64, field: c_int, index: c_int, byte: c_int) callconv(.c) void {
    if (field < 0 or index < 0 or byte < 0 or byte > 255) return;
    if (session(handle)) |value| value.setFilePickerResultByte(@intCast(field), @intCast(index), @intCast(byte));
}

fn nativeFinishFilePicker(_: ?*anyopaque, _: ?*anyopaque, handle: i64, kind: c_int) callconv(.c) void {
    if (session(handle)) |value| value.finishFilePicker(if (kind < 0) 2 else @intCast(kind));
}

fn nativeKey(_: ?*anyopaque, _: ?*anyopaque, handle: i64, keysym: c_int, codepoint: c_int, modifiers: c_int, action: c_int) callconv(.c) c_int {
    const value = session(handle) orelse return 0;
    return @intFromBool(value.key(keysym, codepoint, modifiers, action));
}

fn nativePointerMove(_: ?*anyopaque, _: ?*anyopaque, handle: i64, x: f32, y: f32) callconv(.c) void {
    if (session(handle)) |value| value.pointerMove(x, y);
}

fn nativePointerScroll(_: ?*anyopaque, _: ?*anyopaque, handle: i64, x: f32, y: f32, horizontal: f32, vertical: f32) callconv(.c) void {
    if (session(handle)) |value| value.pointerScroll(x, y, horizontal, vertical);
}

fn nativePendingClipboardWriteLength(_: ?*anyopaque, _: ?*anyopaque, handle: i64) callconv(.c) c_int {
    const value = session(handle) orelse return -1;
    const len = value.pendingClipboardWriteLength() orelse return -1;
    return if (len <= std.math.maxInt(c_int)) @intCast(len) else -1;
}

fn nativePendingClipboardWriteByte(_: ?*anyopaque, _: ?*anyopaque, handle: i64, index: c_int) callconv(.c) c_int {
    if (index < 0) return -1;
    const value = session(handle) orelse return -1;
    return value.pendingClipboardWriteByte(@intCast(index)) orelse -1;
}

fn nativeClearClipboardWrite(_: ?*anyopaque, _: ?*anyopaque, handle: i64) callconv(.c) void {
    if (session(handle)) |value| value.clearClipboardWrite();
}

fn nativeTakeClipboardRead(_: ?*anyopaque, _: ?*anyopaque, handle: i64) callconv(.c) c_int {
    const value = session(handle) orelse return 0;
    return @intFromBool(value.takeClipboardRead());
}

fn nativeBeginClipboardResult(_: ?*anyopaque, _: ?*anyopaque, handle: i64, length: c_int) callconv(.c) c_int {
    if (length < 0) return 0;
    const value = session(handle) orelse return 0;
    value.beginClipboardResult(@intCast(length)) catch return 0;
    return 1;
}

fn nativeClipboardResultByte(_: ?*anyopaque, _: ?*anyopaque, handle: i64, index: c_int, byte: c_int) callconv(.c) void {
    if (index < 0 or byte < 0 or byte > 255) return;
    if (session(handle)) |value| value.setClipboardResultByte(@intCast(index), @intCast(byte));
}

fn nativeFinishClipboardRead(_: ?*anyopaque, _: ?*anyopaque, handle: i64, success: c_int) callconv(.c) void {
    if (session(handle)) |value| value.finishClipboardRead(success != 0);
}

fn nativeLifecycle(_: ?*anyopaque, _: ?*anyopaque, handle: i64, foreground: c_int) callconv(.c) void {
    if (session(handle)) |value| value.setLifecycleState(if (foreground != 0) .foreground else .background);
}

fn nativeBeginServiceFilesDir(_: ?*anyopaque, _: ?*anyopaque, length: c_int) callconv(.c) c_int {
    if (!options.has_background_service or length <= 0) return 0;
    service_files_dir.resize(gpa, @intCast(length)) catch return 0;
    return 1;
}

fn nativeServiceFilesDirByte(_: ?*anyopaque, _: ?*anyopaque, index: c_int, byte: c_int) callconv(.c) void {
    if (index < 0 or byte < 0 or byte > 255) return;
    const i: usize = @intCast(index);
    if (i < service_files_dir.items.len) service_files_dir.items[i] = @intCast(byte);
}

fn runBackgroundService(value: *phantom.android.BackgroundService) void {
    background_module.run(value) catch |err| log(@errorName(err));
    background_finished.store(true, .release);
}

fn nativeServiceStart(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    if (!options.has_background_service or background_service != null or service_files_dir.items.len == 0) return 0;
    const value = phantom.android.BackgroundService.create(gpa, service_files_dir.items) catch |err| {
        log(@errorName(err));
        return 0;
    };
    background_finished.store(false, .release);
    const thread = std.Thread.spawn(.{}, runBackgroundService, .{value}) catch |err| {
        log(@errorName(err));
        background_finished.store(true, .release);
        value.destroy();
        return 0;
    };
    background_service = value;
    background_thread = thread;
    return 1;
}

fn nativeServiceStop(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const value = background_service orelse return;
    value.requestStop();
    if (@hasDecl(background_module, "stop")) background_module.stop(value);
    if (background_thread) |thread| thread.join();
    background_thread = null;
    background_service = null;
    background_finished.store(true, .release);
    value.destroy();
}

fn nativeServiceRunning(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    return @intFromBool(background_service != null and !background_finished.load(.acquire));
}

fn nativeServiceNotificationLength(_: ?*anyopaque, _: ?*anyopaque, field: c_int) callconv(.c) c_int {
    if (field < 0) return -1;
    const value = background_service orelse return -1;
    const len = value.pendingNotificationLength(@intCast(field)) orelse return -1;
    return if (len <= std.math.maxInt(c_int)) @intCast(len) else -1;
}

fn nativeServiceNotificationByte(_: ?*anyopaque, _: ?*anyopaque, field: c_int, index: c_int) callconv(.c) c_int {
    if (field < 0 or index < 0) return -1;
    const value = background_service orelse return -1;
    return value.pendingNotificationByte(@intCast(field), @intCast(index)) orelse -1;
}

fn nativeServiceClearNotification(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (background_service) |value| value.clearPendingNotification();
}

fn nativePlatformConnectivity(_: ?*anyopaque, _: ?*anyopaque, transport: c_int, reachability: c_int, strength: c_int, flags: c_int) callconv(.c) void {
    phantom.android.HostBridge.setConnectivity(.{
        .transport = switch (transport) {
            1 => .ethernet,
            2 => .wifi,
            3 => .cellular,
            else => .none,
        },
        .reachability = switch (reachability) {
            1 => .local,
            2 => .site,
            3 => .internet,
            else => .disconnected,
        },
        .strength = if (strength >= 0 and strength <= 100) @intCast(strength) else null,
        .networking_enabled = flags & 1 != 0,
        .wifi_enabled = flags & 2 != 0,
        .cellular_available = flags & 4 != 0,
        .cellular_enabled = flags & 8 != 0,
    });
}

fn nativePlatformBluetooth(_: ?*anyopaque, _: ?*anyopaque, flags: c_int, connected: c_int, paired: c_int) callconv(.c) void {
    phantom.android.HostBridge.setBluetooth(.{
        .available = flags & 1 != 0,
        .enabled = flags & 2 != 0,
        .discovering = flags & 4 != 0,
        .connected_devices = @intCast(@max(0, @min(connected, std.math.maxInt(u16)))),
        .paired_devices = @intCast(@max(0, @min(paired, std.math.maxInt(u16)))),
    });
}

fn nativePlatformPower(_: ?*anyopaque, _: ?*anyopaque, present: c_int, percent: c_int, status: c_int, time_empty_ms: i64, time_full_ms: i64) callconv(.c) void {
    phantom.android.HostBridge.setPower(.{
        .present = present != 0,
        .percent = @intCast(@max(0, @min(percent, 100))),
        .status = switch (status) {
            2 => .charging,
            3 => if (percent <= 0) .empty else .discharging,
            4 => .pending,
            5 => .full,
            else => .unknown,
        },
        .time_to_empty_s = if (time_empty_ms >= 0) @intCast(@divTrunc(time_empty_ms, 1000)) else null,
        .time_to_full_s = if (time_full_ms >= 0) @intCast(@divTrunc(time_full_ms, 1000)) else null,
    });
}

fn nativePlatformAudio(_: ?*anyopaque, _: ?*anyopaque, volume: c_int, maximum: c_int, muted: c_int) callconv(.c) void {
    if (maximum <= 0) return;
    phantom.android.HostBridge.setAudio(.{
        .output_volume = @max(0, @min(1, @as(f32, @floatFromInt(volume)) / @as(f32, @floatFromInt(maximum)))),
        .muted = muted != 0,
    });
}

fn nativePlatformBrightness(_: ?*anyopaque, _: ?*anyopaque, level: f32) callconv(.c) void {
    if (!std.math.isFinite(level)) return;
    phantom.android.HostBridge.setBrightness(.{ .level = @max(0, @min(1, level)) });
}

fn nativeBeginIdentity(_: ?*anyopaque, _: ?*anyopaque, user_name_len: c_int, display_name_len: c_int, system_name_len: c_int) callconv(.c) c_int {
    if (user_name_len < 0 or display_name_len < 0 or system_name_len < 0) return 0;
    return @intFromBool(phantom.android.HostBridge.beginIdentity(
        @intCast(user_name_len),
        @intCast(display_name_len),
        @intCast(system_name_len),
    ));
}

fn nativeIdentityByte(_: ?*anyopaque, _: ?*anyopaque, field: c_int, offset: c_int, value: c_int) callconv(.c) void {
    if (field < 0 or offset < 0 or value < 0 or value > 255) return;
    phantom.android.HostBridge.identityByte(@intCast(field), @intCast(offset), @intCast(value));
}

fn nativeBeginWifiNetworks(_: ?*anyopaque, _: ?*anyopaque, count: c_int) callconv(.c) c_int {
    if (count < 0) return 0;
    return @intFromBool(phantom.android.HostBridge.beginWifiNetworks(@intCast(count)));
}

fn nativeBeginWifiNetwork(_: ?*anyopaque, _: ?*anyopaque, index: c_int, id_len: c_int, ssid_len: c_int, strength: c_int, secured: c_int, connected: c_int) callconv(.c) c_int {
    if (index < 0 or id_len < 0 or ssid_len < 0 or strength < 0 or strength > 100) return 0;
    return @intFromBool(phantom.android.HostBridge.beginWifiNetwork(
        @intCast(index),
        @intCast(id_len),
        @intCast(ssid_len),
        @intCast(strength),
        secured != 0,
        connected != 0,
    ));
}

fn nativeWifiNetworkByte(_: ?*anyopaque, _: ?*anyopaque, index: c_int, field: c_int, offset: c_int, value: c_int) callconv(.c) void {
    if (index < 0 or field < 0 or offset < 0 or value < 0 or value > 255) return;
    phantom.android.HostBridge.wifiNetworkByte(@intCast(index), @intCast(field), @intCast(offset), @intCast(value));
}

fn nativeBeginApplications(_: ?*anyopaque, _: ?*anyopaque, count: c_int) callconv(.c) c_int {
    if (count < 0) return 0;
    return @intFromBool(phantom.android.HostBridge.beginApplications(@intCast(count)));
}

fn nativeBeginApplication(_: ?*anyopaque, _: ?*anyopaque, index: c_int, id_len: c_int, name_len: c_int, icon_len: c_int, preview_len: c_int, running: c_int) callconv(.c) c_int {
    if (index < 0 or id_len < 0 or name_len < 0 or icon_len < 0 or preview_len < 0) return 0;
    return @intFromBool(phantom.android.HostBridge.beginApplication(@intCast(index), @intCast(id_len), @intCast(name_len), @intCast(icon_len), @intCast(preview_len), running != 0));
}

fn nativeApplicationByte(_: ?*anyopaque, _: ?*anyopaque, index: c_int, field: c_int, offset: c_int, value: c_int) callconv(.c) void {
    if (index < 0 or field < 0 or offset < 0 or value < 0 or value > 255) return;
    phantom.android.HostBridge.applicationByte(@intCast(index), @intCast(field), @intCast(offset), @intCast(value));
}

fn nativeBeginSystemNotifications(_: ?*anyopaque, _: ?*anyopaque, count: c_int) callconv(.c) c_int {
    if (count < 0) return 0;
    return @intFromBool(phantom.android.HostBridge.beginNotifications(@intCast(count)));
}

fn nativeBeginSystemNotification(_: ?*anyopaque, _: ?*anyopaque, index: c_int, key_len: c_int, app_len: c_int, title_len: c_int, body_len: c_int, posted_ms: i64, clearable: c_int) callconv(.c) c_int {
    if (index < 0 or key_len < 0 or app_len < 0 or title_len < 0 or body_len < 0) return 0;
    return @intFromBool(phantom.android.HostBridge.beginNotification(
        @intCast(index),
        .{ @intCast(key_len), @intCast(app_len), @intCast(title_len), @intCast(body_len) },
        posted_ms,
        clearable != 0,
    ));
}

fn nativeSystemNotificationByte(_: ?*anyopaque, _: ?*anyopaque, index: c_int, field: c_int, offset: c_int, value: c_int) callconv(.c) void {
    if (index < 0 or field < 0 or offset < 0 or value < 0 or value > 255) return;
    phantom.android.HostBridge.notificationByte(@intCast(index), @intCast(field), @intCast(offset), @intCast(value));
}

fn nativeTakePlatformAction(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    return phantom.android.HostBridge.takeAction();
}
fn nativePlatformActionValue(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    return @intFromBool(phantom.android.HostBridge.actionValue());
}
fn nativePlatformActionNumber(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) f32 {
    return phantom.android.HostBridge.actionNumber();
}
fn nativePlatformActionTextLength(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const len = phantom.android.HostBridge.actionTextLength();
    return if (len <= std.math.maxInt(c_int)) @intCast(len) else -1;
}
fn nativePlatformActionTextByte(_: ?*anyopaque, _: ?*anyopaque, index: c_int) callconv(.c) c_int {
    if (index < 0) return -1;
    return phantom.android.HostBridge.actionTextByte(@intCast(index)) orelse -1;
}

comptime {
    @export(&nativeCreate, .{ .name = options.jni_prefix ++ "nativeCreate" });
    @export(&nativeBeginFilesDir, .{ .name = options.jni_prefix ++ "nativeBeginFilesDir" });
    @export(&nativeFilesDirByte, .{ .name = options.jni_prefix ++ "nativeFilesDirByte" });
    @export(&nativeDestroy, .{ .name = options.jni_prefix ++ "nativeDestroy" });
    @export(&nativeSurfaceCreated, .{ .name = options.jni_prefix ++ "nativeSurfaceCreated" });
    @export(&nativeSurfaceDestroyed, .{ .name = options.jni_prefix ++ "nativeSurfaceDestroyed" });
    @export(&nativeRender, .{ .name = options.jni_prefix ++ "nativeRender" });
    @export(&nativeTouch, .{ .name = options.jni_prefix ++ "nativeTouch" });
    @export(&nativeTakeSystemAction, .{ .name = options.jni_prefix ++ "nativeTakeSystemAction" });
    @export(&nativeSystemBarsChanged, .{ .name = options.jni_prefix ++ "nativeSystemBarsChanged" });
    @export(&nativeSystemShellState, .{ .name = options.jni_prefix ++ "nativeSystemShellState" });
    @export(&nativeHomeActivated, .{ .name = options.jni_prefix ++ "nativeHomeActivated" });
    @export(&nativeCommitCodepoint, .{ .name = options.jni_prefix ++ "nativeCommitCodepoint" });
    @export(&nativeBeginPreedit, .{ .name = options.jni_prefix ++ "nativeBeginPreedit" });
    @export(&nativeAppendPreeditCodepoint, .{ .name = options.jni_prefix ++ "nativeAppendPreeditCodepoint" });
    @export(&nativeEndPreedit, .{ .name = options.jni_prefix ++ "nativeEndPreedit" });
    @export(&nativeFinishPreedit, .{ .name = options.jni_prefix ++ "nativeFinishPreedit" });
    @export(&nativeDeleteFromIme, .{ .name = options.jni_prefix ++ "nativeDeleteFromIme" });
    @export(&nativeImeAction, .{ .name = options.jni_prefix ++ "nativeImeAction" });
    @export(&nativePendingUrlLength, .{ .name = options.jni_prefix ++ "nativePendingUrlLength" });
    @export(&nativePendingUrlByte, .{ .name = options.jni_prefix ++ "nativePendingUrlByte" });
    @export(&nativePendingUrlMode, .{ .name = options.jni_prefix ++ "nativePendingUrlMode" });
    @export(&nativeClearPendingUrl, .{ .name = options.jni_prefix ++ "nativeClearPendingUrl" });
    @export(&nativePendingNotificationLength, .{ .name = options.jni_prefix ++ "nativePendingNotificationLength" });
    @export(&nativePendingNotificationByte, .{ .name = options.jni_prefix ++ "nativePendingNotificationByte" });
    @export(&nativeClearPendingNotification, .{ .name = options.jni_prefix ++ "nativeClearPendingNotification" });
    @export(&nativeTakeNotificationPermissionRequest, .{ .name = options.jni_prefix ++ "nativeTakeNotificationPermissionRequest" });
    @export(&nativeNotificationPermission, .{ .name = options.jni_prefix ++ "nativeNotificationPermission" });
    @export(&nativePendingFilePickerLength, .{ .name = options.jni_prefix ++ "nativePendingFilePickerLength" });
    @export(&nativePendingFilePickerByte, .{ .name = options.jni_prefix ++ "nativePendingFilePickerByte" });
    @export(&nativeStartFilePicker, .{ .name = options.jni_prefix ++ "nativeStartFilePicker" });
    @export(&nativeBeginFilePickerResult, .{ .name = options.jni_prefix ++ "nativeBeginFilePickerResult" });
    @export(&nativeFilePickerResultByte, .{ .name = options.jni_prefix ++ "nativeFilePickerResultByte" });
    @export(&nativeFinishFilePicker, .{ .name = options.jni_prefix ++ "nativeFinishFilePicker" });
    @export(&nativeKey, .{ .name = options.jni_prefix ++ "nativeKey" });
    @export(&nativePointerMove, .{ .name = options.jni_prefix ++ "nativePointerMove" });
    @export(&nativePointerScroll, .{ .name = options.jni_prefix ++ "nativePointerScroll" });
    @export(&nativePendingClipboardWriteLength, .{ .name = options.jni_prefix ++ "nativePendingClipboardWriteLength" });
    @export(&nativePendingClipboardWriteByte, .{ .name = options.jni_prefix ++ "nativePendingClipboardWriteByte" });
    @export(&nativeClearClipboardWrite, .{ .name = options.jni_prefix ++ "nativeClearClipboardWrite" });
    @export(&nativeTakeClipboardRead, .{ .name = options.jni_prefix ++ "nativeTakeClipboardRead" });
    @export(&nativeBeginClipboardResult, .{ .name = options.jni_prefix ++ "nativeBeginClipboardResult" });
    @export(&nativeClipboardResultByte, .{ .name = options.jni_prefix ++ "nativeClipboardResultByte" });
    @export(&nativeFinishClipboardRead, .{ .name = options.jni_prefix ++ "nativeFinishClipboardRead" });
    @export(&nativeLifecycle, .{ .name = options.jni_prefix ++ "nativeLifecycle" });
    @export(&nativePlatformConnectivity, .{ .name = options.jni_prefix ++ "nativePlatformConnectivity" });
    @export(&nativePlatformBluetooth, .{ .name = options.jni_prefix ++ "nativePlatformBluetooth" });
    @export(&nativePlatformPower, .{ .name = options.jni_prefix ++ "nativePlatformPower" });
    @export(&nativePlatformAudio, .{ .name = options.jni_prefix ++ "nativePlatformAudio" });
    @export(&nativePlatformBrightness, .{ .name = options.jni_prefix ++ "nativePlatformBrightness" });
    @export(&nativeBeginIdentity, .{ .name = options.jni_prefix ++ "nativeBeginIdentity" });
    @export(&nativeIdentityByte, .{ .name = options.jni_prefix ++ "nativeIdentityByte" });
    @export(&nativeBeginWifiNetworks, .{ .name = options.jni_prefix ++ "nativeBeginWifiNetworks" });
    @export(&nativeBeginWifiNetwork, .{ .name = options.jni_prefix ++ "nativeBeginWifiNetwork" });
    @export(&nativeWifiNetworkByte, .{ .name = options.jni_prefix ++ "nativeWifiNetworkByte" });
    @export(&nativeBeginApplications, .{ .name = options.jni_prefix ++ "nativeBeginApplications" });
    @export(&nativeBeginApplication, .{ .name = options.jni_prefix ++ "nativeBeginApplication" });
    @export(&nativeApplicationByte, .{ .name = options.jni_prefix ++ "nativeApplicationByte" });
    @export(&nativeBeginSystemNotifications, .{ .name = options.jni_prefix ++ "nativeBeginSystemNotifications" });
    @export(&nativeBeginSystemNotification, .{ .name = options.jni_prefix ++ "nativeBeginSystemNotification" });
    @export(&nativeSystemNotificationByte, .{ .name = options.jni_prefix ++ "nativeSystemNotificationByte" });
    @export(&nativeTakePlatformAction, .{ .name = options.jni_prefix ++ "nativeTakePlatformAction" });
    @export(&nativePlatformActionValue, .{ .name = options.jni_prefix ++ "nativePlatformActionValue" });
    @export(&nativePlatformActionNumber, .{ .name = options.jni_prefix ++ "nativePlatformActionNumber" });
    @export(&nativePlatformActionTextLength, .{ .name = options.jni_prefix ++ "nativePlatformActionTextLength" });
    @export(&nativePlatformActionTextByte, .{ .name = options.jni_prefix ++ "nativePlatformActionTextByte" });
    @export(&nativeBeginServiceFilesDir, .{ .name = options.service_jni_prefix ++ "nativeBeginServiceFilesDir" });
    @export(&nativeServiceFilesDirByte, .{ .name = options.service_jni_prefix ++ "nativeServiceFilesDirByte" });
    @export(&nativeServiceStart, .{ .name = options.service_jni_prefix ++ "nativeServiceStart" });
    @export(&nativeServiceStop, .{ .name = options.service_jni_prefix ++ "nativeServiceStop" });
    @export(&nativeServiceRunning, .{ .name = options.service_jni_prefix ++ "nativeServiceRunning" });
    @export(&nativeServiceNotificationLength, .{ .name = options.service_jni_prefix ++ "nativeServiceNotificationLength" });
    @export(&nativeServiceNotificationByte, .{ .name = options.service_jni_prefix ++ "nativeServiceNotificationByte" });
    @export(&nativeServiceClearNotification, .{ .name = options.service_jni_prefix ++ "nativeServiceClearNotification" });
}
