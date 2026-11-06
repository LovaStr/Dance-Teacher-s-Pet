//! Decoder tests. WAV fixtures are generated in a temporary directory by the
//! tests themselves, so no binary files are stored in the repository.

const std = @import("std");
const builtin = @import("builtin");
const decoder = @import("decoder");

const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

// --- fixture helpers --------------------------------------------------------

const WavFormat = enum(u16) { pcm = 1, float = 3 };

fn appendInt(list: *std.ArrayList(u8), comptime T: type, v: T) !void {
    try list.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(T, v)));
}

/// A canonical 44-byte-header WAV file around `data`.
fn buildWav(fmt: WavFormat, channels: u16, rate: u32, bits: u16, data: []const u8) ![]u8 {
    var w: std.ArrayList(u8) = .empty;
    errdefer w.deinit(gpa);
    const block: u16 = channels * (bits / 8);
    try w.appendSlice(gpa, "RIFF");
    try appendInt(&w, u32, @intCast(36 + data.len));
    try w.appendSlice(gpa, "WAVEfmt ");
    try appendInt(&w, u32, 16);
    try appendInt(&w, u16, @intFromEnum(fmt));
    try appendInt(&w, u16, channels);
    try appendInt(&w, u32, rate);
    try appendInt(&w, u32, rate * block);
    try appendInt(&w, u16, block);
    try appendInt(&w, u16, bits);
    try w.appendSlice(gpa, "data");
    try appendInt(&w, u32, @intCast(data.len));
    try w.appendSlice(gpa, data);
    return w.toOwnedSlice(gpa);
}

/// 16-bit PCM WAV where every frame repeats `values` (one value per channel).
fn pcm16Wav(rate: u32, frames: usize, values: []const i16) ![]u8 {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    for (0..frames) |_| for (values) |v| try appendInt(&data, i16, v);
    return buildWav(.pcm, @intCast(values.len), rate, 16, data.items);
}

/// 32-bit float WAV where every frame repeats `values`.
fn float32Wav(rate: u32, frames: usize, values: []const f32) ![]u8 {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    for (0..frames) |_| for (values) |v| try appendInt(&data, u32, @bitCast(v));
    return buildWav(.float, @intCast(values.len), rate, 32, data.items);
}

/// Write `bytes` to `name` in `tmp` and return its absolute path (caller frees).
fn writeFixture(tmp: *std.testing.TmpDir, name: []const u8, bytes: []const u8) ![:0]u8 {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
    return tmp.dir.realPathFileAlloc(std.testing.io, name, gpa);
}

fn loadFixture(tmp: *std.testing.TmpDir, name: []const u8, bytes: []const u8) !*decoder.Track {
    const path = try writeFixture(tmp, name, bytes);
    defer gpa.free(path);
    return decoder.load(gpa, path);
}

// --- isSupported ------------------------------------------------------------

test "isSupported accepts the three formats, case-insensitively" {
    try std.testing.expect(decoder.isSupported("a.mp3"));
    try std.testing.expect(decoder.isSupported("a.FLAC"));
    try std.testing.expect(decoder.isSupported("dir/a.Wav"));
    try std.testing.expect(decoder.isSupported("C:\\Music\\a.mp3"));
}

test "isSupported rejects other files" {
    try std.testing.expect(!decoder.isSupported("a.ogg"));
    try std.testing.expect(!decoder.isSupported("mp3"));
    try std.testing.expect(!decoder.isSupported(""));
    try std.testing.expect(!decoder.isSupported("a.mp3.txt"));
}

// --- resample ---------------------------------------------------------------

test "resample doubles the frame count when going 22.05 kHz -> 44.1 kHz" {
    const in: [200]f32 = @splat(0.5); // 100 frames
    const out = try decoder.resample(gpa, &in, 22050);
    defer gpa.free(out);
    try expectEqual(@as(usize, 200 * 2), out.len);
}

test "resample keeps a constant signal constant" {
    var in: [128]f32 = undefined;
    for (&in, 0..) |*s, i| s.* = if (i % 2 == 0) 0.25 else -0.75;
    const out = try decoder.resample(gpa, &in, 22050);
    defer gpa.free(out);
    for (0..out.len / 2) |i| {
        try expectApproxEqAbs(@as(f32, 0.25), out[i * 2], 1e-6);
        try expectApproxEqAbs(@as(f32, -0.75), out[i * 2 + 1], 1e-6);
    }
}

