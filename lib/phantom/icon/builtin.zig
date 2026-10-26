//! Built-in icons: the Midstall set, each a comptime `Path` on the 24 unit grid.
//!
//! A built-in icon is a centreline, not a filled shape. `icon/stroke.zig`
//! expands it at draw time with the grammar's stroke width, so one path serves
//! every size and the geometry cannot drift between two of them.
const path = @import("path.zig");

/// Side of the square every built-in path is authored on. `path.Stroke`'s
/// default width of 1.7 was chosen for this grid.
pub const grid: f32 = 24;

/// The same number as an integer count of units, which is the form
/// `text/raster.zig` takes for the denominator of its scale.
pub const grid_units: u16 = 24;

/// Identifies a built-in icon. The value doubles as the atlas cache id, so a
/// member keeps its number once shipped: renumbering makes a warm atlas draw
/// one mark under another one's name.
pub const Id = enum(u32) {
    torii = 0,

    // The interface set. Each is a centreline on the same 24 grid the torii
    // uses, drawn inside a 2 unit margin so a mark never touches its own box,
    // except the two rules, which are deliberately full bleed (see below).
    //
    // These exist because the bundled fonts do not have them. Mesmerize and
    // Neuropol are display faces: every non-ASCII codepoint probed, U+2713 and
    // U+2502 among them, resolves to glyph 0. In cell mode that costs nothing,
    // since the terminal draws text with its own font, but pixel mode
    // rasterises with the bundled faces and a tick came out as a replacement
    // box. A mark phantom draws itself works in both.
    check = 1,
    cross = 2,
    chevron_left = 3,
    chevron_right = 4,
    chevron_up = 5,
    chevron_down = 6,
    arrow_right = 7,
    plus = 8,
    minus = 9,
    rule_vertical = 10,
    rule_horizontal = 11,

    /// Three dots on the midline, for elided content. U+22EF, which no bundled
    /// face has either.
    ellipsis = 12,

    /// Three horizontal rails used to open application navigation.
    menu = 13,

    /// A three-by-three application grid. Shells use this to open an app
    /// launcher without having to carry a private vector asset.
    apps_grid = 14,

    /// Four window panes used for a workspace or window overview.
    overview = 15,

    /// A notification bell for status areas and notification centres.
    notification = 16,

    wifi_none = 17,
    wifi_weak = 18,
    wifi_fair = 19,
    wifi_good = 20,
    wifi_strong = 21,
    ethernet = 22,
    battery_empty = 23,
    battery_low = 24,
    battery_half = 25,
    battery_high = 26,
    battery_full = 27,
    battery_charging = 28,
};

/// What a cell backend draws in place of the mark.
pub const CellMark = struct {
    /// The codepoint to put in the cell. Every one of them is a single column
    /// wide, so a mark never pushes the text beside it out of place.
    cp: u21,
    /// True for a mark that continues past its own box. A rule fills every cell
    /// it covers, because a line with a gap in it is a different line. A symbol
    /// draws once, in the cell at the middle of the box, because a tick
    /// repeated four times is four ticks.
    tile: bool = false,
};

/// The character a cell backend draws for `id`, or null when no character means
/// the mark and the backend must fall back to a block.
///
/// A cell backend cannot draw a path, but it does not need to: the terminal
/// draws text with its own font, and a text font has these. This is the reverse
/// of the reason the paths exist (see `Id`). The bundled display faces have no
/// tick, so pixel mode draws one itself; the terminal font has one, so cell
/// mode asks for it by number.
///
/// The four chevrons come out as the geometric triangles. A terminal font is
/// much more likely to have those than any of the chevron ornaments, and they
/// give the same direction, which is all the mark says.
pub fn cellMarkFor(id: Id) ?CellMark {
    return switch (id) {
        // The logomark is a drawing of a gate. No character stands for it, so a
        // cell backend keeps its block.
        .torii => null,
        .check => .{ .cp = '\u{2713}' },
        .cross => .{ .cp = '\u{2717}' },
        .chevron_left => .{ .cp = '\u{25C0}' },
        .chevron_right => .{ .cp = '\u{25B6}' },
        .chevron_up => .{ .cp = '\u{25B2}' },
        .chevron_down => .{ .cp = '\u{25BC}' },
        .arrow_right => .{ .cp = '\u{2192}' },
        // Plus and minus are ASCII on purpose. Every font has them, and the
        // typographic minus buys nothing at the size of one cell.
        .plus => .{ .cp = '+' },
        .minus => .{ .cp = '-' },
        .rule_vertical => .{ .cp = '\u{2502}', .tile = true },
        .rule_horizontal => .{ .cp = '\u{2500}', .tile = true },
        .ellipsis => .{ .cp = '\u{22EF}' },
        // U+2630 is two columns wide under Darwin's wcwidth tables. Cell
        // layouts need a guaranteed one-column fallback; the vector backend
        // still draws the proper three-rail menu path.
        .menu => .{ .cp = '=' },
        // Cell mode cannot reproduce the miniature panes, but these remain
        // compact, one-column controls with distinct meanings.
        .apps_grid => .{ .cp = '#' },
        .overview => .{ .cp = '%' },
        .notification => .{ .cp = '!' },
        .wifi_none => .{ .cp = 'x' },
        .wifi_weak => .{ .cp = '.' },
        .wifi_fair => .{ .cp = ':' },
        .wifi_good => .{ .cp = ';' },
        .wifi_strong => .{ .cp = '~' },
        .ethernet => .{ .cp = '=' },
        .battery_empty => .{ .cp = '0' },
        .battery_low => .{ .cp = '1' },
        .battery_half => .{ .cp = '2' },
        .battery_high => .{ .cp = '3' },
        .battery_full => .{ .cp = '4' },
        .battery_charging => .{ .cp = '+' },
    };
}

