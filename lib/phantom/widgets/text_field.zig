//! Editable text, on one line or on many. This is the prompt input of a shell
//! and the search box of a launcher, so it must work the same on the GPU backend
//! and on the terminal backend.
//!
//! What it composes rather than rebuilds:
//!   * `Focus` supplies the keys. The focus manager only dispatches to the focused
//!     node, so an unfocused field never sees a key and needs no guard of its own.
//!     A `KeyboardListener` is deliberately NOT used: a listener sees keys while
//!     the field is not focused, which is the opposite of what a text field wants.
//!   * `Ticker` blinks the caret. It measures real time, so the blink rate is the
//!     same however fast the backend draws frames.
//!   * `text/layout.zig` measures and wraps the text, so the caret lands on a
//!     cell boundary under the terminal's monospace metrics and on a glyph
//!     advance under the GPU's proportional ones.
//!
//! Enter is left unhandled on purpose. The field does not own the meaning of the
//! text, so a caller wraps it in a `KeyboardListener` and decides what submitting
//! means there.
const std = @import("std");
const phantom = @import("../../phantom.zig");
const geom = phantom.geometry;
const layout = phantom.layout;
const Canvas = phantom.Canvas;
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const BuildContext = phantom.BuildContext;
const Ticker = phantom.Ticker;
const input = phantom.input;
const text_layout = @import("../text/layout.zig");
const Font = @import("../text/Font.zig");
const mono = @import("../text/mono.zig");
const grapheme = @import("../text/grapheme.zig");
const theme_mod = @import("../theme.zig");
const testing = @import("../testing.zig");

/// Half of one blink cycle, in nanoseconds. The caret shows for this long and
/// hides for the same again.
pub const default_blink_period: Ticker.Nanos = 500_000_000;

// ---------------------------------------------------------------------------
// Character counting
// ---------------------------------------------------------------------------

