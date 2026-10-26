//! Compact SVG rasterizer for application/theme icons.
//!
//! This intentionally implements SVG's icon-sized drawing subset rather than
//! a browser DOM: path geometry, rectangles, circles/ellipses, solid colours,
//! and a representative colour for linear/radial gradients. Unsupported tags
//! are ignored, so one unusual icon cannot take down a shell frame.
const std = @import("std");
const outline_mod = @import("../text/outline.zig");
const raster = @import("../text/raster.zig");

pub const DecodeError = error{ InvalidSvg, Unsupported, OutOfMemory };

pub const Decoded = struct { rgba: []u8, width: u32, height: u32 };

const Rgba = struct { r: u8, g: u8, b: u8, a: u8 = 255 };

fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, tag, at, name)) |p| {
        const before_ok = p == 0 or std.ascii.isWhitespace(tag[p - 1]);
        var i = p + name.len;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
        if (!before_ok or i >= tag.len or tag[i] != '=') {
            at = p + 1;
            continue;
        }
        i += 1;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
        if (i >= tag.len or (tag[i] != '"' and tag[i] != '\'')) return null;
        const quote = tag[i];
        const start = i + 1;
        const end = std.mem.indexOfScalarPos(u8, tag, start, quote) orelse return null;
        return tag[start..end];
    }
    return null;
}

fn number(value: []const u8) ?f32 {
    var end: usize = 0;
    while (end < value.len and (std.ascii.isDigit(value[end]) or value[end] == '.' or value[end] == '-' or value[end] == '+' or value[end] == 'e' or value[end] == 'E')) : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseFloat(f32, value[0..end]) catch null;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn color(value: []const u8) ?Rgba {
    if (std.ascii.eqlIgnoreCase(value, "none")) return null;
    if (std.ascii.eqlIgnoreCase(value, "white")) return .{ .r = 255, .g = 255, .b = 255 };
    if (std.ascii.eqlIgnoreCase(value, "black")) return .{ .r = 0, .g = 0, .b = 0 };
    if (value.len == 4 and value[0] == '#') {
        const r = hexNibble(value[1]) orelse return null;
        const g = hexNibble(value[2]) orelse return null;
        const b = hexNibble(value[3]) orelse return null;
        return .{ .r = r * 17, .g = g * 17, .b = b * 17 };
    }
    if ((value.len == 7 or value.len == 9) and value[0] == '#') {
        var bytes: [4]u8 = .{ 0, 0, 0, 255 };
        const count: usize = if (value.len == 9) 4 else 3;
        for (0..count) |i| bytes[i] = (hexNibble(value[1 + i * 2]) orelse return null) * 16 + (hexNibble(value[2 + i * 2]) orelse return null);
        return .{ .r = bytes[0], .g = bytes[1], .b = bytes[2], .a = bytes[3] };
    }
    return null;
}

fn gradientColor(svg: []const u8, value: []const u8) ?Rgba {
    if (!std.mem.startsWith(u8, value, "url(#") or value.len < 7 or value[value.len - 1] != ')') return color(value);
    const id = value[5 .. value.len - 1];
    var needle_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "id=\"{s}\"", .{id}) catch return null;
    const id_at = std.mem.indexOf(u8, svg, needle) orelse return null;
    const open = std.mem.lastIndexOfScalar(u8, svg[0..id_at], '<') orelse return null;
    const end_rel = std.mem.indexOf(u8, svg[id_at..], "</") orelse return null;
    const block = svg[open .. id_at + end_rel];
    var first: ?Rgba = null;
    var last: ?Rgba = null;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, block, pos, "stop-color=")) |p| {
        const tail = block[p..];
        const v = attr(tail, "stop-color") orelse {
            pos = p + 1;
            continue;
        };
        if (color(v)) |c| {
            if (first == null) first = c;
            last = c;
        }
        pos = p + 1;
    }
    const a = first orelse return null;
    const b = last orelse a;
    return .{ .r = @intCast((@as(u16, a.r) + b.r) / 2), .g = @intCast((@as(u16, a.g) + b.g) / 2), .b = @intCast((@as(u16, a.b) + b.b) / 2), .a = @intCast((@as(u16, a.a) + b.a) / 2) };
}

