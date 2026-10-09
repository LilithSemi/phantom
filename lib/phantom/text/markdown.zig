//! Markdown, one line at a time, as spans with a style. The caller draws them,
//! so a terminal and a page read the same answer.
//!
//! This covers what agents and READMEs write: headings, bullets, numbered items,
//! rules, fenced code, and inline strong, emphasis, code and links. It is not a
//! full CommonMark parser. A line that opens a construct this does not know is a
//! paragraph, so nothing is lost, it only draws plain.
const std = @import("std");
const Allocator = std.mem.Allocator;
const fit = @import("fit.zig");
const grapheme = @import("grapheme.zig");

pub const Style = packed struct {
    strong: bool = false,
    em: bool = false,
    code: bool = false,
};

/// One run of text with one style. `text` borrows the line given to the parser.
pub const Span = struct {
    text: []const u8,
    style: Style = .{},
    /// The target when the span is part of a link.
    url: ?[]const u8 = null,
};

pub const Block = enum {
    blank,
    paragraph,
    heading,
    bullet,
    numbered,
    rule,
    /// A fence line itself, opening or closing. It has no spans.
    fence,
    /// A line inside a fence. One span, with nothing stripped.
    code,
};

pub const Line = struct {
    block: Block,
    /// The heading level, 1 to 6, or the list depth, one for every two
    /// columns of indent.
    level: u8 = 0,
    /// The number of a numbered item.
    number: u32 = 0,
    /// The language after an opening fence, empty when there is none.
    info: []const u8 = "",
    spans: []const Span = &.{},
};

/// Keeps the one state that spans lines: whether a fence is open.
pub const Parser = struct {
    fence_char: u8 = 0,
    fence_len: usize = 0,

    pub fn inFence(self: Parser) bool {
        return self.fence_char != 0;
    }

    /// Parse one line, with or without its line ending. Spans borrow `raw`, and
    /// only the span slice is allocated in `arena`.
    pub fn line(self: *Parser, arena: Allocator, raw: []const u8) Allocator.Error!Line {
        const text = std.mem.trimEnd(u8, raw, "\r\n");
        const indent = leadingIndent(text);
        const body = text[indent.bytes..];

        if (self.inFence()) {
            if (indent.columns < 4 and closesFence(body, self.fence_char, self.fence_len)) {
                self.fence_char = 0;
                return .{ .block = .fence };
            }
            const spans = try arena.alloc(Span, 1);
            spans[0] = .{ .text = text, .style = .{ .code = true } };
            return .{ .block = .code, .spans = spans };
        }

        if (body.len == 0) return .{ .block = .blank };
        const depth: u8 = @intCast(@min(indent.columns / 2, std.math.maxInt(u8)));
        if (indent.columns < 4) {
            if (opensFence(body)) |f| {
                self.fence_char = f.char;
                self.fence_len = f.len;
                return .{ .block = .fence, .info = f.info };
            }
            if (isRule(body)) return .{ .block = .rule };
            if (heading(body)) |h| {
                return .{ .block = .heading, .level = h.level, .spans = try spansOf(arena, h.text) };
            }
        }
        if (bullet(body)) |rest| {
            return .{ .block = .bullet, .level = depth, .spans = try spansOf(arena, rest) };
        }
        if (numbered(body)) |n| {
            return .{ .block = .numbered, .level = depth, .number = n.number, .spans = try spansOf(arena, n.text) };
        }
        return .{ .block = .paragraph, .spans = try spansOf(arena, body) };
    }
};

const Indent = struct { bytes: usize, columns: usize };

fn leadingIndent(s: []const u8) Indent {
    var columns: usize = 0;
    for (s, 0..) |c, i| switch (c) {
        ' ' => columns += 1,
        '\t' => columns += 4 - columns % 4,
        else => return .{ .bytes = i, .columns = columns },
    };
    return .{ .bytes = s.len, .columns = columns };
}

