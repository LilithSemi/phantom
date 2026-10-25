//! Phantom Demo: a gallery of every widget phantom has. Each category is one
//! route, so on the web every page has its own address and Back works. A new
//! widget gets a section on the page it belongs to, or a page of its own here.

const std = @import("std");
const phantom = @import("phantom");

const Page = struct {
    path: []const u8,
    title: []const u8,
    build: *const fn (*phantom.BuildContext) phantom.Widget,
};

const pages = [_]Page{
    .{ .path = "/text", .title = "Text", .build = @import("pages/text.zig").build },
    .{ .path = "/input", .title = "Input", .build = @import("pages/input.zig").build },
    .{ .path = "/actions", .title = "Actions", .build = @import("pages/actions.zig").build },
    .{ .path = "/layout", .title = "Layout", .build = @import("pages/layout.zig").build },
    .{ .path = "/decoration", .title = "Decoration", .build = @import("pages/decoration.zig").build },
    .{ .path = "/media", .title = "Media", .build = @import("pages/media.zig").build },
    .{ .path = "/scrolling", .title = "Scrolling", .build = @import("pages/scrolling.zig").build },
};

/// One route per page, and "/" shows the first page. The sidebar sits inside
/// each route, because a `RouteLink` finds its router by looking up the tree.
const routes = blk: {
    var list: [pages.len + 1]phantom.Route = undefined;
    list[0] = .{ .path = "/", .build = shellFor(0) };
    for (pages, 1..) |p, i| list[i] = .{ .path = p.path, .build = shellFor(i - 1) };
    const done = list;
    break :blk done;
};

pub fn root(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Router{ .routes = &routes, .not_found = notFound }).widget();
}

fn shellFor(comptime index: usize) *const fn (*phantom.BuildContext) phantom.Widget {
    return struct {
        fn build(b: *phantom.BuildContext) phantom.Widget {
            return shell(b, index);
        }
    }.build;
}

fn notFound(b: *phantom.BuildContext) phantom.Widget {
    return shell(b, null);
}

fn shell(b: *phantom.BuildContext, comptime selected: ?usize) phantom.Widget {
    const theme = phantom.Theme.of(b);
    const scaffold = b.new(phantom.NavigationScaffold{
        .body = .{ .build = bodyBuilder(selected) },
        .navigation = .{ .build = navigationBuilder(selected) },
        .title = .{ .build = titleBuilder(selected) },
    });
    return b.new(phantom.DecoratedBox{ .color = theme.colors.bg, .child = scaffold.widget() }).widget();
}

fn bodyBuilder(comptime selected: ?usize) *const fn (?*anyopaque, *phantom.BuildContext) phantom.Widget {
    return struct {
        fn build(_: ?*anyopaque, b: *phantom.BuildContext) phantom.Widget {
            if (selected) |index| return pages[index].build(b);
            return page(b, "Not found", &.{
                text(b, "No page has this address. Pick one from the list.", .{ .wrap = true }),
            });
        }
    }.build;
}

fn navigationBuilder(comptime selected: ?usize) *const fn (?*anyopaque, *phantom.BuildContext) phantom.Widget {
    return struct {
        fn build(_: ?*anyopaque, b: *phantom.BuildContext) phantom.Widget {
            return sidebar(b, selected);
        }
    }.build;
}

fn titleBuilder(comptime selected: ?usize) *const fn (?*anyopaque, *phantom.BuildContext) phantom.Widget {
    return struct {
        fn build(_: ?*anyopaque, b: *phantom.BuildContext) phantom.Widget {
            const theme = phantom.Theme.of(b);
            const title = if (selected) |index| pages[index].title else "Not found";
            return text(b, title, .{ .font = theme.body_bold_font, .size = 20 });
        }
    }.build;
}

fn sidebar(b: *phantom.BuildContext, selected: ?usize) phantom.Widget {
    const theme = phantom.Theme.of(b);
    var items: [pages.len + 1]phantom.Widget = undefined;
    items[0] = b.new(phantom.Padding{
        .insets = .{ .left = 12, .top = 8, .bottom = 16 },
        .child = text(b, "Phantom", .{ .font = theme.heading_font, .size = 22, .color = theme.accent }),
    }).widget();
    for (pages, 1..) |p, i| {
        const current = selected == i - 1;
        const label = text(b, p.title, .{
            .font = if (current) theme.body_bold_font else theme.body_font,
            .size = 18,
            .color = if (current) theme.accent else theme.colors.fg_primary,
        });
        const entry = b.new(phantom.DecoratedBox{
            .color = if (current) theme.colors.bg_medium else null,
            .radius = 8,
            .child = b.new(phantom.Padding{
                .insets = .symmetric(12, 8),
                .child = b.new(phantom.Row(.{ .children = b.newSlice(phantom.Widget, &.{label}) })).widget(),
            }).widget(),
        });
        items[i] = b.new(phantom.RouteLink{ .to = p.path, .child = entry.widget() }).widget();
    }
    const list = b.new(phantom.Column(.{ .children = b.newSlice(phantom.Widget, &items) }));
    const scroll = b.new(phantom.ScrollView{
        .child = b.new(phantom.Padding{ .insets = .all(12), .child = list.widget() }).widget(),
    });
    return b.new(phantom.DecoratedBox{ .color = theme.colors.bg_dark, .child = scroll.widget() }).widget();
}

