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

fn nativeCreate(_: ?*anyopaque, _: ?*anyopaque, width: c_int, height: c_int, density: f32, text_scale: f32, inset_left: c_int, inset_top: c_int, inset_right: c_int, inset_bottom: c_int, notification_permission: c_int) callconv(.c) i64 {
    if (width <= 0 or height <= 0) return 0;
    if (files_dir.items.len == 0) return 0;
    const value = Session.create(gpa, phantom.Root.plain(app.root), @intCast(width), @intCast(height), density, text_scale, physicalInsets(inset_left, inset_top, inset_right, inset_bottom), files_dir.items, permissionFromInt(notification_permission)) catch |err| {
        log(@errorName(err));
        return 0;
    };
    log("Prism renderer ready");
    return @bitCast(@as(u64, @intFromPtr(value)));
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

comptime {
    @export(&nativeCreate, .{ .name = options.jni_prefix ++ "nativeCreate" });
    @export(&nativeBeginFilesDir, .{ .name = options.jni_prefix ++ "nativeBeginFilesDir" });
    @export(&nativeFilesDirByte, .{ .name = options.jni_prefix ++ "nativeFilesDirByte" });
    @export(&nativeDestroy, .{ .name = options.jni_prefix ++ "nativeDestroy" });
    @export(&nativeSurfaceCreated, .{ .name = options.jni_prefix ++ "nativeSurfaceCreated" });
    @export(&nativeSurfaceDestroyed, .{ .name = options.jni_prefix ++ "nativeSurfaceDestroyed" });
    @export(&nativeRender, .{ .name = options.jni_prefix ++ "nativeRender" });
    @export(&nativeTouch, .{ .name = options.jni_prefix ++ "nativeTouch" });
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
    @export(&nativeBeginServiceFilesDir, .{ .name = options.service_jni_prefix ++ "nativeBeginServiceFilesDir" });
    @export(&nativeServiceFilesDirByte, .{ .name = options.service_jni_prefix ++ "nativeServiceFilesDirByte" });
    @export(&nativeServiceStart, .{ .name = options.service_jni_prefix ++ "nativeServiceStart" });
    @export(&nativeServiceStop, .{ .name = options.service_jni_prefix ++ "nativeServiceStop" });
    @export(&nativeServiceRunning, .{ .name = options.service_jni_prefix ++ "nativeServiceRunning" });
    @export(&nativeServiceNotificationLength, .{ .name = options.service_jni_prefix ++ "nativeServiceNotificationLength" });
    @export(&nativeServiceNotificationByte, .{ .name = options.service_jni_prefix ++ "nativeServiceNotificationByte" });
    @export(&nativeServiceClearNotification, .{ .name = options.service_jni_prefix ++ "nativeServiceClearNotification" });
}
