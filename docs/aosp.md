# AOSP integration

This payload creates Android 17 ARM64-only and x86_64-only Cuttlefish products
named `phantom_cf_arm64_only_phone` and `phantom_cf_x86_64_only_phone`. Each
installs the matching Genesis release APK as a platform-signed privileged app.
The supplied shell provider overrides Launcher3 and is the product's sole HOME
implementation. Genesis is the default provider for this development image. The product
also replaces AOSP's large SystemUI APK with `PhantomSystemUI`, a minimal
framework entry service that handles protected Back, Home, and shell-menu
requests and holds an important binding to the active HOME package's Phantom
shell service. It
discovers that service through the package-neutral
`org.phantomui.intent.action.SYSTEM_SHELL` contract. The stock SystemUI Dagger
graph and UI startables are not built for this product. Genesis, rendered by Phantom, owns the full
display and draws the replacement shell chrome. Each enabled shell bar window
publishes its corresponding Android inset source. Genesis enables only its
status surface; the invisible gesture target does not reserve bottom space.

The bridge also installs a transparent bottom-edge gesture target without
drawing or reserving space for a navigation bar. Horizontal swipes issue Back,
upward swipes issue Home, and an upward hold opens the active shell's menu.

The same bridge discovers the active shell's notification-listener component,
grants listener access, and grants only the runtime radio permissions declared
by that HOME package. This enables received notifications, Android application
discovery, task-snapshot overview and launching, Wi-Fi control/scanning/connection,
and Bluetooth state and control without embedding a Genesis package name in
AOSP.

The [`examples/shell/aosp/`](../examples/shell/aosp/) tree is laid out from the
AOSP checkout root. It intentionally contains only Android source-tree files:

- `device/` defines the Phantom Cuttlefish products and product overlays.
- `frameworks/` contains the minimal Phantom SystemUI implementation.
- `vendor/` defines the shell-provider prebuilt consumed by a product.

Integrate those paths in the corresponding repositories of an Android fork.
Host setup, compatibility patches, image deployment, and Cuttlefish launch
scripts are deliberately downstream concerns and are not shipped here.

Build a provider such as Genesis for the product architecture, then place its
APK at `vendor/phantom/shell/shell-provider.apk` in the Android source tree:

```sh
cd /home/ross/genesis
zig build -Dtarget=aarch64-linux-android.24 --release=safe # ARM64 guest
# Or, for an x86_64 guest:
zig build -Dtarget=x86_64-linux-android.24 --release=safe
install -m 0644 zig-out/bin/genesis-shell-release.apk \
  /path/to/aosp/vendor/phantom/shell/shell-provider.apk
```

Then, from a supported AOSP build environment:

```sh
cd /home/ross/aosp
source build/envsetup.sh
lunch phantom_cf_arm64_only_phone-trunk_staging-userdebug
m -j24
```

Use `phantom_cf_x86_64_only_phone-trunk_staging-userdebug` instead on an
x86_64 host so Cuttlefish can use KVM rather than emulate ARM instructions.

The resulting device images are written to
`out/target/product/vsoc_arm64_only/` or
`out/target/product/vsoc_x86_64_only/`, according to the lunch target. ARM64
images need an ARM64 host package; the x86_64 product can use KVM on an x86_64
host.

For a transferable ARM64-host test bundle, also run:

```sh
m -j24 dist
```

The two files needed on the ARM64 test machine are:

- `out/dist/cvd-host_package.tar.gz` — ARM64 Cuttlefish host tools, including
  `qemu-system-aarch64`
- `out/dist/phantom_cf_arm64_only_phone-img-<build-user>.zip` — the boot,
  super, userdata, and verified-boot images (this checkout produced the
  `-ross.zip` suffix)

(`cvd-host_package-x86_64.tar.gz` is the package for this build machine, not
the ARM64 test host.) Unpack both payloads into one empty directory on the ARM
machine and launch through Cuttlefish's QEMU backend:

```sh
mkdir phantom-cvd && cd phantom-cvd
tar -xzf /path/to/cvd-host_package.tar.gz
unzip /path/to/phantom_cf_arm64_only_phone-img-ross.zip
HOME="$PWD" ./bin/launch_cvd --daemon --vm_manager=qemu_cli
```

This uses Cuttlefish to configure the Android virtual hardware and starts its
bundled QEMU directly. Omitting `--vm_manager=qemu_cli` lets Cuttlefish select
its default VMM instead.

The renderer remains a separate process intentionally. `PhantomSystemUI` is a
small lifecycle and privileged-action bridge, while the Phantom shell process
owns the surfaces. Framework contracts such as screenshots, lock screen, power
UI, and recents must be added deliberately as Phantom implementations rather
than retaining their stock visual implementations.
