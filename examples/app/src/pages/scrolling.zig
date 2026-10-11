const phantom = @import("phantom");
const gallery = @import("../app.zig");

pub fn build(b: *phantom.BuildContext) phantom.Widget {
    return gallery.page(b, "Scrolling", &.{
        gallery.section(b, "A vertical ScrollView of 100 rows", verticalList(b)),
        gallery.section(b, "A ListView of 10,000 rows that builds only what shows", lazyList(b)),
        gallery.section(b, "A horizontal ScrollView", horizontalStrip(b)),
        gallery.section(b, "A GridView of coloured tiles that scrolls on its own", grid(b)),
    });
}

/// A scroll view fills the box it gets, so one inside a page needs a box of
/// fixed size or it would take the whole page.
fn bounded(b: *phantom.BuildContext, width: f32, height: f32, child: phantom.Widget) phantom.Widget {
    const theme = phantom.Theme.of(b);
    return b.new(phantom.SizedBox{
        .width = width,
        .height = height,
        .child = b.new(phantom.DecoratedBox{
            .color = theme.colors.bg_dark,
            .radius = 8,
            .border_color = theme.colors.fg_dim,
            .border_width = 1,
            .child = b.new(phantom.ClipRRect{ .radius = 8, .child = child }).widget(),
        }).widget(),
    }).widget();
}

fn verticalList(b: *phantom.BuildContext) phantom.Widget {
    const theme = phantom.Theme.of(b);
    var rows: [100]phantom.Widget = undefined;
    for (&rows, 1..) |*row, i| {
        const color = if (i % 2 == 0) theme.colors.fg_primary else theme.colors.fg_muted;
        row.* = b.new(phantom.Padding{
            .insets = .symmetric(12, 4),
            .child = gallery.text(b, gallery.format(b, "Row {d}", .{i}), .{ .size = 18, .color = color }),
        }).widget();
    }
    const column = b.new(phantom.Column(.{ .children = b.newSlice(phantom.Widget, &rows) }));
    return bounded(b, 320, 240, b.new(phantom.ScrollView{ .child = column.widget() }).widget());
}

/// Ten thousand rows of three heights. Only the rows near the view are built.
fn lazyList(b: *phantom.BuildContext) phantom.Widget {
    const list = b.new(phantom.ListView{ .count = 10_000, .builder = lazyRow });
    return bounded(b, 320, 240, list.widget());
}

fn lazyRow(_: *anyopaque, b: *phantom.BuildContext, index: usize) phantom.Widget {
    const theme = phantom.Theme.of(b);
    const step: f32 = @floatFromInt(index % 3);
    const color = if (index % 2 == 0) theme.colors.fg_primary else theme.colors.fg_muted;
    return b.new(phantom.Padding{
        .insets = .symmetric(12, 4 + step * 10),
        .child = gallery.text(b, gallery.format(b, "Row {d}", .{index + 1}), .{ .size = 18, .color = color }),
    }).widget();
}

fn horizontalStrip(b: *phantom.BuildContext) phantom.Widget {
    const c = phantom.Theme.of(b).colors;
    const palette = [_]phantom.Color{ c.blue, c.cyan, c.teal, c.green, c.yellow, c.orange, c.red, c.purple };
    var cards: [24]phantom.Widget = undefined;
    for (&cards, 0..) |*card, i| {
        const box = b.new(phantom.DecoratedBox{
            .color = palette[i % palette.len],
            .radius = 10,
            .child = b.new(phantom.SizedBox{
                .width = 96,
                .height = 72,
                .child = b.new(phantom.Center(.{
                    .child = gallery.text(b, gallery.format(b, "{d}", .{i + 1}), .{ .size = 22, .color = c.bg_dark }),
                })).widget(),
            }).widget(),
        });
        card.* = b.new(phantom.Padding{ .insets = .all(8), .child = box.widget() }).widget();
    }
    const row = b.new(phantom.Row(.{ .children = b.newSlice(phantom.Widget, &cards) }));
    return bounded(b, 480, 88, b.new(phantom.ScrollView{ .axis = .horizontal, .child = row.widget() }).widget());
}

fn grid(b: *phantom.BuildContext) phantom.Widget {
    const c = phantom.Theme.of(b).colors;
    const palette = [_]phantom.Color{ c.blue, c.cyan, c.teal, c.green, c.yellow, c.orange, c.red, c.purple };
    var tiles: [48]phantom.Widget = undefined;
    for (&tiles, 0..) |*tile, i| {
        const box = b.new(phantom.DecoratedBox{
            .color = palette[i % palette.len],
            .radius = 8,
            .child = b.new(phantom.Center(.{
                .child = gallery.text(b, gallery.format(b, "{d}", .{i + 1}), .{ .size = 18, .color = c.bg_dark }),
            })).widget(),
        });
        tile.* = box.widget();
    }
    const view = b.new(phantom.GridView{
        .columns = 6,
        .spacing = 8,
        .children = b.newSlice(phantom.Widget, &tiles),
    });
    return bounded(b, 480, 260, b.new(phantom.Padding{ .insets = .all(8), .child = view.widget() }).widget());
}