/// How many characters `s` holds. Every byte that is not a continuation byte
/// starts one, which also counts malformed input without rejecting it.
fn characterCount(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// The render object: a paragraph, a scroll position and a caret
// ---------------------------------------------------------------------------

const RenderCaretText = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    /// Owned copy of the text. The State's buffer moves when it grows, so the
    /// render object must not borrow it across a frame.
    text: []const u8,
    /// Caret position in BYTES, always on a character boundary.
    caret: usize,
    caret_visible: bool,
    font: *Font,
    /// Logical font size. layoutFn multiplies it by the constraint scale.
    size: f32,
    physical_size: f32 = 0,
    color: geom.Color,
    caret_color: geom.Color,
    /// Logical caret width, used only where text is proportional. A character
    /// grid gives the caret a whole cell instead, so it reads as a block.
    caret_width: f32,
    text_metrics: *const mono.TextMetrics,
    para: ?text_layout.Paragraph = null,
    min_lines: u16 = 1,
    max_lines: u16 = 1,
    /// Owned copy. Drawn in `placeholder_color` while `text` is empty.
    placeholder: []const u8 = "",
    placeholder_color: geom.Color = undefined,
    placeholder_line: ?text_layout.Line = null,
    /// How far the view has scrolled right, in physical units. Kept across
    /// layouts so a caret that is already visible does not jump. Only a one
    /// line field scrolls sideways.
    scroll: f32 = 0,
    /// The first line in view, so scrolling moves by whole lines.
    first_line: usize = 0,
    /// Physical caret geometry resolved by the last layout. `caret_x` is inside
    /// the caret's own line.
    caret_line: usize = 0,
    caret_x: f32 = 0,
    physical_caret_width: f32 = 0,
    line_height: f32 = 0,
    shown_lines: u16 = 0,
    lines_cb: ?*const fn (ctx: *anyopaque, lines: u16) void = null,
    lines_ctx: *anyopaque = undefined,
    /// The constraints of the last layout, so `refresh` can lay out again
    /// between frames.
    last_constraints: ?layout.BoxConstraints = null,

    fn dropLayout(self: *RenderCaretText) void {
        if (self.para) |*p| {
            p.deinit(self.gpa);
            self.para = null;
        }
        if (self.placeholder_line) |*l| {
            l.deinit(self.gpa);
            self.placeholder_line = null;
        }
    }

    /// `layoutParagraph` gives no line after a final line feed. The caret needs
    /// one to stand on, so this adds an empty line there.
    fn layoutText(self: *RenderCaretText, wrap_width: f32) !text_layout.Paragraph {
        var p = try text_layout.layoutParagraph(
            self.gpa,
            self.font,
            self.text,
            self.physical_size,
            self.text_metrics.*,
            wrap_width,
        );
        if (self.text.len == 0 or self.text[self.text.len - 1] != '\n') return p;
        errdefer p.deinit(self.gpa);
        const last = p.lines[p.lines.len - 1];
        p.lines = try self.gpa.realloc(p.lines, p.lines.len + 1);
        p.lines[p.lines.len - 1] = .{
            .glyphs = &.{},
            .width = 0,
            .height = last.height,
            .ascent = last.ascent,
            .start = self.text.len,
            .end = self.text.len,
        };
        p.height += last.height;
        return p;
    }

    /// The line that holds `byte`. A caret at a wrap that broke inside a word
    /// belongs to the next line. A caret before a break space or a newline
    /// belongs to the line that ends there.
    fn lineOf(self: *const RenderCaretText, byte: usize) usize {
        const p = self.para orelse return 0;
        for (p.lines, 0..) |l, i| {
            if (byte < l.end) return i;
            const last = i + 1 == p.lines.len;
            if (byte == l.end and (last or p.lines[i + 1].start > l.end)) return i;
        }
        return p.lines.len - 1;
    }

    /// The byte nearest to `x` on `line`, on a cluster boundary. One glyph is
    /// laid out per character, so the glyphs and the code points go in step.
    fn byteAt(self: *const RenderCaretText, line: usize, x: f32) usize {
        const p = self.para orelse return 0;
        const l = p.lines[@min(line, p.lines.len - 1)];
        var b = l.end;
        var at = l.start;
        for (l.glyphs, 0..) |g, i| {
            if (at >= l.end) break;
            const right = if (i + 1 < l.glyphs.len) l.glyphs[i + 1].x else l.width;
            if ((g.x + right) / 2 > x) {
                b = at;
                break;
            }
            at += std.unicode.utf8ByteSequenceLength(self.text[at]) catch 1;
        }
        const before = grapheme.previousBoundary(self.text, b);
        return if (grapheme.nextBoundary(self.text, before) == b) b else before;
    }

    /// Takes a new text and caret and lays out again with the last constraints.
    /// The State calls this before a line move when its buffer changed since
    /// the last frame. On a failed copy the old text stays.
    fn refresh(self: *RenderCaretText, text: []const u8, caret: usize) void {
        const owned = self.gpa.dupe(u8, text) catch return;
        self.gpa.free(self.text);
        self.text = owned;
        self.caret = @min(caret, owned.len);
        if (self.last_constraints) |c| _ = layoutFn(&self.base, c);
    }

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderCaretText = @fieldParentPtr("base", base);
        self.last_constraints = c;
        self.dropLayout();
        self.physical_size = self.size * c.scale;
        self.physical_caret_width = switch (self.text_metrics.*) {
            // A character grid has no sub cell position, so a thin bar would
            // either vanish or tint a whole cell anyway. A full cell block is
            // what a terminal cursor looks like.
            .mono => |m| m.advance,
            .proportional => self.caret_width * c.scale,
        };

        const wrap_width: f32 = if (self.max_lines > 1 and std.math.isFinite(c.max_width))
            @max(1, c.max_width - self.physical_caret_width)
        else
            0;
        const p = self.layoutText(wrap_width) catch {
            // Measuring failed, so there is nothing to place a caret against.
            // The field keeps its box and paints nothing this frame.
            return c.constrain(.zero);
        };
        self.para = p;
        self.line_height = p.lines[0].height;

        const caret = @min(self.caret, self.text.len);
        self.caret_line = self.lineOf(caret);
        const cl = p.lines[self.caret_line];
        const index = characterCount(self.text[cl.start..@max(cl.start, @min(caret, cl.end))]);
        self.caret_x = if (index >= cl.glyphs.len) cl.width else cl.glyphs[index].x;

        const count: u16 = @intCast(@min(p.lines.len, std.math.maxInt(u16)));
        const shown = std.math.clamp(count, self.min_lines, self.max_lines);
        const height = @as(f32, @floatFromInt(shown)) * self.line_height;

        // An unbounded width has no view to scroll inside, so the field reports
        // its natural width. Everywhere else it fills what it was offered.
        const width = if (std.math.isInf(c.max_width)) p.width + self.physical_caret_width else c.max_width;
        const size = c.constrain(.{ .width = width, .height = height });

        if (self.caret_line < self.first_line) self.first_line = self.caret_line;
        if (self.caret_line >= self.first_line + shown) self.first_line = self.caret_line + 1 - shown;
        self.first_line = @min(self.first_line, p.lines.len -| shown);

        if (self.max_lines == 1) {
            // Keep the caret inside the view. A long prompt in a narrow field
            // then stays usable, because what the user is typing is always on
            // screen.
            if (self.caret_x < self.scroll) self.scroll = self.caret_x;
            const right_edge = self.scroll + size.width - self.physical_caret_width;
            if (self.caret_x > right_edge) self.scroll = self.caret_x - size.width + self.physical_caret_width;
            const max_scroll = @max(@as(f32, 0), p.width + self.physical_caret_width - size.width);
            self.scroll = std.math.clamp(self.scroll, 0, max_scroll);
        } else {
            self.scroll = 0;
        }

        if (self.text.len == 0 and self.placeholder.len > 0) {
            // A missing placeholder costs nothing the user typed, so a failure
            // only hides it.
            self.placeholder_line = text_layout.layoutLine(
                self.gpa,
                self.font,
                self.placeholder,
                self.physical_size,
                self.text_metrics.*,
            ) catch null;
        }

        if (shown != self.shown_lines) {
            self.shown_lines = shown;
            if (self.lines_cb) |f| f(self.lines_ctx, shown);
        }
        return size;
    }

    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderCaretText = @fieldParentPtr("base", base);
        const p = self.para orelse return;
        const last = @min(self.first_line + self.shown_lines, p.lines.len);
        // The caret goes down first so a glyph under a block caret still reads.
        if (self.caret_visible and self.caret_line >= self.first_line and self.caret_line < last) {
            const row: f32 = @floatFromInt(self.caret_line - self.first_line);
            try cv.fillRRect(.{
                .x = offset.x + self.caret_x - self.scroll,
                .y = offset.y + row * self.line_height,
                .width = self.physical_caret_width,
                .height = self.line_height,
            }, 0, self.caret_color);
        }
        for (p.lines[self.first_line..last], 0..) |l, k| {
            if (l.start == l.end) continue;
            try cv.drawText(.{
                .glyphs = l.glyphs,
                .text = self.text[l.start..l.end],
                .font = @ptrCast(self.font),
                .size = self.physical_size,
                .color = self.color,
                .origin = .{
                    .x = offset.x - self.scroll,
                    .y = offset.y + @as(f32, @floatFromInt(k)) * self.line_height,
                },
                .ascent = l.ascent,
            });
        }
        if (self.placeholder_line) |l| {
            try cv.drawText(.{
                .glyphs = l.glyphs,
                .text = self.placeholder,
                .font = @ptrCast(self.font),
                .size = self.physical_size,
                .color = self.placeholder_color,
                .origin = offset,
                .ascent = l.ascent,
            });
        }
    }

    /// The State may already be gone here, so this touches only its own data.
    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderCaretText = @fieldParentPtr("base", base);
        self.dropLayout();
        gpa.free(self.text);
        gpa.free(self.placeholder);
        gpa.destroy(self);
    }
};