/// The mark to draw in place of `cp` when the face has no glyph for it, or null
/// when nothing here means that codepoint.
///
/// The bundled faces are display faces: every non-ASCII codepoint probed
/// resolves to glyph 0, so text carrying one of these draws a replacement box in
/// pixel mode while a terminal draws it correctly from its own font. That split
/// is what this closes. A caller writes the character it means, in ordinary
/// text, and both modes show the same thing.
///
/// This is `cellMarkFor` read backwards, plus the near neighbours: a caller
/// reaching for a right-pointing triangle may write the small one or the large
/// one, and both mean the same mark. Nothing here is a substitution between
/// DIFFERENT marks, only between spellings of one.
///
/// Only codepoints with a real mark belong here. A face that is missing a letter
/// is a fault to see, not to paper over.
pub fn iconForCodepoint(cp: u21) ?Id {
    return switch (cp) {
        '\u{2713}' => .check,
        '\u{2717}' => .cross,
        // Both sizes of each geometric triangle. U+25B8 and U+25BE are what a
        // terminal interface usually reaches for, being lighter beside text.
        '\u{25C0}', '\u{25C2}' => .chevron_left,
        '\u{25B6}', '\u{25B8}' => .chevron_right,
        '\u{25B2}', '\u{25B4}' => .chevron_up,
        '\u{25BC}', '\u{25BE}' => .chevron_down,
        '\u{2192}' => .arrow_right,
        '\u{2502}' => .rule_vertical,
        '\u{2500}' => .rule_horizontal,
        '\u{22EF}' => .ellipsis,
        '\u{2630}' => .menu,
        else => null,
    };
}

/// The centreline of `id`.
pub fn pathFor(id: Id) path.Path {
    return switch (id) {
        .torii => torii,
        .check => check,
        .cross => cross,
        .chevron_left => chevron_left,
        .chevron_right => chevron_right,
        .chevron_up => chevron_up,
        .chevron_down => chevron_down,
        .arrow_right => arrow_right,
        .plus => plus,
        .minus => minus,
        .rule_vertical => rule_vertical,
        .rule_horizontal => rule_horizontal,
        .ellipsis => ellipsis,
        .menu => menu,
        .apps_grid => apps_grid,
        .overview => overview,
        .notification => notification,
        .wifi_none => wifi_none,
        .wifi_weak => wifi_weak,
        .wifi_fair => wifi_fair,
        .wifi_good => wifi_good,
        .wifi_strong => wifi_strong,
        .ethernet => ethernet,
        .battery_empty => battery_empty,
        .battery_low => battery_low,
        .battery_half => battery_half,
        .battery_high => battery_high,
        .battery_full => battery_full,
        .battery_charging => battery_charging,
    };
}

