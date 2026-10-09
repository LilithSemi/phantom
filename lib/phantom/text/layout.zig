const std = @import("std");
const dl = @import("../display_list.zig");
const Font = @import("Font.zig");
const builtin = @import("builtin.zig");
const mono = @import("mono.zig");
const grapheme = @import("grapheme.zig");

pub const Line = struct {
    glyphs: []dl.PositionedGlyph,
    width: f32,
    height: f32,
    ascent: f32,
    /// The byte range of this line in the text passed to `layoutLine`.
    /// `layoutParagraph` shifts this to the byte range in the whole paragraph,
    /// so a caller can slice the source text for exactly this line, and never
    /// has to hand a backend the whole paragraph for one line's run.
    start: usize,
    end: usize,
    pub fn deinit(self: *Line, gpa: std.mem.Allocator) void {
        gpa.free(self.glyphs);
        self.* = undefined;
    }
};

/// Lay out one line of UTF-8 `text` in `font` at `size` px. Positions each glyph
/// on the baseline by cumulative advance (left to right, no kerning/shaping this
/// slice). Metrics only; the only allocation is the returned glyphs slice.
///
/// `metrics` selects the advance model. `.proportional` reads the font, which is
/// what the GPU backend and the web backend need. `.mono` gives every codepoint the
/// cell advance multiplied by its column count, which is what a character grid
/// needs, and it ignores `size`.
pub fn layoutLine(
    gpa: std.mem.Allocator,
    font: *Font,
    text: []const u8,
    size: f32,
    metrics: mono.TextMetrics,
) !Line {
    const scale = size / @as(f32, @floatFromInt(font.metrics.units_per_em));
    const font_ascent = @as(f32, @floatFromInt(font.ascent())) * scale;
    // Only the ascent is needed on its own now: the line box comes from
    // `Font.lineHeight`, so the two cannot disagree.

    var glyphs: std.ArrayList(dl.PositionedGlyph) = .empty;
    errdefer glyphs.deinit(gpa);
    var pen_x: f32 = 0;
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |cp| {
        try glyphs.append(gpa, .{ .cp = cp, .x = pen_x, .y = 0 });
        pen_x += switch (metrics) {
            .proportional => font.advance(cp, size),
            .mono => |m| m.advance * @as(f32, @floatFromInt(mono.wcwidth(cp))),
        };
    }

    return .{
        .glyphs = try glyphs.toOwnedSlice(gpa),
        .width = pen_x,
        .start = 0,
        .end = text.len,
        .height = switch (metrics) {
            // Through `Font.lineHeight` rather than repeating the subtraction,
            // so the line box a caller can ASK for and the one a run actually
            // gets are the same number by construction.
            .proportional => font.lineHeight(size),
            .mono => |m| m.line,
        },
        .ascent = switch (metrics) {
            .proportional => font_ascent,
            .mono => |m| m.ascent,
        },
    };
}

test "layoutLine positions glyphs by cumulative advance and measures the line" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var line = try layoutLine(gpa, &font, "AB", 48, .proportional);
    defer line.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), line.glyphs.len);
    try std.testing.expectEqual(@as(f32, 0), line.glyphs[0].x);
    // second glyph starts at the first glyph's advance
    try std.testing.expectApproxEqAbs(font.advance('A', 48), line.glyphs[1].x, 0.01);
    // width is the sum of both advances
    try std.testing.expectApproxEqAbs(font.advance('A', 48) + font.advance('B', 48), line.width, 0.01);
    // height is (ascent - descent) scaled; ascent > 0
    try std.testing.expect(line.height > 0 and line.ascent > 0);
}

test "mono metrics give every ASCII glyph the cell advance and the cell line height" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(9, 18) };
    var line = try layoutLine(gpa, &font, "Hello", 14, m);
    defer line.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 5), line.glyphs.len);
    // Five columns of nine pixels, and not the proportional advance of the font.
    try std.testing.expectEqual(@as(f32, 45), line.width);
    try std.testing.expectEqual(@as(f32, 18), line.height);
    try std.testing.expectEqual(@as(f32, 0), line.glyphs[0].x);
    try std.testing.expectEqual(@as(f32, 9), line.glyphs[1].x);
    try std.testing.expectEqual(@as(f32, 36), line.glyphs[4].x);
}

