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
    const peaks = waveform.analyze(&samples);
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
    const peaks = waveform.analyze(&[_]f32{ 1, 1, 1, 1 });
    try expectEqual(@as(f32, 1), waveform.bar(&peaks, 1, 0, .db).left);
    try expectEqual(@as(f32, 1), waveform.bar(&peaks, 20000, 999, .db).left);
}

test "linear scale uses the peak as is, dB scale lifts quiet parts" {
    const peaks = waveform.analyze(&[_]f32{ 0.1, 0.5, 0.1, 0.5 });
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
    const peaks = waveform.analyze(&samples);
    const w = 200;
    const h = 20;
    var px: [w * h * 4]u8 = undefined;
    waveform.render(&px, w, h, &peaks, 100, .db, 2.0, .{ 10, 20, 30 });
    const alpha = struct {
        fn at(p: []const u8, x: usize, y: usize) u8 {
            return p[(y * w + x) * 4 + 3];
        }
    }.at;
    // Bar 0 is centred on x = 1 (200 px / 100 bars) and 2 px wide: column 0 is full.
    try expectEqual(@as(u8, 255), alpha(&px, 0, 5));
    try expectEqual(@as(u8, 0), alpha(&px, 0, 15)); // below the centre: silent
    // A 1 px line centred on a pixel border is split evenly over both columns.
    waveform.render(&px, w, h, &peaks, 100, .db, 1.0, .{ 10, 20, 30 });
    try expectEqual(@as(u8, 128), alpha(&px, 0, 5));
    try expectEqual(@as(u8, 128), alpha(&px, 1, 5));
    try expectEqual(@as(u8, 10), px[0]); // colour is kept even where transparent
}

test "analyze handles tracks shorter than the bin count and empty input" {
    const short = [_]f32{ 0.5, 0.25, 1.0, 0.0 };
    const peaks = waveform.analyze(&short);
    try expectApproxEqAbs(waveform.levelFromPeak(1.0), waveform.bar(&peaks, 100, 99, .db).left, 1e-6);
    const empty = waveform.analyze(&.{});
    try expectEqual(@as(f32, 0), waveform.bar(&empty, 100, 0, .db).left);
}
