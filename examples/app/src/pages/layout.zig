const phantom = @import("phantom");
const gallery = @import("../app.zig");

pub fn build(b: *phantom.BuildContext) phantom.Widget {
    return gallery.page(b, "Layout", &.{
        gallery.section(b, "Row spreads its children by its main alignment", rowAlignments(b)),
        gallery.section(b, "Row places children of different heights by its cross alignment", crossAlignments(b)),
        gallery.section(b, "Column does the same along the vertical axis", columnAlignments(b)),
        gallery.section(b, "Stack puts children on top of each other, Positioned pins them to an edge", stack(b)),
        gallery.section(b, "Align and Center move a child inside a bigger box", aligns(b)),
        gallery.section(b, "Padding adds space around its child", padding(b)),
        gallery.section(b, "SizedBox gives its child a fixed size", sizedBoxes(b)),
        gallery.section(b, "Expanded shares the free space by flex: 1, 2 and 3", expanded(b)),
    });
}

/// A thin outline that shows the bounds of a layout example.
fn frame(b: *phantom.BuildContext, child: phantom.Widget) phantom.Widget {
    const theme = phantom.Theme.of(b);
    return b.new(phantom.DecoratedBox{
        .border_color = theme.colors.fg_dim,
        .border_width = 1,
        .radius = 6,
        .child = child,
    }).widget();
}

fn label(b: *phantom.BuildContext, value: []const u8) phantom.Widget {
    const theme = phantom.Theme.of(b);
    return gallery.text(b, value, .{ .size = 14, .color = theme.colors.fg_muted });
}

fn rowAlignments(b: *phantom.BuildContext) phantom.Widget {
    const c = phantom.Theme.of(b).colors;
    const alignments = [_]phantom.MainAxisAlignment{ .start, .center, .end, .space_between, .space_around, .space_evenly };
    var rows: [alignments.len]phantom.Widget = undefined;
    for (alignments, &rows) |alignment, *out| {
        const row = b.new(phantom.Row(.{ .main = alignment, .children = b.newSlice(phantom.Widget, &.{
            gallery.swatch(b, c.blue, 48, 24),
            gallery.swatch(b, c.teal, 48, 24),
            gallery.swatch(b, c.green, 48, 24),
        }) }));
        out.* = gallery.spacedColumn(b, 4, &.{
            label(b, @tagName(alignment)),
            frame(b, row.widget()),
        });
    }
    return b.new(phantom.SizedBox{ .width = 480, .child = gallery.spacedColumn(b, 12, &rows) }).widget();
}

fn crossAlignments(b: *phantom.BuildContext) phantom.Widget {
    const c = phantom.Theme.of(b).colors;
    const alignments = [_]phantom.CrossAxisAlignment{ .start, .center, .end };
    var columns: [alignments.len]phantom.Widget = undefined;
    for (alignments, &columns) |alignment, *out| {
        const row = b.new(phantom.Row(.{ .cross = alignment, .main_size = .min, .children = b.newSlice(phantom.Widget, &.{
            gallery.swatch(b, c.orange, 32, 64),
            gallery.swatch(b, c.yellow, 32, 40),
            gallery.swatch(b, c.red, 32, 20),
        }) }));
        out.* = gallery.spacedColumn(b, 4, &.{ label(b, @tagName(alignment)), frame(b, row.widget()) });
    }
    return gallery.spacedRow(b, 24, .center, &columns);
}

fn columnAlignments(b: *phantom.BuildContext) phantom.Widget {
    const c = phantom.Theme.of(b).colors;
    const alignments = [_]phantom.MainAxisAlignment{ .start, .center, .end, .space_between };
    var columns: [alignments.len]phantom.Widget = undefined;
    for (alignments, &columns) |alignment, *out| {
        // A column fills a bounded height, so the SizedBox gives the main
        // alignment some free space to share.
        const column = b.new(phantom.Column(.{ .main = alignment, .cross = .center, .children = b.newSlice(phantom.Widget, &.{
            gallery.swatch(b, c.purple, 40, 24),
            gallery.swatch(b, c.cyan, 64, 24),
        }) }));
        const box = b.new(phantom.SizedBox{ .width = 100, .height = 140, .child = frame(b, column.widget()) });
        out.* = gallery.spacedColumn(b, 4, &.{ label(b, @tagName(alignment)), box.widget() });
    }
    return gallery.spacedRow(b, 16, .center, &columns);
}

