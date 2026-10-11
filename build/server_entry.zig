//! The server binary of a web app, built by `zig build <exec>-server`. It
//! serves the dist directory of the app and renders each page request with
//! the app root.
//!
//! PHANTOM_SERVE_DIR is the dist directory (default "."), PHANTOM_SERVE_HOST
//! the address to bind (default every interface) and PHANTOM_SERVE_PORT the
//! port (default 8080), the same as the script servers.

const std = @import("std");
const phantom = @import("phantom");
const app_root = @import("app_root");
const options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const env = init.environ_map;
    const dir_path = env.get("PHANTOM_SERVE_DIR") orelse ".";
    const host = env.get("PHANTOM_SERVE_HOST") orelse "0.0.0.0";
    const port = if (env.get("PHANTOM_SERVE_PORT")) |text|
        std.fmt.parseInt(u16, text, 10) catch return error.InvalidPort
    else
        8080;

    var dist = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dist.close(io);

    var log_buf: [1024]u8 = undefined;
    var log = std.Io.File.stdout().writer(io, &log_buf);

    var server = try phantom.ssr.Server.init(init.gpa, io, .{
        .root = phantom.Root.plain(app_root.root),
        .shell = options.shell,
        .dist = dist,
        .base = options.base_path,
        .default_size = .{ .width = @floatFromInt(options.width), .height = @floatFromInt(options.height) },
        .hash_routes = options.strategy_is_hash,
        .log = &log.interface,
    });
    defer server.deinit();

    const address = try std.Io.net.IpAddress.parse(host, port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    try log.interface.print("phantom serve: http://localhost:{d}{s} serving {s}\n", .{ listener.socket.address.getPort(), options.base_path, dir_path });
    try log.interface.flush();
    try server.serve(&listener);
}