// ---------------------------------------------------------------------------
// The Midstall logomark
//
// Transcribed from branding/pkgs/midstall-logo/midstall_logo/logomark.py, which
// builds a torii gate with an integrated letter M out of six stroked elements:
// the kasagi (top rail), the two M diagonals, the two pillars, and the nuki
// (crossbar).
//
// The generator works on a 220 by 170 canvas. Fitting that across the 24 grid
// is a uniform scale of 24/220 = 0.109091, under which the 170 tall canvas
// becomes 18.545 units, so centring it leaves 2.7273 clear above and below.
// Source y grows downwards, grid y grows upwards, hence
//
//     grid_x = 24 * src_x / 220
//     grid_y = 24 - 2.7273 - 24 * src_y / 220
//
// Working the named ratios through gives, in source units then grid units:
//
//   padding_top    = 4.5 + 170*0.09          = 19.8
//   padding_bottom = 4.5
//   usable_height  = 170 - 19.8 - 4.5        = 145.7
//
//   beam_left_x    = 220*(0.28-0.12)  =  35.2  ->  3.840
//   pillar_left_x  = 220*0.28         =  61.6  ->  6.720
//   centre_x       = 220/2            = 110.0  -> 12.000
//   pillar_right_x = 220*0.72         = 158.4  -> 17.280
//   beam_right_x   = 220*(0.72+0.12)  = 184.8  -> 20.160
//
//   kasagi_end_y   = 19.8 - 170*0.09  =   4.5  -> 20.782
//   beam_y         = padding_top      =  19.8  -> 19.113
//   crossbar_y     = 19.8 + 145.7*0.33 = 67.881 -> 13.868
//   diagonal_y     = 19.8 + 145.7*0.33 = 67.881 -> 13.868
//   pillar_bottom_y= 170 - 4.5        = 165.5  ->  3.218
//
// The kasagi's ends (20.782) sit ABOVE its centre control point (19.113), which
// is the upward sweep that makes the shape read as a torii. Each pillar starts
// where that curve passes over it, at t = (6.72-3.84)/(20.16-3.84) = 3/17,
// giving 20.297.
//
// The stroke is NOT scaled with the geometry. See src_stroke below.
// ---------------------------------------------------------------------------

const src_w: f32 = 220;
const src_h: f32 = 170;
const pillar_inset: f32 = 0.28;
const beam_overhang: f32 = 0.12;
const diagonal_depth: f32 = 0.33;
const crossbar_position: f32 = 0.33;
const kasagi_curve: f32 = 0.09;

/// The generator's own stroke width, used here ONLY for the padding it reserves
/// at the top and bottom of the canvas. It is deliberately not carried onto the
/// icon grid: 4.5 * 24/220 is 0.49 units, a hairline that disappears at icon
/// size. The 220 wide mark is for display use, where a fine stroke reads; an
/// icon takes the grammar's 1.7, which is `path.Stroke`'s default.
const src_stroke: f32 = 4.5;

const padding_top = src_stroke + src_h * kasagi_curve;
const padding_bottom = src_stroke;
const usable_height = src_h - padding_top - padding_bottom;

/// Width is the binding axis: fitting 220 across 24 leaves the 170 tall canvas
/// short of the grid, which is what `pad_y` then takes up.
const scale = grid / src_w;

/// Half the height the mark leaves over, which centres it vertically.
const pad_y = (grid - src_h * scale) / 2;

fn gx(x_src: f32) f32 {
    return x_src * scale;
}

/// The generator draws with y growing downwards, as SVG does. `text/raster.zig`
/// flips y on its way to a top-down bitmap, so a path handed to it has to grow
/// upwards or the mark rasterises upside down.
fn gy(y_src: f32) f32 {
    return grid - (pad_y + y_src * scale);
}

const beam_left_x = gx(src_w * (pillar_inset - beam_overhang));
const pillar_left_x = gx(src_w * pillar_inset);
const centre_x = gx(src_w / 2);
const pillar_right_x = gx(src_w * (1 - pillar_inset));
const beam_right_x = gx(src_w * (1 - pillar_inset + beam_overhang));

const beam_y = gy(padding_top);
const kasagi_end_y = gy(padding_top - src_h * kasagi_curve);
const pillar_bottom_y = gy(src_h - padding_bottom);
const diagonal_y = gy(padding_top + usable_height * diagonal_depth);
const crossbar_y = gy(padding_top + usable_height * crossbar_position);

/// The kasagi's y at Bezier parameter `t`. The two ends share a y and the
/// control point at the centre is the low one, so the rail sweeps upwards.
fn kasagiY(t: f32) f32 {
    const u = 1 - t;
    return u * u * kasagi_end_y + 2 * u * t * beam_y + t * t * kasagi_end_y;
}

/// Where the kasagi passes over a pillar. The curve is symmetric about
/// `centre_x`, so both pillars start at the same height and one value serves.
const pillar_top_y = kasagiY((pillar_left_x - beam_left_x) / (beam_right_x - beam_left_x));