fn stack(b: *phantom.BuildContext) phantom.Widget {
    const c = phantom.Theme.of(b).colors;
    // The first child decides the size of the stack.
    return b.new(phantom.Stack{
        .children = b.newSlice(phantom.Widget, &.{
            gallery.swatch(b, c.bg_medium, 320, 160),
            b.new(phantom.Positioned{ .top = 12, .left = 12, .child = gallery.swatch(b, c.blue, 64, 40) }).widget(),
            b.new(phantom.Positioned{ .top = 12, .right = 12, .child = gallery.swatch(b, c.green, 64, 40) }).widget(),
            // Pinned to the left and the right, so it stretches between them.
            b.new(phantom.Positioned{ .bottom = 12, .left = 12, .right = 12, .child = b.new(phantom.SizedBox{
                .height = 32,
                .child = b.new(phantom.ColoredBox{ .color = c.red, .radius = 6 }).widget(),
            }).widget() }).widget(),
            b.new(phantom.Positioned{ .top = 40, .left = 120, .child = gallery.text(b, "on top", .{ .size = 18 }) }).widget(),
        }),
    }).widget();
}

fn aligns(b: *phantom.BuildContext) phantom.Widget {
    const c = phantom.Theme.of(b).colors;
    const alignments = [_]phantom.Alignment{ .top_left, .center_right, .bottom_center };
    var boxes: [alignments.len + 1]phantom.Widget = undefined;
    for (alignments, boxes[0..alignments.len]) |alignment, *out| {
        const aligned = b.new(phantom.Align{ .alignment = alignment, .child = gallery.swatch(b, c.teal, 32, 32) });
        out.* = gallery.spacedColumn(b, 4, &.{
            label(b, @tagName(alignment)),
            b.new(phantom.SizedBox{ .width = 120, .height = 96, .child = frame(b, aligned.widget()) }).widget(),
        });
    }
    const centered = b.new(phantom.Center(.{ .child = gallery.swatch(b, c.yellow, 32, 32) }));
    boxes[alignments.len] = gallery.spacedColumn(b, 4, &.{
        label(b, "Center"),
        b.new(phantom.SizedBox{ .width = 120, .height = 96, .child = frame(b, centered.widget()) }).widget(),
    });
    return gallery.spacedRow(b, 16, .center, &boxes);
}

fn padding(b: *phantom.BuildContext) phantom.Widget {
    const c = phantom.Theme.of(b).colors;
    const insets = [_]f32{ 0, 8, 24 };
    var boxes: [insets.len]phantom.Widget = undefined;
    for (insets, &boxes) |inset, *out| {
        const padded = b.new(phantom.Padding{ .insets = .all(inset), .child = gallery.swatch(b, c.blue, 48, 48) });
        out.* = gallery.spacedColumn(b, 4, &.{
            label(b, gallery.format(b, "all({d})", .{inset})),
            frame(b, padded.widget()),
        });
    }
    return gallery.spacedRow(b, 16, .start, &boxes);
}

fn sizedBoxes(b: *phantom.BuildContext) phantom.Widget {
    const c = phantom.Theme.of(b).colors;
    return gallery.spacedRow(b, 16, .center, &.{
        gallery.swatch(b, c.purple, 24, 24),
        gallery.swatch(b, c.purple, 48, 48),
        gallery.swatch(b, c.purple, 96, 48),
        gallery.swatch(b, c.purple, 48, 96),
    });
}

fn expanded(b: *phantom.BuildContext) phantom.Widget {
    const c = phantom.Theme.of(b).colors;
    const colors = [_]phantom.Color{ c.red, c.yellow, c.green };
    var parts: [colors.len]phantom.Widget = undefined;
    for (colors, &parts, 1..) |color, *out, flex| {
        const box = b.new(phantom.SizedBox{
            .height = 40,
            .child = b.new(phantom.ColoredBox{ .color = color, .radius = 6 }).widget(),
        });
        out.* = b.new(phantom.Expanded(.{ .flex = @intCast(flex), .child = box.widget() })).widget();
    }
    const row = b.new(phantom.Row(.{ .children = b.newSlice(phantom.Widget, &parts) }));
    return b.new(phantom.SizedBox{ .width = 480, .child = row.widget() }).widget();
}
