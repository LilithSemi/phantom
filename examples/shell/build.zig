const std = @import("std");
const phantom = @import("phantom");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gpu_drivers = b.option([]const u8, "gpu-drivers", "Specific GPU drivers to enable");

    const phantom_dep = b.dependency("phantom", .{
        .target = target,
        .optimize = optimize,
        .@"gpu-drivers" = gpu_drivers,
    });

    if (target.result.abi.isAndroid()) {
        const app = phantom.addApp(b, phantom_dep, .{
            .id = "org.phantom.shell",
            .name = .{ .default = "Phantom Shell" },
            .summary = .{ .default = "A Phantom UI system shell prototype" },
            .description = .{ .default = "The shared Phantom shell surface used by Android SystemUI and the Wayland compositor." },
            .categories = &.{.system},
            .root = b.path("src/app.zig"),
            .developer = "Phantom UI",
            .license = "Apache-2.0",
            .android = .{
                .system_ui = .edge_to_edge,
                .home_screen = true,
                .system_shell = true,
                .permissions = &.{
                    .status_bar_service,
                    .internal_system_window,
                    .network_state,
                    .wifi_state,
                    .wifi_control,
                    .wifi_privileged,
                    .nearby_wifi,
                    .fine_location,
                    .bluetooth,
                    .bluetooth_scan,
                    .bluetooth_privileged,
                    .app_discovery,
                },
            },
            .target = target,
            .optimize = optimize,
        });
        b.getInstallStep().dependOn(app);
        return;
    }

    if (target.result.os.tag != .linux) {
        @panic("examples/shell currently supports Android and Linux");
    }

    const lattice_dep = b.dependency("lattice", .{
        .target = target,
        .optimize = optimize,
        .@"gpu-drivers" = gpu_drivers,
    });
    const exe = b.addExecutable(.{
        .name = "phantom-shell",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wayland.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("phantom", phantom_dep.module("phantom"));
    exe.root_module.addImport("lattice", lattice_dep.module("lattice"));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the Phantom Wayland compositor");
    run_step.dependOn(&run.step);
    b.getInstallStep().dependOn(&exe.step);
}
