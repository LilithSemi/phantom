//! The build time host that renders routes of a web app to static pages.
//!
//! `addWebDist` builds this file for the build machine, with the consumer's
//! source as `app_root`, and runs it once. The arguments are the shell page,
//! the output directory, the manifest file, and then each route.
//! `phantom.ssr.writePage` writes each page with its stylesheet and font
//! files. The manifest lists every file written, one path a line, relative to
//! the output directory.

const std = @import("std");
const phantom = @import("phantom");
const app_root = @import("app_root");
const options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) return error.MissingArgument;

    const cwd = std.Io.Dir.cwd();
    const shell = try cwd.readFileAlloc(io, args[1], gpa, .limited(1 << 20));
    defer gpa.free(shell);

    try cwd.createDirPath(io, args[2]);
    var out = try cwd.openDir(io, args[2], .{});
    defer out.close(io);

    var written: phantom.ssr.Written = .{};
    defer written.deinit(gpa);
    for (args[4..]) |route| {
        try renderRoute(gpa, io, out, shell, route, &written);
    }

    var manifest: std.Io.Writer.Allocating = .init(gpa);
    defer manifest.deinit();
    for (written.paths.keys()) |path| {
        try manifest.writer.print("{s}\n", .{path});
    }
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = manifest.written() });
}

fn renderRoute(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: std.Io.Dir,
    shell: []const u8,
    route: []const u8,
    written: *phantom.ssr.Written,
) !void {
    // The live `.path` strategy reads the full pathname, base included.
    const path = try std.mem.concat(gpa, u8, &.{ options.base_path, std.mem.trim(u8, route, "/") });
    defer gpa.free(path);
    try phantom.ssr.writePage(gpa, out, shell, .{
        .root = phantom.Root.plain(app_root.root),
        .path = path,
        .viewport = .{ .width = @floatFromInt(options.width), .height = @floatFromInt(options.height) },
        .base = options.base_path,
        .io = io,
    }, written);
}
