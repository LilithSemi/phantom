const std = @import("std");
const phantom = @import("phantom");
const gallery = @import("../app.zig");

const markdown_source =
    \\# A heading
    \\
    \\A paragraph with **strong**, *emphasis*, `inline code` and
    \\[a link](https://ziglang.org).
    \\
    \\## Lists
    \\
    \\- A bullet
    \\  - A nested bullet
    \\- Another bullet
    \\
    \\1. The first step
    \\2. The second step
    \\
    \\---
    \\
    \\```zig
    \\const greeting = "hello";
    \\```
    \\
    \\#### A small heading
;

pub fn build(b: *phantom.BuildContext) phantom.Widget {
    const theme = phantom.Theme.of(b);
    const c = theme.colors;
    const sizes = gallery.spacedRow(b, 16, .center, &.{
        gallery.text(b, "Small", .{ .size = 14 }),
        gallery.text(b, "Body", .{}),
        gallery.text(b, "Large", .{ .size = 36 }),
        gallery.text(b, "Heading", .{ .font = theme.heading_font, .size = 36 }),
    });
    const colours = gallery.spacedRow(b, 16, .center, &.{
        gallery.text(b, "Blue", .{ .color = c.blue }),
        gallery.text(b, "Green", .{ .color = c.green }),
        gallery.text(b, "Yellow", .{ .color = c.yellow }),
        gallery.text(b, "Red", .{ .color = c.red }),
        gallery.text(b, "Muted", .{ .color = c.fg_muted }),
    });
    const wrapped = b.new(phantom.SizedBox{
        .width = 360,
        .child = gallery.text(b, "This text has wrap on, so it breaks at the edge of its 360 unit box instead of running past it.", .{ .wrap = true, .size = 18 }),
    }).widget();

    return gallery.page(b, "Text", &.{
        gallery.section(b, "Text in different sizes and fonts", sizes),
        gallery.section(b, "Text in the theme colours", colours),
        gallery.section(b, "Text that wraps", wrapped),
        gallery.section(b, "RichText mixes styles in one paragraph", b.new(RichDemo{}).widget()),
        gallery.section(b, "Markdown turns a document into widgets", b.new(phantom.SizedBox{
            .width = 560,
            .child = b.new(phantom.Markdown{ .text = markdown_source }).widget(),
        }).widget()),
    });
}

/// Shows the url of the last link tapped in the paragraph.
const RichDemo = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        shown_buf: [160]u8 = undefined,
        shown: []const u8 = "Tap the link.",

        fn onLink(ctx: *anyopaque, url: []const u8) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            s.shown = std.fmt.bufPrint(&s.shown_buf, "Tapped: {s}", .{url}) catch "Tapped a link with a long url.";
            phantom.markNeedsBuild(s);
        }

        pub fn build(s: *State, b: *phantom.BuildContext) anyerror!phantom.Widget {
            const theme = phantom.Theme.of(b);
            const rich = b.new(phantom.RichText{
                .spans = b.newSlice(phantom.RichText.Span, &.{
                    .{ .text = "RichText can be " },
                    .{ .text = "strong", .style = .{ .strong = true } },
                    .{ .text = ", " },
                    .{ .text = "emphasised", .style = .{ .em = true } },
                    .{ .text = ", " },
                    .{ .text = "code", .style = .{ .code = true } },
                    .{ .text = ", " },
                    .{ .text = "underlined", .style = .{ .underline = true } },
                    .{ .text = " or " },
                    .{ .text = "coloured", .color = theme.colors.purple },
                    .{ .text = ". This is " },
                    .{ .text = "a link", .url = "https://ziglang.org", .color = theme.accent, .style = .{ .underline = true } },
                    .{ .text = "." },
                }),
                .size = 20,
                .on_link = onLink,
                .ctx = s,
            });
            return gallery.spacedColumn(b, 8, &.{
                b.new(phantom.SizedBox{ .width = 560, .child = rich.widget() }).widget(),
                gallery.text(b, s.shown, .{ .size = 16, .color = theme.colors.fg_muted }),
            });
        }
    };

    pub fn widget(self: *const RichDemo) phantom.Widget {
        return phantom.StatefulWidget(RichDemo, self);
    }
};