/// The Midstall logomark. Six separate subpaths, one per element, matching the
/// generator: it strokes six shapes with round caps rather than one connected
/// outline, and joining them here would change where the round ends fall.
pub const torii = path.Path{ .verbs = &.{
    .{ .move = .{ .x = beam_left_x, .y = kasagi_end_y } },
    .{ .quad = .{
        .ctrl = .{ .x = centre_x, .y = beam_y },
        .end = .{ .x = beam_right_x, .y = kasagi_end_y },
    } },

    .{ .move = .{ .x = pillar_left_x, .y = pillar_top_y } },
    .{ .line = .{ .x = pillar_left_x, .y = pillar_bottom_y } },

    .{ .move = .{ .x = pillar_right_x, .y = pillar_top_y } },
    .{ .line = .{ .x = pillar_right_x, .y = pillar_bottom_y } },

    .{ .move = .{ .x = pillar_left_x, .y = pillar_top_y } },
    .{ .line = .{ .x = centre_x, .y = diagonal_y } },

    .{ .move = .{ .x = pillar_right_x, .y = pillar_top_y } },
    .{ .line = .{ .x = centre_x, .y = diagonal_y } },

    .{ .move = .{ .x = pillar_left_x, .y = crossbar_y } },
    .{ .line = .{ .x = pillar_right_x, .y = crossbar_y } },
} };

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const std = @import("std");
const stroke = @import("stroke.zig");
const raster = @import("../text/raster.zig");
const mono = @import("../text/mono.zig");

/// Coverage of the bitmap cell holding the grid point (x, y), or 0 when that
/// cell lies outside the bitmap, which is the same thing as no coverage.
/// raster.zig flips y on its way to a top-down bitmap, so a path-space y lands
/// in the row holding device y = -y.
fn coverageAt(cov: raster.Coverage, x: f32, y: f32) u8 {
    const col = @as(i64, @intFromFloat(@floor(x))) - cov.left;
    const row = @as(i64, @intFromFloat(@floor(-y))) - cov.top;
    if (col < 0 or row < 0) return 0;
    if (col >= cov.w or row >= cov.h) return 0;
    return cov.pixels[@as(usize, @intCast(row)) * cov.w + @as(usize, @intCast(col))];
}

test "the torii rasterises with solid pillars and a clear gap between them" {
    // One pixel per grid unit, so a bitmap cell is the unit square of the same
    // name and every coordinate below is read straight off the derivation in
    // this file. A golden that only counted lit pixels would pass for a blob.
    const gpa = std.testing.allocator;
    var out = try stroke.expand(gpa, torii);
    defer out.deinit(gpa);
    var cov = try raster.rasterize(gpa, out, grid_units, grid, grid_units);
    defer cov.deinit(gpa);

    // Inside the left pillar, below the nuki. The centreline is at x = 6.72 and
    // the stroke is 1.7 wide, so the band covers 5.87 to 7.57 and the cell
    // x in [6,7] sits wholly inside it.
    try std.testing.expectEqual(@as(u8, 255), coverageAt(cov, 6.72, 8.5));

    // The gap between the two pillars at the same height. The left pillar ends
    // at 7.57, the right starts at 16.43, the nuki's lower edge is at 13.02 and
    // every diagonal is above that, so nothing may reach here. A stroker that
    // filled its subpaths rather than stroking them lights this cell up.
    try std.testing.expectEqual(@as(u8, 0), coverageAt(cov, 12, 8.5));

    // The nuki itself. Sampled at x = 9, NOT at the centre: crossbar_position
    // and diagonal_depth are both 0.33, so the two M diagonals meet the nuki at
    // exactly one point and a centre sample stays lit with no crossbar at all.
    // At x in [9,10] the nearer diagonal is down to 14.96 at its lowest, so
    // this cell belongs to the nuki alone. Not a full 255: the band runs from
    // 13.02 to 14.72, so the cell y in [13,14] is short by the 0.02 sliver
    // under the band. Zero without a nuki, and far under this with a hairline.
    try std.testing.expect(coverageAt(cov, 9, 13.87) > 240);

    // The kasagi sweeps UP at its ends: they reach past y = 21 while the
    // middle, pulled down by the control point at 19.11, stops at 20.80. An
    // inverted curve swaps the two and gives the mark a sagging beam.
    try std.testing.expect(coverageAt(cov, 3.84, 21.5) > 0);
    try std.testing.expectEqual(@as(u8, 0), coverageAt(cov, 12, 21.5));

    // The mark is centred on the grid on both axes. Dropping the offset that
    // centres a 170 tall canvas inside a 24 square puts the vertical centre
    // near 9 instead of 12.
    const right = cov.left + @as(i64, cov.w);
    const top = -cov.top; // path-space y of the bitmap's top edge
    const bottom = -(cov.top + @as(i64, cov.h));
    try std.testing.expectEqual(@as(i64, 12), @divExact(cov.left + right, 2));
    try std.testing.expectEqual(@as(i64, 12), @divExact(top + bottom, 2));

    // And it stays inside the grid, so a caller may size the icon box at the
    // grid and never clip the mark.
    try std.testing.expect(cov.left >= 0 and right <= 24);
    try std.testing.expect(bottom >= 0 and top <= 24);
}