fn runLen(s: []const u8, i: usize, c: u8) usize {
    var j = i;
    while (j < s.len and s[j] == c) j += 1;
    return j - i;
}

const Fence = struct { char: u8, len: usize, info: []const u8 };

fn opensFence(body: []const u8) ?Fence {
    const c = body[0];
    if (c != '`' and c != '~') return null;
    const n = runLen(body, 0, c);
    if (n < 3) return null;
    const info = std.mem.trim(u8, body[n..], " \t");
    // A backtick fence cannot carry a backtick in its info, or it would read
    // as inline code instead.
    if (c == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    return .{ .char = c, .len = n, .info = info };
}

fn closesFence(body: []const u8, c: u8, len: usize) bool {
    if (body.len == 0 or body[0] != c) return false;
    const n = runLen(body, 0, c);
    return n >= len and std.mem.trim(u8, body[n..], " \t").len == 0;
}

fn isRule(body: []const u8) bool {
    const c = body[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var count: usize = 0;
    for (body) |b| {
        if (b == c) {
            count += 1;
        } else if (b != ' ' and b != '\t') {
            return false;
        }
    }
    return count >= 3;
}

const Heading = struct { level: u8, text: []const u8 };

fn heading(body: []const u8) ?Heading {
    const n = runLen(body, 0, '#');
    if (n == 0 or n > 6) return null;
    if (n < body.len and body[n] != ' ' and body[n] != '\t') return null;
    var rest = std.mem.trim(u8, body[n..], " \t");
    // An optional closing run of '#' after a space is decoration.
    const hashes = std.mem.trimEnd(u8, rest, "#");
    if (hashes.len < rest.len and (hashes.len == 0 or hashes[hashes.len - 1] == ' ')) {
        rest = std.mem.trimEnd(u8, hashes, " \t");
    }
    return .{ .level = @intCast(n), .text = rest };
}

fn bullet(body: []const u8) ?[]const u8 {
    if (body.len < 2) return null;
    if (body[0] != '-' and body[0] != '*' and body[0] != '+') return null;
    if (body[1] != ' ' and body[1] != '\t') return null;
    return std.mem.trimStart(u8, body[2..], " \t");
}

const Numbered = struct { number: u32, text: []const u8 };

fn numbered(body: []const u8) ?Numbered {
    var i: usize = 0;
    while (i < body.len and i < 9 and std.ascii.isDigit(body[i])) i += 1;
    if (i == 0 or i + 1 >= body.len) return null;
    if (body[i] != '.' and body[i] != ')') return null;
    if (body[i + 1] != ' ' and body[i + 1] != '\t') return null;
    const number = std.fmt.parseInt(u32, body[0..i], 10) catch return null;
    return .{ .number = number, .text = std.mem.trimStart(u8, body[i + 2 ..], " \t") };
}

/// The inline spans of `text`. Spans borrow `text`.
pub fn spansOf(arena: Allocator, text: []const u8) Allocator.Error![]const Span {
    var out: std.ArrayList(Span) = .empty;
    try parseInline(arena, &out, text, .{}, null);
    return out.toOwnedSlice(arena);
}

fn emit(arena: Allocator, out: *std.ArrayList(Span), text: []const u8, style: Style, url: ?[]const u8) Allocator.Error!void {
    if (text.len == 0) return;
    try out.append(arena, .{ .text = text, .style = style, .url = url });
}

fn parseInline(arena: Allocator, out: *std.ArrayList(Span), text: []const u8, style: Style, url: ?[]const u8) Allocator.Error!void {
    var plain: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            '\\' => if (i + 1 < text.len and std.ascii.isPunctuation(text[i + 1])) {
                try emit(arena, out, text[plain..i], style, url);
                try emit(arena, out, text[i + 1 .. i + 2], style, url);
                i += 2;
                plain = i;
                continue;
            },
            '`' => {
                const n = runLen(text, i, '`');
                if (codeClose(text, i + n, n)) |close| {
                    try emit(arena, out, text[plain..i], style, url);
                    var inner = text[i + n .. close];
                    if (inner.len >= 2 and inner[0] == ' ' and inner[inner.len - 1] == ' ' and
                        std.mem.trim(u8, inner, " ").len > 0)
                    {
                        inner = inner[1 .. inner.len - 1];
                    }
                    var code_style = style;
                    code_style.code = true;
                    try emit(arena, out, inner, code_style, url);
                    i = close + n;
                    plain = i;
                    continue;
                }
                i += n;
                continue;
            },
            '*', '_' => {
                const c = text[i];
                const n = runLen(text, i, c);
                if (emphasis(text, i, c, n)) |close| {
                    try emit(arena, out, text[plain..i], style, url);
                    var inner_style = style;
                    if (n != 2) inner_style.em = true;
                    if (n >= 2) inner_style.strong = true;
                    try parseInline(arena, out, text[i + n .. close], inner_style, url);
                    i = close + n;
                    plain = i;
                    continue;
                }
                i += n;
                continue;
            },
            '[' => if (link(text, i)) |l| {
                try emit(arena, out, text[plain..i], style, url);
                try parseInline(arena, out, text[i + 1 .. l.label_end], style, l.url);
                i = l.end;
                plain = i;
                continue;
            },
            else => {},
        }
        i += 1;
    }
    try emit(arena, out, text[plain..], style, url);
}

