//! Responsive application navigation. Wide views keep navigation beside the
//! body; compact views put it in a modal drawer opened from a top app bar.

const std = @import("std");
const phantom = @import("../../phantom.zig");
const Widget = phantom.Widget;
const BuildContext = phantom.BuildContext;

pub const NavigationScaffold = struct {
    /// Builders are retained by the scaffold state, so their context must
    /// outlive the scaffold. Rebuilding the children on every state change
    /// keeps frame-arena widget configs from escaping their frame.
    pub const Builder = struct {
        ctx: ?*anyopaque = null,
        build: *const fn (?*anyopaque, *BuildContext) Widget,

        fn call(self: Builder, b: *BuildContext) Widget {
            return self.build(self.ctx, b);
        }
    };

    body: Builder,
    navigation: Builder,
    title: Builder,
    breakpoint: f32 = 720,
    navigation_width: f32 = 224,
    app_bar_height: f32 = 56,

    pub fn widget(self: *const NavigationScaffold) Widget {
        return phantom.StatefulWidget(NavigationScaffold, self);
    }

    pub const State = struct {
        base: phantom.StateBase = .{},
        body: Builder = undefined,
        navigation: Builder = undefined,
        title: Builder = undefined,
        breakpoint: f32 = 720,
        navigation_width: f32 = 224,
        app_bar_height: f32 = 56,
        drawer_open: bool = false,

        pub fn initState(s: *State, config: *const NavigationScaffold) !void {
            s.configure(config);
        }

        pub fn didUpdateWidget(s: *State, config: *const NavigationScaffold) !void {
            s.configure(config);
            // Route changes normally update the shell. Do not carry an open
            // modal drawer onto the destination page.
            s.drawer_open = false;
        }

        fn configure(s: *State, config: *const NavigationScaffold) void {
            s.body = config.body;
            s.navigation = config.navigation;
            s.title = config.title;
            s.breakpoint = positiveOr(config.breakpoint, 720);
            s.navigation_width = positiveOr(config.navigation_width, 224);
            s.app_bar_height = @max(48, positiveOr(config.app_bar_height, 56));
        }

        fn positiveOr(value: f32, fallback: f32) f32 {
            return if (std.math.isFinite(value) and value > 0) value else fallback;
        }

        fn open(ctx: *anyopaque) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            phantom.setState(s, struct {
                fn mutate(state: *State) void {
                    state.drawer_open = true;
                }
            }.mutate);
        }

        fn close(ctx: *anyopaque) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            phantom.setState(s, struct {
                fn mutate(state: *State) void {
                    state.drawer_open = false;
                }
            }.mutate);
        }

        pub fn build(s: *State, b: *BuildContext) anyerror!Widget {
            const media = phantom.MediaQuery.of(b);
            const width = media.size.width;
            const body = s.body.call(b);
            const navigation = s.navigation.call(b);
            const title = s.title.call(b);
            if (width >= s.breakpoint) return s.buildWide(b, body, navigation, media.view_padding);
            return s.buildCompact(b, width, body, navigation, title, media.view_padding);
        }

        fn buildWide(s: *State, b: *BuildContext, body: Widget, navigation: Widget, safe: phantom.LogicalEdgeInsets) Widget {
            const navigation_box = b.new(phantom.SizedBox{
                .width = s.navigation_width,
                .child = b.new(phantom.Padding{
                    .insets = .{ .left = safe.left, .top = safe.top, .bottom = safe.bottom },
                    .child = navigation,
                }).widget(),
            });
            return b.new(phantom.Row(.{ .children = b.newSlice(Widget, &.{
                navigation_box.widget(),
                b.new(phantom.Expanded(.{
                    .child = b.new(phantom.Padding{
                        .insets = .{ .top = safe.top, .right = safe.right, .bottom = safe.bottom },
                        .child = body,
                    }).widget(),
                })).widget(),
            }) })).widget();
        }

        fn buildCompact(s: *State, b: *BuildContext, viewport_width: f32, body: Widget, navigation: Widget, title: Widget, safe: phantom.LogicalEdgeInsets) Widget {
            const theme = phantom.Theme.of(b);
            const menu_icon = b.new(phantom.Icon{
                .id = .menu,
                .size = 22,
                .color = theme.colors.fg_primary,
                .label = "Open navigation",
            });
            const menu_button = b.new(phantom.Button{
                .variant = .secondary,
                .on_tap = open,
                .ctx = s,
                .id = "navigation-menu",
                .child = menu_icon.widget(),
            });
            const bar = b.new(phantom.SizedBox{
                .height = s.app_bar_height + safe.top,
                .child = b.new(phantom.DecoratedBox{
                    .color = theme.colors.bg_dark,
                    .child = b.new(phantom.Padding{
                        .insets = .{ .left = safe.left, .top = safe.top, .right = safe.right },
                        .child = b.new(phantom.Row(.{
                            .cross = .center,
                            .children = b.newSlice(Widget, &.{
                                menu_button.widget(),
                                b.new(phantom.Expanded(.{
                                    .child = b.new(phantom.Padding{
                                        .insets = .{ .left = 4, .right = 16 },
                                        .child = title,
                                    }).widget(),
                                })).widget(),
                            }),
                        })).widget(),
                    }).widget(),
                }).widget(),
            });
            const base = b.new(phantom.Column(.{ .children = b.newSlice(Widget, &.{
                bar.widget(),
                b.new(phantom.Expanded(.{
                    .child = b.new(phantom.Padding{
                        .insets = .{ .left = safe.left, .right = safe.right, .bottom = safe.bottom },
                        .child = body,
                    }).widget(),
                })).widget(),
            }) }));
            if (!s.drawer_open) return base.widget();

            const scrim = b.new(phantom.GestureDetector{
                .on_tap = close,
                .ctx = s,
                .child = b.new(phantom.ColoredBox{
                    .color = .{ .r = 0, .g = 0, .b = 0, .a = 0.58 },
                }).widget(),
            });
            const drawer_width = @max(0, @min(s.navigation_width, viewport_width - 48));
            const drawer = b.new(phantom.SizedBox{
                .width = drawer_width,
                .child = b.new(phantom.Padding{
                    .insets = .{ .left = safe.left, .top = safe.top, .bottom = safe.bottom },
                    .child = navigation,
                }).widget(),
            });
            return b.new(phantom.Stack{ .children = b.newSlice(Widget, &.{
                base.widget(),
                b.new(phantom.Positioned{
                    .top = 0,
                    .right = 0,
                    .bottom = 0,
                    .left = 0,
                    .child = scrim.widget(),
                }).widget(),
                b.new(phantom.Positioned{
                    .top = 0,
                    .bottom = 0,
                    .left = 0,
                    .child = drawer.widget(),
                }).widget(),
            }) }).widget();
        }
    };
};

