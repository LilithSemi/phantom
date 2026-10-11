const phantom = @import("phantom");
const gallery = @import("../app.zig");

pub fn build(b: *phantom.BuildContext) phantom.Widget {
    const theme = phantom.Theme.of(b);
    const link = b.new(phantom.Link{
        .url = "https://ziglang.org",
        .child = gallery.text(b, "Open ziglang.org in a new tab", .{ .color = theme.accent }),
    });
    return gallery.page(b, "Actions", &.{
        gallery.section(b, "Buttons in the primary and secondary variants", b.new(Counter{}).widget()),
        gallery.section(b, "A Link opens a url through the platform", link.widget()),
        gallery.section(b, "A GestureDetector makes any widget tappable", b.new(TapBox{}).widget()),
    });
}

const Counter = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        count: i32 = 0,

        fn add(s: *State) void {
            s.count += 1;
        }

        fn subtract(s: *State) void {
            s.count -= 1;
        }

        fn onAdd(ctx: *anyopaque) void {
            phantom.setState(@as(*State, @ptrCast(@alignCast(ctx))), add);
        }

        fn onSubtract(ctx: *anyopaque) void {
            phantom.setState(@as(*State, @ptrCast(@alignCast(ctx))), subtract);
        }

        pub fn build(s: *State, b: *phantom.BuildContext) anyerror!phantom.Widget {
            const minus = b.new(phantom.Button{
                .variant = .secondary,
                .on_tap = onSubtract,
                .ctx = s,
                .child = buttonLabel(b, "Subtract"),
            });
            const plus = b.new(phantom.Button{
                .on_tap = onAdd,
                .ctx = s,
                .child = buttonLabel(b, "Add"),
            });
            const disabled = b.new(phantom.Button{
                .enabled = false,
                .child = buttonLabel(b, "Disabled"),
            });
            return gallery.spacedRow(b, 16, .center, &.{
                minus.widget(),
                gallery.text(b, gallery.format(b, "{d}", .{s.count}), .{ .size = 32 }),
                plus.widget(),
                disabled.widget(),
            });
        }
    };

    pub fn widget(self: *const Counter) phantom.Widget {
        return phantom.StatefulWidget(Counter, self);
    }
};

fn buttonLabel(b: *phantom.BuildContext, label: []const u8) phantom.Widget {
    return b.new(phantom.Padding{
        .insets = .symmetric(16, 8),
        .child = gallery.text(b, label, .{ .size = 18 }),
    }).widget();
}

const TapBox = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        taps: u32 = 0,

        fn tap(s: *State) void {
            s.taps += 1;
        }

        fn onTap(ctx: *anyopaque) void {
            phantom.setState(@as(*State, @ptrCast(@alignCast(ctx))), tap);
        }

        pub fn build(s: *State, b: *phantom.BuildContext) anyerror!phantom.Widget {
            const theme = phantom.Theme.of(b);
            const label = if (s.taps == 0) "Tap this box" else gallery.format(b, "Tapped {d} times", .{s.taps});
            const box = b.new(phantom.SizedBox{
                .width = 240,
                .height = 96,
                .child = b.new(phantom.DecoratedBox{
                    .color = theme.colors.purple_dark,
                    .radius = 12,
                    .child = b.new(phantom.Center(.{
                        .child = gallery.text(b, label, .{ .color = theme.colors.bg_dark }),
                    })).widget(),
                }).widget(),
            });
            return b.new(phantom.GestureDetector{ .on_tap = onTap, .ctx = s, .child = box.widget() }).widget();
        }
    };

    pub fn widget(self: *const TapBox) phantom.Widget {
        return phantom.StatefulWidget(TapBox, self);
    }
};
