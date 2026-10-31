# Platform services

`BuildContext.owner.platform` exposes capabilities that do not belong to the
widget tree: file selection, clipboard access, notifications, lifecycle state,
and persistent settings. Capability calls report unsupported hosts instead of
silently succeeding. File selection, clipboard reads, and permission requests
complete through callbacks because browsers and Android may show UI after the
initiating frame has returned.

Settings are opaque byte values addressed by portable UTF-8 keys. Linux writes
one deterministic ZON document to
`$XDG_CONFIG_HOME/<application-id>/settings.zon`, or
`$HOME/.config/<application-id>/settings.zon` when `XDG_CONFIG_HOME` is not
set. Writes replace the document atomically. Web builds use a namespace in
`localStorage` scoped by the same reverse-DNS application id.

Android local notifications use `NotificationManager`. Apps that enable the
`.notifications` Android permission can request the Android 13 notification
permission through the platform API. Phantom does not select or bundle a remote
notification transport.

## Android background services

An Android app can package a Zig module as a foreground background service:

```zig
const service = b.createModule(.{
    .root_source_file = b.path("src/android/service.zig"),
    .target = target,
    .optimize = optimize,
});

.android = .{
    .permissions = &.{ .internet, .notifications },
    .background_service = .{
        .module = service,
        .notification_title = "Connected to Chock",
        .notification_body = "Listening for session updates",
        .service_type = .special_use,
        .special_use_subtype = "persistent connection to a user-configured Chock daemon",
    },
},
```

The module exports `run(*phantom.android.BackgroundService) !void`. Phantom
runs it on a worker thread; it can use `io()`, `filesDir()`, `shouldStop()`, and
`showNotification()`. `run` must return when `shouldStop()` becomes true. A
module blocked on its own socket can additionally export `stop(service)` to
close that socket before Phantom joins the worker. Android always displays the
configured ongoing notification while the service runs.

This transport is suitable for Chock maintaining its own daemon connection.
It does not require Firebase: the foreground service receives daemon events and
posts local Android notifications through Phantom.
