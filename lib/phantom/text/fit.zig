//! Fit a line of text into a width. A terminal row and an elided label both
//! need the part of a string that fits, cut where a person sees a character
//! end and never inside a UTF-8 sequence.
const std = @import("std");
const Font = @import("Font.zig");
const mono = @import("mono.zig");
const grapheme = @import("grapheme.zig");

const Allocator = std.mem.Allocator;

/// How wide text draws. `font` is not read under `.mono` metrics.
pub const Measure = struct {
    font: *const Font,
    size: f32,
    metrics: mono.TextMetrics,

    /// One unit for each terminal cell, so widths are column counts.
    pub const cells: Measure = .{
        .font = undefined,
        .size = 1,
        .metrics = .{ .mono = .{ .advance = 1, .line = 1, .ascent = 1 } },
    };

    pub fn advance(self: Measure, cp: u21) f32 {
        return switch (self.metrics) {
            .proportional => self.font.advance(cp, self.size),
            .mono => |m| m.advance * @as(f32, @floatFromInt(mono.wcwidth(cp))),
        };
    }

    /// The width of `text` as `fitLine` draws it.
    pub fn width(self: Measure, text: []const u8) f32 {
        var used: f32 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const d = grapheme.decodeAt(text, i);
            used += self.advance(shown(d));
            i += d.len;
        }
        return used;
    }
};

/// The code point drawn for `d`. A control byte has no printed form and an
/// invalid byte has no code point, so each shows as one plain character.
fn shown(d: grapheme.Decoded) u21 {
    if (!d.valid) return '?';
    if (grapheme.isControl(d.cp)) return ' ';
    return d.cp;
}

/// The longest prefix of `text` that fits in `room`, cut at a cluster boundary.
/// A control byte becomes a space and an invalid byte becomes '?', so the result
/// is always valid UTF-8 with no control bytes. Owned by the caller.
pub fn fitLine(gpa: Allocator, measure: Measure, text: []const u8, room: f32) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var used: f32 = 0;
    var at: usize = 0;
    while (at < text.len) {
        const end = grapheme.nextBoundary(text, at);
        const cluster = text[at..end];
        const w = measure.width(cluster);
        if (used + w > room) break;
        var i: usize = 0;
        while (i < cluster.len) {
            const d = grapheme.decodeAt(cluster, i);
            if (d.valid and !grapheme.isControl(d.cp)) {
                try out.appendSlice(gpa, cluster[i..][0..d.len]);
            } else {
                try out.append(gpa, @intCast(shown(d)));
            }
            i += d.len;
        }
        used += w;
        at = end;
    }
    return out.toOwnedSlice(gpa);
}

/// `left` hard left and `right` hard right in `room`, with spaces between. When
/// both do not fit, `left` is cut first. When `right` alone does not fit, only
/// `right` is drawn, cut to `room`. Owned by the caller.
pub fn justify(gpa: Allocator, measure: Measure, left: []const u8, right: []const u8, room: f32) Allocator.Error![]u8 {
    if (right.len == 0) return fitLine(gpa, measure, left, room);
    const pinned = measure.width(right);
    if (pinned >= room) return fitLine(gpa, measure, right, room);

    const gap = measure.advance(' ');
    const cut = try fitLine(gpa, measure, left, @max(0, room - pinned - gap));
    defer gpa.free(cut);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, cut);
    const starts = room - pinned;
    var filled = measure.width(cut);
    while (filled + gap <= starts) : (filled += gap) try out.append(gpa, ' ');
    try out.appendSlice(gpa, right);
    return out.toOwnedSlice(gpa);
}

fn expectFit(text: []const u8, room: f32, want: []const u8) !void {
    const got = try fitLine(std.testing.allocator, Measure.cells, text, room);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "a wide character that does not fit whole is left out, not split" {
    try expectFit("あいうえお", 4, "あい");
    try expectFit("あいうえお", 5, "あい");
    try expectFit("abc", 10, "abc");
    try expectFit("abc", 0, "");
}

test "a cluster is kept whole or left out whole" {
    try expectFit("e\u{301}e\u{301}", 1, "e\u{301}");
    try expectFit("\u{1F44D}\u{1F3FD}x", 1, "");
}

test "a control byte draws as a space and an invalid byte as a question mark" {
    try expectFit("a\tb\xffc", 10, "a b?c");
}

test "justify pins the right text and fills the gap with spaces" {
    const gpa = std.testing.allocator;
    const m = Measure.cells;
    const row = try justify(gpa, m, "chock", "3 tools", 16);
    defer gpa.free(row);
    try std.testing.expectEqualStrings("chock    3 tools", row);

    const tight = try justify(gpa, m, "a long title", "end", 9);
    defer gpa.free(tight);
    try std.testing.expectEqualStrings("a lon end", tight);

    const only_right = try justify(gpa, m, "left", "far too wide", 6);
    defer gpa.free(only_right);
    try std.testing.expectEqualStrings("far to", only_right);
}

test "proportional widths come from the font" {
    const gpa = std.testing.allocator;
    const builtin = @import("builtin.zig");
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m: Measure = .{ .font = &font, .size = 20, .metrics = .proportional };
    const room = m.advance('A') + m.advance('B');
    const got = try fitLine(gpa, m, "ABC", room);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("AB", got);
}