test "mono metrics ignore the font size, so two sizes measure the same" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(9, 18) };
    var small = try layoutLine(gpa, &font, "Hi", 8, m);
    defer small.deinit(gpa);
    var large = try layoutLine(gpa, &font, "Hi", 48, m);
    defer large.deinit(gpa);
    try std.testing.expectEqual(small.width, large.width);
    try std.testing.expectEqual(small.height, large.height);
}

test "mono metrics reserve two columns for a wide glyph" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var line = try layoutLine(gpa, &font, "\u{4E00}A", 14, m);
    defer line.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), line.glyphs.len);
    // The wide glyph takes two columns, so the ASCII glyph starts at column two.
    try std.testing.expectEqual(@as(f32, 20), line.glyphs[1].x);
    try std.testing.expectEqual(@as(f32, 30), line.width);
}

test "proportional metrics keep the font advances unchanged" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var line = try layoutLine(gpa, &font, "AB", 48, .proportional);
    defer line.deinit(gpa);
    try std.testing.expectApproxEqAbs(font.advance('A', 48), line.glyphs[1].x, 0.01);
}

/// A run of text broken into lines that each fit a width.
pub const Paragraph = struct {
    lines: []Line,
    /// The widest line, which is what the paragraph occupies.
    width: f32,
    /// The sum of the line heights, stacked with no extra leading.
    height: f32,

    pub fn deinit(self: *Paragraph, gpa: std.mem.Allocator) void {
        for (self.lines) |*l| l.deinit(gpa);
        gpa.free(self.lines);
        self.* = undefined;
    }
};

/// The advance one codepoint contributes under `metrics`, which is the same
/// question `layoutLine` asks per glyph. Breaking has to measure with the model
/// that will draw, or a line that was measured as fitting would not.
fn advanceOf(font: *Font, cp: u21, size: f32, metrics: mono.TextMetrics) f32 {
    return switch (metrics) {
        .proportional => font.advance(cp, size),
        .mono => |m| m.advance * @as(f32, @floatFromInt(mono.wcwidth(cp))),
    };
}

/// Where the line starting at `from` ends, and where the next one starts.
///
/// The two differ when the break falls on a space: the space ends the line and
/// is not carried onto the next one, so a wrapped paragraph does not begin
/// lines with a blank.
const Break = struct { end: usize, next: usize };

fn nextBreak(
    font: *Font,
    text: []const u8,
    from: usize,
    size: f32,
    metrics: mono.TextMetrics,
    max_width: f32,
) Break {
    var width: f32 = 0;
    var last_space: ?usize = null;
    var i = from;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cp = std.unicode.utf8Decode(text[i..][0..@min(len, text.len - i)]) catch {
            // Malformed input is a runtime fault, not a reason to stop laying
            // out. Treat the byte as one character and keep going, which is
            // what `layoutLine` does with the same input.
            i += 1;
            continue;
        };
        if (cp == '\n') return .{ .end = i, .next = i + len };

        const w = advanceOf(font, cp, size, metrics);
        // `width > 0` keeps the line making progress: a single codepoint wider
        // than the whole line still gets a line of its own, rather than looping
        // for ever on a break that cannot be taken.
        if (max_width > 0 and width + w > max_width and width > 0) {
            // The space that does not fit is itself the break, so the word
            // before it keeps its place on this line.
            if (cp == ' ') return .{ .end = i, .next = i + len };
            if (last_space) |sp| {
                const sp_len = std.unicode.utf8ByteSequenceLength(text[sp]) catch 1;
                return .{ .end = sp, .next = sp + sp_len };
            }
            // No space to break at, so the word is longer than the line and is
            // broken between characters instead. Overflowing the box would hide
            // the text under whatever is drawn next to it.
            return .{ .end = i, .next = i };
        }
        width += w;
        if (cp == ' ') last_space = i;
        i += len;
    }
    return .{ .end = text.len, .next = text.len };
}

