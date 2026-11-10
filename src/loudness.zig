//! Perceived loudness of a decoded track (ITU-R BS.1770 / EBU R128 integrated
//! loudness: K-weighting plus gating) and the gain that brings it to a target.
//!
//! Targets are given in LUFS. Pure code, no dependencies besides std.

const std = @import("std");

pub const sample_rate: u32 = 44100;
pub const min_target_lufs: f32 = -24;
pub const max_target_lufs: f32 = -7;
pub const default_target_lufs: f32 = -10;

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

/// Longest gain reduction (dB) the limiter may apply, and the default.
pub const max_reduction_limit_db: f32 = 12;
pub const default_reduction_db: f32 = 6;

/// Gain in dB that brings a track of loudness `lufs` to `target_lufs`, held back
/// so that the limiter never has to reduce the peak by more than `max_red_db`.
/// With `max_red_db` 0 that is a plain gain that keeps the peak at full scale.
pub fn gainDb(lufs: f64, peak: f32, target_lufs: f32, max_red_db: f32) f64 {
    var gain_db = @as(f64, target_lufs) - lufs;
    if (peak > 0) gain_db = @min(gain_db, @as(f64, max_red_db) - 20.0 * std.math.log10(@as(f64, peak)));
    return gain_db;
}

/// Linear form of `gainDb`.
pub fn gainFor(lufs: f64, peak: f32, target_lufs: f32, max_red_db: f32) f32 {
    return @floatCast(std.math.pow(f64, 10.0, gainDb(lufs, peak, target_lufs, max_red_db) / 20.0));
}

const look_ahead: usize = sample_rate / 100; // 10 ms: the gain reaches its dip this far before a peak
const release_secs: f64 = 0.15;

/// Gain envelope (<= 1) that keeps `src * g` at or below full scale: a look-ahead
/// minimum of the needed reduction (limited to `min_gain`), a fast-attack /
/// exponential-release follower, then a moving average that turns the attack into
/// a smooth ramp ending at the peak. Averaging values that are all at or below the
/// need keeps the result at or below the need. `env` has one value per frame.
fn limiterEnvelope(gpa: std.mem.Allocator, src: []const f32, g: f32, min_gain: f32, env: []f32) !void {
    const frames = env.len;
    const n = @min(look_ahead, frames);
    for (0..frames) |i| {
        const p = @max(@abs(src[i * 2]), @abs(src[i * 2 + 1])) * g;
        env[i] = if (p > 1.0) @max(1.0 / p, min_gain) else 1.0;
    }

    // Look-ahead minimum over frames i..i+n-1 (monotonic deque, walking backwards).
    const dq_idx = try gpa.alloc(u32, n + 1);
    defer gpa.free(dq_idx);
    const dq_val = try gpa.alloc(f32, n + 1);
    defer gpa.free(dq_val);
    const cap = n + 1;
    var head: usize = 0;
    var len: usize = 0;
    var i = frames;
    while (i > 0) {
        i -= 1;
        while (len > 0 and dq_idx[head] >= i + n) {
            head = (head + 1) % cap;
            len -= 1;
        }
        const v = env[i];
        while (len > 0 and dq_val[(head + len - 1) % cap] >= v) len -= 1;
        dq_idx[(head + len) % cap] = @intCast(i);
        dq_val[(head + len) % cap] = v;
        len += 1;
        env[i] = dq_val[head];
    }

    // Release: the envelope recovers towards 1 exponentially.
    const c: f32 = @floatCast(@exp(-1.0 / (release_secs * @as(f64, sample_rate))));
    var prev: f32 = 1.0;
    for (env) |*e| {
        prev = @min(e.*, 1.0 - (1.0 - prev) * c);
        e.* = prev;
    }

    // Moving average over the last n values (padded with the first one).
    const ring = try gpa.alloc(f32, n);
    defer gpa.free(ring);
    @memset(ring, env[0]);
    var sum: f64 = @as(f64, env[0]) * @as(f64, @floatFromInt(n));
    var pos: usize = 0;
    for (env) |*e| {
        sum += @as(f64, e.*) - @as(f64, ring[pos]);
        ring[pos] = e.*;
        pos = (pos + 1) % n;
        e.* = @floatCast(sum / @as(f64, @floatFromInt(n)));
    }
}

fn scaleInto(out: []f32, src: []const f32, g: f32) void {
    for (out, src) |*o, s| o.* = std.math.clamp(s * g, -1.0, 1.0);
}

/// A range of frames (`end` exclusive) whose loudness is what counts.
pub const Region = struct { start: usize, end: usize };

/// Fill `out` (same length as `src`, interleaved stereo) with `src` brought to
/// `target_lufs`. `m` is the measurement of `src` over `region` (the whole track,
/// or just the part that plays); the re-measurements look at that region only. The gain is raised as far as a
/// limiter that reduces peaks by at most `max_red_db` allows; the result is
/// re-measured and the gain adjusted a few times, because limiting costs some
/// loudness. With `max_red_db` 0 (or when memory is short) it is a plain gain
/// that keeps the peak at full scale.
pub fn normalize(gpa: std.mem.Allocator, src: []const f32, out: []f32, m: Result, target_lufs: f32, max_red_db: f32, region: Region) void {
    std.debug.assert(src.len == out.len);
    if (max_red_db < 0.05) {
        scaleInto(out, src, gainFor(m.lufs, m.peak, target_lufs, 0));
        return;
    }
    const frames = src.len / 2;
    const env = gpa.alloc(f32, frames) catch {
        scaleInto(out, src, gainFor(m.lufs, m.peak, target_lufs, 0));
        return;
    };
    defer gpa.free(env);
    const min_gain: f32 = @floatCast(std.math.pow(f64, 10.0, -@as(f64, max_red_db) / 20.0));

    var g_db = gainDb(m.lufs, m.peak, target_lufs, max_red_db);
    var iter: u32 = 0;
    while (true) : (iter += 1) {
        const g: f32 = @floatCast(std.math.pow(f64, 10.0, g_db / 20.0));
        limiterEnvelope(gpa, src, g, min_gain, env) catch {
            scaleInto(out, src, gainFor(m.lufs, m.peak, target_lufs, 0));
            return;
        };
        for (0..frames) |i| {
            const k = g * env[i];
            out[i * 2] = std.math.clamp(src[i * 2] * k, -1.0, 1.0);
            out[i * 2 + 1] = std.math.clamp(src[i * 2 + 1] * k, -1.0, 1.0);
        }
        if (iter >= 3) return;
        const got = measure(gpa, out[region.start * 2 .. region.end * 2]) orelse return;
        const err = @as(f64, target_lufs) - got.lufs;
        const next = @min(g_db + err, gainDb(m.lufs, m.peak, 1000, max_red_db));
        if (@abs(next - g_db) < 0.05) return;
        g_db = next;
    }
}

