const std = @import("std");
const phantom = @import("phantom");

const AndroidSystemAction = enum(u8) {
    none = 0,
    back = 1,
    home = 2,
};

var pending_android_system_action: std.atomic.Value(u8) = .init(@backingInt(AndroidSystemAction.none));
var android_action_context: u8 = 0;

pub fn root(b: *phantom.BuildContext) phantom.Widget {
    const theme = phantom.Theme.of(b);
    const media = phantom.MediaQuery.of(b);
    const safe = media.view_padding;

    const status = bar(b, "Phantom", "Connected  10:42", 36, theme.colors.bg_dark);
    const workspace_view = workspace(b);
    const dock = bar(b, "Applications", "Workspace 1", 64, theme.colors.bg_medium);
    const body = b.new(phantom.Column(.{ .children = b.newSlice(phantom.Widget, &.{
        status,
        b.new(phantom.Expanded(.{ .child = workspace_view })).widget(),
        dock,
    }) })).widget();

    return b.new(phantom.DecoratedBox{
        .color = theme.colors.bg,
        .child = b.new(phantom.Padding{ .insets = safe, .child = body }).widget(),
    }).widget();
}

/// Android hosts three independent Phantom surfaces: the HOME content and the
/// persistent status and navigation windows above application tasks. Linux
/// continues to use `root`, which includes all shell chrome in one compositor.
pub fn androidRoot(role: i32) phantom.Root {
    return switch (role) {
        1 => phantom.Root.plain(androidStatusRoot),
        2 => phantom.Root.plain(androidNavigationRoot),
        else => phantom.Root.plain(androidHomeRoot),
    };
}

pub fn takeAndroidSystemAction() i32 {
    return pending_android_system_action.swap(
        @backingInt(AndroidSystemAction.none),
        .acq_rel,
    );
}

fn androidHomeRoot(b: *phantom.BuildContext) phantom.Widget {
    return workspace(b);
}

fn androidStatusRoot(b: *phantom.BuildContext) phantom.Widget {
    const theme = phantom.Theme.of(b);
    return bar(b, "Phantom", "Connected  10:42", 36, theme.colors.bg_dark);
}

fn requestBack(_: *anyopaque) void {
    pending_android_system_action.store(@backingInt(AndroidSystemAction.back), .release);
}

fn requestHome(_: *anyopaque) void {
    pending_android_system_action.store(@backingInt(AndroidSystemAction.home), .release);
}

fn androidNavigationRoot(b: *phantom.BuildContext) phantom.Widget {
    const theme = phantom.Theme.of(b);
    const back = b.new(phantom.Button{
        .variant = .secondary,
        .padding = .symmetric(20, 10),
        .on_tap = requestBack,
        .ctx = &android_action_context,
        .child = b.new(phantom.Text{ .text = "Back", .font = theme.body_bold_font, .size = 14 }).widget(),
    });
    const home = b.new(phantom.Button{
        .variant = .secondary,
        .padding = .symmetric(20, 10),
        .on_tap = requestHome,
        .ctx = &android_action_context,
        .child = b.new(phantom.Text{ .text = "Home", .font = theme.body_bold_font, .size = 14 }).widget(),
    });
    return b.new(phantom.DecoratedBox{
        .color = theme.colors.bg_medium,
        .child = b.new(phantom.Row(.{
            .main = .space_evenly,
            .cross = .center,
            .children = b.newSlice(phantom.Widget, &.{ back.widget(), home.widget() }),
        })).widget(),
    }).widget();
}

fn workspace(b: *phantom.BuildContext) phantom.Widget {
    const theme = phantom.Theme.of(b);
    const compact = phantom.MediaQuery.of(b).size.width < 500;
    return b.new(phantom.DecoratedBox{
        .color = phantom.Color.rgb(0.055, 0.07, 0.12),
        .child = b.new(phantom.Align{
            .alignment = .center,
            .child = b.new(phantom.Column(.{
                .main = .center,
                .cross = .center,
                .main_size = .min,
                .children = b.newSlice(phantom.Widget, &.{
                    b.new(phantom.Text{
                        .text = "Phantom Shell",
                        .font = theme.heading_font,
                        .size = if (compact) 28 else 42,
                        .color = theme.colors.fg_primary,
                    }).widget(),
                    b.new(phantom.Padding{
                        .insets = .{ .top = 12 },
                        .child = b.new(phantom.Text{
                            .text = if (compact)
                                "Android + Wayland system shell"
                            else
                                "Phantom system UI + standalone Wayland compositor",
                            .size = if (compact) 12 else 17,
                            .color = theme.colors.fg_muted,
                        }).widget(),
                    }).widget(),
                }),
            })).widget(),
        }).widget(),
    }).widget();
}

fn bar(
    b: *phantom.BuildContext,
    left: []const u8,
    right: []const u8,
    height: f32,
    color: phantom.Color,
) phantom.Widget {
    const theme = phantom.Theme.of(b);
    const row = b.new(phantom.Row(.{
        .main = .space_between,
        .cross = .center,
        .children = b.newSlice(phantom.Widget, &.{
            b.new(phantom.Text{ .text = left, .font = theme.body_bold_font, .size = 15 }).widget(),
            b.new(phantom.Text{ .text = right, .size = 14, .color = theme.colors.fg_muted }).widget(),
        }),
    })).widget();
    return b.new(phantom.SizedBox{
        .height = height,
        .child = b.new(phantom.DecoratedBox{
            .color = color,
            .child = b.new(phantom.Padding{ .insets = .symmetric(18, 0), .child = row }).widget(),
        }).widget(),
    }).widget();
}

pub fn main(init: std.process.Init) !void {
    try phantom.App.runWithId(init, phantom.Root.plain(root), "org.phantom.shell");
}