/// Lay out `text` as lines that each fit `max_width`, breaking at spaces where
/// there is one and between characters where there is not.
///
/// A `max_width` of zero or less does not wrap: only the line feeds in `text`
/// break it. That is the honest reading of "no width to fit into", and it is
/// what an unbounded constraint gives.
///
/// Line feeds always break, wrapped or not. Nothing else in the text is treated
/// as markup.
///
/// This lives here, beside `layoutLine`, because breaking has to agree with
/// measuring: it asks `advanceOf` the same question `layoutLine` asks per glyph,
/// including the wide-character rule under `.mono`. A caller that broke text
/// itself would own a second copy of that agreement.
pub fn layoutParagraph(
    gpa: std.mem.Allocator,
    font: *Font,
    text: []const u8,
    size: f32,
    metrics: mono.TextMetrics,
    max_width: f32,
) !Paragraph {
    var lines: std.ArrayList(Line) = .empty;
    errdefer {
        for (lines.items) |*l| l.deinit(gpa);
        lines.deinit(gpa);
    }

    var pos: usize = 0;
    while (true) {
        const b = nextBreak(font, text, pos, size, metrics, max_width);
        var line = try layoutLine(gpa, font, text[pos..b.end], size, metrics);
        errdefer line.deinit(gpa);
        // `layoutLine` measured a slice starting at zero; shift its range to
        // where that slice actually sits in the paragraph, so `line.start` and
        // `line.end` slice the paragraph, not just the fragment it saw.
        line.start += pos;
        line.end += pos;
        try lines.append(gpa, line);
        if (b.next >= text.len) break;
        pos = b.next;
    }

    var width: f32 = 0;
    var height: f32 = 0;
    for (lines.items) |l| {
        width = @max(width, l.width);
        height += l.height;
    }
    return .{
        .lines = try lines.toOwnedSlice(gpa),
        .width = width,
        .height = height,
    };
}

// ---------------------------------------------------------------------------
// Spans: runs in different fonts and sizes, wrapped into rows that share a
// baseline.
// ---------------------------------------------------------------------------

/// One run of text in one font at one size. Several spans wrap together into
/// rows, each row sharing a baseline, which is what a mixed-style line such as
/// bold text next to plain text needs.
pub const Span = struct {
    /// Borrowed. Must outlive the `SpanLayout` built from this span.
    text: []const u8,
    font: *Font,
    size: f32,
    metrics: mono.TextMetrics,
};

/// One span's contribution to a row: the glyphs of its byte range, placed from
/// `x` on the row's baseline.
pub const Piece = struct {
    /// Index into the spans passed to `layoutSpans`.
    span: usize,
    /// Byte range inside that span's text.
    start: usize,
    end: usize,
    x: f32,
    width: f32,
    ascent: f32,
    glyphs: []dl.PositionedGlyph,
};

/// One row of a span layout: the pieces that share its baseline, and the box
/// they occupy together.
pub const Row = struct { pieces: []Piece, width: f32, height: f32, ascent: f32 };

/// Spans wrapped into rows.
pub const SpanLayout = struct {
    rows: []Row,
    width: f32,
    height: f32,

    pub fn deinit(self: *SpanLayout, gpa: std.mem.Allocator) void {
        for (self.rows) |*r| freeRow(gpa, r);
        gpa.free(self.rows);
        self.* = undefined;
    }
};

/// The width of one row of a span layout, counted from zero. Zero or less
/// does not wrap.
pub const RowWidth = struct {
    ctx: ?*anyopaque = null,
    width_of: *const fn (ctx: ?*anyopaque, row: usize) f32,
};

const Pos = struct { span: usize, at: usize };

/// Wrap `spans` into rows that fit `row_width`, by the same rules
/// `layoutParagraph` uses for plain text: a row breaks at its last space and
/// the space is dropped, a word longer than the row breaks at a cluster edge,
/// and a line feed always breaks.
pub fn layoutSpans(gpa: std.mem.Allocator, spans: []const Span, row_width: RowWidth) !SpanLayout {
    var rows: std.ArrayList(Row) = .empty;
    errdefer {
        for (rows.items) |*r| freeRow(gpa, r);
        rows.deinit(gpa);
    }
    var start: Pos = .{ .span = 0, .at = 0 };
    var index: usize = 0;
    while (true) {
        const cut = nextSpanBreak(spans, start, row_width.width_of(row_width.ctx, index));
        var row = try buildRow(gpa, spans, start, cut.end);
        errdefer freeRow(gpa, &row);
        try rows.append(gpa, row);
        if (atEnd(spans, cut.next)) break;
        start = cut.next;
        index += 1;
    }
    var width: f32 = 0;
    var height: f32 = 0;
    for (rows.items) |r| {
        width = @max(width, r.width);
        height += r.height;
    }
    return .{ .rows = try rows.toOwnedSlice(gpa), .width = width, .height = height };
}

