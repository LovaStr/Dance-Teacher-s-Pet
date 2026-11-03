const std = @import("std");
const waveform = @import("waveform");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

test "levelFromPeak maps dBFS onto 0..1" {
    try expectEqual(@as(f32, 0), waveform.levelFromPeak(0));
    try expectEqual(@as(f32, 0), waveform.levelFromPeak(0.0001)); // -80 dB, below the floor
    try expectApproxEqAbs(@as(f32, 1), waveform.levelFromPeak(1), 1e-6);
    try expectApproxEqAbs(@as(f32, 0.5), waveform.levelFromPeak(0.0316228), 1e-3); // -30 dB
    try expectEqual(@as(f32, 1), waveform.levelFromPeak(2)); // clipped
}

test "bars keep the channels apart for any bar count" {
    var samples: [2 * 800]f32 = undefined;
    for (0..800) |f| {
        samples[f * 2] = 0.1; // left
        samples[f * 2 + 1] = if (f < 400) 1.0 else 0.0; // right: loud first half only
    }
    var peaks: waveform.Peaks = .{};
    waveform.analyze(&peaks, &samples);
    for ([_]usize{ waveform.min_bars, 600, waveform.max_bars }) |n| {
        const first = waveform.bar(&peaks, n, 0, .db);
        const last = waveform.bar(&peaks, n, n - 1, .db);
        try expectApproxEqAbs(waveform.levelFromPeak(0.1), first.left, 1e-6);
        try expectApproxEqAbs(waveform.levelFromPeak(0.1), last.left, 1e-6);
        try expectEqual(@as(f32, 1), first.right);
        try expectEqual(@as(f32, 0), last.right);
    }
}

test "bar counts outside the range are clamped" {
    var peaks: waveform.Peaks = .{};
    waveform.analyze(&peaks, &[_]f32{ 1, 1, 1, 1 });
    try expectEqual(@as(f32, 1), waveform.bar(&peaks, 1, 0, .db).left);
    try expectEqual(@as(f32, 1), waveform.bar(&peaks, 20000, 999, .db).left);
}

test "linear scale uses the peak as is, dB scale lifts quiet parts" {
    var peaks: waveform.Peaks = .{};
    waveform.analyze(&peaks, &[_]f32{ 0.1, 0.5, 0.1, 0.5 });
    try expectApproxEqAbs(@as(f32, 0.1), waveform.bar(&peaks, 100, 0, .linear).left, 1e-6);
    try expectApproxEqAbs(@as(f32, 0.5), waveform.bar(&peaks, 100, 0, .linear).right, 1e-6);
    try expectApproxEqAbs(waveform.levelFromPeak(0.1), waveform.bar(&peaks, 100, 0, .db).left, 1e-6);
    try expect(waveform.level(0.1, .db) > waveform.level(0.1, .linear));
    try expectEqual(@as(f32, 1), waveform.level(3, .linear)); // clipped
}

test "render draws right channel above and left below the centre line" {
    // Right channel loud, left channel silent.
    var samples: [2 * 100]f32 = undefined;
    for (0..100) |f| {
        samples[f * 2] = 0;
        samples[f * 2 + 1] = 1.0;
    }
    var peaks: waveform.Peaks = .{};
    waveform.analyze(&peaks, &samples);
    const w = 200;
    const h = 20;
    var px: [w * h * 4]u8 = undefined;
    waveform.render(&px, w, h, &peaks, 100, .db, .peak, 2.0, .{ 10, 20, 30 });
    const alpha = struct {
        fn at(p: []const u8, x: usize, y: usize) u8 {
            return p[(y * w + x) * 4 + 3];
        }
    }.at;
    // Bar 0 is centred on x = 1 (200 px / 100 bars) and 2 px wide: column 0 is full.
    try expectEqual(@as(u8, 255), alpha(&px, 0, 5));
    try expectEqual(@as(u8, 0), alpha(&px, 0, 15)); // below the centre: silent
    // A 1 px line centred on a pixel border is split evenly over both columns.
    waveform.render(&px, w, h, &peaks, 100, .db, .peak, 1.0, .{ 10, 20, 30 });
    try expectEqual(@as(u8, 128), alpha(&px, 0, 5));
    try expectEqual(@as(u8, 128), alpha(&px, 1, 5));
    try expectEqual(@as(u8, 10), px[0]); // colour is kept even where transparent
}

