const std = @import("std");
const phantom = @import("phantom");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gpu_drivers: ?[]const u8 = b.option([]const u8, "gpu-drivers", "Specific GPU drivers to enable, defaults to Phantom's choice.") orelse null;

    const phantom_dep = b.dependency("phantom", .{
        .target = target,
        .optimize = optimize,
        .@"gpu-drivers" = gpu_drivers,
    });

    const background_service = b.option(bool, "background-service", "Package the Android background-service example") orelse false;
    const service_mod = b.createModule(.{
        .root_source_file = b.path("src/background.zig"),
        .target = target,
        .optimize = optimize,
    });
    const android: phantom.AndroidOptions = .{
        .permissions = if (background_service) &.{.notifications} else &.{},
        .background_service = if (background_service) .{
            .module = service_mod,
            .notification_title = "Phantom Demo",
        } else null,
    };

    const app = phantom.addApp(b, phantom_dep, .{
        .id = "org.example.phantom.demo",
        .name = .{ .default = "Phantom Demo" },
        .summary = .{ .default = "A gallery of every PhantomUI widget" },
        .description = .{ .default = "Every widget PhantomUI has, one page per category, with live examples." },
        .categories = &.{.utility},
        .root = b.path("src/app.zig"),
        .developer = "Example Developer",
        .license = "Apache-2.0",
        .icons = &.{},
        .android = android,
        .target = target,
        .optimize = optimize,
        .url_strategy = .path,
        .prerender_routes = &.{ "/", "/text", "/input", "/actions", "/layout", "/decoration", "/media", "/scrolling" },
    });

    b.getInstallStep().dependOn(app);
}