/// The leaf the TextField's State builds. Private: a caller configures the field,
/// not the view inside it.
const CaretText = struct {
    text: []const u8,
    caret: usize,
    caret_visible: bool,
    font: *Font,
    size: f32,
    color: geom.Color,
    caret_color: geom.Color,
    caret_width: f32,
    min_lines: u16,
    max_lines: u16,
    placeholder: []const u8,
    placeholder_color: geom.Color,
    lines_cb: ?*const fn (ctx: *anyopaque, lines: u16) void,
    lines_ctx: *anyopaque,
    /// Where the State keeps a pointer to the render object.
    slot: *?*RenderCaretText,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    fn widget(self: *const CaretText) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const CaretText = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const owned = try gpa.dupe(u8, self.text);
        errdefer gpa.free(owned);
        const owned_placeholder = try gpa.dupe(u8, self.placeholder);
        errdefer gpa.free(owned_placeholder);
        const ro = try gpa.create(RenderCaretText);
        errdefer gpa.destroy(ro);
        ro.* = .{
            .base = .{
                .layoutFn = RenderCaretText.layoutFn,
                .paintFn = RenderCaretText.paintFn,
                .destroyFn = RenderCaretText.destroyFn,
            },
            .gpa = gpa,
            .text = owned,
            .caret = @min(self.caret, owned.len),
            .caret_visible = self.caret_visible,
            .font = self.font,
            .size = self.size,
            .color = self.color,
            .caret_color = self.caret_color,
            .caret_width = self.caret_width,
            .text_metrics = &bctx.owner.text_metrics,
            .min_lines = self.min_lines,
            .max_lines = self.max_lines,
            .placeholder = owned_placeholder,
            .placeholder_color = self.placeholder_color,
            .lines_cb = self.lines_cb,
            .lines_ctx = self.lines_ctx,
        };
        const el = try gpa.create(Element);
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(CaretText),
            .render_object = &ro.base,
            .depth = phantom.widget.depthOf(parent),
        };
        self.slot.* = ro;
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        _ = bctx;
        const self: *const CaretText = @ptrCast(@alignCast(ptr));
        const ro: *RenderCaretText = @fieldParentPtr("base", el.render_object.?);
        // Duplicate before freeing, so a failed allocation leaves the old string
        // in place rather than a dangling one.
        const owned = try ro.gpa.dupe(u8, self.text);
        errdefer ro.gpa.free(owned);
        const owned_placeholder = try ro.gpa.dupe(u8, self.placeholder);
        ro.gpa.free(ro.text);
        ro.text = owned;
        ro.gpa.free(ro.placeholder);
        ro.placeholder = owned_placeholder;
        ro.caret = @min(self.caret, owned.len);
        ro.caret_visible = self.caret_visible;
        ro.font = self.font;
        ro.size = self.size;
        ro.color = self.color;
        ro.caret_color = self.caret_color;
        ro.caret_width = self.caret_width;
        ro.min_lines = self.min_lines;
        ro.max_lines = self.max_lines;
        ro.placeholder_color = self.placeholder_color;
        ro.lines_cb = self.lines_cb;
        ro.lines_ctx = self.lines_ctx;
        self.slot.* = ro;
        ro.dropLayout();
    }
};

// ---------------------------------------------------------------------------
// The widget
// ---------------------------------------------------------------------------

/// Reads and sets a mounted field's text and caret, for history, completion and
/// anything else that edits the field from outside. Owned by the application
/// and handed to one field through `TextField.controller`. Before the field
/// mounts and after it unmounts, reads are empty and writes do nothing.
pub const TextFieldController = struct {
    state: ?*TextField.State = null,

    /// The text. Borrowed and valid until the next edit.
    pub fn text(self: *const TextFieldController) []const u8 {
        const s = self.state orelse return "";
        return s.buf.items;
    }

    /// The caret position in bytes, always on a cluster boundary.
    pub fn caret(self: *const TextFieldController) usize {
        const s = self.state orelse return 0;
        return s.caret;
    }

    /// Replaces the text and puts the caret at its end. `on_change` does not
    /// fire, because the caller already knows what it set.
    pub fn setText(self: *TextFieldController, new_text: []const u8) error{OutOfMemory}!void {
        const s = self.state orelse return;
        s.buf.clearRetainingCapacity();
        try s.buf.appendSlice(s.base.gpa(), new_text);
        s.caret = s.buf.items.len;
        s.afterMove();
    }

    /// Moves the caret to `at`, or to the cluster boundary before it when `at`
    /// is inside a cluster. Past the end is the end.
    pub fn setCaret(self: *TextFieldController, at: usize) void {
        const s = self.state orelse return;
        const items = s.buf.items;
        const end = @min(at, items.len);
        const before = grapheme.previousBoundary(items, end);
        s.caret = if (grapheme.nextBoundary(items, before) == end) end else before;
        s.afterMove();
    }
};

