//! Decodes MP3 / FLAC / WAV files with mackron/dr_libs (through `lm_decode.c`)
//! into interleaved stereo float32 PCM at a fixed sample rate, the single format
//! the zoto audio context is opened with.

const std = @import("std");

/// The format of the one-and-only zoto context (see audio.zig).
pub const sample_rate: u32 = 44100;
pub const channels: u8 = 2;
pub const bytes_per_frame: usize = channels * @sizeOf(f32);

const Handle = opaque {};
extern "c" fn lm_open(path: [*:0]const u8, channels: *u32, sample_rate: *u32, err: *c_int) ?*Handle;
extern "c" fn lm_total_frames(h: *Handle) u64;
extern "c" fn lm_read_f32(h: *Handle, frames: u64, out: [*]f32) u64;
extern "c" fn lm_close(h: *Handle) void;

/// Source sample rates outside this range are rejected: the rate comes straight
/// from the (untrusted) file header and sizes the resampler's output buffer.
pub const min_source_rate: u32 = 8_000;
pub const max_source_rate: u32 = 384_000;

/// Most channels a source file may have (they are folded down to stereo).
pub const max_source_channels: u32 = 8;

/// Longest track that is decoded into memory (about 2.5 GB of float32 stereo).
pub const max_track_seconds: u64 = 2 * 60 * 60;

pub const Error = error{
    OpenFailed,
    UnsupportedChannelCount,
    UnsupportedSampleRate,
    TooLong,
    EmptyAudio,
    /// Decoding stopped before the length declared in the file header.
    Truncated,
    /// The path is not valid UTF-8.
    InvalidPath,
    OutOfMemory,
};

/// A sentence for the status bar describing `err`. Errors this module does not
/// know (e.g. from the audio device) fall back to their name.
pub fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.OpenFailed => "Could not open file (missing, locked or damaged)",
        error.UnsupportedChannelCount => std.fmt.comptimePrint("More than {d} channels are not supported", .{max_source_channels}),
        error.UnsupportedSampleRate => std.fmt.comptimePrint("Sample rate is not supported (only {d}-{d} Hz)", .{ min_source_rate, max_source_rate }),
        error.TooLong => std.fmt.comptimePrint("Track is longer than {d} hours", .{max_track_seconds / 3600}),
        error.EmptyAudio => "File contains no audio",
        error.Truncated => "File is incomplete or damaged",
        error.InvalidPath => "File path is not valid text",
        error.OutOfMemory => "Out of memory",
        else => @errorName(err),
    };
}

/// Values of `lm_open`'s `err` out-parameter (see lm_decode.c).
const lm_err_oom = 2;
const lm_err_path = 3;

/// A fully decoded track. Heap-allocated (see `load`) so `reader` has a stable
/// address: zoto's player keeps a pointer to it.
pub const Track = struct {
    /// Interleaved L/R frames at `sample_rate`.
    samples: []f32,
    /// zoto pulls PCM bytes from here.
    reader: std.Io.Reader,

    pub fn frameCount(self: *const Track) usize {
        return self.samples.len / channels;
    }

    pub fn durationSeconds(self: *const Track) f64 {
        return @as(f64, @floatFromInt(self.frameCount())) / @as(f64, sample_rate);
    }

    pub fn destroy(self: *Track, gpa: std.mem.Allocator) void {
        gpa.free(self.samples);
        gpa.destroy(self);
    }
};

/// Audio is silent while its average level over `silence_window` (one second)
/// stays below a threshold in dBFS (mean square of both channels).
pub const silence_window: usize = sample_rate;

/// Range of frames `start..end` between the leading and trailing silence.
pub const Bounds = struct { start: usize, end: usize };

/// Frames of `samples` (interleaved stereo) without the silence at the start and
/// end. The start is the first position whose following `window` frames have a
/// mean level of at least `threshold_db`; the end is the last position whose
/// preceding `window` frames do. Audio is never cut, so up to `window` frames of
/// silence can remain next to the music. A track that is quiet all the way
/// through keeps its full range.
pub fn audibleBounds(samples: []const f32, threshold_db: f32, window: usize) Bounds {
    const frames = samples.len / channels;
    const whole: Bounds = .{ .start = 0, .end = frames };
    if (frames == 0) return whole;
    const w = std.math.clamp(window, 1, frames);
    // Sum of squares (both channels) that a window must reach to count as audible.
    const limit = std.math.pow(f64, 10.0, @as(f64, threshold_db) / 10.0) * 2.0 * @as(f64, @floatFromInt(w));

    var sum: f64 = 0;
    for (0..w) |i| sum += energy(samples, i);
    var first: usize = 0;
    while (sum < limit) {
        if (first + w >= frames) return whole;
        sum += energy(samples, first + w) - energy(samples, first);
        first += 1;
    }

    sum = 0;
    for (frames - w..frames) |i| sum += energy(samples, i);
    var last: usize = frames;
    while (sum < limit) {
        if (last <= w) return whole;
        sum += energy(samples, last - w - 1) - energy(samples, last - 1);
        last -= 1;
    }
    return .{ .start = first, .end = @max(last, first) };
}

