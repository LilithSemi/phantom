//! Open a URI through the desktop portal on Linux.
//!
//! The portal is preferable to starting `xdg-open`: it works in sandboxed
//! applications, is native to Wayland desktops, and does not require a shell or
//! a child-process lifetime policy from the embedding application.

const std = @import("std");
const dbus = @import("dbus");
const platform = @import("platform.zig");

const portal_name = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const portal_interface = "org.freedesktop.portal.OpenURI";

pub const Opener = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    session_bus_address: ?[]const u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, session_bus_address: ?[]const u8) Opener {
        return .{ .gpa = gpa, .io = io, .session_bus_address = session_bus_address };
    }

    pub fn asPlatform(self: *Opener) platform.Platform {
        return .{ .ctx = self, .open_url = openUrl };
    }

    fn openUrl(ctx: *anyopaque, url: []const u8, mode: platform.OpenMode) bool {
        const self: *Opener = @ptrCast(@alignCast(ctx));
        // A native application has no tabs of its own. Both modes therefore
        // mean handing the URI to the user's browser; the distinction remains
        // meaningful on the web backend only.
        _ = mode;
        return self.open(url) catch false;
    }

    fn open(self: *Opener, url: []const u8) !bool {
        var loop = try dbus.event_loop.EventLoop.init(self.gpa);
        defer loop.deinit();

        const bus = try self.connect(&loop);
        defer bus.deinit();

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        try marshalOpenUriBody(self.gpa, &body, bus.conn.endian, url);

        var reply: PortalReply = .{};
        _ = try bus.call(.{
            .msg_type = .method_call,
            .serial = 0,
            .path = portal_path,
            .interface = portal_interface,
            .member = "OpenURI",
            .destination = portal_name,
            .body_signature = "ssa{sv}",
            .body = body.items,
        }, PortalReply.onReply, &reply);

        // Calling the hook is synchronous, as it is on web and Android. Wait
        // for the portal to accept the request, but put a bound on a broken bus
        // so a click cannot freeze the application indefinitely.
        var attempts: usize = 0;
        while (!reply.done and attempts < 100) : (attempts += 1) {
            _ = loop.dispatch(50);
        }
        return reply.accepted;
    }

    fn connect(self: *Opener, loop: *dbus.event_loop.EventLoop) !*dbus.client.Bus {
        const uid = std.os.linux.getuid();

        if (self.session_bus_address) |raw| {
            if (dbus.address.parse(self.gpa, raw)) |parsed| {
                var addresses = parsed;
                defer addresses.deinit(self.gpa);
                for (addresses.items) |address| {
                    if (address.kind != .unix) continue;
                    if (address.path) |path| {
                        if (dbus.client.Bus.connectUnix(self.gpa, loop, self.io, path, false, uid)) |bus| return bus else |_| {}
                    }
                    if (address.abstract) |name| {
                        if (dbus.client.Bus.connectUnix(self.gpa, loop, self.io, name, true, uid)) |bus| return bus else |_| {}
                    }
                }
            } else |_| {}
        }

        // This is the standard session-bus address when the environment did
        // not provide one (systemd user sessions use it).
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/run/user/{d}/bus", .{uid});
        return dbus.client.Bus.connectUnix(self.gpa, loop, self.io, path, false, uid);
    }
};

const PortalReply = struct {
    done: bool = false,
    accepted: bool = false,

    fn onReply(ctx: ?*anyopaque, conn: *dbus.connection.Connection, reply: ?*const dbus.Message) void {
        _ = conn;
        const self: *PortalReply = @ptrCast(@alignCast(ctx.?));
        defer self.done = true;
        const message = reply orelse return;
        if (message.msg_type != .method_return) return;

        // OpenURI returns the object path of its Request. Parsing it also
        // rejects a malformed method return instead of reporting success merely
        // because some message arrived.
        var reader = dbus.Reader.init(message.body, message.endian);
        const request_path = reader.objectPath() catch return;
        self.accepted = request_path.len != 0 and request_path[0] == '/';
    }
};

fn marshalOpenUriBody(
    gpa: std.mem.Allocator,
    body: *std.ArrayList(u8),
    endian: std.builtin.Endian,
    url: []const u8,
) !void {
    var writer = dbus.Writer.init(gpa, body, endian);
    try writer.string(""); // No parent window identifier is portable here.
    try writer.string(url);
    const options = try writer.beginArray(8);
    writer.endArray(options); // No options.
}

test "OpenURI body contains an empty parent, the URL, and an empty options dictionary" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    try marshalOpenUriBody(std.testing.allocator, &body, .little, "https://example.com/docs?q=zig");

    var reader = dbus.Reader.init(body.items, .little);
    try std.testing.expectEqualStrings("", try reader.string());
    try std.testing.expectEqualStrings("https://example.com/docs?q=zig", try reader.string());
    const options = try reader.readValue(std.testing.allocator, "a{sv}");
    defer dbus.unmarshal.freeValue(std.testing.allocator, options);
    try std.testing.expectEqual(@as(usize, 0), options.array.len);
}