pub const TextField = struct {
    /// The text the field starts with. It is copied on mount and the field owns
    /// its text from then on, so a later rebuild does not overwrite what the user
    /// typed.
    text: []const u8 = "",
    /// Logical font size. Null takes the theme's.
    size: ?f32 = null,
    /// Null takes the theme's text colour.
    color: ?geom.Color = null,
    /// Null takes the theme's accent, which is the colour that marks the active
    /// element everywhere else.
    caret_color: ?geom.Color = null,
    /// Null takes the theme's body font.
    font: ?*Font = null,
    /// Logical caret width where text is proportional.
    caret_width: f32 = 2,
    /// Half of a blink cycle in nanoseconds. Zero or less holds the caret steady.
    blink_period: Ticker.Nanos = default_blink_period,
    /// Called after every edit with the whole text. The slice is borrowed and is
    /// valid for the call only.
    on_change: ?*const fn (ctx: *anyopaque, text: []const u8) void = null,
    ctx: *anyopaque = undefined,
    /// The name `FocusManager.focusById` moves the focus here by. This is what a
    /// click on the field routes through, because a pointer hit gives a render
    /// object and the focus is held by name. Null leaves the field reachable
    /// through Tab only.
    id: ?[]const u8 = null,
    /// Sees every key before the field does, with `ctx`. Return true to use the
    /// key, and the field then ignores it. This is where completion, history and
    /// keys with a meaning of their own go, Tab included.
    on_key: ?*const fn (ctx: *anyopaque, ev: input.KeyEvent) bool = null,
    /// Reads and sets the text and the caret from outside the field.
    controller: ?*TextFieldController = null,
    /// The most lines the field shows. Past this it scrolls by whole lines.
    /// One gives a single line field that scrolls sideways.
    max_lines: u16 = 1,
    /// The fewest lines the field shows, even while the text is shorter.
    min_lines: u16 = 1,
    /// Drawn in the theme's muted colour while the text is empty.
    placeholder: ?[]const u8 = null,
    /// Called with `ctx` when the number of shown lines changes, so a parent
    /// can give the field more room on the next frame.
    on_lines_change: ?*const fn (ctx: *anyopaque, lines: u16) void = null,

    pub fn widget(self: *const TextField) Widget {
        return phantom.StatefulWidget(TextField, self);
    }

    pub const State = struct {
        base: phantom.StateBase = .{},
        /// The field's own text. Owned, so a `KeyEvent.text` slice that borrows
        /// decoder storage is copied in here and never held.
        buf: std.ArrayList(u8) = .empty,
        /// Caret position in bytes, always on a character boundary.
        caret: usize = 0,
        focused: bool = false,
        /// The blink phase. The caret only draws when the field is focused AND
        /// this is on.
        caret_on: bool = true,
        ticker: Ticker = undefined,
        blink_period: Ticker.Nanos = default_blink_period,
        on_change: ?*const fn (ctx: *anyopaque, text: []const u8) void = null,
        user_ctx: *anyopaque = undefined,
        font: ?*Font = null,
        size: ?f32 = null,
        color: ?geom.Color = null,
        caret_color: ?geom.Color = null,
        caret_width: f32 = 2,
        /// Borrowed from the config. The `Focus` widget below copies it, so the
        /// slice only has to survive until the next build.
        id: ?[]const u8 = null,
        on_key: ?*const fn (ctx: *anyopaque, ev: input.KeyEvent) bool = null,
        controller: ?*TextFieldController = null,
        max_lines: u16 = 1,
        min_lines: u16 = 1,
        /// Borrowed from the config. `CaretText` copies it.
        placeholder: ?[]const u8 = null,
        on_lines_change: ?*const fn (ctx: *anyopaque, lines: u16) void = null,
        /// The mounted render object, so line moves can ask it about lines.
        ro: ?*RenderCaretText = null,
        // The built configs live here so their addresses stay stable across the
        // build, which is what a Widget borrows.
        view: CaretText = undefined,
        focus_config: phantom.Focus = undefined,

        pub fn initState(s: *State, config: *const TextField) anyerror!void {
            s.takeStyle(config);
            try s.buf.appendSlice(s.base.gpa(), config.text);
            s.caret = s.buf.items.len;
            s.ticker = .{
                .scheduler = s.base.scheduler(),
                .ctx = s,
                .on_tick = State.onFrame,
            };
            s.attach(config.controller);
        }

        pub fn didUpdateWidget(s: *State, config: *const TextField) anyerror!void {
            // The text is deliberately not taken again: the field owns it after
            // mount, and a parent rebuild must not undo what the user typed.
            s.takeStyle(config);
            if (config.controller != s.controller) {
                s.detach();
                s.attach(config.controller);
            }
        }

        pub fn dispose(s: *State) void {
            s.ro = null;
            // Without this the scheduler keeps calling a freed State every frame.
            s.ticker.deinit();
            s.detach();
            s.buf.deinit(s.base.gpa());
        }

        fn attach(s: *State, controller: ?*TextFieldController) void {
            s.controller = controller;
            if (controller) |c| c.state = s;
        }

        fn detach(s: *State) void {
            const c = s.controller orelse return;
            if (c.state == s) c.state = null;
            s.controller = null;
        }

        fn takeStyle(s: *State, config: *const TextField) void {
            s.on_change = config.on_change;
            s.user_ctx = config.ctx;
            s.font = config.font;
            s.size = config.size;
            s.color = config.color;
            s.caret_color = config.caret_color;
            s.caret_width = config.caret_width;
            s.blink_period = config.blink_period;
            s.id = config.id;
            s.on_key = config.on_key;
            s.max_lines = config.max_lines;
            s.min_lines = config.min_lines;
            s.placeholder = config.placeholder;
            s.on_lines_change = config.on_lines_change;
        }

        /// The text as it stands. Borrowed and valid until the next edit.
        pub fn value(s: *const State) []const u8 {
            return s.buf.items;
        }

        pub fn build(s: *State, b: *BuildContext) anyerror!Widget {
            const td = phantom.Theme.of(b);
            const max_lines = @max(1, s.max_lines);
            s.view = .{
                .text = s.buf.items,
                .caret = s.caret,
                .caret_visible = s.focused and s.caret_on,
                .font = s.font orelse td.body_font,
                .size = s.size orelse td.text_size,
                .color = s.color orelse td.text_color,
                .caret_color = s.caret_color orelse td.accent,
                .caret_width = s.caret_width,
                .max_lines = max_lines,
                .min_lines = @min(@max(1, s.min_lines), max_lines),
                .placeholder = s.placeholder orelse "",
                .placeholder_color = td.colors.fg_muted,
                .lines_cb = State.onLines,
                .lines_ctx = s,
                .slot = &s.ro,
            };
            s.focus_config = .{
                .child = s.view.widget(),
                .on_key = State.onKey,
                .on_focus_change = State.onFocusChange,
                .ctx = s,
                .id = s.id,
            };
            return s.focus_config.widget();
        }

        // -- editing -------------------------------------------------------

        fn insert(s: *State, bytes: []const u8) bool {
            s.buf.insertSlice(s.base.gpa(), s.caret, bytes) catch {
                s.base.sink().report(.oom, "text field could not insert typed text");
                return false;
            };
            s.caret += bytes.len;
            return true;
        }

        fn backspace(s: *State) bool {
            if (s.caret == 0) return false; // no edit, and no unsigned underflow
            const start = grapheme.previousBoundary(s.buf.items, s.caret);
            s.buf.replaceRangeAssumeCapacity(start, s.caret - start, &.{});
            s.caret = start;
            return true;
        }

        fn deleteForward(s: *State) bool {
            if (s.caret >= s.buf.items.len) return false;
            const end = grapheme.nextBoundary(s.buf.items, s.caret);
            s.buf.replaceRangeAssumeCapacity(s.caret, end - s.caret, &.{});
            return true;
        }

        /// A caret that just moved must be visible, or the user cannot see where
        /// the next character will land.
        fn showCaret(s: *State) void {
            s.caret_on = true;
            s.ticker.reset();
        }

        fn afterEdit(s: *State) void {
            s.showCaret();
            if (s.on_change) |f| f(s.user_ctx, s.buf.items);
            phantom.markNeedsBuild(s);
        }

        fn afterMove(s: *State) void {
            s.showCaret();
            phantom.markNeedsBuild(s);
        }

        // -- callbacks -----------------------------------------------------

        fn onKey(ctx: *anyopaque, ev: input.KeyEvent) bool {
            const s: *State = @ptrCast(@alignCast(ctx));
            if (s.on_key) |f| {
                if (f(s.user_ctx, ev)) return true;
            }
            if (ev.action == .release) return false;
            // Keysym is not exhaustive, because a printable key carries a unicode
            // keysym, so the default prong is the printable path.
            switch (ev.keysym) {
                .backspace => {
                    if (s.backspace()) s.afterEdit() else s.afterMove();
                    return true;
                },
                .delete => {
                    if (s.deleteForward()) s.afterEdit() else s.afterMove();
                    return true;
                },
                .left => {
                    s.caret = grapheme.previousBoundary(s.buf.items, s.caret);
                    s.afterMove();
                    return true;
                },
                .right => {
                    s.caret = grapheme.nextBoundary(s.buf.items, s.caret);
                    s.afterMove();
                    return true;
                },
                .home => {
                    s.caret = 0;
                    s.afterMove();
                    return true;
                },
                .end => {
                    s.caret = s.buf.items.len;
                    s.afterMove();
                    return true;
                },
                else => {
                    // The decoder already resolved what the key produces, so the
                    // keysym is never consulted here. `text` borrows decoder
                    // storage, so `insert` copies it before returning.
                    const typed = ev.text orelse return false;
                    if (typed.len == 0) return false;
                    if (!s.insert(typed)) return true;
                    s.afterEdit();
                    return true;
                },
            }
        }

        fn onLines(ctx: *anyopaque, lines: u16) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            if (s.on_lines_change) |f| f(s.user_ctx, lines);
        }

        fn onFocusChange(ctx: *anyopaque, focused: bool) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            s.focused = focused;
            if (focused) {
                s.caret_on = true;
                s.ticker.reset();
                s.ticker.start(s.base.gpa()) catch {
                    // A caret that cannot blink still shows, so the field stays
                    // usable. The fault names why it stopped blinking.
                    s.base.sink().report(.oom, "text field caret blink not scheduled");
                };
            } else {
                s.ticker.stop();
            }
            phantom.markNeedsBuild(s);
        }

        fn onFrame(ctx: *anyopaque, elapsed: Ticker.Nanos) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            if (s.blink_period <= 0) return;
            const on = @rem(@divTrunc(elapsed, s.blink_period), 2) == 0;
            // Only a phase change costs a rebuild. Otherwise the field would
            // rebuild on every frame and drown the dirty queue.
            if (on == s.caret_on) return;
            s.caret_on = on;
            phantom.markNeedsBuild(s);
        }
    };
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Recorder = struct {
    calls: u32 = 0,
    last: [64]u8 = undefined,
    last_len: usize = 0,

    fn onChange(ctx: *anyopaque, value: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const n = @min(value.len, self.last.len);
        @memcpy(self.last[0..n], value[0..n]);
        self.last_len = n;
    }

    fn text(self: *const Recorder) []const u8 {
        return self.last[0..self.last_len];
    }
};