const SpanBreak = struct { end: Pos, next: Pos };

fn spanCluster(spans: []const Span, p: Pos) []const u8 {
    const s = spans[p.span].text;
    return s[p.at..grapheme.nextBoundary(s, p.at)];
}

fn clusterWidth(span: Span, cluster: []const u8) f32 {
    var w: f32 = 0;
    var i: usize = 0;
    while (i < cluster.len) {
        const d = grapheme.decodeAt(cluster, i);
        w += advanceOf(span.font, d.cp, span.size, span.metrics);
        i += d.len;
    }
    return w;
}

fn nextSpanBreak(spans: []const Span, from: Pos, room: f32) SpanBreak {
    var used: f32 = 0;
    var last_space: ?Pos = null;
    var p = from;
    while (p.span < spans.len) {
        if (p.at >= spans[p.span].text.len) {
            p = .{ .span = p.span + 1, .at = 0 };
            continue;
        }
        const cluster = spanCluster(spans, p);
        const after: Pos = .{ .span = p.span, .at = p.at + cluster.len };
        if (cluster[0] == '\n') return .{ .end = p, .next = after };
        const w = clusterWidth(spans[p.span], cluster);
        if (room > 0 and used + w > room and used > 0) {
            if (std.mem.eql(u8, cluster, " ")) return .{ .end = p, .next = after };
            if (last_space) |sp| return .{ .end = sp, .next = .{ .span = sp.span, .at = sp.at + 1 } };
            return .{ .end = p, .next = p };
        }
        used += w;
        if (std.mem.eql(u8, cluster, " ")) last_space = p;
        p = after;
    }
    return .{ .end = p, .next = p };
}

fn atEnd(spans: []const Span, p: Pos) bool {
    var i = p.span;
    var at = p.at;
    while (i < spans.len) : ({
        i += 1;
        at = 0;
    }) {
        if (at < spans[i].text.len) return false;
    }
    return true;
}

fn buildRow(gpa: std.mem.Allocator, spans: []const Span, from: Pos, to: Pos) !Row {
    var pieces: std.ArrayList(Piece) = .empty;
    errdefer {
        for (pieces.items) |pc| gpa.free(pc.glyphs);
        pieces.deinit(gpa);
    }
    var x: f32 = 0;
    var ascent: f32 = 0;
    var descent: f32 = 0;
    var i = from.span;
    while (i < spans.len and i <= to.span) : (i += 1) {
        const s = spans[i];
        const a = if (i == from.span) from.at else 0;
        const b = if (i == to.span) to.at else s.text.len;
        if (b <= a) continue;
        const placed = try placeGlyphs(gpa, s, s.text[a..b]);
        errdefer gpa.free(placed.glyphs);
        const m = spanMetrics(s);
        try pieces.append(gpa, .{ .span = i, .start = a, .end = b, .x = x, .width = placed.width, .ascent = m.ascent, .glyphs = placed.glyphs });
        x += placed.width;
        ascent = @max(ascent, m.ascent);
        descent = @max(descent, m.height - m.ascent);
    }
    if (pieces.items.len == 0 and from.span < spans.len) {
        // An empty row still has the height of the span it sits in.
        const m = spanMetrics(spans[from.span]);
        ascent = m.ascent;
        descent = m.height - m.ascent;
    }
    return .{ .pieces = try pieces.toOwnedSlice(gpa), .width = x, .height = ascent + descent, .ascent = ascent };
}

/// The same line box `layoutLine` gives, without reading the font under
/// `.mono`, so a span in terminal cells needs no real font.
fn spanMetrics(s: Span) struct { ascent: f32, height: f32 } {
    return switch (s.metrics) {
        .mono => |m| .{ .ascent = m.ascent, .height = m.line },
        .proportional => .{
            .ascent = @as(f32, @floatFromInt(s.font.ascent())) * s.size / @as(f32, @floatFromInt(s.font.unitsPerEm())),
            .height = s.font.lineHeight(s.size),
        },
    };
}

