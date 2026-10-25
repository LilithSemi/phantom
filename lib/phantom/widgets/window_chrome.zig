//! Native window decoration widgets. Hosts without a controller render only the body.
const phantom = @import("../../phantom.zig");

pub const WindowController = struct {
    pub const Action = enum { move, minimize, maximize, close };
    ctx: *anyopaque,
    command: *const fn (*anyopaque, Action) void,
    visible: bool = false,
    maximized: bool = false,
    title: []const u8 = "",
    state: ?*WindowChrome.State = null,

    pub fn changed(self: *WindowController) void {
        if (self.state) |s| phantom.markNeedsBuild(s);
    }
};

pub const WindowTitleBar = struct {
    controller: *WindowController,

    pub fn build(self: WindowTitleBar, b: *phantom.BuildContext) phantom.Widget {
        const c = self.controller;
        const theme = phantom.Theme.of(b);
        const title = b.new(phantom.Listener{
            .ctx = c,
            .on_pointer_down = drag,
            .child = b.new(phantom.DecoratedBox{
                .color = theme.colors.bg_dark,
                .child = b.new(phantom.Padding{
                    .insets = .{ .left = 12, .right = 12 },
                    .child = b.new(phantom.Align{ .alignment = .center_left, .child = b.new(phantom.Text{ .text = c.title }).widget() }).widget(),
                }).widget(),
            }).widget(),
        }).widget();
        return b.new(phantom.SizedBox{
            .height = 36,
            .child = b.new(phantom.Row(.{
                .cross = .center,
                .children = b.newSlice(phantom.Widget, &.{
                    b.new(phantom.Expanded(.{ .child = title })).widget(),
                    control(b, c, "Minimize", .minimize, minimize),
                    control(b, c, "Maximize or restore", .maximize, maximize),
                    control(b, c, "Close window", .close, close),
                }),
            })).widget(),
        }).widget();
    }

    fn control(b: *phantom.BuildContext, c: *WindowController, id: []const u8, action: WindowController.Action, tap: *const fn (*anyopaque) void) phantom.Widget {
        const color = phantom.Theme.of(b).colors.fg_primary;
        const mark = if (action == .maximize) b.new(phantom.SizedBox{
            .width = 12,
            .height = 12,
            .child = b.new(phantom.DecoratedBox{
                .border_color = color,
                .border_width = if (c.maximized) 2 else 1,
                .child = b.new(phantom.ColoredBox{ .color = .{ .a = 0 } }).widget(),
            }).widget(),
        }).widget() else b.new(phantom.Icon{
            .id = if (action == .minimize) .minus else .cross,
            .size = 16,
            .color = color,
            .label = id,
        }).widget();
        return b.new(phantom.Button{
            .variant = .secondary,
            .padding = .{},
            .id = id,
            .ctx = c,
            .on_tap = tap,
            .child = b.new(phantom.SizedBox{ .width = 44, .height = 36, .child = b.new(phantom.Align{ .alignment = .center, .child = mark }).widget() }).widget(),
        }).widget();
    }
    fn send(ctx: *anyopaque, action: WindowController.Action) void {
        const c: *WindowController = @ptrCast(@alignCast(ctx));
        c.command(c.ctx, action);
    }
    fn drag(ctx: *anyopaque, _: phantom.PointerEvent) void {
        send(ctx, .move);
    }
    fn minimize(ctx: *anyopaque) void {
        send(ctx, .minimize);
    }
    fn maximize(ctx: *anyopaque) void {
        send(ctx, .maximize);
    }
    fn close(ctx: *anyopaque) void {
        send(ctx, .close);
    }
};

pub const WindowChrome = struct {
    controller: *WindowController,
    body: phantom.Root,

    pub fn widget(self: *const WindowChrome) phantom.Widget {
        return phantom.StatefulWidget(WindowChrome, self);
    }
    pub const State = struct {
        base: phantom.StateBase = .{},
        controller: *WindowController = undefined,
        body: phantom.Root = undefined,
        pub fn initState(s: *State, config: *const WindowChrome) !void {
            s.controller = config.controller;
            s.body = config.body;
            s.controller.state = s;
        }
        pub fn didUpdateWidget(s: *State, config: *const WindowChrome) !void {
            s.controller.state = null;
            try s.initState(config);
        }
        pub fn dispose(s: *State) void {
            s.controller.state = null;
        }
        pub fn build(s: *State, b: *phantom.BuildContext) !phantom.Widget {
            const body = s.body.call(b);
            return b.new(phantom.Column(.{ .children = b.newSlice(phantom.Widget, &.{
                if (s.controller.visible) (WindowTitleBar{ .controller = s.controller }).build(b) else b.new(phantom.SizedBox{ .height = 0, .child = b.new(phantom.ColoredBox{ .color = .{ .a = 0 } }).widget() }).widget(),
                b.new(phantom.Expanded(.{ .child = body })).widget(),
            }) })).widget();
        }
    };
};

test "window chrome routes controls and removes them when hidden" {
    const std = @import("std");
    const Spy = struct {
        last: ?WindowController.Action = null,
        fn command(ctx: *anyopaque, action: WindowController.Action) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.last = action;
        }
        fn body(b: *phantom.BuildContext, _: *@This()) phantom.Widget {
            return b.new(phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 0) }).widget();
        }
    };
    var spy = Spy{};
    var controller = WindowController{ .ctx = &spy, .command = Spy.command, .visible = true, .title = "Test window" };
    const chrome = WindowChrome{ .controller = &controller, .body = phantom.Root.of(Spy, Spy.body, &spy) };
    var h = try phantom.testing.mount(std.testing.allocator, chrome.widget());
    defer h.deinit();
    try h.pump();
    h.tapAt(.{ .x = 778, .y = 18 });
    try std.testing.expectEqual(WindowController.Action.close, spy.last.?);
    h.tapAt(.{ .x = 734, .y = 18 });
    try std.testing.expectEqual(WindowController.Action.maximize, spy.last.?);
    h.tapAt(.{ .x = 690, .y = 18 });
    try std.testing.expectEqual(WindowController.Action.minimize, spy.last.?);
    h.tapAt(.{ .x = 100, .y = 18 });
    try std.testing.expectEqual(WindowController.Action.move, spy.last.?);
    spy.last = null;
    controller.visible = false;
    controller.changed();
    try h.pump();
    h.tapAt(.{ .x = 778, .y = 18 });
    try std.testing.expect(spy.last == null);
    try h.expectNoFaults();
}