const PathScanner = struct {
    data: []const u8,
    at: usize = 0,
    fn skip(s: *PathScanner) void {
        while (s.at < s.data.len and (std.ascii.isWhitespace(s.data[s.at]) or s.data[s.at] == ',')) : (s.at += 1) {}
    }
    fn command(s: *PathScanner) ?u8 {
        s.skip();
        if (s.at < s.data.len and std.ascii.isAlphabetic(s.data[s.at])) {
            const c = s.data[s.at];
            s.at += 1;
            return c;
        }
        return null;
    }
    fn num(s: *PathScanner) ?f32 {
        s.skip();
        const start = s.at;
        if (s.at < s.data.len and (s.data[s.at] == '+' or s.data[s.at] == '-')) s.at += 1;
        var digits = false;
        while (s.at < s.data.len and std.ascii.isDigit(s.data[s.at])) : (s.at += 1) digits = true;
        if (s.at < s.data.len and s.data[s.at] == '.') {
            s.at += 1;
            while (s.at < s.data.len and std.ascii.isDigit(s.data[s.at])) : (s.at += 1) digits = true;
        }
        if (!digits) {
            s.at = start;
            return null;
        }
        if (s.at < s.data.len and (s.data[s.at] == 'e' or s.data[s.at] == 'E')) {
            s.at += 1;
            if (s.at < s.data.len and (s.data[s.at] == '+' or s.data[s.at] == '-')) s.at += 1;
            while (s.at < s.data.len and std.ascii.isDigit(s.data[s.at])) : (s.at += 1) {}
        }
        return std.fmt.parseFloat(f32, s.data[start..s.at]) catch null;
    }
};

fn buildPath(gpa: std.mem.Allocator, d: []const u8, out: *outline_mod.Outline) !void {
    var scan = PathScanner{ .data = d };
    var builder = outline_mod.Builder.init(out);
    var cmd: u8 = 0;
    var x: f32 = 0;
    var y: f32 = 0;
    var start_x: f32 = 0;
    var start_y: f32 = 0;
    var last_cx: f32 = 0;
    var last_cy: f32 = 0;
    while (scan.at < d.len) {
        if (scan.command()) |c| cmd = c else if (cmd == 0) return error.InvalidSvg;
        const rel = std.ascii.isLower(cmd);
        switch (std.ascii.toUpper(cmd)) {
            'Z' => {
                try builder.lineTo(gpa, start_x, -start_y);
                builder.finish();
                x = start_x;
                y = start_y;
                cmd = 0;
            },
            'M', 'L', 'T' => {
                var nx = scan.num() orelse break;
                var ny = scan.num() orelse return error.InvalidSvg;
                if (rel) {
                    nx += x;
                    ny += y;
                }
                if (std.ascii.toUpper(cmd) == 'M') {
                    try builder.moveTo(gpa, nx, -ny);
                    start_x = nx;
                    start_y = ny;
                    cmd = if (rel) 'l' else 'L';
                } else try builder.lineTo(gpa, nx, -ny);
                x = nx;
                y = ny;
            },
            'H' => {
                var nx = scan.num() orelse break;
                if (rel) nx += x;
                try builder.lineTo(gpa, nx, -y);
                x = nx;
            },
            'V' => {
                var ny = scan.num() orelse break;
                if (rel) ny += y;
                try builder.lineTo(gpa, x, -ny);
                y = ny;
            },
            'C' => {
                var x1 = scan.num() orelse break;
                var y1 = scan.num() orelse return error.InvalidSvg;
                var x2 = scan.num() orelse return error.InvalidSvg;
                var y2 = scan.num() orelse return error.InvalidSvg;
                var nx = scan.num() orelse return error.InvalidSvg;
                var ny = scan.num() orelse return error.InvalidSvg;
                if (rel) {
                    x1 += x;
                    y1 += y;
                    x2 += x;
                    y2 += y;
                    nx += x;
                    ny += y;
                }
                try builder.cubicTo(gpa, x1, -y1, x2, -y2, nx, -ny);
                last_cx = x2;
                last_cy = y2;
                x = nx;
                y = ny;
            },
            'S' => {
                var x2 = scan.num() orelse break;
                var y2 = scan.num() orelse return error.InvalidSvg;
                var nx = scan.num() orelse return error.InvalidSvg;
                var ny = scan.num() orelse return error.InvalidSvg;
                if (rel) {
                    x2 += x;
                    y2 += y;
                    nx += x;
                    ny += y;
                }
                try builder.cubicTo(gpa, 2 * x - last_cx, -(2 * y - last_cy), x2, -y2, nx, -ny);
                last_cx = x2;
                last_cy = y2;
                x = nx;
                y = ny;
            },
            'Q' => {
                var cx = scan.num() orelse break;
                var cy = scan.num() orelse return error.InvalidSvg;
                var nx = scan.num() orelse return error.InvalidSvg;
                var ny = scan.num() orelse return error.InvalidSvg;
                if (rel) {
                    cx += x;
                    cy += y;
                    nx += x;
                    ny += y;
                }
                try builder.quadTo(gpa, cx, -cy, nx, -ny);
                last_cx = cx;
                last_cy = cy;
                x = nx;
                y = ny;
            },
            'A' => {
                _ = scan.num() orelse break;
                _ = scan.num() orelse return error.InvalidSvg;
                _ = scan.num() orelse return error.InvalidSvg;
                _ = scan.num() orelse return error.InvalidSvg;
                _ = scan.num() orelse return error.InvalidSvg;
                var nx = scan.num() orelse return error.InvalidSvg;
                var ny = scan.num() orelse return error.InvalidSvg;
                if (rel) {
                    nx += x;
                    ny += y;
                }
                try builder.lineTo(gpa, nx, -ny);
                x = nx;
                y = ny;
            },
            else => return error.Unsupported,
        }
    }
    builder.finish();
}

