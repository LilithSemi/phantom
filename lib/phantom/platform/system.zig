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