test "NavigationScaffold validates dimensions and drawer transitions" {
    var state = NavigationScaffold.State{};
    const buildBox = struct {
        fn build(_: ?*anyopaque, b: *BuildContext) Widget {
            return b.new(phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 0) }).widget();
        }
    }.build;
    const config = NavigationScaffold{
        .body = .{ .build = buildBox },
        .navigation = .{ .build = buildBox },
        .title = .{ .build = buildBox },
        .breakpoint = -1,
        .navigation_width = std.math.nan(f32),
        .app_bar_height = 20,
    };
    state.configure(&config);
    try std.testing.expectEqual(@as(f32, 720), state.breakpoint);
    try std.testing.expectEqual(@as(f32, 224), state.navigation_width);
    try std.testing.expectEqual(@as(f32, 48), state.app_bar_height);
}

test "compact NavigationScaffold opens from the app bar and closes from the scrim" {
    const buildBox = struct {
        fn build(_: ?*anyopaque, b: *BuildContext) Widget {
            return b.new(phantom.ColoredBox{ .color = phantom.Color.rgb(0.1, 0.1, 0.1) }).widget();
        }
    }.build;
    var scaffold = NavigationScaffold{
        .body = .{ .build = buildBox },
        .navigation = .{ .build = buildBox },
        .title = .{ .build = buildBox },
    };
    var media = phantom.MediaQueryData{
        .size = .{ .width = 360, .height = 640 },
        .dpr = 1,
    };
    var query = phantom.MediaQuery{ .data = &media, .child = scaffold.widget() };
    var h = try phantom.testing.mount(std.testing.allocator, query.widget());
    defer h.deinit();
    h.viewport = media.size;
    try h.pump();

    const state = try h.stateOf(phantom.testing.find.byType(NavigationScaffold), NavigationScaffold.State);
    try std.testing.expect(!state.drawer_open);
    h.tapAt(.{ .x = 24, .y = 24 });
    try std.testing.expect(state.drawer_open);
    try h.pump();
    try h.expect(phantom.testing.find.byType(phantom.Stack), .found);

    h.tapAt(.{ .x = 320, .y = 100 });
    try std.testing.expect(!state.drawer_open);
    try h.pump();
    try h.expectNoFaults();
}