// Helpers the pages share.

pub const TextStyle = struct {
    font: ?*phantom.text.Font = null,
    size: ?f32 = null,
    color: ?phantom.Color = null,
    wrap: bool = false,
};

pub fn text(b: *phantom.BuildContext, value: []const u8, style: TextStyle) phantom.Widget {
    return b.new(phantom.Text{
        .text = value,
        .font = style.font,
        .size = style.size,
        .color = style.color,
        .wrap = style.wrap,
    }).widget();
}

/// Formats into the build arena, which lives until the frame is painted.
pub fn format(b: *phantom.BuildContext, comptime fmt: []const u8, args: anytype) []const u8 {
    return b.arena.print(fmt, args) catch {
        b.sink().report(.oom, "out of memory formatting gallery text");
        return "";
    };
}

/// A page: its title, then its sections in a padded column that scrolls.
pub fn page(b: *phantom.BuildContext, title: []const u8, sections: []const phantom.Widget) phantom.Widget {
    const theme = phantom.Theme.of(b);
    const compact = phantom.MediaQuery.of(b).size.width < 720;
    var children: std.ArrayList(phantom.Widget) = .empty;
    children.ensureTotalCapacity(b.arena, sections.len + @intFromBool(!compact)) catch {
        b.sink().report(.oom, "out of memory building a gallery page");
        return text(b, title, .{});
    };
    if (!compact) {
        children.appendAssumeCapacity(b.new(phantom.Padding{
            .insets = .{ .bottom = 24 },
            .child = text(b, title, .{ .font = theme.heading_font, .size = 36 }),
        }).widget());
    }
    children.appendSliceAssumeCapacity(sections);
    const column = b.new(phantom.Column(.{ .children = children.items }));
    return b.new(phantom.ScrollView{
        .child = b.new(phantom.Padding{ .insets = .all(if (compact) 16 else 32), .child = column.widget() }).widget(),
    }).widget();
}

/// A one-line caption above a live example.
pub fn section(b: *phantom.BuildContext, caption: []const u8, example: phantom.Widget) phantom.Widget {
    const theme = phantom.Theme.of(b);
    const column = b.new(phantom.Column(.{ .children = b.newSlice(phantom.Widget, &.{
        b.new(phantom.Padding{
            .insets = .{ .bottom = 10 },
            .child = text(b, caption, .{ .size = 16, .color = theme.colors.fg_muted, .wrap = true }),
        }).widget(),
        example,
    }) }));
    return b.new(phantom.Padding{ .insets = .{ .bottom = 32 }, .child = column.widget() }).widget();
}

/// A fixed-size block of colour, for layout examples.
pub fn swatch(b: *phantom.BuildContext, color: phantom.Color, width: f32, height: f32) phantom.Widget {
    return b.new(phantom.SizedBox{
        .width = width,
        .height = height,
        .child = b.new(phantom.ColoredBox{ .color = color, .radius = 6 }).widget(),
    }).widget();
}

/// Children laid out in a row with a gap between them.
pub fn spacedRow(b: *phantom.BuildContext, gap: f32, cross: phantom.CrossAxisAlignment, items: []const phantom.Widget) phantom.Widget {
    const spaced = b.arena.alloc(phantom.Widget, items.len) catch {
        b.sink().report(.oom, "out of memory building a gallery row");
        return b.new(phantom.Row(.{ .cross = cross, .children = items })).widget();
    };
    for (items, spaced, 0..) |item, *out, i| {
        out.* = if (i + 1 == items.len) item else b.new(phantom.Padding{ .insets = .{ .right = gap }, .child = item }).widget();
    }
    return b.new(phantom.Row(.{ .cross = cross, .children = spaced })).widget();
}

/// Children laid out in a column with a gap between them.
pub fn spacedColumn(b: *phantom.BuildContext, gap: f32, items: []const phantom.Widget) phantom.Widget {
    const spaced = b.arena.alloc(phantom.Widget, items.len) catch {
        b.sink().report(.oom, "out of memory building a gallery column");
        return b.new(phantom.Column(.{ .children = items })).widget();
    };
    for (items, spaced, 0..) |item, *out, i| {
        out.* = if (i + 1 == items.len) item else b.new(phantom.Padding{ .insets = .{ .bottom = gap }, .child = item }).widget();
    }
    return b.new(phantom.Column(.{ .children = spaced })).widget();
}