/// The index of the backtick run of exactly `n` that closes a code span
/// starting at `from`.
fn codeClose(text: []const u8, from: usize, n: usize) ?usize {
    var j = from;
    while (j < text.len) {
        if (text[j] == '`') {
            const m = runLen(text, j, '`');
            if (m == n) return j;
            j += m;
        } else j += 1;
    }
    return null;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// The index of the run that closes an emphasis opened by `n` of `c` at `i`,
/// or null when the run at `i` opens nothing. An underscore only opens after a
/// non-word byte and only closes before one, so `snake_case` stays literal.
fn emphasis(text: []const u8, i: usize, c: u8, n: usize) ?usize {
    if (n > 3) return null;
    const after = i + n;
    if (after >= text.len or std.ascii.isWhitespace(text[after])) return null;
    if (c == '_' and i > 0 and isWordByte(text[i - 1])) return null;

    var j = after;
    while (j < text.len) {
        switch (text[j]) {
            '\\' => j += 2,
            '`' => {
                const m = runLen(text, j, '`');
                j = if (codeClose(text, j + m, m)) |close| close + m else j + m;
            },
            else => if (text[j] == c) {
                const m = runLen(text, j, c);
                const closes = m == n and !std.ascii.isWhitespace(text[j - 1]) and
                    (c != '_' or j + m >= text.len or !isWordByte(text[j + m]));
                if (closes) return j;
                j += m;
            } else {
                j += 1;
            },
        }
    }
    return null;
}

const Link = struct { label_end: usize, url: []const u8, end: usize };

fn link(text: []const u8, i: usize) ?Link {
    var depth: usize = 0;
    var j = i;
    const label_end = while (j < text.len) {
        switch (text[j]) {
            '\\' => {
                j += 2;
                continue;
            },
            '`' => {
                const m = runLen(text, j, '`');
                j = if (codeClose(text, j + m, m)) |close| close + m else j + m;
                continue;
            },
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) break j;
            },
            else => {},
        }
        j += 1;
    } else return null;

    if (label_end + 1 >= text.len or text[label_end + 1] != '(') return null;
    var parens: usize = 0;
    var k = label_end + 1;
    const close = while (k < text.len) : (k += 1) {
        switch (text[k]) {
            '(' => parens += 1,
            ')' => {
                parens -= 1;
                if (parens == 0) break k;
            },
            else => {},
        }
    } else return null;

    const inside = std.mem.trim(u8, text[label_end + 2 .. close], " \t");
    // A title after the target is dropped: `[a](url "title")`.
    const target = if (std.mem.indexOfAny(u8, inside, " \t")) |sp| inside[0..sp] else inside;
    if (target.len == 0) return null;
    return .{ .label_end = label_end, .url = target, .end = close + 1 };
}