/// Glyphs on the baseline by cumulative advance, like `layoutLine`, but an
/// invalid byte becomes U+FFFD instead of failing the whole layout.
fn placeGlyphs(gpa: std.mem.Allocator, s: Span, text: []const u8) !struct { glyphs: []dl.PositionedGlyph, width: f32 } {
    var glyphs: std.ArrayList(dl.PositionedGlyph) = .empty;
    errdefer glyphs.deinit(gpa);
    var pen: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const d = grapheme.decodeAt(text, i);
        try glyphs.append(gpa, .{ .cp = d.cp, .x = pen, .y = 0 });
        pen += advanceOf(s.font, d.cp, s.size, s.metrics);
        i += d.len;
    }
    return .{ .glyphs = try glyphs.toOwnedSlice(gpa), .width = pen };
}

fn freeRow(gpa: std.mem.Allocator, r: *Row) void {
    for (r.pieces) |pc| gpa.free(pc.glyphs);
    gpa.free(r.pieces);
}

test "text that fits stays on one line" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var p = try layoutParagraph(gpa, &font, "abc", 14, m, 100);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), p.lines.len);
    try std.testing.expectEqual(@as(f32, 30), p.width);
    try std.testing.expectEqual(@as(f32, 20), p.height);
}

test "a wrap breaks at a space, and the space does not begin the next line" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    // Ten pixel columns and a fifty pixel line: five columns fit.
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var p = try layoutParagraph(gpa, &font, "ab cd", 14, m, 50);
    defer p.deinit(gpa);
    // "ab cd" is exactly five columns, so it fits on one line.
    try std.testing.expectEqual(@as(usize, 1), p.lines.len);

    var q = try layoutParagraph(gpa, &font, "abc def", 14, m, 50);
    defer q.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), q.lines.len);
    // Three glyphs on each line: the space between them belongs to neither, or
    // the second line would start with a blank column.
    try std.testing.expectEqual(@as(usize, 3), q.lines[0].glyphs.len);
    try std.testing.expectEqual(@as(usize, 3), q.lines[1].glyphs.len);
    try std.testing.expectEqual(@as(u21, 'd'), q.lines[1].glyphs[0].cp);
}

test "a space that does not fit ends the line and does not begin the next one" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };

    const a = "alpha beta";
    var p = try layoutParagraph(gpa, &font, a, 14, m, 50);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), p.lines.len);
    try std.testing.expectEqualStrings("alpha", a[p.lines[0].start..p.lines[0].end]);
    try std.testing.expectEqualStrings("beta", a[p.lines[1].start..p.lines[1].end]);

    // A word that fits exactly stays on its line, rather than the break going
    // back to an earlier space.
    const b = "ab cdefghi jk";
    var q = try layoutParagraph(gpa, &font, b, 14, m, 100);
    defer q.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), q.lines.len);
    try std.testing.expectEqualStrings("ab cdefghi", b[q.lines[0].start..q.lines[0].end]);
    try std.testing.expectEqualStrings("jk", b[q.lines[1].start..q.lines[1].end]);
}

test "a word wider than the line breaks between characters instead of overflowing" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var p = try layoutParagraph(gpa, &font, "abcdefgh", 14, m, 30);
    defer p.deinit(gpa);
    // Three columns to a line, so eight characters need three lines. Letting it
    // overflow instead would hide the text under whatever is drawn beside it.
    try std.testing.expectEqual(@as(usize, 3), p.lines.len);
    for (p.lines) |l| try std.testing.expect(l.width <= 30);
}

test "no line is ever wider than the width it was given" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(9, 18) };
    const prose = "the quick brown fox jumps over the lazy dog and keeps going";
    for ([_]f32{ 27, 45, 90, 180 }) |w| {
        var p = try layoutParagraph(gpa, &font, prose, 14, m, w);
        defer p.deinit(gpa);
        for (p.lines) |l| try std.testing.expect(l.width <= w);
        try std.testing.expect(p.width <= w);
    }
}