test "resample interpolates linearly and holds the last frame" {
    // Two frames (0 and 1) at half the output rate -> 0, 0.5, 1, 1.
    const in = [_]f32{ 0, 0, 1, 1 };
    const out = try decoder.resample(gpa, &in, 22050);
    defer gpa.free(out);
    try expectEqual(@as(usize, 8), out.len);
    const expected = [_]f32{ 0, 0.5, 1, 1 };
    for (expected, 0..) |e, i| {
        try expectApproxEqAbs(e, out[i * 2], 1e-6);
        try expectApproxEqAbs(e, out[i * 2 + 1], 1e-6);
    }
}

test "resample 48 kHz -> 44.1 kHz gives about 44100 frames per second" {
    const in: [96000]f32 = @splat(0);
    const out = try decoder.resample(gpa, &in, 48000);
    defer gpa.free(out);
    const frames: i64 = @intCast(out.len / 2);
    try std.testing.expect(@abs(frames - 44100) <= 1);
}

test "resample rejects source rates outside the supported range" {
    const in: [200]f32 = @splat(0);
    try std.testing.expectError(error.UnsupportedSampleRate, decoder.resample(gpa, &in, 0));
    try std.testing.expectError(error.UnsupportedSampleRate, decoder.resample(gpa, &in, decoder.min_source_rate - 1));
    try std.testing.expectError(error.UnsupportedSampleRate, decoder.resample(gpa, &in, decoder.max_source_rate + 1));
    try std.testing.expectError(error.UnsupportedSampleRate, decoder.resample(gpa, &in, std.math.maxInt(u32)));
}

test "resample accepts the edges of the supported range" {
    const in: [200]f32 = @splat(0);
    const lo = try decoder.resample(gpa, &in, decoder.min_source_rate);
    gpa.free(lo);
    const hi = try decoder.resample(gpa, &in, decoder.max_source_rate);
    gpa.free(hi);
}

// --- load -------------------------------------------------------------------

test "load rejects a WAV with a sample rate below the supported range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const wav = try pcm16Wav(decoder.min_source_rate - 1, 100, &.{ 0, 0 });
    defer gpa.free(wav);
    const path = try writeFixture(&tmp, "slow_rate.wav", wav);
    defer gpa.free(path);
    try std.testing.expectError(error.UnsupportedSampleRate, decoder.load(gpa, path));
}

test "load rejects a WAV with a sample rate above the supported range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const wav = try pcm16Wav(decoder.max_source_rate + 1, 100, &.{ 0, 0 });
    defer gpa.free(wav);
    const path = try writeFixture(&tmp, "fast_rate.wav", wav);
    defer gpa.free(path);
    // dr_wav has the same 384 kHz limit and already refuses to open the file;
    // our own check (UnsupportedSampleRate) covers MP3/FLAC and `resample`.
    try std.testing.expectError(error.OpenFailed, decoder.load(gpa, path));
}

test "load keeps a 44.1 kHz stereo file as is" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const wav = try pcm16Wav(44100, 4410, &.{ 16384, -16384 }); // 0.5 / -0.5
    defer gpa.free(wav);

    const t = try loadFixture(&tmp, "stereo.wav", wav);
    defer t.destroy(gpa);

    try expectEqual(@as(usize, 4410), t.frameCount());
    try expectApproxEqAbs(@as(f64, 0.1), t.durationSeconds(), 1e-9);
    try expectApproxEqAbs(@as(f32, 0.5), t.samples[0], 1e-6);
    try expectApproxEqAbs(@as(f32, -0.5), t.samples[1], 1e-6);
    try expectApproxEqAbs(@as(f32, 0.5), t.samples[t.samples.len - 2], 1e-6);
}

test "load duplicates a mono file into both channels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const wav = try pcm16Wav(44100, 1000, &.{8192}); // 0.25
    defer gpa.free(wav);

    const t = try loadFixture(&tmp, "mono.wav", wav);
    defer t.destroy(gpa);

    try expectEqual(@as(usize, 1000), t.frameCount());
    try expectApproxEqAbs(@as(f32, 0.25), t.samples[0], 1e-6);
    try expectApproxEqAbs(@as(f32, 0.25), t.samples[1], 1e-6);
}

test "load resamples a 22.05 kHz file to double length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const wav = try pcm16Wav(22050, 2205, &.{ 8192, 8192 });
    defer gpa.free(wav);

    const t = try loadFixture(&tmp, "slow.wav", wav);
    defer t.destroy(gpa);

    try expectEqual(@as(usize, 4410), t.frameCount());
    try expectApproxEqAbs(@as(f64, 0.1), t.durationSeconds(), 1e-9);
}

