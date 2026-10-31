# Android platform integration

Phantom's Android platform target replaces the user-visible Android system UI.
Android continues to provide the kernel, framework services, application
runtime, window manager, and ordinary application views. Phantom renders the
launcher, status area, notification and quick-settings surfaces, navigation and
overview, lock screen, volume and power surfaces, and other system-owned UI.

## Shell provider contract

Phantom does not name or select a particular desktop environment. An Android
application opts into the system-shell contract with `AppOptions.android`:

```zig
.android = .{
    .system_ui = .edge_to_edge,
    .home_screen = true,
    .system_shell = true,
    .system_shell_navigation_bar = false,
    .permissions = &.{
        .status_bar_service, .internal_system_window,
        .network_state, .wifi_state, .wifi_control, .wifi_privileged,
        .nearby_wifi, .fine_location,
        .bluetooth, .bluetooth_scan, .bluetooth_privileged,
        .app_discovery,
    },
},
```

The generated manifest advertises the standard HOME activity and an exported,
signature-permission-protected service for
`org.phantomui.intent.action.SYSTEM_SHELL`. The AOSP bridge resolves the active
HOME package, finds that package's service through this action, verifies that
it holds `android.permission.STATUS_BAR_SERVICE`, and binds it. Back, Home, and
shell-menu requests use the package-neutral
`org.phantomui.intent.action.SYSTEM_UI_ACTION` contract.

The minimal platform bridge owns a transparent bottom-edge gesture target. It
draws no navigation bar and publishes no navigation inset: an upward swipe
returns Home, an upward hold opens the shell menu, and a horizontal swipe goes
Back. HOME activities are generated as single-task activities and receive an
`androidHomeActivated` callback when Home targets an already-visible shell, so
the shell can dismiss its own menus and overlays. The same callback carries a
package-neutral shell-menu request for the held gesture.

WindowManager's requested-visible and transient system-bar masks are delivered
to the active HOME package through
`org.phantomui.intent.action.SYSTEM_BARS_CHANGED`. The generated shell service
accepts this only from a sender holding `STATUS_BAR_SERVICE`, passes normalized
state to the optional Zig `androidSystemBarsChanged` hook, and applies the
shell's returned visibility to Phantom-owned surfaces. This lets a shell honor,
reinterpret, or decline conventional bars without allowing stock SystemUI to
draw them.

Genesis is the first implementation, not a name embedded in Phantom or the
framework bridge. Another shell can use the same build options and replace the
prebuilt APK without modifying PhantomSystemUI. Status and navigation surfaces
are independently selectable; a shell using gestures or its own dock can set
`system_shell_navigation_bar = false` and reserve no bottom bar.
System-shell surfaces use alpha-capable Android buffers and a transparent
renderer clear, so opacity is controlled by the shell theme rather than an
opaque host window.
The persistent status strip remains a small `TYPE_STATUS_BAR` window. When its
menu opens, Phantom creates a separate full-display
`TYPE_STATUS_BAR_SUB_PANEL`; this gives the translucent menu a native-size
buffer without stretching the strip and leaves application input unobstructed
while the menu is closed.

## Shell platform services

The Android host publishes the same portable `BuildOwner.platform` contracts
used by native shells. A shell can read connectivity and visible Wi-Fi
networks, scan, connect, disconnect, and toggle Wi-Fi; read and toggle
Bluetooth and request discovery; enumerate launchable activities with their
labels, PNG icons, live-task state, and task snapshots; bring an activity task
to the front; read and control media volume, mute state, and display brightness;
read the current Android user's display name and Android release; and read,
invoke, dismiss, or clear Android notifications. Android objects and permissions
stay on the Java side of the bridge; widget and shell code only sees borrowed
Zig value types and queues platform actions.

For a system-shell package, the minimal AOSP SystemUI bridge grants the runtime
permissions the active HOME package declared and grants its
`NotificationListenerService` access. Both are resolved from intent contracts,
so replacing Genesis with another Phantom shell requires no framework package
name change. Ordinary Phantom applications do not receive these privileges.

## AOSP repositories

The public entry point should be a fork of AOSP's `platform/manifest`. A branch
of that manifest pins the matching Android release and adds or replaces these
projects:

| Checkout path | Purpose |
| --- | --- |
| `frameworks/phantom` | Phantom UI framework, renderer, and Android platform backend |
| `packages/apps/PhantomSystemUI` | Platform-signed SystemUI host and private Android adapters |
| `frameworks/base` | Small, version-matched fork for framework/SystemUI contracts that cannot live out of tree |
| `device/google/cuttlefish` | Cuttlefish product used for development and CI |
| `build/soong` | First-class Zig module types and Android toolchain integration |
| `prebuilts/zig` | Pinned Zig compiler binaries for supported build hosts |

There is no `external/phantom` project: Phantom is part of the platform, not an
imported third-party library. There is also no general `device/phantom`
implementation project. Device repositories contain only device-specific
product definitions and overlays. A Pixel or GrapheneOS-based port replaces the
Cuttlefish device project while sharing the framework, SystemUI host, Soong,
and Zig projects.

## Unified build

The complete image must be reproducible through the Android build graph:

```sh
source build/envsetup.sh
lunch phantom_cf_x86_64_only_phone-trunk_staging-userdebug
m
```

Gradle, a separately installed Android NDK, an ambient `zig` executable, and a
post-build APK copy are not part of this path.

The `build/soong` fork should add module types modeled on Soong's Rust support:

- `zig_library` and `zig_library_shared`;
- `zig_binary`;
- `zig_test`;
- `zig_defaults` for shared target and policy settings.

These modules select the pinned compiler from `prebuilts/zig`, translate Soong's
OS and architecture variants into Zig targets, declare all Zig source and module
dependencies, and emit depfiles for incremental builds. Soong remains
responsible for Android linking and installation so Zig output uses the same
Bionic CRT, platform libraries, ABI checks, sanitizers, stripping, debug info,
license metadata, and partition rules as C/C++ and Rust modules. The Android
platform build must not route through the standalone Phantom `build.zig` APK
packager.

A SystemUI host can then consume the renderer as an ordinary native dependency:

```bp
zig_library_shared {
    name: "libphantom_systemui",
    root: "src/android/system_ui.zig",
    shared_libs: ["libandroid", "liblog"],
    platform_apis: true,
}

android_app {
    name: "PhantomSystemUI",
    privileged: true,
    platform_apis: true,
    certificate: "platform",
    jni_libs: ["libphantom_systemui"],
}
```

The exact properties will be defined and tested in the Soong fork; this example
describes the intended dependency boundary rather than a `genrule` workaround.

## Migration order

1. Make Phantom the full-screen HOME surface and remove stock status,
   navigation, and keyguard windows.
2. Host reusable Phantom surfaces in the privileged SystemUI process.
3. Extend the existing Android notification, connectivity, Wi-Fi, Bluetooth,
   and application adapters with battery, task, and user state.
4. Replace notification shade and quick settings, overview/navigation,
   lock/bouncer, volume, power, screenshot, and remaining system dialogs.
5. Remove stock visual implementations once their framework contracts have
   Phantom replacements and regression coverage.

Keeping a stock service temporarily is acceptable only when it is headless. A
stock Android view appearing on screen is a missing Phantom surface, not part of
the final architecture.