/// Sum of the squares of one frame's two samples.
fn energy(samples: []const f32, frame: usize) f64 {
    const l: f64 = samples[frame * channels];
    const r: f64 = samples[frame * channels + 1];
    return l * l + r * r;
}
/// True for the file extensions the decoder understands.
pub fn isSupported(path: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const ext = path[dot..];
    return std.ascii.eqlIgnoreCase(ext, ".mp3") or
        std.ascii.eqlIgnoreCase(ext, ".flac") or
        std.ascii.eqlIgnoreCase(ext, ".wav");
}

fn validSourceRate(rate: u32) bool {
    return rate >= min_source_rate and rate <= max_source_rate;
}

/// Decode the whole file to stereo @ 44.1 kHz float32.
pub fn load(gpa: std.mem.Allocator, path: []const u8) Error!*Track {
    const cpath = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(cpath);

    var src_channels: u32 = 0;
    var src_rate: u32 = 0;
    var open_err: c_int = 0;
    const h = lm_open(cpath.ptr, &src_channels, &src_rate, &open_err) orelse return switch (open_err) {
        lm_err_oom => error.OutOfMemory,
        lm_err_path => error.InvalidPath,
        else => error.OpenFailed,
    };
    defer lm_close(h);
    const declared_frames = lm_total_frames(h);
    if (src_channels == 0 or src_channels > max_source_channels) return error.UnsupportedChannelCount;
    if (!validSourceRate(src_rate)) return error.UnsupportedSampleRate;
    const max_src_frames: usize = @intCast(max_track_seconds * src_rate);

    const chunk_frames: usize = 4096;
    const chunk = try gpa.alloc(f32, chunk_frames * src_channels);
    defer gpa.free(chunk);

    // 1) Read everything, folding to stereo at the source rate.
    var stereo: std.ArrayList(f32) = .empty;
    defer stereo.deinit(gpa);
    while (true) {
        const got: usize = @intCast(lm_read_f32(h, chunk_frames, chunk.ptr));
        if (got == 0) break;
        if (stereo.items.len / 2 + got > max_src_frames) return error.TooLong;
        try stereo.ensureUnusedCapacity(gpa, got * 2);
        for (0..got) |i| {
            const f = chunk[i * src_channels ..][0..src_channels];
            const l = f[0];
            const r = if (src_channels == 1) f[0] else f[1];
            stereo.appendAssumeCapacity(l);
            stereo.appendAssumeCapacity(r);
        }
    }
    if (stereo.items.len == 0) return error.EmptyAudio;
    // lm_read_f32 returns 0 for both EOF and a read error; a file that ends
    // before the length its header declares was cut off or is corrupt.
    if (declared_frames != 0 and stereo.items.len / 2 < declared_frames) return error.Truncated;

    // 2) Resample (linear interpolation) to the context rate if needed.
    const samples: []f32 = if (src_rate == sample_rate)
        try stereo.toOwnedSlice(gpa)
    else
        try resample(gpa, stereo.items, src_rate);
    errdefer gpa.free(samples);

    for (samples) |*s| s.* = std.math.clamp(s.*, -1.0, 1.0);

    const track = try gpa.create(Track);
    track.* = .{
        .samples = samples,
        .reader = std.Io.Reader.fixed(std.mem.sliceAsBytes(samples)),
    };
    return track;
}

/// Linear-interpolation resampler for interleaved stereo (`in.len` is even).
pub fn resample(gpa: std.mem.Allocator, in: []const f32, in_rate: u32) Error![]f32 {
    if (!validSourceRate(in_rate)) return error.UnsupportedSampleRate;
    const in_frames = in.len / 2;
    const ratio = @as(f64, @floatFromInt(in_rate)) / @as(f64, sample_rate);
    const out_frames: usize = @intFromFloat(@as(f64, @floatFromInt(in_frames)) / ratio);
    const out = try gpa.alloc(f32, out_frames * 2);
    for (0..out_frames) |i| {
        const pos = @as(f64, @floatFromInt(i)) * ratio;
        const ia: usize = @intFromFloat(pos);
        const ib = @min(ia + 1, in_frames - 1);
        const t: f32 = @floatCast(pos - @as(f64, @floatFromInt(ia)));
        inline for (0..2) |ch| {
            const a = in[ia * 2 + ch];
            const b = in[ib * 2 + ch];
            out[i * 2 + ch] = a + (b - a) * t;
        }
    }
    return out;
}