// ---------------------------------------------------------------------------
// Wrapping
// ---------------------------------------------------------------------------

/// How `wrapSpans` measures and how wide each row is.
pub const Wrap = struct {
    ctx: ?*anyopaque = null,
    /// The measure a span of `style` draws with. A terminal can answer
    /// `fit.Measure.cells` for every style. A window answers the font it draws
    /// that style in, because a bold face is wider.
    measure_for: *const fn (ctx: ?*anyopaque, style: Style) fit.Measure,
    /// The width of row `row`, counted from zero. Zero or less does not wrap.
    width_of: *const fn (ctx: ?*anyopaque, row: usize) f32,
};

const Pos = struct { span: usize, at: usize };

/// Wrap the spans of one logical line into rows, by the rules
/// `layout.layoutParagraph` uses for plain text: a row breaks at its last space
/// and the space is dropped, a word longer than the row breaks at a cluster
/// edge, and a line feed always breaks. A line with no spans is one empty row.
///
/// Rows borrow the text of `spans`. Only the row slices are allocated.
pub fn wrapSpans(arena: Allocator, spans: []const Span, wrap: Wrap) Allocator.Error![]const []const Span {
    var rows: std.ArrayList([]const Span) = .empty;
    var start: Pos = .{ .span = 0, .at = 0 };
    var row: usize = 0;
    while (true) {
        const room = wrap.width_of(wrap.ctx, row);
        var used: f32 = 0;
        var last_space: ?Pos = null;
        var p = start;
        const cut: struct { end: Pos, next: Pos } = while (p.span < spans.len) {
            const s = spans[p.span];
            if (p.at >= s.text.len) {
                p = .{ .span = p.span + 1, .at = 0 };
                continue;
            }
            const e = grapheme.nextBoundary(s.text, p.at);
            const cluster = s.text[p.at..e];
            if (cluster[0] == '\n') break .{ .end = p, .next = .{ .span = p.span, .at = e } };
            const w = wrap.measure_for(wrap.ctx, s.style).width(cluster);
            if (room > 0 and used + w > room and used > 0) {
                if (std.mem.eql(u8, cluster, " ")) break .{ .end = p, .next = .{ .span = p.span, .at = e } };
                if (last_space) |sp| break .{ .end = sp, .next = .{ .span = sp.span, .at = sp.at + 1 } };
                break .{ .end = p, .next = p };
            }
            used += w;
            if (std.mem.eql(u8, cluster, " ")) last_space = p;
            p = .{ .span = p.span, .at = e };
        } else .{ .end = p, .next = p };

        try rows.append(arena, try slice(arena, spans, start, cut.end));
        if (cut.next.span >= spans.len or atEnd(spans, cut.next)) break;
        start = cut.next;
        row += 1;
    }
    return rows.toOwnedSlice(arena);
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

fn slice(arena: Allocator, spans: []const Span, from: Pos, to: Pos) Allocator.Error![]const Span {
    var out: std.ArrayList(Span) = .empty;
    var i = from.span;
    while (i < spans.len and i <= to.span) : (i += 1) {
        const s = spans[i];
        const a = if (i == from.span) from.at else 0;
        const b = if (i == to.span) to.at else s.text.len;
        if (b > a) try out.append(arena, .{ .text = s.text[a..b], .style = s.style, .url = s.url });
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectSpans(text: []const u8, want: []const Span) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try spansOf(arena.allocator(), text);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqualStrings(w.text, g.text);
        try testing.expectEqual(w.style, g.style);
        if (w.url) |u| try testing.expectEqualStrings(u, g.url.?) else try testing.expect(g.url == null);
    }
}

const strong: Style = .{ .strong = true };
const em: Style = .{ .em = true };
const code: Style = .{ .code = true };

test "an agent's summary line splits into strong, plain and code spans" {
    try expectSpans("**What changed** (commit `d66199d`, +2/-2 in `src/Terminal.astro`)", &.{
        .{ .text = "What changed", .style = strong },
        .{ .text = " (commit " },
        .{ .text = "d66199d", .style = code },
        .{ .text = ", +2/-2 in " },
        .{ .text = "src/Terminal.astro", .style = code },
        .{ .text = ")" },
    });
}

test "an underscore inside a word is literal, and around a word is emphasis" {
    try expectSpans("a_b_c and snake_case_name", &.{.{ .text = "a_b_c and snake_case_name" }});
    try expectSpans("_em_ and *em*", &.{
        .{ .text = "em", .style = em },
        .{ .text = " and " },
        .{ .text = "em", .style = em },
    });
}

test "a star with space on its right opens nothing" {
    try expectSpans("2 * 3 * 4", &.{.{ .text = "2 * 3 * 4" }});
    try expectSpans("**open but never closed", &.{.{ .text = "**open but never closed" }});
}

test "styles nest, and code inside strong keeps both" {
    try expectSpans("**bold `code`** and ***both***", &.{
        .{ .text = "bold ", .style = strong },
        .{ .text = "code", .style = .{ .strong = true, .code = true } },
        .{ .text = " and " },
        .{ .text = "both", .style = .{ .strong = true, .em = true } },
    });
}

test "markers inside code are not parsed" {
    try expectSpans("`a_b_*c*` then ``x ` y``", &.{
        .{ .text = "a_b_*c*", .style = code },
        .{ .text = " then " },
        .{ .text = "x ` y", .style = code },
    });
}

test "a link carries its target, and its label keeps its own styles" {
    try expectSpans("see [the **docs**](https://x.dev/a_(b) \"title\") now", &.{
        .{ .text = "see " },
        .{ .text = "the ", .url = "https://x.dev/a_(b)" },
        .{ .text = "docs", .style = strong, .url = "https://x.dev/a_(b)" },
        .{ .text = " now" },
    });
    try expectSpans("[not a link] (gap)", &.{.{ .text = "[not a link] (gap)" }});
}

test "a backslash escapes a marker" {
    try expectSpans("\\*not em\\*", &.{
        .{ .text = "*" },
        .{ .text = "not em" },
        .{ .text = "*" },
    });
}

test "block kinds: headings, lists, rules and blanks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p: Parser = .{};

    const h = try p.line(a, "## Plan ##\r\n");
    try testing.expectEqual(Block.heading, h.block);
    try testing.expectEqual(@as(u8, 2), h.level);
    try testing.expectEqualStrings("Plan", h.spans[0].text);

    try testing.expectEqual(Block.paragraph, (try p.line(a, "#hashtag")).block);

    const b = try p.line(a, "  - nested **item**");
    try testing.expectEqual(Block.bullet, b.block);
    try testing.expectEqual(@as(u8, 1), b.level);
    try testing.expectEqualStrings("item", b.spans[1].text);

    const n = try p.line(a, "12. twelfth");
    try testing.expectEqual(Block.numbered, n.block);
    try testing.expectEqual(@as(u32, 12), n.number);
    try testing.expectEqualStrings("twelfth", n.spans[0].text);

    try testing.expectEqual(Block.rule, (try p.line(a, "---")).block);
    try testing.expectEqual(Block.rule, (try p.line(a, "* * *")).block);
    try testing.expectEqual(Block.blank, (try p.line(a, "   ")).block);
}