test "load clamps samples outside -1..1" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const wav = try float32Wav(44100, 10, &.{ 2.0, -3.0 });
    defer gpa.free(wav);

    const t = try loadFixture(&tmp, "loud.wav", wav);
    defer t.destroy(gpa);

    for (0..t.frameCount()) |i| {
        try expectEqual(@as(f32, 1.0), t.samples[i * 2]);
        try expectEqual(@as(f32, -1.0), t.samples[i * 2 + 1]);
    }
}

test "load of a 3-channel file currently uses only the first two channels" {
    // Documents today's behaviour (no real down-mix): the third channel is dropped.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const wav = try pcm16Wav(44100, 100, &.{ 16384, -16384, 8192 });
    defer gpa.free(wav);

    const t = try loadFixture(&tmp, "three.wav", wav);
    defer t.destroy(gpa);

    try expectEqual(@as(usize, 100), t.frameCount());
    try expectApproxEqAbs(@as(f32, 0.5), t.samples[0], 1e-6);
    try expectApproxEqAbs(@as(f32, -0.5), t.samples[1], 1e-6);
}

test "load handles non-ASCII file names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const wav = try pcm16Wav(44100, 100, &.{ 100, 100 });
    defer gpa.free(wav);

    const t = try loadFixture(&tmp, "lÃ¥t â€“ Ã¶.wav", wav);
    defer t.destroy(gpa);

    try expectEqual(@as(usize, 100), t.frameCount());
}

test "load reports an error for a WAV file without audio data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const wav = try pcm16Wav(44100, 0, &.{ 0, 0 });
    defer gpa.free(wav);

    const path = try writeFixture(&tmp, "empty.wav", wav);
    defer gpa.free(path);
    // Either the decoder rejects it up front or the track turns out empty.
    const result = decoder.load(gpa, path);
    if (result) |t| {
        t.destroy(gpa);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expect(err == error.EmptyAudio or err == error.OpenFailed);
    }
}

// dr_wav clamps a WAV's declared length to the bytes actually present, so a cut
// WAV looks complete; only FLAC (STREAMINFO total sample count) can be detected.

fn crc8(bytes: []const u8) u8 {
    var crc: u8 = 0;
    for (bytes) |b| {
        crc ^= b;
        for (0..8) |_| crc = if (crc & 0x80 != 0) (crc << 1) ^ 0x07 else crc << 1;
    }
    return crc;
}

fn crc16(bytes: []const u8) u16 {
    var crc: u16 = 0;
    for (bytes) |b| {
        crc ^= @as(u16, b) << 8;
        for (0..8) |_| crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x8005 else crc << 1;
    }
    return crc;
}

/// Mono 16-bit 44.1 kHz FLAC with one verbatim frame of `frames` samples, whose
/// STREAMINFO claims `declared_frames` samples in total.
fn verbatimFlac(frames: u16, declared_frames: u64) ![]u8 {
    var f: std.ArrayList(u8) = .empty;
    errdefer f.deinit(gpa);
    try f.appendSlice(gpa, "fLaC");
    // STREAMINFO: last-block flag + type 0, length 34.
    try f.appendSlice(gpa, &.{ 0x80, 0, 0, 34 });
    try f.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, frames))); // min block size
    try f.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, frames))); // max block size
    try f.appendSlice(gpa, &.{ 0, 0, 0, 0, 0, 0 }); // min/max frame size: unknown
    const packed_info: u64 = (@as(u64, 44100) << 44) | (@as(u64, 15) << 36) | declared_frames;
    try f.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u64, packed_info)));
    try f.appendSlice(gpa, &@as([16]u8, @splat(0))); // MD5: unset

    const frame_start = f.items.len;
    // Frame header: fixed block size, 16-bit block size follows, rate from
    // STREAMINFO, mono, 16 bits per sample, frame number 0.
    try f.appendSlice(gpa, &.{ 0xFF, 0xF8, 0x70, 0x08, 0x00 });
    try f.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, frames - 1)));
    try f.append(gpa, crc8(f.items[frame_start..]));
    try f.append(gpa, 0x02); // verbatim subframe
    for (0..frames) |_| try f.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(i16, 1000)));
    try f.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, crc16(f.items[frame_start..]))));
    return f.toOwnedSlice(gpa);
}

test "load reads a complete FLAC fixture" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const flac = try verbatimFlac(1000, 1000);
    defer gpa.free(flac);

    const t = try loadFixture(&tmp, "whole.flac", flac);
    defer t.destroy(gpa);
    try expectEqual(@as(usize, 1000), t.frameCount());
}