test "a line feed breaks even where the text would have fitted" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var p = try layoutParagraph(gpa, &font, "a\nb", 14, m, 1000);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), p.lines.len);
    try std.testing.expectEqual(@as(u21, 'a'), p.lines[0].glyphs[0].cp);
    try std.testing.expectEqual(@as(u21, 'b'), p.lines[1].glyphs[0].cp);
}

test "a width of zero does not wrap, and only the line feeds break the text" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var p = try layoutParagraph(gpa, &font, "a long line of words", 14, m, 0);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), p.lines.len);

    var q = try layoutParagraph(gpa, &font, "one\ntwo", 14, m, 0);
    defer q.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), q.lines.len);
}

test "breaking counts a wide character as the two columns it will be drawn in" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    // Three wide glyphs are six columns. A sixty pixel line holds all three; a
    // fifty pixel line holds two. Counting them as one column each would put
    // all three on the short line and draw past its edge.
    var wide = try layoutParagraph(gpa, &font, "\u{4E00}\u{4E00}\u{4E00}", 14, m, 60);
    defer wide.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), wide.lines.len);

    var narrow = try layoutParagraph(gpa, &font, "\u{4E00}\u{4E00}\u{4E00}", 14, m, 50);
    defer narrow.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), narrow.lines.len);
    try std.testing.expectEqual(@as(usize, 2), narrow.lines[0].glyphs.len);
}

test "a paragraph is as tall as its lines together and as wide as its widest" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var p = try layoutParagraph(gpa, &font, "abc de", 14, m, 30);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), p.lines.len);
    try std.testing.expectEqual(@as(f32, 40), p.height);
    // The widest line, not the sum and not the last one.
    var widest: f32 = 0;
    for (p.lines) |l| widest = @max(widest, l.width);
    try std.testing.expectEqual(widest, p.width);
}

test "empty text is one empty line, so it occupies a row like any other" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var p = try layoutParagraph(gpa, &font, "", 14, m, 100);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), p.lines.len);
    try std.testing.expectEqual(@as(usize, 0), p.lines[0].glyphs.len);
    try std.testing.expectEqual(@as(f32, 20), p.height);
}

test "a line's byte range slices back to exactly that line's text" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    const text = "abc def";
    var p = try layoutParagraph(gpa, &font, text, 14, m, 50);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), p.lines.len);
    try std.testing.expectEqualStrings("abc", text[p.lines[0].start..p.lines[0].end]);
    try std.testing.expectEqualStrings("def", text[p.lines[1].start..p.lines[1].end]);
}

test "an unwrapped paragraph's one line covers the whole source string" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    const text = "a long line of words";
    var p = try layoutParagraph(gpa, &font, text, 14, m, 0);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), p.lines.len);
    try std.testing.expectEqualStrings(text, text[p.lines[0].start..p.lines[0].end]);
}

test "three wrapped lines' byte ranges concatenate back to the source, minus the spaces they broke on" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    const text = "one two three";
    var p = try layoutParagraph(gpa, &font, text, 14, m, 55);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), p.lines.len);
    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(gpa);
    for (p.lines, 0..) |l, i| {
        if (i > 0) try rebuilt.append(gpa, ' ');
        try rebuilt.appendSlice(gpa, text[l.start..l.end]);
    }
    try std.testing.expectEqualStrings(text, rebuilt.items);
    // Each line's slice is a real fragment of the paragraph, not the whole thing.
    for (p.lines) |l| try std.testing.expect(l.end - l.start < text.len);
}

test "a paragraph's UTF-8 line range slices on byte offsets, not codepoint counts" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    // Each han character is three UTF-8 bytes but one column under mono metrics
    // (wcwidth treats it as narrow here), so a byte-range bug that assumed one
    // byte per codepoint would slice mid-character and corrupt the text.
    const text = "\u{4E2D}\u{6587} ab";
    var p = try layoutParagraph(gpa, &font, text, 14, m, 1000);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), p.lines.len);
    try std.testing.expectEqualStrings(text, text[p.lines[0].start..p.lines[0].end]);
}

