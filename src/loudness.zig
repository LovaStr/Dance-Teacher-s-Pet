//! Perceived loudness of a decoded track (ITU-R BS.1770 / EBU R128 integrated
//! loudness: K-weighting plus gating) and the gain that brings it to a target.
//!
//! Targets are given in ReplayGain-style dB, where 89 dB is -18 LUFS (the
//! ReplayGain 2.0 reference), so `LUFS = db - reference_offset_db`. Pure code,
//! no dependencies besides std.

const std = @import("std");

pub const sample_rate: u32 = 44100;
/// `db - reference_offset_db` converts the ReplayGain-style scale to LUFS.
pub const reference_offset_db: f64 = 107;
pub const min_target_db: f32 = 83;
pub const max_target_db: f32 = 100;
pub const default_target_db: f32 = 93;

pub const Result = struct {
    /// Integrated loudness in LUFS.
    lufs: f64,
    /// Largest absolute sample value.
    peak: f32,
};

const Biquad = struct {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    x1: f64 = 0,
    x2: f64 = 0,
    y1: f64 = 0,
    y2: f64 = 0,

    fn process(f: *Biquad, x: f64) f64 {
        const y = f.b0 * x + f.b1 * f.x1 + f.b2 * f.x2 - f.a1 * f.y1 - f.a2 * f.y2;
        f.x2 = f.x1;
        f.x1 = x;
        f.y2 = f.y1;
        f.y1 = y;
        return y;
    }
};

/// K-weighting for one channel: a high shelf (head model) then a high-pass (RLB).
const KFilter = struct {
    shelf: Biquad,
    hp: Biquad,

    fn init(fs: f64) KFilter {
        // Same derivation as libebur128, valid for any sample rate.
        const f0 = 1681.974450955533;
        const g = 3.999843853973347;
        const q = 0.7071752369554196;
        const k = @tan(std.math.pi * f0 / fs);
        const vh = std.math.pow(f64, 10.0, g / 20.0);
        const vb = std.math.pow(f64, vh, 0.4996667741545416);
        const a0 = 1.0 + k / q + k * k;
        const shelf: Biquad = .{
            .b0 = (vh + vb * k / q + k * k) / a0,
            .b1 = 2.0 * (k * k - vh) / a0,
            .b2 = (vh - vb * k / q + k * k) / a0,
            .a1 = 2.0 * (k * k - 1.0) / a0,
            .a2 = (1.0 - k / q + k * k) / a0,
        };
        const f1 = 38.13547087602444;
        const q1 = 0.5003270373238773;
        const k1 = @tan(std.math.pi * f1 / fs);
        const a01 = 1.0 + k1 / q1 + k1 * k1;
        const hp: Biquad = .{
            .b0 = 1.0,
            .b1 = -2.0,
            .b2 = 1.0,
            .a1 = 2.0 * (k1 * k1 - 1.0) / a01,
            .a2 = (1.0 - k1 / q1 + k1 * k1) / a01,
        };
        return .{ .shelf = shelf, .hp = hp };
    }

    fn process(f: *KFilter, x: f64) f64 {
        return f.hp.process(f.shelf.process(x));
    }
};

fn blockLufs(mean_square_sum: f64) f64 {
    return -0.691 + 10.0 * std.math.log10(mean_square_sum);
}

/// Integrated loudness and peak of interleaved stereo `samples` at `sample_rate`.
/// Null when the track is shorter than one 400 ms block, silent, or on OOM.
pub fn measure(gpa: std.mem.Allocator, samples: []const f32) ?Result {
    const sub: usize = sample_rate / 10; // 100 ms; a 400 ms block is 4 of them
    const frames = samples.len / 2;
    const n_sub = frames / sub;
    if (n_sub < 4) return null;

    // Mean square (per channel, summed over both) of every 100 ms sub-block.
    var energies = gpa.alloc(f64, n_sub) catch return null;
    defer gpa.free(energies);
    var filters = [2]KFilter{ KFilter.init(sample_rate), KFilter.init(sample_rate) };
    var peak: f32 = 0;
    for (0..n_sub) |s| {
        var sum = [2]f64{ 0, 0 };
        for (s * sub..(s + 1) * sub) |i| {
            inline for (0..2) |c| {
                const x = samples[i * 2 + c];
                peak = @max(peak, @abs(x));
                const y = filters[c].process(x);
                sum[c] += y * y;
            }
        }
        energies[s] = (sum[0] + sum[1]) / @as(f64, @floatFromInt(sub));
    }
    // Peak of the unprocessed tail too.
    for (n_sub * sub * 2..samples.len) |i| peak = @max(peak, @abs(samples[i]));

    // Gating over overlapping 400 ms blocks (75 % overlap).
    const n_blocks = n_sub - 3;
    var abs_sum: f64 = 0;
    var abs_n: usize = 0;
    for (0..n_blocks) |b| {
        const z = (energies[b] + energies[b + 1] + energies[b + 2] + energies[b + 3]) / 4.0;
        if (z > 0 and blockLufs(z) > -70.0) {
            abs_sum += z;
            abs_n += 1;
        }
    }
    if (abs_n == 0) return null;
    const rel_gate = blockLufs(abs_sum / @as(f64, @floatFromInt(abs_n))) - 10.0;

    var sum: f64 = 0;
    var n: usize = 0;
    for (0..n_blocks) |b| {
        const z = (energies[b] + energies[b + 1] + energies[b + 2] + energies[b + 3]) / 4.0;
        if (z > 0 and blockLufs(z) > -70.0 and blockLufs(z) > rel_gate) {
            sum += z;
            n += 1;
        }
    }
    if (n == 0) return null;
    return .{ .lufs = blockLufs(sum / @as(f64, @floatFromInt(n))), .peak = peak };
}

/// Linear gain that brings a track of loudness `lufs` to `target_db` (ReplayGain
/// style dB). It never pushes the sample peak above full scale, so a loud
/// track may end up below the target instead of clipping.
pub fn gainFor(lufs: f64, peak: f32, target_db: f32) f32 {
    var gain_db = (@as(f64, target_db) - reference_offset_db) - lufs;
    if (peak > 0) gain_db = @min(gain_db, -20.0 * std.math.log10(@as(f64, peak)));
    return @floatCast(std.math.pow(f64, 10.0, gain_db / 20.0));
}
