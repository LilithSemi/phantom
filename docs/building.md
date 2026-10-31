# Building and platform targets

From the repository root:

```sh
zig build test          # the full test suite
zig build run-hello     # the window backend (needs a Wayland compositor)
zig build run-hello:web # builds the wasm + HTML demo
zig build run-hello:tui # the terminal backend (needs a real terminal)
```

## Android

An Android target builds and packages an APK through the same `addApp` step as
the native and web targets. Phantom mounts and lays out the application's real
widget tree and renders its display list with Prism's Vulkan driver. Lattice
owns the asynchronous Android surface lifecycle, and Prism presents directly to
the `ANativeWindow` swapchain without a CPU readback or Android bitmap.

This path shares Prism's text, images, clipping, rounded rectangles, and
built-in icon rendering with the desktop backend. Raw multi-touch,
virtual-keyboard commits, IME composition, deletion, and editor actions enter
through Lattice's neutral event model. Physical keyboards use the same
X11-style keysyms and modifier model as Wayland, including repeat and release
events. Android Back, including gesture navigation, is an Escape key; an
unconsumed Back leaves the single Activity. Mouse and trackpad hover and wheel
events feed the same pointer dispatcher as a Wayland seat. Rendering pauses
with the Activity while a configured background service can continue running.

```sh
cd examples/app
zig build -Dtarget=aarch64-linux-android.24
adb install -r zig-out/bin/demo-debug.apk
```

The Nix development shell supplies Android SDK 36, the NDK, JDK 17, and Gradle.
Outside Nix, set `ANDROID_NDK_ROOT` and put Gradle on `PATH`. The
`-Dandroid-ndk` and `-Dandroid-gradle` options override those locations.
Debug builds produce `<name>-debug.apk`; every non-debug optimization mode
produces `<name>-release.apk`.

### System UI and shell mode

`AndroidOptions.system_ui` defaults to `.edge_to_edge`: Phantom draws behind
the Android bars and publishes their safe insets through
`MediaQuery.of(b).view_padding`. A fullscreen shell can select `.immersive`;
the bars then reveal transiently on an edge swipe and the view padding contains
only display-cutout safety.

Setting `AndroidOptions.home_screen` also advertises the generated Activity as
an Android HOME implementation. It is off by default and is primarily useful
for platform-image shell prototypes such as `examples/shell`.

`AndroidOptions.system_shell` packages persistent Phantom system surfaces.
`system_shell_status_bar` and `system_shell_navigation_bar` independently
select the top and bottom surfaces. Both default on; shells that provide
gesture or dock navigation can disable the conventional bottom surface.

`examples/shell` is the system-shell bring-up target. Its Android build renders
the shared Phantom shell surface in immersive mode, while its Linux build is a
Lattice Wayland compositor that creates a socket, hosts XDG toplevels, forwards
seat input, and composites the focused surface. The AOSP integration launches
the Android surface as a platform HOME from SystemUI for the first bring-up;
embedding its view directly into SystemUI is the following integration slice.

## Native window chrome

Native window sessions add a draggable title bar with minimize,
maximize/restore, and close buttons when Lattice negotiates client-side
decorations. Fullscreen windows and windows with server-side decorations hide
the bar. `WindowChrome`, `WindowTitleBar`, and `WindowController` are also
exported for custom hosts.

Mobile detection runs at startup, including on Linux: it checks mobile desktop
sessions such as Phosh and Plasma Mobile, chassis metadata, and device-tree
hints. Native Android and iOS targets are also classified as mobile. Devices
without identifying metadata can use `window.Options.mobile = true` to suppress
the chrome; `false` explicitly selects desktop behavior. Window width alone
does not classify a device.