/// A mounted field with a focus manager wired to it. Every test drives keys the
/// way the terminal and the compositor do, through the manager.
const Fixture = struct {
    harness: testing.Harness,
    manager: phantom.FocusManager = .{},
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, field: *const TextField) !Fixture {
        return .{ .harness = try testing.mount(gpa, field.widget()), .gpa = gpa };
    }

    fn deinit(self: *Fixture) void {
        self.harness.deinit();
        self.manager.deinit(self.gpa);
    }

    fn state(self: *Fixture) !*TextField.State {
        return self.harness.stateOf(testing.find.byType(TextField), TextField.State);
    }

    /// Re-collect the focus order, which a real frame loop does after every build.
    /// The owner is wired here rather than in `init`, because a Fixture returned by
    /// value would carry a pointer to the local it was built in.
    fn refresh(self: *Fixture) !void {
        self.harness.owner.focus = &self.manager;
        try self.manager.collect(self.gpa, self.harness.root);
    }

    fn focus(self: *Fixture) !void {
        try self.refresh();
        self.manager.focusNext();
    }

    fn typeText(self: *Fixture, s: []const u8) void {
        _ = self.manager.dispatch(.{ .keysym = .no_symbol, .text = s });
    }

    fn press(self: *Fixture, key: input.Keysym) void {
        _ = self.manager.dispatch(.{ .keysym = key });
    }
};

test "a named TextField takes the focus by id, which is what a click on it does" {
    const gpa = std.testing.allocator;
    var field = TextField{ .id = "prompt", .text = "" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.refresh();

    // A pointer hit gives the application a place on screen, not a Tab count, so
    // this is the only way a click can reach one field out of several.
    try std.testing.expect(f.manager.focusById("prompt"));
    f.typeText("hi");
    const s = try f.state();
    try std.testing.expectEqualStrings("hi", s.value());
}

test "an unnamed TextField answers to no id, so a stray name cannot focus it" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.refresh();

    try std.testing.expect(!f.manager.focusById("prompt"));
    f.typeText("hi");
    const s = try f.state();
    // Nothing holds the focus, so the key went nowhere.
    try std.testing.expectEqualStrings("", s.value());
}

test "typing inserts at the caret and not at the end of the text" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "ac" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    try std.testing.expectEqualStrings("ac", s.value());
    f.press(.left); // caret now sits between 'a' and 'c'
    f.typeText("b");
    try std.testing.expectEqualStrings("abc", s.value());
    try std.testing.expectEqual(@as(usize, 2), s.caret);
}

test "backspace at position zero changes nothing and does not underflow" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "hi" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    f.press(.home);
    try std.testing.expectEqual(@as(usize, 0), s.caret);
    f.press(.backspace);
    f.press(.backspace);
    try std.testing.expectEqualStrings("hi", s.value());
    try std.testing.expectEqual(@as(usize, 0), s.caret);
}

test "backspace removes the character before the caret and leaves the rest" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "abc" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    f.press(.left); // caret between 'b' and 'c'
    f.press(.backspace);
    try std.testing.expectEqualStrings("ac", s.value());
    try std.testing.expectEqual(@as(usize, 1), s.caret);
}

