//! Portable host state used by system surfaces such as control centres.
//!
//! These are deliberately value types. Linux can fill them from the system
//! D-Bus (UPower, NetworkManager and ModemManager), while Android can fill the
//! same shapes through its Java host bridge. A widget never has to import a
//! desktop daemon or an Android API.

pub const Connectivity = struct {
    pub const Transport = enum { none, ethernet, wifi, cellular };
    pub const Reachability = enum { disconnected, local, site, internet };

    transport: Transport = .none,
    reachability: Reachability = .disconnected,
    /// Percentage reported by the active radio, when one exists.
    strength: ?u8 = null,
    networking_enabled: bool = true,
    wifi_enabled: bool = false,
    /// Whether the host has a cellular/WWAN radio. This is independent of
    /// `cellular_enabled`: a disabled modem still needs a tile that can turn it
    /// back on, while a machine with no modem should not show one at all.
    cellular_available: bool = false,
    cellular_enabled: bool = false,
};

/// One Wi-Fi access point visible to the host. The strings are borrowed from
/// the platform backend and remain valid until the next scan.
pub const WifiNetwork = struct {
    pub const Security = enum { open, secured };
    id: []const u8,
    ssid: []const u8,
    strength: u8,
    security: Security,
    connected: bool = false,
};

/// One launchable application exposed by the host shell. Android uses an
/// explicit `package/class` component as `id`; desktop hosts may use a desktop
/// file id. The host owns all slices until its next catalog refresh.
pub const Application = struct {
    id: []const u8,
    name: []const u8,
    /// Encoded PNG supplied by the host, or empty when no icon was exported.
    icon_png: []const u8 = "",
    /// Encoded task/window preview supplied by a system shell host.
    preview_png: []const u8 = "",
    /// True when the host currently owns a live task/window for this app.
    running: bool = false,
};

pub const Bluetooth = struct {
    enabled: bool,
    available: bool = true,
    discovering: bool = false,
    connected_devices: u16 = 0,
    paired_devices: u16 = 0,
};

/// A notification posted by another application and visible to a system
/// shell. `key` is opaque and is only passed back to dismiss/invoke actions.
pub const SystemNotification = struct {
    key: []const u8,
    app_name: []const u8,
    title: []const u8,
    body: []const u8,
    posted_ms: i64,
    clearable: bool = true,
};

pub const Power = struct {
    pub const Status = enum { unknown, charging, discharging, full, empty, pending };

    /// False is a valid desktop answer. Null from `Platform.readPower` means
    /// that the backend cannot ask its host at all.
    present: bool = false,
    percent: u8 = 0,
    status: Status = .unknown,
    time_to_empty_s: ?u64 = null,
    time_to_full_s: ?u64 = null,
};

pub const Audio = struct {
    /// Normalized 0...1. Hosts clamp writes to this range.
    output_volume: f32,
    muted: bool,
};

pub const Brightness = struct {
    /// Normalized 0...1. Hosts clamp writes to this range.
    level: f32,
};

pub const SessionCapabilities = packed struct {
    lock: bool = false,
    logout: bool = false,
    can_suspend: bool = false,
    restart: bool = false,
    power_off: bool = false,
};

/// Human-facing identity for system chrome. The slices are owned by the host
/// and remain valid for the lifetime of its `Platform`.
pub const Identity = struct {
    /// Stable account/login name.
    user_name: []const u8,
    /// Human-facing name configured by the account provider.
    display_name: ?[]const u8 = null,
    /// Host path or URI for the account portrait, when one is configured.
    avatar: ?[]const u8 = null,
    system_name: []const u8,
};
