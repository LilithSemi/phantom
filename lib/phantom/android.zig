//! Android host support. Lattice owns the native window lifecycle and Prism
//! presents the rendered display list through a Vulkan swapchain.
const std = @import("std");
const phantom = @import("../phantom.zig");
const lattice = @import("lattice");

const OpenUrlRequest = struct {
    bytes: std.ArrayList(u8) = .empty,
    mode: phantom.OpenMode = .new_tab,
    pending: bool = false,

    fn deinit(self: *OpenUrlRequest, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
    }

    fn queue(self: *OpenUrlRequest, gpa: std.mem.Allocator, url: []const u8, mode: phantom.OpenMode) bool {
        self.pending = false;
        self.bytes.clearRetainingCapacity();
        self.bytes.appendSlice(gpa, url) catch return false;
        self.mode = mode;
        self.pending = true;
        return true;
    }

    fn clear(self: *OpenUrlRequest) void {
        self.pending = false;
        self.bytes.clearRetainingCapacity();
    }
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    sink: phantom.FaultSink,
    owner: phantom.BuildOwner,
    focus: phantom.FocusManager,
    dispatcher: phantom.input.Dispatcher,
    el: *phantom.Element,
    canvas: phantom.Canvas,
    threaded: std.Io.Threaded,
    host: *lattice.backends.Android,
    surface: lattice.Surface,
    renderer: phantom.backend.PrismBackend,
    scale: f32,
    text_scale: f32,
    active_pointer: ?u32 = null,
    pointer_position: phantom.PhysicalOffset = .zero,
    touch_scroll: phantom.input.TouchScrollRecognizer = .{},
    preedit_buffer: std.ArrayList(u8) = .empty,
    open_url_request: OpenUrlRequest = .{},

    pub fn create(
        gpa: std.mem.Allocator,
        root: phantom.Root,
        width: u32,
        height: u32,
        density: f32,
        text_scale: f32,
        system_insets: phantom.PhysicalEdgeInsets,
    ) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);

        self.gpa = gpa;
        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        self.sink = .{};
        self.owner = .{ .gpa = gpa, .sink = &self.sink };
        errdefer self.owner.deinit();
        self.focus = .{};
        errdefer self.focus.deinit(gpa);
        self.dispatcher = .{};
        self.owner.focus = &self.focus;
        self.owner.dispatcher = &self.dispatcher;
        self.threaded = std.Io.Threaded.init(gpa, .{});
        errdefer self.threaded.deinit();
        self.owner.io = self.threaded.io();
        self.owner.platform = .{ .ctx = self, .open_url = queueOpenUrl };
        self.scale = validDensity(density);
        self.text_scale = validTextScale(text_scale);
        self.preedit_buffer = .empty;
        self.open_url_request = .{};

        _ = try phantom.View.open(&self.owner, .{
            .title = "Android",
            .size = logicalSize(width, height, self.scale * self.text_scale),
            .dpr = self.scale,
            .text_scale = self.text_scale,
            .view_padding = logicalInsets(system_insets, self.scale * self.text_scale),
        });
        const view = self.owner.activeView().?;
        var bctx = phantom.BuildContext{ .arena = self.arena.allocator(), .owner = &self.owner };
        const root_widget = root.call(&bctx);
        var mq = phantom.MediaQuery{ .data = &view.metrics, .child = root_widget };
        self.el = if (self.sink.ok())
            try mq.widget().mount(&bctx, null)
        else eb: {
            const error_box = phantom.ErrorBox{};
            break :eb try error_box.widget().mount(&bctx, null);
        };
        errdefer self.el.deinit(gpa);
        self.canvas = phantom.Canvas.init(gpa);
        errdefer self.canvas.deinit();

        self.host = try lattice.backends.Android.init(gpa, self.threaded.io());
        errdefer self.host.backend().deinit();
        self.surface = try self.host.backend().createSurface(.{
            .title = "Android",
            .width = width,
            .height = height,
            .color = lattice.ColorConfig.sdr(.xrgb8888),
        });
        self.renderer = try phantom.backend.PrismBackend.init(self.host.device, gpa);
        errdefer self.renderer.deinit();
        self.renderer.flip_y = true;
        return self;
    }

    pub fn destroy(self: *Session) void {
        self.renderer.deinit();
        self.host.backend().deinit();
        self.canvas.deinit();
        self.el.deinit(self.gpa);
        self.focus.deinit(self.gpa);
        self.owner.deinit();
        self.arena.deinit();
        self.threaded.deinit();
        self.preedit_buffer.deinit(self.gpa);
        self.open_url_request.deinit(self.gpa);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn attachNativeWindow(self: *Session, window: *anyopaque, width: u32, height: u32, density: f32) !void {
        try self.host.attachNativeWindow(self.surface.id, window, width, height, density);
    }

    pub fn detachNativeWindow(self: *Session) void {
        self.host.detachNativeWindow(self.surface.id);
    }

    pub fn render(
        self: *Session,
        width: u32,
        height: u32,
        density: f32,
        text_scale: f32,
        system_insets: phantom.PhysicalEdgeInsets,
        frame_nanos: i64,
    ) !void {
        try self.host.resize(self.surface.id, width, height, density);
        try self.drainEvents();
        const target = try self.host.backend().surfaceRenderTarget(self.surface.id);
        self.scale = validDensity(density);
        self.text_scale = validTextScale(text_scale);
        const effective_scale = self.scale * self.text_scale;
        const physical = phantom.PhysicalSize{
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        };
        self.owner.setActiveViewMetrics(.{
            .size = logicalSize(width, height, effective_scale),
            .dpr = self.scale,
            .text_scale = self.text_scale,
            .view_padding = logicalInsets(system_insets, effective_scale),
        });

        self.owner.scheduler.tick(@intCast(frame_nanos));
        var bctx = phantom.BuildContext{ .arena = self.arena.allocator(), .owner = &self.owner };
        self.owner.flushDirty(&bctx);
        try self.focus.collect(self.gpa, self.el);
        self.canvas.clear();
        const ro = self.el.renderObject() orelse return error.NoRootRenderObject;
        _ = ro.layout(phantom.BoxConstraints.tightScaled(physical, effective_scale));
        try ro.paint(&self.canvas, phantom.PhysicalOffset.zero);
        try self.renderer.render(
            target.context.*,
            target.target,
            physical,
            self.canvas.list,
            phantom.Color.rgb(26.0 / 255.0, 27.0 / 255.0, 38.0 / 255.0),
        );
        try self.host.backend().commitFrame(self.surface.id);
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn touch(self: *Session, action: i32, pointer_id: u32, x: f32, y: f32) !bool {
        switch (action) {
            0 => try self.host.touchDown(self.surface.id, pointer_id, x, y),
            1 => try self.host.touchMove(self.surface.id, pointer_id, x, y),
            2 => try self.host.touchUp(self.surface.id, pointer_id, x, y),
            3 => try self.host.touchCancel(self.surface.id, pointer_id, x, y),
            else => {},
        }
        try self.drainEvents();
        const enabled = self.focus.acceptsTextInput();
        self.host.backend().setTextInput(self.surface.id, if (enabled) .{} else null) catch {};
        return enabled;
    }

    pub fn commitCodepoint(self: *Session, codepoint: u21) !void {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(codepoint, &buf);
        try self.host.commitText(self.surface.id, buf[0..len]);
        try self.drainEvents();
    }

    pub fn beginPreedit(self: *Session) void {
        self.preedit_buffer.clearRetainingCapacity();
    }

    pub fn appendPreeditCodepoint(self: *Session, codepoint: u21) !void {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(codepoint, &buf);
        try self.preedit_buffer.appendSlice(self.gpa, buf[0..len]);
    }

    pub fn endPreedit(self: *Session) !void {
        try self.host.preeditText(self.surface.id, self.preedit_buffer.items, null);
        try self.drainEvents();
    }

    pub fn finishPreedit(self: *Session) !void {
        try self.host.finishPreedit(self.surface.id);
        try self.drainEvents();
    }

    pub fn deleteFromIme(self: *Session, before: bool) !void {
        try self.host.key(self.surface.id, .{
            .keycode = 0,
            .state = .pressed,
            .keysym = if (before) 0xff08 else 0xffff,
        });
        try self.drainEvents();
    }

    pub fn imeAction(self: *Session, platform_action: i32) !void {
        const action: lattice.text_input.Action = switch (platform_action) {
            2 => .go,
            3 => .search,
            4 => .send,
            5 => .next,
            6 => .done,
            7 => .previous,
            else => .none,
        };
        try self.host.inputAction(self.surface.id, action);
        try self.drainEvents();
    }

    pub fn pendingUrlLength(self: *const Session) ?usize {
        if (!self.open_url_request.pending) return null;
        return self.open_url_request.bytes.items.len;
    }

    pub fn pendingUrlByte(self: *const Session, index: usize) ?u8 {
        if (!self.open_url_request.pending or index >= self.open_url_request.bytes.items.len) return null;
        return self.open_url_request.bytes.items[index];
    }

    pub fn pendingUrlMode(self: *const Session) phantom.OpenMode {
        return self.open_url_request.mode;
    }

    pub fn clearPendingUrl(self: *Session) void {
        self.open_url_request.clear();
    }

    fn drainEvents(self: *Session) !void {
        try self.host.backend().pump(0, handleEvent, self);
    }

    fn handleEvent(ctx: *anyopaque, queued: lattice.Event) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        switch (queued) {
            .input => |input_event| self.handleInput(input_event),
            .text_input => |text_event| if (text_event.surface == self.surface.id) self.handleTextInput(text_event.event),
            else => {},
        }
    }

    fn handleInput(self: *Session, input_event: lattice.InputEvent) void {
        switch (input_event) {
            .touch_down => |point_event| {
                if (self.active_pointer != null) return;
                self.active_pointer = point_event.id;
                const point = touchPoint(point_event);
                self.pointer_position = point;
                self.touch_scroll.down(point);
                if (phantom.input.hitTestFocus(self.el, point)) |handler| {
                    _ = self.focus.focusNode(handler);
                } else self.focus.clear();
                self.dispatcher.down(self.el, point);
            },
            .touch_motion => |point_event| {
                if (self.active_pointer != point_event.id) return;
                const point = touchPoint(point_event);
                self.pointer_position = point;
                switch (self.touch_scroll.move(point, 8 * self.scale)) {
                    .pending => self.dispatcher.move(self.el, point),
                    .begin => |delta| {
                        self.dispatcher.up(self.el, .{ .x = -1.0e9, .y = -1.0e9 });
                        self.dispatcher.scroll(self.el, self.touch_scroll.origin, delta.dx, delta.dy);
                    },
                    .scroll => |delta| self.dispatcher.scroll(
                        self.el,
                        self.touch_scroll.origin,
                        delta.dx,
                        delta.dy,
                    ),
                }
            },
            .touch_up => |point_event| {
                if (self.active_pointer != point_event.id) return;
                const point = touchPoint(point_event);
                self.pointer_position = point;
                if (!self.touch_scroll.finish()) self.dispatcher.up(self.el, point);
                self.active_pointer = null;
            },
            .touch_cancel => |point_event| {
                if (self.active_pointer != point_event.id) return;
                _ = self.touch_scroll.finish();
                self.dispatcher.up(self.el, .{ .x = -1.0e9, .y = -1.0e9 });
                self.active_pointer = null;
            },
            .pointer_axis => |axis| self.dispatcher.scroll(
                self.el,
                self.pointer_position,
                @floatCast(axis.horizontal),
                @floatCast(axis.vertical),
            ),
            .key => |key| _ = self.focus.dispatch(.{
                .keysym = @fromBackingInt(@intCast(key.keysym)),
                .text = key.text,
                .mods = .{ .shift = key.mods.shift, .ctrl = key.mods.ctrl, .alt = key.mods.alt, .super = key.mods.super },
                .action = if (key.state == .pressed) .press else .release,
            }),
            else => {},
        }
    }

    fn handleTextInput(self: *Session, input_event: lattice.text_input.Event) void {
        switch (input_event) {
            .commit => |text| _ = self.focus.dispatchTextInput(.{ .commit = text }),
            .preedit => |preedit| _ = self.focus.dispatchTextInput(.{ .preedit = .{
                .text = preedit.text,
                .selection = if (preedit.selection) |selection| .{
                    .start = selection.start,
                    .end = selection.end,
                } else null,
            } }),
            .finish_preedit => _ = self.focus.dispatchTextInput(.{ .finish_preedit = {} }),
            .delete_surrounding => |delete| {
                _ = self.focus.dispatchTextInput(.{ .delete_surrounding = .{
                    .before_bytes = delete.before_bytes,
                    .after_bytes = delete.after_bytes,
                } });
            },
            .action => |action| _ = self.focus.dispatchTextInput(.{ .action = switch (action) {
                .none => .none,
                .done => .done,
                .go => .go,
                .next => .next,
                .previous => .previous,
                .search => .search,
                .send => .send,
            } }),
        }
    }
};