// ---------------------------------------------------------------------------
// The interface set
//
// Authored directly on the 24 grid rather than transcribed from a generator, so
// the numbers below ARE the geometry. Two rules hold across all of them:
//
//   * y grows UPWARDS here, as it does for the torii above, because
//     `text/raster.zig` flips on its way to a top-down bitmap.
//   * a mark keeps a 2 unit margin, so the default 1.7 stroke has room for its
//     round cap without touching the edge of the box.
//
// The exception is the two rules, which run the full height or width. A rail is
// drawn once per row and has to JOIN the one above it: a 2 unit margin would
// leave a visible gap at every row boundary, so they run 0 to 24 and take butt
// caps, which stop exactly at the boundary instead of rounding past it.

/// A tick. Down from the left, then up to the right, with the vertex low and
/// off centre, which is what makes it read as a tick rather than a V.
const check = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 5, .y = 13 } },
    .{ .line = .{ .x = 10, .y = 8 } },
    .{ .line = .{ .x = 19, .y = 18 } },
} };

/// Two diagonals through the centre.
const cross = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 6.5, .y = 6.5 } },
    .{ .line = .{ .x = 17.5, .y = 17.5 } },
    .{ .move = .{ .x = 17.5, .y = 6.5 } },
    .{ .line = .{ .x = 6.5, .y = 17.5 } },
} };

const chevron_left = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 14.5, .y = 19 } },
    .{ .line = .{ .x = 8, .y = 12 } },
    .{ .line = .{ .x = 14.5, .y = 5 } },
} };

const chevron_right = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 9.5, .y = 19 } },
    .{ .line = .{ .x = 16, .y = 12 } },
    .{ .line = .{ .x = 9.5, .y = 5 } },
} };

const chevron_up = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 5, .y = 9.5 } },
    .{ .line = .{ .x = 12, .y = 16 } },
    .{ .line = .{ .x = 19, .y = 9.5 } },
} };

const chevron_down = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 5, .y = 14.5 } },
    .{ .line = .{ .x = 12, .y = 8 } },
    .{ .line = .{ .x = 19, .y = 14.5 } },
} };

/// Shaft and head. The head meets the shaft at its tip rather than crossing it,
/// so the join stays clean at a small size.
const arrow_right = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 4, .y = 12 } },
    .{ .line = .{ .x = 19.5, .y = 12 } },
    .{ .move = .{ .x = 13.5, .y = 18 } },
    .{ .line = .{ .x = 19.5, .y = 12 } },
    .{ .line = .{ .x = 13.5, .y = 6 } },
} };

const plus = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 12, .y = 5 } },
    .{ .line = .{ .x = 12, .y = 19 } },
    .{ .move = .{ .x = 5, .y = 12 } },
    .{ .line = .{ .x = 19, .y = 12 } },
} };

const minus = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 5, .y = 12 } },
    .{ .line = .{ .x = 19, .y = 12 } },
} };

/// Three dots on the midline. Drawn as three of the shortest strokes the round
/// cap can make, so each reads as a dot rather than a dash: a zero length
/// segment would be culled before it reached the rasterizer.
const ellipsis = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 5, .y = 12 } },
    .{ .line = .{ .x = 5.01, .y = 12 } },
    .{ .move = .{ .x = 12, .y = 12 } },
    .{ .line = .{ .x = 12.01, .y = 12 } },
    .{ .move = .{ .x = 19, .y = 12 } },
    .{ .line = .{ .x = 19.01, .y = 12 } },
} };

/// Three rails with the same inset as the rest of the interface set.
const menu = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 4, .y = 18 } },
    .{ .line = .{ .x = 20, .y = 18 } },
    .{ .move = .{ .x = 4, .y = 12 } },
    .{ .line = .{ .x = 20, .y = 12 } },
    .{ .move = .{ .x = 4, .y = 6 } },
    .{ .line = .{ .x = 20, .y = 6 } },
} };

/// Nine short round-capped strokes read as dots at icon size. Small strokes
/// are used instead of zero-length ones because the stroker deliberately
/// culls degenerate segments.
const apps_grid = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 5, .y = 18 } },  .{ .line = .{ .x = 5.01, .y = 18 } },
    .{ .move = .{ .x = 12, .y = 18 } }, .{ .line = .{ .x = 12.01, .y = 18 } },
    .{ .move = .{ .x = 19, .y = 18 } }, .{ .line = .{ .x = 19.01, .y = 18 } },
    .{ .move = .{ .x = 5, .y = 12 } },  .{ .line = .{ .x = 5.01, .y = 12 } },
    .{ .move = .{ .x = 12, .y = 12 } }, .{ .line = .{ .x = 12.01, .y = 12 } },
    .{ .move = .{ .x = 19, .y = 12 } }, .{ .line = .{ .x = 19.01, .y = 12 } },
    .{ .move = .{ .x = 5, .y = 6 } },   .{ .line = .{ .x = 5.01, .y = 6 } },
    .{ .move = .{ .x = 12, .y = 6 } },  .{ .line = .{ .x = 12.01, .y = 6 } },
    .{ .move = .{ .x = 19, .y = 6 } },  .{ .line = .{ .x = 19.01, .y = 6 } },
} };