fn rectPath(gpa: std.mem.Allocator, tag: []const u8, out: *outline_mod.Outline) !void {
    const x = number(attr(tag, "x") orelse "0") orelse 0;
    const y = number(attr(tag, "y") orelse "0") orelse 0;
    const w = number(attr(tag, "width") orelse return error.InvalidSvg) orelse return error.InvalidSvg;
    const h = number(attr(tag, "height") orelse return error.InvalidSvg) orelse return error.InvalidSvg;
    var b = outline_mod.Builder.init(out);
    try b.moveTo(gpa, x, -y);
    try b.lineTo(gpa, x + w, -y);
    try b.lineTo(gpa, x + w, -(y + h));
    try b.lineTo(gpa, x, -(y + h));
    try b.lineTo(gpa, x, -y);
    b.finish();
}

fn ellipsePath(gpa: std.mem.Allocator, tag: []const u8, circle: bool, out: *outline_mod.Outline) !void {
    const cx = number(attr(tag, "cx") orelse "0") orelse 0;
    const cy = number(attr(tag, "cy") orelse "0") orelse 0;
    const rx = number(attr(tag, if (circle) "r" else "rx") orelse return error.InvalidSvg) orelse return error.InvalidSvg;
    const ry = if (circle) rx else number(attr(tag, "ry") orelse return error.InvalidSvg) orelse return error.InvalidSvg;
    const k: f32 = 0.55228475;
    var b = outline_mod.Builder.init(out);
    try b.moveTo(gpa, cx + rx, -cy);
    try b.cubicTo(gpa, cx + rx, -(cy + k * ry), cx + k * rx, -(cy + ry), cx, -(cy + ry));
    try b.cubicTo(gpa, cx - k * rx, -(cy + ry), cx - rx, -(cy + k * ry), cx - rx, -cy);
    try b.cubicTo(gpa, cx - rx, -(cy - k * ry), cx - k * rx, -(cy - ry), cx, -(cy - ry));
    try b.cubicTo(gpa, cx + k * rx, -(cy - ry), cx + rx, -(cy - k * ry), cx + rx, -cy);
    b.finish();
}

