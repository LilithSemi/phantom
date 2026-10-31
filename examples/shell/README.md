# Phantom Shell

This is the reference bring-up target for Phantom UI's system-shell contract.
The production desktop environment is [Genesis](https://git.lilithsemi.com/LilithSemi/genesis),
which uses Phantom's compositor architecture and the same Android surface roles.

The repository and unified AOSP/Soong build design is documented in
[`docs/android-platform.md`](../../docs/android-platform.md).

- Android builds package a reference shell surface in an immersive HOME
  Activity. The AOSP product replaces Launcher3 and the stock SystemUI APK with
  Phantom implementations so Phantom owns the display.
- Linux builds run a Lattice Wayland compositor. It creates a new Wayland
  socket, hosts XDG toplevels, forwards seat input, and composites the focused
  surface. Phantom chrome around hosted surfaces is the next integration step.

The [`aosp/`](aosp/) directory mirrors only files that belong in an AOSP
checkout (`device/`, `frameworks/`, and `vendor/`). Build-host setup and
Cuttlefish runtime policy belong to the downstream Android fork.

Build the production Genesis shell from its checkout:

```sh
cd /home/ross/genesis
zig build -Dtarget=aarch64-linux-android.24 --release=safe
```

Run the compositor nested under an existing Wayland session or directly from a
TTY where Lattice can acquire KMS:

```sh
zig build run
```

The compositor prints its `WAYLAND_DISPLAY` name. Start a client against that
socket to map it into the shell.
