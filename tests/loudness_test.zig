const std = @import("std");
const loudness = @import("loudness");

const expect = std.testing.expect;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

fn sine(gpa: std.mem.Allocator, amp: f32, seconds: usize) ![]f32 {
    const n = seconds * loudness.sample_rate;
    const out = try gpa.alloc(f32, n * 2);
    for (0..n) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, loudness.sample_rate);
        const v: f32 = amp * @as(f32, @floatCast(@sin(2.0 * std.math.pi * 997.0 * t)));
        out[i * 2] = v;
        out[i * 2 + 1] = v;
    }
    return out;
}

test "a 997 Hz stereo sine of amplitude 0.1 measures about -20 LUFS" {
    const gpa = std.testing.allocator;
    const s = try sine(gpa, 0.1, 5);
    defer gpa.free(s);
    const r = loudness.measure(gpa, s).?;
    try expectApproxEqAbs(@as(f64, -20.0), r.lufs, 0.3);
    try expectApproxEqAbs(@as(f32, 0.1), r.peak, 1e-3);
}

test "silence and too-short audio have no loudness" {
    const gpa = std.testing.allocator;
    const quiet = try gpa.alloc(f32, loudness.sample_rate * 2 * 3);
    defer gpa.free(quiet);
    @memset(quiet, 0);
    try expect(loudness.measure(gpa, quiet) == null);
    const s = try sine(gpa, 0.5, 5);
    defer gpa.free(s);
    try expect(loudness.measure(gpa, s[0 .. loudness.sample_rate / 4]) == null);
}

test "gainFor reaches the target and respects the peak" {
    // From -20 LUFS to -14 LUFS is +6 dB.
    try expectApproxEqAbs(@as(f32, 1.9953), loudness.gainFor(-20, 0.1, -14, 0), 1e-3);
    // Peak 0.9 leaves only ~0.915 dB (x1.111) of headroom...
    try expectApproxEqAbs(@as(f32, 1.0 / 0.9), loudness.gainFor(-20, 0.9, -14, 0), 1e-3);
    // ...unless a limiter may take 6 dB off the peak.
    try expect(loudness.gainFor(-20, 0.9, -14, 6) > 1.9);
    // Louder than the target: attenuate.
    try expect(loudness.gainFor(-8, 0.5, -14, 0) < 1.0);
}

test "limiter reaches a target the peak cap alone cannot, without exceeding full scale" {
    const gpa = std.testing.allocator;
    // -14 LUFS sine with a spike at 0.9 every half second.
    const src = try sine(gpa, 0.2, 6);
    defer gpa.free(src);
    var i: usize = 0;
    while (i < src.len / 2) : (i += loudness.sample_rate / 2) {
        src[i * 2] = 0.9;
        src[i * 2 + 1] = 0.9;
    }
    const m = loudness.measure(gpa, src).?;
    const out = try gpa.alloc(f32, src.len);
    defer gpa.free(out);

    loudness.normalize(gpa, src, out, m, -10, 6);
    var peak: f32 = 0;
    for (out) |s| peak = @max(peak, @abs(s));
    try expect(peak <= 1.0);
    const got = loudness.measure(gpa, out).?;
    try expectApproxEqAbs(@as(f64, -10.0), got.lufs, 0.5);

    // Without a limiter the peak cap holds the track much lower.
    loudness.normalize(gpa, src, out, m, -10, 0);
    const capped = loudness.measure(gpa, out).?;
    try expect(capped.lufs < got.lufs - 1.5);
}