test "proportional wrapping measures with the font, not with a fixed column" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const prose = "wrapping measured against the real advances of the face";
    const width: f32 = 200;
    var p = try layoutParagraph(gpa, &font, prose, 16, .proportional, width);
    defer p.deinit(gpa);
    try std.testing.expect(p.lines.len > 1);
    for (p.lines) |l| try std.testing.expect(l.width <= width);
}

fn fixedWidth(ctx: ?*anyopaque, _: usize) f32 {
    return @as(*const f32, @ptrCast(@alignCast(ctx.?))).*;
}

test "one span breaks exactly where layoutParagraph breaks" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    const t = "alpha beta gamma delta epsilon ab cdefghi jk";
    var width: f32 = 100;
    var para = try layoutParagraph(gpa, &font, t, 14, m, width);
    defer para.deinit(gpa);
    var spans = try layoutSpans(gpa, &.{.{ .text = t, .font = &font, .size = 14, .metrics = m }}, .{ .ctx = &width, .width_of = fixedWidth });
    defer spans.deinit(gpa);
    try std.testing.expectEqual(para.lines.len, spans.rows.len);
    for (para.lines, spans.rows) |l, r| {
        try std.testing.expectEqual(l.start, r.pieces[0].start);
        try std.testing.expectEqual(l.end, r.pieces[r.pieces.len - 1].end);
    }
}

fn firstNarrow(_: ?*anyopaque, row: usize) f32 {
    return if (row == 0) 50 else 110;
}

test "a span splits across rows, and each row takes its own width" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    const a = "alpha ";
    const b = "beta gamma delta";
    var l = try layoutSpans(gpa, &.{
        .{ .text = a, .font = &font, .size = 14, .metrics = m },
        .{ .text = b, .font = &font, .size = 14, .metrics = m },
    }, .{ .width_of = firstNarrow });
    defer l.deinit(gpa);
    // "beta gamma delta" is 160px wide. A row of 110px holds "beta gamma " (110px)
    // at most. So "delta" goes on a third row and does not join the second.
    try std.testing.expectEqual(@as(usize, 3), l.rows.len);
    try std.testing.expectEqualStrings("alpha", a[l.rows[0].pieces[0].start..l.rows[0].pieces[0].end]);
    try std.testing.expectEqual(@as(usize, 1), l.rows[1].pieces[0].span);
    try std.testing.expectEqualStrings("beta gamma", b[l.rows[1].pieces[0].start..l.rows[1].pieces[0].end]);
    try std.testing.expectEqualStrings("delta", b[l.rows[2].pieces[0].start..l.rows[2].pieces[0].end]);
}

test "a taller span sets the row, and every piece shares one baseline" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.mesmerize_rg_bytes);
    defer font.deinit(gpa);
    var l = try layoutSpans(gpa, &.{
        .{ .text = "small ", .font = &font, .size = 12, .metrics = .proportional },
        .{ .text = "BIG", .font = &font, .size = 36, .metrics = .proportional },
    }, .{ .width_of = struct {
        fn f(_: ?*anyopaque, _: usize) f32 {
            return 0;
        }
    }.f });
    defer l.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), l.rows.len);
    const r = l.rows[0];
    try std.testing.expectEqual(r.pieces[1].ascent, r.ascent);
    try std.testing.expect(r.pieces[0].ascent < r.ascent);
    try std.testing.expect(r.height >= font.lineHeight(36));
}

test "a line feed in a span always breaks" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var l = try layoutSpans(gpa, &.{.{ .text = "a\nb", .font = &font, .size = 14, .metrics = m }}, .{ .width_of = struct {
        fn f(_: ?*anyopaque, _: usize) f32 {
            return 0;
        }
    }.f });
    defer l.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), l.rows.len);
}

fn layoutSpansUnderFailingAllocator(gpa: std.mem.Allocator, font: *Font) !void {
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var l = try layoutSpans(gpa, &.{
        .{ .text = "alpha ", .font = font, .size = 14, .metrics = m },
        .{ .text = "beta gamma delta", .font = font, .size = 14, .metrics = m },
    }, .{ .width_of = firstNarrow });
    l.deinit(gpa);
}

test "layoutSpans frees a built row when appending it fails, and frees placed glyphs when adding a piece fails" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    try std.testing.checkAllAllocationFailures(gpa, layoutSpansUnderFailingAllocator, .{&font});
}