/// Four inset panes. Each subpath is closed so the mark remains legible at
/// both dock and compact top-bar sizes.
const overview = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 4, .y = 13 } },  .{ .line = .{ .x = 10, .y = 13 } },
    .{ .line = .{ .x = 10, .y = 20 } }, .{ .line = .{ .x = 4, .y = 20 } },
    .close,                             .{ .move = .{ .x = 14, .y = 13 } },
    .{ .line = .{ .x = 20, .y = 13 } }, .{ .line = .{ .x = 20, .y = 20 } },
    .{ .line = .{ .x = 14, .y = 20 } }, .close,
    .{ .move = .{ .x = 4, .y = 4 } },   .{ .line = .{ .x = 10, .y = 4 } },
    .{ .line = .{ .x = 10, .y = 10 } }, .{ .line = .{ .x = 4, .y = 10 } },
    .close,                             .{ .move = .{ .x = 14, .y = 4 } },
    .{ .line = .{ .x = 20, .y = 4 } },  .{ .line = .{ .x = 20, .y = 10 } },
    .{ .line = .{ .x = 14, .y = 10 } }, .close,
} };

/// Bell silhouette with a separate clapper. The body is one closed stroked
/// contour so it remains recognisable at compact top-bar sizes.
const notification = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 5, .y = 17 } },
    .{ .quad = .{ .ctrl = .{ .x = 7, .y = 15 }, .end = .{ .x = 7, .y = 10 } } },
    .{ .quad = .{ .ctrl = .{ .x = 7, .y = 5 }, .end = .{ .x = 12, .y = 5 } } },
    .{ .quad = .{ .ctrl = .{ .x = 17, .y = 5 }, .end = .{ .x = 17, .y = 10 } } },
    .{ .quad = .{ .ctrl = .{ .x = 17, .y = 15 }, .end = .{ .x = 19, .y = 17 } } },
    .close,
    .{ .move = .{ .x = 10, .y = 20 } },
    .{ .quad = .{ .ctrl = .{ .x = 12, .y = 22 }, .end = .{ .x = 14, .y = 20 } } },
} };

const wifi_dot = [_]path.Verb{
    .{ .move = .{ .x = 12, .y = 5 } }, .{ .line = .{ .x = 12.01, .y = 5 } },
};
const wifi_low_arc = [_]path.Verb{
    .{ .move = .{ .x = 8.5, .y = 8 } },
    .{ .quad = .{ .ctrl = .{ .x = 12, .y = 11 }, .end = .{ .x = 15.5, .y = 8 } } },
};
const wifi_mid_arc = [_]path.Verb{
    .{ .move = .{ .x = 5.5, .y = 12 } },
    .{ .quad = .{ .ctrl = .{ .x = 12, .y = 17 }, .end = .{ .x = 18.5, .y = 12 } } },
};
const wifi_high_arc = [_]path.Verb{
    .{ .move = .{ .x = 2.5, .y = 16 } },
    .{ .quad = .{ .ctrl = .{ .x = 12, .y = 21.5 }, .end = .{ .x = 21.5, .y = 16 } } },
};

const wifi_none = path.Path{ .verbs = &.{
    wifi_high_arc[0],                  wifi_high_arc[1],                  wifi_mid_arc[0], wifi_mid_arc[1],
    wifi_low_arc[0],                   wifi_low_arc[1],                   wifi_dot[0],     wifi_dot[1],
    .{ .move = .{ .x = 5, .y = 19 } }, .{ .line = .{ .x = 19, .y = 5 } },
} };
const wifi_weak = path.Path{ .verbs = &.{ wifi_dot[0], wifi_dot[1] } };
const wifi_fair = path.Path{ .verbs = &.{ wifi_low_arc[0], wifi_low_arc[1], wifi_dot[0], wifi_dot[1] } };
const wifi_good = path.Path{ .verbs = &.{ wifi_mid_arc[0], wifi_mid_arc[1], wifi_low_arc[0], wifi_low_arc[1], wifi_dot[0], wifi_dot[1] } };
const wifi_strong = path.Path{ .verbs = &.{ wifi_high_arc[0], wifi_high_arc[1], wifi_mid_arc[0], wifi_mid_arc[1], wifi_low_arc[0], wifi_low_arc[1], wifi_dot[0], wifi_dot[1] } };

