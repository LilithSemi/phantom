const std = @import("std");
const phantom = @import("phantom");
const gallery = @import("../app.zig");

pub fn build(b: *phantom.BuildContext) phantom.Widget {
    return gallery.page(b, "Input", &.{b.new(InputDemo{}).widget()});
}

/// A field draws only its text, so the gallery puts a border around it.
fn fieldBox(b: *phantom.BuildContext, field: phantom.Widget) phantom.Widget {
    const theme = phantom.Theme.of(b);
    return b.new(phantom.SizedBox{
        .width = 420,
        .child = b.new(phantom.DecoratedBox{
            .color = theme.colors.bg_dark,
            .radius = 8,
            .border_color = theme.colors.fg_dim,
            .border_width = 1,
            .child = b.new(phantom.Padding{ .insets = .symmetric(12, 8), .child = field }).widget(),
        }).widget(),
    }).widget();
}

const InputDemo = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        echo_buf: [96]u8 = undefined,
        echo: []const u8 = "Type in the field above.",
        lines: u16 = 2,
        message: phantom.TextFieldController = .{},
        /// The last text sent with Enter. Owned by the gpa, because it must
        /// outlive the frame that sent it.
        sent: std.ArrayList(u8) = .empty,

        pub fn dispose(s: *State) void {
            s.sent.deinit(s.base.gpa());
        }

        fn onChange(ctx: *anyopaque, value: []const u8) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            s.echo = std.fmt.bufPrint(&s.echo_buf, "You typed: {s}", .{value}) catch "You typed a lot.";
            phantom.markNeedsBuild(s);
        }

        fn onLines(ctx: *anyopaque, lines: u16) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            s.lines = lines;
            phantom.markNeedsBuild(s);
        }

        /// The field leaves a plain Enter to its owner. Here it sends the text
        /// and clears the field. Shift and Enter still adds a line.
        fn onKey(ctx: *anyopaque, ev: phantom.input.KeyEvent) bool {
            const s: *State = @ptrCast(@alignCast(ctx));
            if (ev.keysym != .enter or ev.mods.shift or ev.mods.alt) return false;
            s.sent.clearRetainingCapacity();
            s.sent.appendSlice(s.base.gpa(), s.message.text()) catch {
                s.base.sink().report(.oom, "out of memory keeping the sent message");
                return true;
            };
            s.message.setText("") catch s.base.sink().report(.oom, "out of memory clearing the message field");
            phantom.markNeedsBuild(s);
            return true;
        }

        pub fn build(s: *State, b: *phantom.BuildContext) anyerror!phantom.Widget {
            const theme = phantom.Theme.of(b);
            const muted = gallery.TextStyle{ .size = 16, .color = theme.colors.fg_muted };

            const single = b.new(phantom.TextField{
                .id = "gallery-name",
                .placeholder = "Your name",
                .on_change = onChange,
                .ctx = s,
            });
            const multi = b.new(phantom.TextField{
                .id = "gallery-message",
                .placeholder = "Write a message",
                .min_lines = 2,
                .max_lines = 5,
                .controller = &s.message,
                .on_lines_change = onLines,
                .on_key = onKey,
                .ctx = s,
            });
            const sent = if (s.sent.items.len == 0)
                "Nothing sent yet."
            else
                gallery.format(b, "Sent: {s}", .{s.sent.items});

            return gallery.spacedColumn(b, 0, &.{
                gallery.section(b, "A single-line TextField with a placeholder", gallery.spacedColumn(b, 8, &.{
                    fieldBox(b, single.widget()),
                    gallery.text(b, s.echo, muted),
                })),
                gallery.section(b, "A multi-line TextField that grows from two lines to five", gallery.spacedColumn(b, 8, &.{
                    fieldBox(b, multi.widget()),
                    gallery.text(b, "Enter sends the message. Shift and Enter adds a line.", muted),
                    gallery.text(b, gallery.format(b, "lines: {d}", .{s.lines}), muted),
                    b.new(phantom.SizedBox{
                        .width = 420,
                        .child = gallery.text(b, sent, .{ .size = 18, .wrap = true }),
                    }).widget(),
                })),
            });
        }
    };

    pub fn widget(self: *const InputDemo) phantom.Widget {
        return phantom.StatefulWidget(InputDemo, self);
    }
};