test "delete removes the character after the caret and is a no-op at the end" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "abc" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    f.press(.delete); // caret is at the end, so nothing to remove
    try std.testing.expectEqualStrings("abc", s.value());
    f.press(.home);
    f.press(.delete);
    try std.testing.expectEqualStrings("bc", s.value());
    try std.testing.expectEqual(@as(usize, 0), s.caret);
}

test "the left arrow steps over a whole multi byte character" {
    // The euro sign is three bytes. A caret that steps one byte lands inside the
    // sequence, and the next insert splits the character into rubbish.
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "a\u{20AC}b" }; // 1 + 3 + 1 bytes
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    try std.testing.expectEqual(@as(usize, 5), s.value().len);
    try std.testing.expectEqual(@as(usize, 5), s.caret);

    f.press(.left); // over 'b'
    try std.testing.expectEqual(@as(usize, 4), s.caret);
    f.press(.left); // over the whole euro sign, three bytes at once
    try std.testing.expectEqual(@as(usize, 1), s.caret);
    f.press(.left); // over 'a'
    try std.testing.expectEqual(@as(usize, 0), s.caret);

    // Stepping right lands on the same boundaries in the other direction.
    f.press(.right);
    try std.testing.expectEqual(@as(usize, 1), s.caret);
    f.press(.right);
    try std.testing.expectEqual(@as(usize, 4), s.caret);
}

test "the caret and backspace move over a whole grapheme cluster" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "e\u{301}\u{1F44D}\u{1F3FD}" }; // 3 + 8 bytes
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    f.press(.left); // over the thumb and its skin tone together
    try std.testing.expectEqual(@as(usize, 3), s.caret);
    f.press(.backspace); // the accent goes with its letter
    try std.testing.expectEqualStrings("\u{1F44D}\u{1F3FD}", s.value());
    try std.testing.expectEqual(@as(usize, 0), s.caret);
}

test "on_key sees a key first, and a key it uses never reaches the field" {
    const gpa = std.testing.allocator;
    const Completer = struct {
        tabs: u32 = 0,
        fn onKey(ctx: *anyopaque, ev: input.KeyEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (ev.keysym != .tab) return false;
            self.tabs += 1;
            return true;
        }
    };
    var completer = Completer{};
    var field = TextField{ .text = "ab", .on_key = Completer.onKey, .ctx = &completer, .id = "a" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    f.press(.tab);
    try std.testing.expectEqual(@as(u32, 1), completer.tabs);
    // Tab did not move the focus away, because the hook used it.
    try std.testing.expect(s.focused);
    f.typeText("c");
    try std.testing.expectEqualStrings("abc", s.value());
}

test "a controller sets the text and the caret, and reads them back" {
    const gpa = std.testing.allocator;
    var controller = TextFieldController{};
    try std.testing.expectEqualStrings("", controller.text());

    var field = TextField{ .text = "draft", .controller = &controller };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    try std.testing.expectEqualStrings("draft", controller.text());
    try controller.setText("git status");
    try std.testing.expectEqual(@as(usize, 10), controller.caret());
    controller.setCaret(3);
    f.typeText("!");
    try std.testing.expectEqualStrings("git! status", controller.text());

    try controller.setText("a\u{20AC}");
    controller.setCaret(2); // inside the euro sign
    try std.testing.expectEqual(@as(usize, 1), controller.caret());
    controller.setCaret(99);
    try std.testing.expectEqual(@as(usize, 4), controller.caret());
}

test "a controller forgets its field when the field unmounts" {
    const gpa = std.testing.allocator;
    var controller = TextFieldController{};
    var field = TextField{ .text = "x", .controller = &controller };
    {
        var f = try Fixture.init(gpa, &field);
        defer f.deinit();
        try std.testing.expect(controller.state != null);
    }
    try std.testing.expect(controller.state == null);
    try controller.setText("ignored");
    try std.testing.expectEqualStrings("", controller.text());
}

test "backspace over a multi byte character removes the whole character" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "a\u{20AC}" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    f.press(.backspace);
    try std.testing.expectEqualStrings("a", s.value());
    // A one byte removal would leave a broken sequence behind.
    try std.testing.expect(std.unicode.utf8ValidateSlice(s.value()));
}

test "delete over a multi byte character removes the whole character" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "\u{20AC}a" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    f.press(.home);
    f.press(.delete);
    try std.testing.expectEqualStrings("a", s.value());
    try std.testing.expect(std.unicode.utf8ValidateSlice(s.value()));
}

test "the field copies the borrowed key text instead of holding the decoder's slice" {
    // KeyEvent.text borrows decoder storage and is valid for the callback only.
    // A field that keeps the slice reads freed or reused memory on the next key.
    const gpa = std.testing.allocator;
    var field = TextField{};
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    // A mutable buffer standing in for the decoder's scratch storage.
    var decoder_scratch = [_]u8{ 'h', 'i' };
    _ = f.manager.dispatch(.{ .keysym = .no_symbol, .text = decoder_scratch[0..] });

    // The decoder reuses its buffer for the next sequence.
    @memcpy(decoder_scratch[0..], "ZZ");

    const s = try f.state();
    try std.testing.expectEqualStrings("hi", s.value());
}

test "an unfocused field ignores every key" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "start" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.refresh(); // collected, but nothing is focused

    const s = try f.state();
    f.typeText("x");
    f.press(.backspace);
    f.press(.home);
    try std.testing.expectEqualStrings("start", s.value());
    try std.testing.expectEqual(@as(usize, 5), s.caret);

    // Focusing it makes the very same keys land.
    f.focus() catch unreachable;
    f.typeText("x");
    try std.testing.expectEqualStrings("startx", s.value());
}