test "load reports Truncated for a FLAC that ends before its declared length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // STREAMINFO promises 2000 samples but the file holds only 1000.
    const flac = try verbatimFlac(1000, 2000);
    defer gpa.free(flac);

    const path = try writeFixture(&tmp, "cut.flac", flac);
    defer gpa.free(path);
    try std.testing.expectError(error.Truncated, decoder.load(gpa, path));
}

test "load reports InvalidPath for a path that is not valid UTF-8" {
    // The UTF-8 -> UTF-16 conversion that rejects it only exists on Windows.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidPath, decoder.load(gpa, "C:\\music\\\xff\xfe.wav"));
}

test "load fails for a missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const wav = try pcm16Wav(44100, 10, &.{ 0, 0 });
    defer gpa.free(wav);
    const path = try writeFixture(&tmp, "exists.wav", wav);
    defer gpa.free(path);

    const missing = try std.mem.concat(gpa, u8, &.{ path[0 .. path.len - "exists.wav".len], "missing.wav" });
    defer gpa.free(missing);
    try std.testing.expectError(error.OpenFailed, decoder.load(gpa, missing));
}

test "load fails for garbage with a .wav name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(&tmp, "junk.wav", "this is not a wav file at all, just text");
    defer gpa.free(path);
    try std.testing.expectError(error.OpenFailed, decoder.load(gpa, path));
}

test "load fails for an unsupported extension even if the content is a valid WAV" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const wav = try pcm16Wav(44100, 10, &.{ 0, 0 });
    defer gpa.free(wav);
    const path = try writeFixture(&tmp, "audio.ogg", wav);
    defer gpa.free(path);
    try std.testing.expectError(error.OpenFailed, decoder.load(gpa, path));
}

test "describeError gives a sentence for each decoder error and falls back to the name" {
    try std.testing.expectEqualStrings("File is incomplete or damaged", decoder.describeError(error.Truncated));
    try std.testing.expectEqualStrings("Track is longer than 2 hours", decoder.describeError(error.TooLong));
    try std.testing.expectEqualStrings("More than 8 channels are not supported", decoder.describeError(error.UnsupportedChannelCount));
    try std.testing.expectEqualStrings("Could not open file (missing, locked or damaged)", decoder.describeError(error.OpenFailed));
    try std.testing.expectEqualStrings("SomethingElse", decoder.describeError(error.SomethingElse));
}

test "audibleBounds trims by mean level over the window" {
    // 10 silent frames, 6 loud ones (left 0.5), 10 silent frames; window 4 frames.
    var s: [2 * 26]f32 = @splat(0);
    for (10..16) |f| s[f * 2] = 0.5;
    // -20 dB: a window needs a mean square of 0.01 per channel sample.
    const b = decoder.audibleBounds(&s, -20, 4);
    try expectEqual(@as(usize, 7), b.start); // first window that reaches into the music
    try expectEqual(@as(usize, 19), b.end); // last window that still holds music
    // A stricter threshold needs more music in the window, so less is trimmed.
    const strict = decoder.audibleBounds(&s, -12, 4);
    try expect(strict.start > b.start and strict.end < b.end);
}

test "audibleBounds keeps a quiet or empty track whole" {
    const quiet = [_]f32{ 0, 0, 0.0001, 0, 0, 0 };
    const b = decoder.audibleBounds(&quiet, -60, 2);
    try expectEqual(@as(usize, 0), b.start);
    try expectEqual(@as(usize, 3), b.end);
    const e = decoder.audibleBounds(&.{}, -60, 2);
    try expectEqual(@as(usize, 0), e.end);
}
test "loudestWindow picks the window with the highest mean level" {
    // 20 frames; a quiet burst at 2..4 and a louder one at 12..16.
    var s: [2 * 20]f32 = @splat(0);
    for (2..4) |f| s[f * 2] = 0.2;
    for (12..16) |f| s[f * 2] = 0.8;
    const b = decoder.loudestWindow(&s, 5);
    try expectEqual(@as(usize, 5), b.end - b.start);
    try expect(b.start >= 11 and b.start <= 12); // holds all four loud frames
    try expect(b.start + 5 >= 16);
}

test "loudestWindow returns a short track whole" {
    const s = [_]f32{ 0.1, 0.1, 0.2, 0.2, 0.3, 0.3 };
    const b = decoder.loudestWindow(&s, 10);
    try expectEqual(@as(usize, 0), b.start);
    try expectEqual(@as(usize, 3), b.end);
}
