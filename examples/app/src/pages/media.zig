const std = @import("std");
const phantom = @import("phantom");
const gallery = @import("../app.zig");

const logo_png = @embedFile("../logo.png");
// A downscaled copy of a 6512x4341 progressive JPEG. The full image is too
// heavy to embed and upload as a texture.
const wallpaper_png = @embedFile("../wallpaper.png");

pub fn build(b: *phantom.BuildContext) phantom.Widget {
    return gallery.page(b, "Media", &.{
        gallery.section(b, "Image decodes a PNG and scales it to the size it is given", images(b)),
        gallery.section(b, "Icon draws every built-in mark in the theme colour", icons(b)),
    });
}

fn images(b: *phantom.BuildContext) phantom.Widget {
    return gallery.spacedRow(b, 24, .center, &.{
        b.new(phantom.Image{ .bytes = logo_png, .width = 32, .height = 32 }).widget(),
        b.new(phantom.Image{ .bytes = logo_png, .width = 96, .height = 96 }).widget(),
        b.new(phantom.Image{ .bytes = wallpaper_png, .width = 360, .height = 240 }).widget(),
    });
}

fn icons(b: *phantom.BuildContext) phantom.Widget {
    const c = phantom.Theme.of(b).colors;
    const ids = std.meta.tags(phantom.icon.Id);
    var tiles: [ids.len]phantom.Widget = undefined;
    for (ids, &tiles) |id, *out| {
        const icon = b.new(phantom.Icon{ .id = id, .size = 32, .label = @tagName(id) });
        const column = b.new(phantom.Column(.{ .cross = .center, .children = b.newSlice(phantom.Widget, &.{
            b.new(phantom.Padding{ .insets = .{ .bottom = 6 }, .child = icon.widget() }).widget(),
            gallery.text(b, @tagName(id), .{ .size = 13, .color = c.fg_muted }),
        }) }));
        // A column of open height is as wide as its widest child, so Center
        // puts it in the middle of the tile.
        const centered = b.new(phantom.Center(.{ .child = column.widget() }));
        out.* = b.new(phantom.SizedBox{ .width = 120, .child = centered.widget() }).widget();
    }
    // Rows of five keep the grid inside a narrow window.
    const per_row = 5;
    var rows: [(ids.len + per_row - 1) / per_row]phantom.Widget = undefined;
    for (&rows, 0..) |*row, i| {
        const start = i * per_row;
        row.* = b.new(phantom.Row(.{ .children = b.newSlice(phantom.Widget, tiles[start..@min(start + per_row, ids.len)]) })).widget();
    }
    return gallery.spacedColumn(b, 16, &rows);
}