test "on_change fires once per edit and never once per frame" {
    const gpa = std.testing.allocator;
    var recorder = Recorder{};
    var field = TextField{ .on_change = Recorder.onChange, .ctx = &recorder };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    f.typeText("a");
    f.typeText("b");
    f.typeText("c");
    try std.testing.expectEqual(@as(u32, 3), recorder.calls);
    try std.testing.expectEqualStrings("abc", recorder.text());

    // Caret movement is not an edit.
    f.press(.left);
    f.press(.home);
    f.press(.end);
    try std.testing.expectEqual(@as(u32, 3), recorder.calls);

    // Nor is a frame. Sixty of them blink the caret several times over.
    var frame: u32 = 0;
    while (frame < 60) : (frame += 1) {
        f.harness.owner.scheduler.tick(@as(Ticker.Nanos, frame) * 100_000_000);
    }
    try std.testing.expectEqual(@as(u32, 3), recorder.calls);

    // A backspace that removes nothing is not an edit either.
    f.press(.home);
    f.press(.backspace);
    try std.testing.expectEqual(@as(u32, 3), recorder.calls);

    // A backspace that does remove something is.
    f.press(.end);
    f.press(.backspace);
    try std.testing.expectEqual(@as(u32, 4), recorder.calls);
    try std.testing.expectEqualStrings("ab", recorder.text());
}

test "the caret blinks off and on again as real time passes" {
    const gpa = std.testing.allocator;
    var field = TextField{ .blink_period = 100 };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    try std.testing.expect(s.caret_on);
    f.harness.owner.scheduler.tick(0); // baselines the ticker
    f.harness.owner.scheduler.tick(150); // one and a half periods in: off
    try std.testing.expect(!s.caret_on);
    f.harness.owner.scheduler.tick(250); // two and a half: on again
    try std.testing.expect(s.caret_on);
}

test "an unfocused field draws no caret and a focused one draws it" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "hi" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    f.harness.viewport = .{ .width = 200, .height = 40 };
    try f.harness.pump();

    // Unfocused: the text run only, no caret rectangle.
    try std.testing.expectEqual(@as(usize, 1), f.harness.canvas.list.primitives.items.len);
    _ = f.harness.canvas.list.primitives.items[0].text;

    try f.focus();
    try f.harness.pump();
    const prims = f.harness.canvas.list.primitives.items;
    try std.testing.expectEqual(@as(usize, 2), prims.len);
    // The caret goes down first so a glyph under a block caret still reads.
    const caret = prims[0].rrect;
    try std.testing.expect(caret.rect.width > 0);
    try std.testing.expect(caret.rect.height > 0);
}

test "the caret is drawn at the theme accent colour" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    f.harness.viewport = .{ .width = 200, .height = 40 };
    try f.focus();
    try f.harness.pump();

    const accent = phantom.theme.defaultTheme(f.harness.owner).accent;
    const caret = f.harness.canvas.list.primitives.items[0].rrect;
    try std.testing.expectEqual(accent, caret.color);
}

test "the caret width scales with the layout scale" {
    // Without the scale multiply the caret is half width on a HiDPI display.
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "", .caret_width = 3 };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    f.harness.viewport = .{ .width = 200, .height = 40 };
    try f.focus();

    try f.harness.pump();
    try std.testing.expectEqual(@as(f32, 3), f.harness.canvas.list.primitives.items[0].rrect.rect.width);

    f.harness.dpr = 2.0;
    try f.harness.pump();
    try std.testing.expectEqual(@as(f32, 6), f.harness.canvas.list.primitives.items[0].rrect.rect.width);
}

test "a long line scrolls so the caret stays inside the field" {
    const gpa = std.testing.allocator;
    var field = TextField{};
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    // A narrow field, so a handful of characters already overflow it.
    f.harness.viewport = .{ .width = 60, .height = 40 };
    try f.focus();

    // Type far more than fits.
    var i: u32 = 0;
    while (i < 40) : (i += 1) f.typeText("W");
    try f.harness.pump();

    const prims = f.harness.canvas.list.primitives.items;
    const caret = prims[0].rrect;
    const run = prims[1].text;
    // The run scrolled left, which is what puts the end of the line on screen.
    try std.testing.expect(run.origin.x < 0);
    // The caret is inside the field, not past its right edge.
    try std.testing.expect(caret.rect.x >= 0);
    try std.testing.expect(caret.rect.x + caret.rect.width <= 60.001);

    // Home brings the view back to the start of the line.
    f.press(.home);
    try f.harness.pump();
    const home_prims = f.harness.canvas.list.primitives.items;
    try std.testing.expectEqual(@as(f32, 0), home_prims[1].text.origin.x);
    try std.testing.expectEqual(@as(f32, 0), home_prims[0].rrect.rect.x);
}

test "in a terminal the caret covers a whole cell and the text lands on cells" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "hi" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    // One row, because a tight parent wins over the size a child asks for: in a
    // three row grid the field fills all three and the caret with it.
    var r = try f.harness.tuiRender(20, 1, 8, 16);
    defer r.deinit();

    try r.expectCell(0, 0, 'h');
    try r.expectCell(1, 0, 'i');

    // The caret sits after the text and fills its cell, so a terminal shows a
    // block cursor rather than a sliver that rounds away to nothing.
    const prims = f.harness.canvas.list.primitives.items;
    const caret = prims[0].rrect;
    try std.testing.expectEqual(@as(f32, 8), caret.rect.width);
    try std.testing.expectEqual(@as(f32, 16), caret.rect.height);
    try std.testing.expectEqual(@as(f32, 16), caret.rect.x); // two cells in
    try r.expectBg(2, 0, phantom.theme.defaultTheme(f.harness.owner).accent);
}

test "unmounting a focused field cancels its blink registration" {
    // A ticker that outlives its State calls a freed pointer on the next frame.
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "x" };
    var f = try Fixture.init(gpa, &field);
    try f.focus();
    try std.testing.expectEqual(@as(usize, 1), f.harness.owner.scheduler.entries.items.len);

    const owner = f.harness.owner;
    f.harness.root.deinit(gpa);
    // The entry is cancelled rather than merely forgotten, so the next sweep
    // drops it instead of calling into the freed State.
    for (owner.scheduler.entries.items) |e| try std.testing.expect(e.cancelled);
    owner.scheduler.tick(1_000);
    try std.testing.expectEqual(@as(usize, 0), owner.scheduler.entries.items.len);

    // Tear down the rest by hand: the harness root was already freed above.
    // This mirrors `Harness.deinit` and has to be kept in step with it.
    f.harness.focus.deinit(gpa);
    owner.deinit();
    f.harness.canvas.deinit();
    f.harness.arena.deinit();
    gpa.destroy(f.harness.arena);
    gpa.destroy(f.harness.owner);
    gpa.destroy(f.harness.sink);
    gpa.destroy(f.harness.focus);
    f.manager.deinit(gpa);
}