test "inside a fence nothing is stripped, until the fence closes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p: Parser = .{};

    const open = try p.line(a, "```zig");
    try testing.expectEqual(Block.fence, open.block);
    try testing.expectEqualStrings("zig", open.info);
    try testing.expect(p.inFence());

    const body = try p.line(a, "    const a = **b**; // # not a heading");
    try testing.expectEqual(Block.code, body.block);
    try testing.expectEqualStrings("    const a = **b**; // # not a heading", body.spans[0].text);
    try testing.expectEqual(code, body.spans[0].style);

    // A shorter run does not close a longer fence, and a tilde does not close
    // a backtick fence.
    try testing.expectEqual(Block.code, (try p.line(a, "~~~")).block);
    try testing.expectEqual(Block.fence, (try p.line(a, "```")).block);
    try testing.expect(!p.inFence());
    try testing.expectEqual(Block.paragraph, (try p.line(a, "after")).block);
}

test "malformed fragments parse without reading out of range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inputs = [_][]const u8{
        "",          "[",        "]",            "](",   "[a](",     "[]()", "[a]()",
        "`",         "``",       "\\",           "a\\",  "*",        "**",   "***",
        "****",      "_",        "_*_",          "*_*_", "[`]`](x)", "#",    "######",
        "####### x", "1.",       "1. ",          "-",    "- ",       "```",  "~~",
        "\xff\xfe",  "**\xff**", "[\xff](\xff)",
    };
    for (inputs) |s| {
        var p: Parser = .{};
        const l = try p.line(a, s);
        for (l.spans) |span| {
            const start = @intFromPtr(span.text.ptr);
            try testing.expect(start >= @intFromPtr(s.ptr) and start + span.text.len <= @intFromPtr(s.ptr) + s.len);
        }
    }
}

