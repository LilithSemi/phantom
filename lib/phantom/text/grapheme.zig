//! Grapheme cluster boundaries: what a person sees as one character. A caret
//! that stops inside a cluster splits an accent from its letter or a family
//! emoji into its members.
//!
//! This is a close approximation of UAX #29 built on the `mono` width tables, not
//! the full property table. A cluster is a base code point followed by every
//! zero-width code point, skin tone modifier, and code point after a zero-width
//! joiner. Regional indicators pair into flags, and CR LF is one cluster.
const std = @import("std");
const mono = @import("mono.zig");

pub const Decoded = struct {
    cp: u21,
    len: usize,
    /// False for a byte that starts no valid sequence. `cp` is then U+FFFD and
    /// `len` is 1, so a caller always makes progress.
    valid: bool,
};

pub fn decodeAt(s: []const u8, i: usize) Decoded {
    const invalid: Decoded = .{ .cp = 0xFFFD, .len = 1, .valid = false };
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return invalid;
    if (i + len > s.len) return invalid;
    const cp = std.unicode.utf8Decode(s[i..][0..len]) catch return invalid;
    return .{ .cp = cp, .len = len, .valid = true };
}

pub fn isControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7F and cp < 0xA0);
}

const zwj: u21 = 0x200D;

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

fn isExtend(cp: u21) bool {
    if (cp >= 0x1F3FB and cp <= 0x1F3FF) return true;
    return !isControl(cp) and mono.wcwidth(cp) == 0;
}

/// The byte index of the cluster boundary after `i`.
pub fn nextBoundary(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    const first = decodeAt(s, i);
    var j = i + first.len;
    if (first.cp == '\r' and j < s.len and s[j] == '\n') return j + 1;
    if (isControl(first.cp) or !first.valid) return j;

    var prev = first.cp;
    var regional: usize = @intFromBool(isRegionalIndicator(first.cp));
    while (j < s.len) {
        const next = decodeAt(s, j);
        if (!next.valid or isControl(next.cp)) break;
        const joins = isExtend(next.cp) or prev == zwj or
            (regional == 1 and isRegionalIndicator(next.cp));
        if (!joins) break;
        if (isRegionalIndicator(next.cp)) regional += 1;
        prev = next.cp;
        j += next.len;
    }
    return j;
}

/// The byte index of the cluster boundary before `i`. Walks from the start,
/// because a cluster cannot be found by reading backwards alone.
pub fn previousBoundary(s: []const u8, i: usize) usize {
    if (i == 0) return 0;
    const end = @min(i, s.len);
    var at: usize = 0;
    while (true) {
        const next = nextBoundary(s, at);
        if (next >= end) return at;
        at = next;
    }
}

fn expectClusters(s: []const u8, want: []const []const u8) !void {
    var at: usize = 0;
    for (want) |cluster| {
        const next = nextBoundary(s, at);
        try std.testing.expectEqualStrings(cluster, s[at..next]);
        try std.testing.expectEqual(at, previousBoundary(s, next));
        at = next;
    }
    try std.testing.expectEqual(s.len, at);
}

test "a letter and its combining accent are one cluster" {
    try expectClusters("e\u{301}x", &.{ "e\u{301}", "x" });
}

test "an emoji joined by zero-width joiners is one cluster" {
    try expectClusters("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}!", &.{ "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "!" });
}

test "a skin tone and a presentation selector stay with their emoji" {
    try expectClusters("\u{1F44D}\u{1F3FD}\u{2764}\u{FE0F}", &.{ "\u{1F44D}\u{1F3FD}", "\u{2764}\u{FE0F}" });
}

test "regional indicators pair into flags and no further" {
    try expectClusters("\u{1F1EF}\u{1F1F5}\u{1F1FA}\u{1F1F8}", &.{ "\u{1F1EF}\u{1F1F5}", "\u{1F1FA}\u{1F1F8}" });
}

test "wide characters, CR LF and a control are each their own cluster" {
    try expectClusters("あい\r\n\tz", &.{ "あ", "い", "\r\n", "\t", "z" });
}

test "an invalid byte is one cluster, so a caret can always leave it" {
    try expectClusters("a\xffb", &.{ "a", "\xff", "b" });
}

test "a boundary past the end clamps rather than reading out of range" {
    try std.testing.expectEqual(@as(usize, 2), nextBoundary("ab", 9));
    try std.testing.expectEqual(@as(usize, 1), previousBoundary("ab", 9));
    try std.testing.expectEqual(@as(usize, 0), previousBoundary("", 0));
}
