const std = @import("std");
const phantom = @import("phantom");
const app = @import("app_root");
const options = @import("android_options");

pub const std_options: std.Options = .{ .enable_segfault_handler = false };
extern "log" fn __android_log_write(priority: c_int, tag: [*:0]const u8, message: [*:0]const u8) c_int;

const Session = phantom.android.Session;
const gpa = std.heap.c_allocator;
const log_tag: [*:0]const u8 = "Phantom";

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

fn nativeCreate(_: ?*anyopaque, _: ?*anyopaque, width: c_int, height: c_int, density: f32) callconv(.c) i64 {
    if (width <= 0 or height <= 0) return 0;
    const value = Session.create(gpa, phantom.Root.plain(app.root), @intCast(width), @intCast(height), density) catch |err| {
        log(@errorName(err));
        return 0;
    };
    log("Prism renderer ready");
    return @bitCast(@as(u64, @intFromPtr(value)));
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

fn nativeRender(_: ?*anyopaque, _: ?*anyopaque, handle: i64, width: c_int, height: c_int, density: f32, frame_nanos: i64) callconv(.c) c_int {
    const value = session(handle) orelse return 0;
    value.render(@intCast(width), @intCast(height), density, frame_nanos) catch |err| {
        log(@errorName(err));
        return 0;
    };
    return 1;
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

comptime {
    @export(&nativeCreate, .{ .name = options.jni_prefix ++ "nativeCreate" });
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
}