/// A compact wired-network jack: cable, plug body and four contacts.
const ethernet = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 12, .y = 3 } },  .{ .line = .{ .x = 12, .y = 7 } },
    .{ .move = .{ .x = 5, .y = 7 } },   .{ .line = .{ .x = 19, .y = 7 } },
    .{ .line = .{ .x = 19, .y = 18 } }, .{ .line = .{ .x = 5, .y = 18 } },
    .close,                             .{ .move = .{ .x = 8, .y = 18 } },
    .{ .line = .{ .x = 8, .y = 21 } },  .{ .move = .{ .x = 11, .y = 18 } },
    .{ .line = .{ .x = 11, .y = 21 } }, .{ .move = .{ .x = 14, .y = 18 } },
    .{ .line = .{ .x = 14, .y = 21 } }, .{ .move = .{ .x = 17, .y = 18 } },
    .{ .line = .{ .x = 17, .y = 21 } },
} };

const battery_outline = [_]path.Verb{
    .{ .move = .{ .x = 3, .y = 6 } },   .{ .line = .{ .x = 18, .y = 6 } },
    .{ .line = .{ .x = 18, .y = 18 } }, .{ .line = .{ .x = 3, .y = 18 } },
    .close,                             .{ .move = .{ .x = 20, .y = 9 } },
    .{ .line = .{ .x = 20, .y = 15 } },
};
const battery_bar_1 = [_]path.Verb{ .{ .move = .{ .x = 6, .y = 9 } }, .{ .line = .{ .x = 6, .y = 15 } } };
const battery_bar_2 = [_]path.Verb{ .{ .move = .{ .x = 9, .y = 9 } }, .{ .line = .{ .x = 9, .y = 15 } } };
const battery_bar_3 = [_]path.Verb{ .{ .move = .{ .x = 12, .y = 9 } }, .{ .line = .{ .x = 12, .y = 15 } } };
const battery_bar_4 = [_]path.Verb{ .{ .move = .{ .x = 15, .y = 9 } }, .{ .line = .{ .x = 15, .y = 15 } } };
const battery_empty = path.Path{ .verbs = &battery_outline };
const battery_low = path.Path{ .verbs = &(battery_outline ++ battery_bar_1) };
const battery_half = path.Path{ .verbs = &(battery_outline ++ battery_bar_1 ++ battery_bar_2) };
const battery_high = path.Path{ .verbs = &(battery_outline ++ battery_bar_1 ++ battery_bar_2 ++ battery_bar_3) };
const battery_full = path.Path{ .verbs = &(battery_outline ++ battery_bar_1 ++ battery_bar_2 ++ battery_bar_3 ++ battery_bar_4) };
const battery_charging = path.Path{ .verbs = &(battery_outline ++ [_]path.Verb{
    .{ .move = .{ .x = 12.5, .y = 17 } }, .{ .line = .{ .x = 8, .y = 11 } },
    .{ .line = .{ .x = 12, .y = 11 } },   .{ .line = .{ .x = 8.5, .y = 7 } },
}) };

/// Full bleed and butt capped, so stacking one per row draws a continuous rail
/// with no seam at the row boundaries. This is U+2502's job in a terminal, and
/// the reason it is here is that no bundled font has that glyph.
const rule_vertical = path.Path{
    .verbs = &.{
        .{ .move = .{ .x = 12, .y = 0 } },
        .{ .line = .{ .x = 12, .y = 24 } },
    },
    .stroke = .{ .cap = .butt },
};

