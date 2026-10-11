const phantom = @import("phantom");
const gallery = @import("../app.zig");

const wallpaper_png = @embedFile("../wallpaper.png");

pub fn build(b: *phantom.BuildContext) phantom.Widget {
    return gallery.page(b, "Decoration", &.{
        gallery.section(b, "DecoratedBox paints a colour, a corner radius and a border behind its child", boxes(b)),
        gallery.section(b, "ClipRRect cuts its child to a rounded rectangle", clips(b)),
        gallery.section(b, "ColoredBox swatches of the theme colours", swatches(b)),
    });
}

fn decorated(
    b: *phantom.BuildContext,
    caption: []const u8,
    color: ?phantom.Color,
    radius: f32,
    border: ?phantom.Color,
) phantom.Widget {
    const box = b.new(phantom.DecoratedBox{
        .color = color,
        .radius = radius,
        .border_color = border,
        .border_width = if (border != null) 2 else 0,
        .child = b.new(phantom.SizedBox{
            .width = 140,
            .height = 80,
            .child = b.new(phantom.Center(.{ .child = gallery.text(b, caption, .{ .size = 16 }) })).widget(),
        }).widget(),
    });
    return box.widget();
}

fn boxes(b: *phantom.BuildContext) phantom.Widget {
    const c = phantom.Theme.of(b).colors;
    return gallery.spacedRow(b, 16, .center, &.{
        decorated(b, "colour", c.bg_medium, 0, null),
        decorated(b, "radius 16", c.bg_medium, 16, null),
        decorated(b, "border", null, 0, c.blue),
        decorated(b, "all three", c.bg_medium, 24, c.purple),
    });
}

fn clips(b: *phantom.BuildContext) phantom.Widget {
    const radii = [_]f32{ 0, 16, 60 };
    var images: [radii.len]phantom.Widget = undefined;
    for (radii, &images) |radius, *out| {
        const image = b.new(phantom.Image{ .bytes = wallpaper_png, .width = 180, .height = 120 });
        out.* = b.new(phantom.ClipRRect{ .radius = radius, .child = image.widget() }).widget();
    }
    return gallery.spacedRow(b, 16, .center, &images);
}

fn swatches(b: *phantom.BuildContext) phantom.Widget {
    const c = phantom.Theme.of(b).colors;
    const Named = struct { name: []const u8, color: phantom.Color };
    const named = [_]Named{
        .{ .name = "bg", .color = c.bg },
        .{ .name = "bg_medium", .color = c.bg_medium },
        .{ .name = "bg_dark", .color = c.bg_dark },
        .{ .name = "fg", .color = c.fg },
        .{ .name = "fg_muted", .color = c.fg_muted },
        .{ .name = "blue", .color = c.blue },
        .{ .name = "cyan", .color = c.cyan },
        .{ .name = "teal", .color = c.teal },
        .{ .name = "green", .color = c.green },
        .{ .name = "yellow", .color = c.yellow },
        .{ .name = "orange", .color = c.orange },
        .{ .name = "red", .color = c.red },
        .{ .name = "purple", .color = c.purple },
    };
    var tiles: [named.len]phantom.Widget = undefined;
    for (named, &tiles) |n, *out| {
        const box = b.new(phantom.SizedBox{
            .width = 96,
            .height = 56,
            .child = b.new(phantom.ColoredBox{ .color = n.color, .radius = 8 }).widget(),
        });
        out.* = gallery.spacedColumn(b, 4, &.{
            outlined(b, box.widget()),
            gallery.text(b, n.name, .{ .size = 14, .color = c.fg_muted }),
        });
    }
    // Two rows, so the swatches fit a narrow window.
    const half = named.len / 2 + 1;
    return gallery.spacedColumn(b, 16, &.{
        gallery.spacedRow(b, 12, .center, tiles[0..half]),
        gallery.spacedRow(b, 12, .center, tiles[half..]),
    });
}

/// The darkest swatches vanish on the page background, so each gets an outline.
fn outlined(b: *phantom.BuildContext, child: phantom.Widget) phantom.Widget {
    const c = phantom.Theme.of(b).colors;
    return b.new(phantom.DecoratedBox{
        .border_color = c.fg_dim,
        .border_width = 1,
        .radius = 8,
        .child = child,
    }).widget();
}