fn queueOpenUrl(ctx: *anyopaque, url: []const u8, mode: phantom.OpenMode) bool {
    const self: *Session = @ptrCast(@alignCast(ctx));
    return self.open_url_request.queue(self.gpa, url, mode);
}

fn touchPoint(touch: lattice.event.TouchPoint) phantom.PhysicalOffset {
    return .{ .x = @floatCast(touch.x), .y = @floatCast(touch.y) };
}

fn validDensity(density: f32) f32 {
    return if (std.math.isFinite(density) and density > 0) density else 1;
}

fn validTextScale(scale: f32) f32 {
    return if (std.math.isFinite(scale) and scale > 0) scale else 1;
}

fn logicalSize(width: u32, height: u32, density: f32) phantom.LogicalSize {
    return .{
        .width = @as(f32, @floatFromInt(width)) / density,
        .height = @as(f32, @floatFromInt(height)) / density,
    };
}

fn logicalInsets(insets: phantom.PhysicalEdgeInsets, scale: f32) phantom.LogicalEdgeInsets {
    return .{
        .left = @max(0, insets.left) / scale,
        .top = @max(0, insets.top) / scale,
        .right = @max(0, insets.right) / scale,
        .bottom = @max(0, insets.bottom) / scale,
    };
}

test "Android URL requests own their UTF-8 bytes until consumed" {
    var request = OpenUrlRequest{};
    defer request.deinit(std.testing.allocator);

    var source = [_]u8{ 'h', 't', 't', 'p', 's', ':', '/', '/', 'x' };
    try std.testing.expect(request.queue(std.testing.allocator, &source, .new_tab));
    source[8] = 'y';
    try std.testing.expectEqualStrings("https://x", request.bytes.items);
    try std.testing.expectEqual(phantom.OpenMode.new_tab, request.mode);
    try std.testing.expect(request.pending);

    request.clear();
    try std.testing.expect(!request.pending);
    try std.testing.expectEqual(@as(usize, 0), request.bytes.items.len);
}

test "Android display scales reject invalid density and font scale values" {
    try std.testing.expectEqual(@as(f32, 1), validDensity(0));
    try std.testing.expectEqual(@as(f32, 1), validTextScale(std.math.nan(f32)));
    try std.testing.expectEqual(@as(f32, 1.5), validTextScale(1.5));
    const size = logicalSize(1080, 2400, 3 * 1.5);
    try std.testing.expectEqual(@as(f32, 240), size.width);
    const insets = logicalInsets(.{ .top = 108, .bottom = 63 }, 3);
    try std.testing.expectEqual(@as(f32, 36), insets.top);
    try std.testing.expectEqual(@as(f32, 21), insets.bottom);
}