/// The same, along the other axis, for a separator that meets its neighbours.
const rule_horizontal = path.Path{
    .verbs = &.{
        .{ .move = .{ .x = 0, .y = 12 } },
        .{ .line = .{ .x = 24, .y = 12 } },
    },
    .stroke = .{ .cap = .butt },
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The margin every mark keeps, except the two rules. See the section comment.
const margin: f32 = 2;

const Bounds = struct { min_x: f32, min_y: f32, max_x: f32, max_y: f32 };

fn boundsOf(p: path.Path) Bounds {
    var b = Bounds{ .min_x = grid, .min_y = grid, .max_x = 0, .max_y = 0 };
    for (p.verbs) |v| {
        const pts: []const path.Point = switch (v) {
            .move => |pt| &.{pt},
            .line => |pt| &.{pt},
            .quad => |q| &.{ q.ctrl, q.end },
            .cubic => |c| &.{ c.c1, c.c2, c.end },
            .close => &.{},
        };
        for (pts) |pt| {
            b.min_x = @min(b.min_x, pt.x);
            b.min_y = @min(b.min_y, pt.y);
            b.max_x = @max(b.max_x, pt.x);
            b.max_y = @max(b.max_y, pt.y);
        }
    }
    return b;
}

test "every built-in id has a path, and none of them is empty" {
    // Exhaustive over the enum, so adding a member without a centreline fails
    // here rather than drawing nothing at a call site.
    inline for (@typeInfo(Id).@"enum".field_values) |value| {
        const id: Id = @fromBackingInt(@intCast(value));
        try std.testing.expect(pathFor(id).verbs.len > 0);
    }
}

test "every built-in mark stays inside its own grid" {
    inline for (@typeInfo(Id).@"enum".field_values) |value| {
        const b = boundsOf(pathFor(@fromBackingInt(@intCast(value))));
        try std.testing.expect(b.min_x >= 0 and b.min_y >= 0);
        try std.testing.expect(b.max_x <= grid and b.max_y <= grid);
    }
}

test "the interface marks keep their margin, so a round cap never touches the edge" {
    // The rules are excluded on purpose: they are full bleed so that stacking
    // them draws a continuous rail, which is the whole reason they exist.
    inline for (@typeInfo(Id).@"enum".field_values) |value| {
        const id: Id = @fromBackingInt(@intCast(value));
        if (id == .rule_vertical or id == .rule_horizontal or id == .torii) continue;
        const b = boundsOf(pathFor(id));
        try std.testing.expect(b.min_x >= margin and b.min_y >= margin);
        try std.testing.expect(b.max_x <= grid - margin and b.max_y <= grid - margin);
    }
}

test "a rule runs the full length and stops square, so stacked rules meet with no seam" {
    const v = pathFor(.rule_vertical);
    const vb = boundsOf(v);
    try std.testing.expectEqual(@as(f32, 0), vb.min_y);
    try std.testing.expectEqual(grid, vb.max_y);
    // A round cap would bulge past the boundary and a gap would still show
    // between rows wherever the bulge did not reach.
    try std.testing.expectEqual(path.Cap.butt, v.stroke.cap);

    const h = pathFor(.rule_horizontal);
    const hb = boundsOf(h);
    try std.testing.expectEqual(@as(f32, 0), hb.min_x);
    try std.testing.expectEqual(grid, hb.max_x);
    try std.testing.expectEqual(path.Cap.butt, h.stroke.cap);
}

test "every built-in mark rasterises to real ink, which is what a missing glyph did not" {
    const gpa = std.testing.allocator;
    inline for (@typeInfo(Id).@"enum".field_values) |value| {
        const id: Id = @fromBackingInt(@intCast(value));
        var out = try stroke.expand(gpa, pathFor(id));
        defer out.deinit(gpa);
        // The same call the GPU backend makes in `ensureIcon`.
        var cov = try raster.rasterize(gpa, out, grid_units, 24, grid_units);
        defer cov.deinit(gpa);

        var lit: usize = 0;
        for (cov.pixels) |px| {
            if (px > 0) lit += 1;
        }
        // The point of the whole set: a tick drawn by phantom puts ink on the
        // surface, where U+2713 in a bundled font resolved to glyph 0.
        try std.testing.expect(lit > 0);
    }
}

test "the check mark is a tick and not a V: its vertex sits left of centre" {
    const b = boundsOf(pathFor(.check));
    const verbs = pathFor(.check).verbs;
    try std.testing.expectEqual(@as(usize, 3), verbs.len);
    const vertex = verbs[1].line;
    // Lowest point of the three, and left of the middle, which is what
    // distinguishes a tick from a symmetric V.
    try std.testing.expectEqual(b.min_y, vertex.y);
    try std.testing.expect(vertex.x < grid / 2);
}

test "every mark a terminal font can draw is one column wide" {
    // A mark two columns wide would push the text beside it out of place, and
    // the cell backend has no way to know that happened.
    inline for (@typeInfo(Id).@"enum".field_values) |value| {
        const id: Id = @fromBackingInt(@intCast(value));
        if (cellMarkFor(id)) |mark| {
            try std.testing.expectEqual(@as(u2, 1), mono.wcwidth(mark.cp));
        }
    }
}

test "only the rules tile, and every interface mark has a character" {
    inline for (@typeInfo(Id).@"enum".field_values) |value| {
        const id: Id = @fromBackingInt(@intCast(value));
        const mark = cellMarkFor(id);
        if (id == .torii) {
            // The logomark is a drawing, and no character means it.
            try std.testing.expect(mark == null);
            continue;
        }
        try std.testing.expect(mark != null);
        const tiles = (id == .rule_vertical or id == .rule_horizontal);
        try std.testing.expectEqual(tiles, mark.?.tile);
    }
}
