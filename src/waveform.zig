//! Per-track loudness graph. A track is analysed once into `base_bins` fine peak
//! values per channel; any bar count between `min_bars` and `max_bars` is then
//! derived from those cheaply, so the setting can change while the UI runs.

const std = @import("std");

pub const min_bars = 100;
pub const max_bars = 10000;
pub const default_bars = 600;

/// Resolution of the analysis (well above `max_bars`).
pub const base_bins = 2 * max_bars;

/// Peaks at or below this level (dBFS) map to 0; 0 dBFS maps to 1.
pub const floor_db: f32 = -60;

/// Linear peak (0..1) of the left and right channel in each of `base_bins` windows.
pub const Peaks = struct {
    left: [base_bins]f32 = @splat(0),
    right: [base_bins]f32 = @splat(0),
};

pub const Bar = struct {
    /// 0..1 on the dB scale.
    left: f32,
    right: f32,
};

/// How a peak is mapped to a bar length.
pub const Scale = enum { db, linear };

/// Map a linear peak (0..1) to 0..1 on a dB scale.
pub fn levelFromPeak(peak: f32) f32 {
    if (peak <= 0) return 0;
    const db = 20 * @log10(peak);
    return std.math.clamp((db - floor_db) / -floor_db, 0, 1);
}

/// Map a linear peak (0..1) to 0..1 on `scale`.
pub fn level(peak: f32, scale: Scale) f32 {
    return switch (scale) {
        .db => levelFromPeak(peak),
        .linear => std.math.clamp(peak, 0, 1),
    };
}

/// `samples` is interleaved L/R. Each bin covers an equal share of the frames
/// and holds the largest absolute sample in it.
pub fn analyze(samples: []const f32) Peaks {
    var p: Peaks = .{};
    const frames = samples.len / 2;
    if (frames == 0) return p;
    for (0..base_bins) |i| {
        const start = frames * i / base_bins;
        const end = @min(@max(frames * (i + 1) / base_bins, start + 1), frames);
        var l: f32 = 0;
        var r: f32 = 0;
        for (start..end) |f| {
            l = @max(l, @abs(samples[f * 2]));
            r = @max(r, @abs(samples[f * 2 + 1]));
        }
        p.left[i] = l;
        p.right[i] = r;
    }
    return p;
}

/// Rasterize the graph into `pixels` (RGBA8, `w` x `h`, straight alpha): `bars`
/// vertical lines of width `line_w` pixels, the right channel growing up and
/// the left channel down from the horizontal centre line. Edges are
/// anti-aliased through the alpha channel; the colour is `rgb` everywhere.
pub fn render(pixels: []u8, w: u32, h: u32, peaks: *const Peaks, bars: usize, scale: Scale, line_w: f32, rgb: [3]u8) void {
    std.debug.assert(pixels.len == @as(usize, w) * h * 4);
    var k: usize = 0;
    while (k < pixels.len) : (k += 4) {
        pixels[k] = rgb[0];
        pixels[k + 1] = rgb[1];
        pixels[k + 2] = rgb[2];
        pixels[k + 3] = 0;
    }
    const n = std.math.clamp(bars, min_bars, max_bars);
    const wf: f32 = @floatFromInt(w);
    const mid: f32 = @as(f32, @floatFromInt(h)) / 2;
    for (0..n) |i| {
        const b = bar(peaks, n, i, scale);
        const xc = (@as(f32, @floatFromInt(i)) + 0.5) * wf / @as(f32, @floatFromInt(n));
        const x0 = xc - line_w / 2;
        const x1 = xc + line_w / 2;
        const first: usize = @intFromFloat(@floor(@max(x0, 0)));
        const last: usize = @intFromFloat(@ceil(@min(x1, wf)));
        for (first..last) |col| {
            const cf: f32 = @floatFromInt(col);
            const cx = std.math.clamp(@min(x1, cf + 1) - @max(x0, cf), 0, 1);
            fillSpan(pixels, w, h, col, mid - b.right * mid, mid, cx);
            fillSpan(pixels, w, h, col, mid, mid + b.left * mid, cx);
        }
    }
}

/// Raise the alpha of column `col` between rows `y0` and `y1` (fractional ends
/// get partial coverage), scaled by the horizontal coverage `cx`.
fn fillSpan(pixels: []u8, w: u32, h: u32, col: usize, y0: f32, y1: f32, cx: f32) void {
    if (y1 - y0 < 0.01) return;
    const first: usize = @intFromFloat(@floor(@max(y0, 0)));
    const last: usize = @intFromFloat(@ceil(@min(y1, @as(f32, @floatFromInt(h)))));
    for (first..last) |row| {
        const rf: f32 = @floatFromInt(row);
        const cy = std.math.clamp(@min(y1, rf + 1) - @max(y0, rf), 0, 1);
        const a: u8 = @intFromFloat(@round(255 * cx * cy));
        const idx = (row * w + col) * 4 + 3;
        pixels[idx] = @max(pixels[idx], a);
    }
}

/// Bar `i` of `count` (clamped to `min_bars..max_bars`).
pub fn bar(p: *const Peaks, count: usize, i: usize, scale: Scale) Bar {
    const n = std.math.clamp(count, min_bars, max_bars);
    const start = base_bins * i / n;
    const end = @min(@max(base_bins * (i + 1) / n, start + 1), base_bins);
    var l: f32 = 0;
    var r: f32 = 0;
    for (start..end) |b| {
        l = @max(l, p.left[b]);
        r = @max(r, p.right[b]);
    }
    return .{ .left = level(l, scale), .right = level(r, scale) };
}