test "analyze handles tracks shorter than the bin count and empty input" {
    const short = [_]f32{ 0.5, 0.25, 1.0, 0.0 };
    var peaks: waveform.Peaks = .{};
    waveform.analyze(&peaks, &short);
    try expectApproxEqAbs(waveform.levelFromPeak(1.0), waveform.bar(&peaks, 100, 99, .db).left, 1e-6);
    waveform.analyze(&peaks, &.{}); // also clears what was there before
    try expectEqual(@as(f32, 0), waveform.bar(&peaks, 100, 0, .db).left);
    try expectEqual(@as(f32, 0), waveform.bar(&peaks, 100, 0, .db).left_rms);
}

test "rms of a constant signal equals its level, a square-wave burst is merged by energy" {
    // Left: constant 0.5. Right: alternating 1 / 0 every frame (RMS = sqrt(0.5), peak = 1).
    var samples: [2 * 800]f32 = undefined;
    for (0..800) |f| {
        samples[f * 2] = 0.5;
        samples[f * 2 + 1] = if (f % 2 == 0) 1.0 else 0.0;
    }
    var peaks: waveform.Peaks = .{};
    waveform.analyze(&peaks, &samples);
    // Only bar counts where a bar spans whole 1/0 periods (a bar inside one
    // frame would see just a 1 or just a 0).
    for ([_]usize{ waveform.min_bars, 200 }) |n| {
        const b = waveform.bar(&peaks, n, n / 2, .linear);
        try expectApproxEqAbs(@as(f32, 0.5), b.left_rms, 1e-5);
        try expectApproxEqAbs(@as(f32, 0.5), b.left, 1e-6);
        try expectApproxEqAbs(@sqrt(@as(f32, 0.5)), b.right_rms, 1e-5);
        try expectEqual(@as(f32, 1), b.right);
    }
}

test "display chooses between peak, rms and both" {
    // Right channel: one loud frame per bin pair, so peak 1 but RMS well below.
    var samples: [2 * 200]f32 = undefined;
    for (0..200) |f| {
        samples[f * 2] = 0;
        samples[f * 2 + 1] = if (f % 10 == 0) 1.0 else 0.0;
    }
    var peaks: waveform.Peaks = .{};
    waveform.analyze(&peaks, &samples);
    const w = 100;
    const h = 40;
    var px: [w * h * 4]u8 = undefined;
    const alpha = struct {
        fn at(p: []const u8, x: usize, y: usize) u8 {
            return p[(y * w + x) * 4 + 3];
        }
    }.at;
    // Column 0 has full coverage at line_w 2. Row 1 is near the top, which the
    // peak (1.0) reaches but the RMS (about 0.7) does not; row 19 is just above
    // the centre line, inside both.
    waveform.render(&px, w, h, &peaks, 100, .linear, .peak, 2.0, .{ 0, 0, 0 });
    try expectEqual(@as(u8, 255), alpha(&px, 0, 1));
    waveform.render(&px, w, h, &peaks, 100, .linear, .rms, 2.0, .{ 0, 0, 0 });
    try expectEqual(@as(u8, 0), alpha(&px, 0, 1)); // RMS is far below the peak
    try expectEqual(@as(u8, 255), alpha(&px, 0, 19)); // just above the centre line
    waveform.render(&px, w, h, &peaks, 100, .linear, .both, 2.0, .{ 0, 0, 0 });
    try expectEqual(@as(u8, 102), alpha(&px, 0, 1)); // faint peak (40 %)
    try expectEqual(@as(u8, 255), alpha(&px, 0, 19)); // solid RMS on top
}