const TestWrap = struct {
    widths: []const f32,
    strong_cells: f32 = 1,

    fn measureFor(ctx: ?*anyopaque, style: Style) fit.Measure {
        const self: *const TestWrap = @ptrCast(@alignCast(ctx.?));
        var m = fit.Measure.cells;
        if (style.strong) m.metrics.mono.advance = self.strong_cells;
        return m;
    }

    fn widthOf(ctx: ?*anyopaque, row: usize) f32 {
        const self: *const TestWrap = @ptrCast(@alignCast(ctx.?));
        return self.widths[@min(row, self.widths.len - 1)];
    }

    fn wrap(self: *TestWrap) Wrap {
        return .{ .ctx = self, .measure_for = measureFor, .width_of = widthOf };
    }
};

fn expectRows(text: []const u8, tw: *TestWrap, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try wrapSpans(a, try spansOf(a, text), tw.wrap());
    try testing.expectEqual(want.len, rows.len);
    for (want, rows) |w, row| {
        var joined: std.ArrayList(u8) = .empty;
        for (row) |s| try joined.appendSlice(a, s.text);
        try testing.expectEqualStrings(w, joined.items);
    }
}

test "spans wrap at spaces, keep their styles, and drop the space at the break" {
    var tw = TestWrap{ .widths = &.{14} };
    try expectRows("**What changed** in `src/app.zig` today", &tw, &.{ "What changed", "in src/app.zig", "today" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try wrapSpans(a, try spansOf(a, "**What changed** in `src/app.zig`"), tw.wrap());
    try testing.expectEqual(strong, rows[0][0].style);
    try testing.expectEqual(code, rows[1][1].style);
}

test "each row has its own width, so a pinned first row wraps narrower" {
    var tw = TestWrap{ .widths = &.{ 5, 11 } };
    try expectRows("alpha beta gamma delta", &tw, &.{ "alpha", "beta gamma", "delta" });
}

test "a word longer than the row breaks at a cluster edge, and a wide character is never split" {
    var tw = TestWrap{ .widths = &.{4} };
    try expectRows("abcdefghij", &tw, &.{ "abcd", "efgh", "ij" });
    try expectRows("あいうえお", &tw, &.{ "あい", "うえ", "お" });
}

test "a wider bold measure moves the break" {
    var tw = TestWrap{ .widths = &.{8}, .strong_cells = 2 };
    try expectRows("**bold** text", &tw, &.{ "bold", "text" });
}

test "no width means one row, and no spans mean one empty row" {
    var tw = TestWrap{ .widths = &.{0} };
    try expectRows("one long line that never wraps", &tw, &.{"one long line that never wraps"});
    var narrow = TestWrap{ .widths = &.{3} };
    try expectRows("", &narrow, &.{""});
}