test "characterCount counts characters and not bytes" {
    try std.testing.expectEqual(@as(usize, 0), characterCount(""));
    try std.testing.expectEqual(@as(usize, 3), characterCount("abc"));
    try std.testing.expectEqual(@as(usize, 3), characterCount("a\u{20AC}b"));
    try std.testing.expectEqual(@as(usize, 1), characterCount("\u{1F600}"));
}

/// Mounts `field` inside a Column, so its height is loose and it can grow.
fn mountLoose(gpa: std.mem.Allocator, field: *const TextField) !struct { h: testing.Harness, col: *phantom.widgets.Flex } {
    const col = try gpa.create(phantom.widgets.Flex);
    errdefer gpa.destroy(col);
    const children = try gpa.dupe(Widget, &.{field.widget()});
    errdefer gpa.free(children);
    col.* = phantom.Column(.{ .children = children });
    var h = try testing.mount(gpa, col.widget());
    h.viewport = .{ .width = 80, .height = 400 };
    h.owner.text_metrics = .{ .mono = mono.Mono.fromCell(8, 16) };
    return .{ .h = h, .col = col };
}

fn freeLoose(gpa: std.mem.Allocator, h: *testing.Harness, col: *phantom.widgets.Flex) void {
    h.deinit();
    gpa.free(col.children);
    gpa.destroy(col);
}

fn fieldRo(h: *testing.Harness) !*RenderCaretText {
    const s = try h.stateOf(testing.find.byType(TextField), TextField.State);
    return s.ro orelse error.NoRenderObject;
}

test "a multi-line field wraps at its width" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "alpha beta gamma", .max_lines = 4 };
    var m = try mountLoose(gpa, &field);
    defer freeLoose(gpa, &m.h, m.col);
    try m.h.pump();

    var runs: usize = 0;
    for (m.h.canvas.list.primitives.items) |p| switch (p) {
        .text => |t| {
            runs += 1;
            const last = t.glyphs[t.glyphs.len - 1];
            try std.testing.expect(t.origin.x >= 0);
            try std.testing.expect(t.origin.x + last.x + 8 <= 80);
        },
        else => {},
    };
    try std.testing.expect(runs > 1);
}

test "a multi-line field grows from min_lines to max_lines and then scrolls" {
    const gpa = std.testing.allocator;
    var controller = TextFieldController{};
    var field = TextField{ .text = "a", .min_lines = 1, .max_lines = 2, .controller = &controller };
    var m = try mountLoose(gpa, &field);
    defer freeLoose(gpa, &m.h, m.col);
    try m.h.pump();

    const ro = try fieldRo(&m.h);
    try std.testing.expectEqual(@as(f32, 16), ro.base.size.height);

    try controller.setText("alpha beta");
    try m.h.pump();
    try std.testing.expectEqual(@as(f32, 32), ro.base.size.height);

    try controller.setText("alpha beta gamma delta epsilon");
    try m.h.collectFocus();
    m.h.focus.focusNext();
    try m.h.pump();
    try std.testing.expectEqual(@as(f32, 32), ro.base.size.height);
    try std.testing.expectEqual(@as(usize, 3), ro.first_line);
    const caret = m.h.canvas.list.primitives.items[0].rrect;
    try std.testing.expect(caret.rect.y >= 0);
    try std.testing.expect(caret.rect.y + caret.rect.height <= 32);
}

test "min_lines reserves height while the text is short" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "a", .min_lines = 3, .max_lines = 5 };
    var m = try mountLoose(gpa, &field);
    defer freeLoose(gpa, &m.h, m.col);
    try m.h.pump();
    try std.testing.expectEqual(@as(f32, 48), (try fieldRo(&m.h)).base.size.height);
}

test "a newline in the text starts a new line" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "one\ntwo", .max_lines = 3 };
    var m = try mountLoose(gpa, &field);
    defer freeLoose(gpa, &m.h, m.col);
    try m.h.pump();

    const prims = m.h.canvas.list.primitives.items;
    try std.testing.expectEqual(@as(usize, 2), prims.len);
    try std.testing.expectEqualStrings("one", prims[0].text.text);
    try std.testing.expectEqualStrings("two", prims[1].text.text);
    try std.testing.expect(prims[0].text.origin.y != prims[1].text.origin.y);
}

test "the placeholder shows only while the text is empty" {
    const gpa = std.testing.allocator;
    var controller = TextFieldController{};
    var field = TextField{ .placeholder = "Type / for commands", .controller = &controller };
    var m = try mountLoose(gpa, &field);
    defer freeLoose(gpa, &m.h, m.col);
    try m.h.pump();

    const muted = phantom.theme.defaultTheme(m.h.owner).colors.fg_muted;
    var found = false;
    for (m.h.canvas.list.primitives.items) |p| switch (p) {
        .text => |t| if (std.mem.eql(u8, t.text, "Type / for commands")) {
            try std.testing.expectEqual(muted, t.color);
            found = true;
        },
        else => {},
    };
    try std.testing.expect(found);

    try controller.setText("x");
    try m.h.pump();
    for (m.h.canvas.list.primitives.items) |p| switch (p) {
        .text => |t| try std.testing.expectEqualStrings("x", t.text),
        else => {},
    };
}

test "on_lines_change reports each change once" {
    const gpa = std.testing.allocator;
    const Spy = struct {
        calls: u32 = 0,
        last: u16 = 0,
        fn onLines(ctx: *anyopaque, lines: u16) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            self.last = lines;
        }
    };
    var spy = Spy{};
    var controller = TextFieldController{};
    var field = TextField{
        .text = "a",
        .max_lines = 3,
        .on_lines_change = Spy.onLines,
        .ctx = &spy,
        .controller = &controller,
    };
    var m = try mountLoose(gpa, &field);
    defer freeLoose(gpa, &m.h, m.col);

    try m.h.pump();
    try std.testing.expectEqual(@as(u32, 1), spy.calls);
    try std.testing.expectEqual(@as(u16, 1), spy.last);

    try controller.setText("alpha beta");
    try m.h.pump();
    try std.testing.expectEqual(@as(u32, 2), spy.calls);
    try std.testing.expectEqual(@as(u16, 2), spy.last);

    try m.h.pump();
    try std.testing.expectEqual(@as(u32, 2), spy.calls);
}