fn composite(dst: []u8, dst_w: u32, dst_h: u32, cov: raster.Coverage, paint: Rgba) void {
    for (0..cov.h) |yy| for (0..cov.w) |xx| {
        const dx_i = cov.left + @as(i32, @intCast(xx));
        const dy_i = cov.top + @as(i32, @intCast(yy));
        if (dx_i < 0 or dy_i < 0 or dx_i >= dst_w or dy_i >= dst_h) continue;
        const coverage = cov.pixels[yy * cov.w + xx];
        const sa: u16 = (@as(u16, coverage) * paint.a) / 255;
        if (sa == 0) continue;
        const i: usize = (@as(usize, @intCast(dy_i)) * dst_w + @as(usize, @intCast(dx_i))) * 4;
        const inv: u16 = 255 - sa;
        dst[i] = @intCast((@as(u16, paint.r) * sa + @as(u16, dst[i]) * inv) / 255);
        dst[i + 1] = @intCast((@as(u16, paint.g) * sa + @as(u16, dst[i + 1]) * inv) / 255);
        dst[i + 2] = @intCast((@as(u16, paint.b) * sa + @as(u16, dst[i + 2]) * inv) / 255);
        dst[i + 3] = @intCast(sa + (@as(u16, dst[i + 3]) * inv) / 255);
    };
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!Decoded {
    const svg_at = std.mem.indexOf(u8, bytes, "<svg") orelse return error.InvalidSvg;
    const svg_end = std.mem.indexOfScalarPos(u8, bytes, svg_at, '>') orelse return error.InvalidSvg;
    const root = bytes[svg_at .. svg_end + 1];
    var view_w: f32 = number(attr(root, "width") orelse "") orelse 0;
    var view_h: f32 = number(attr(root, "height") orelse "") orelse 0;
    if (attr(root, "viewBox")) |vb| {
        var s = PathScanner{ .data = vb };
        _ = s.num();
        _ = s.num();
        view_w = s.num() orelse view_w;
        view_h = s.num() orelse view_h;
    }
    if (view_w <= 0 or view_h <= 0 or view_w > 4096 or view_h > 4096) return error.InvalidSvg;
    const width: u32 = @intFromFloat(@ceil(view_w));
    const height: u32 = @intFromFloat(@ceil(view_h));
    const rgba = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(rgba);
    @memset(rgba, 0);
    var pos = svg_end + 1;
    while (std.mem.indexOfScalarPos(u8, bytes, pos, '<')) |open| {
        const close = std.mem.indexOfScalarPos(u8, bytes, open, '>') orelse break;
        const tag = bytes[open .. close + 1];
        pos = close + 1;
        const kind: enum { path, rect, circle, ellipse } = if (std.mem.startsWith(u8, tag, "<path ")) .path else if (std.mem.startsWith(u8, tag, "<rect ")) .rect else if (std.mem.startsWith(u8, tag, "<circle ")) .circle else if (std.mem.startsWith(u8, tag, "<ellipse ")) .ellipse else continue;
        const fill = attr(tag, "fill") orelse continue;
        const paint = gradientColor(bytes, fill) orelse continue;
        var outline = outline_mod.Outline{};
        defer outline.deinit(gpa);
        switch (kind) {
            .path => try buildPath(gpa, attr(tag, "d") orelse continue, &outline),
            .rect => try rectPath(gpa, tag, &outline),
            .circle => try ellipsePath(gpa, tag, true, &outline),
            .ellipse => try ellipsePath(gpa, tag, false, &outline),
        }
        var cov = raster.rasterizeScaled(gpa, outline, @intFromFloat(@ceil(view_w)), @floatFromInt(width), @floatFromInt(height), @intFromFloat(@ceil(view_w))) catch continue;
        defer cov.deinit(gpa);
        composite(rgba, width, height, cov, paint);
    }
    return .{ .rgba = rgba, .width = width, .height = height };
}

test "decodes a solid SVG path" {
    const bytes = "<svg width=\"8\" height=\"8\" viewBox=\"0 0 8 8\"><path d=\"M1 1H7V7H1Z\" fill=\"#ff0000\"/></svg>";
    const d = try decode(std.testing.allocator, bytes);
    defer std.testing.allocator.free(d.rgba);
    try std.testing.expectEqual(@as(u32, 8), d.width);
    try std.testing.expect(d.rgba[(3 * 8 + 3) * 4] > 200);
}
