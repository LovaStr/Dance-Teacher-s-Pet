//! Playback engine: one zoto `Context` (opened as stereo float32 @ 44.1 kHz) and
//! at most one `Player` streaming the currently loaded, fully decoded track.

const std = @import("std");
const builtin = @import("builtin");
const zoto = @import("zoto");
const decoder = @import("decoder.zig");
const waveform = @import("waveform.zig");

pub const Audio = struct {
    gpa: std.mem.Allocator,
    ctx: *zoto.Context,
    track: ?*decoder.Track = null,
    /// Loudness graph of `track`, computed once when it is loaded.
    peaks: waveform.Peaks = .{},
    /// Bumped whenever `peaks` is replaced, so a cached picture of it can tell.
    peaks_gen: u32 = 0,
    player: ?*zoto.Player = null,
    volume: f64 = 0.8,
    /// Skip the silence at the start and end of a track (applied by `load`,
    /// `seekSeconds` and `setTrimSilence`, never to a reader a player is using).
    trim_silence: bool = true,
    /// Mean level (dBFS over one second) below which audio counts as silence.
    /// Read when a track is loaded or skipping is switched on.
    silence_db: f32 = -34,
    /// Frames of `track` between its leading and trailing silence (valid while
    /// `trim_silence` is on).
    bounds: decoder.Bounds = .{ .start = 0, .end = 0 },

    pub fn init(gpa: std.mem.Allocator) !Audio {
        // Only one context may exist per process.
        const ctx = try zoto.newContext(gpa, .{
            .sample_rate = decoder.sample_rate,
            .channel_count = decoder.channels,
            .format = .float32_le,
            .buffer_size = 0, // let zoto choose
        });
        ctx.waitForReady();
        return .{ .gpa = gpa, .ctx = ctx };
    }

    pub fn deinit(self: *Audio) void {
        self.unload();
        self.ctx.deinit();
    }

    /// Stop and release the current track, if any.
    pub fn unload(self: *Audio) void {
        if (self.player) |p| {
            p.pause();
            p.deinit(); // must precede freeing the reader it points at
            self.player = null;
        }
        if (self.track) |t| {
            t.destroy(self.gpa);
            self.track = null;
        }
    }

    /// Decode `path` and start playing it from the beginning.
    pub fn load(self: *Audio, path: []const u8) !void {
        self.unload();
        const t = try decoder.load(self.gpa, path);
        errdefer t.destroy(self.gpa);
        if (self.trim_silence) self.bounds = decoder.audibleBounds(t.samples, self.silence_db, decoder.silence_window);
        self.limitReader(t, 0);
        const p = try self.ctx.newPlayer(&t.reader);
        errdefer p.deinit();
        p.setVolume(self.volume);
        try p.play();
        self.track = t;
        self.player = p;
        waveform.analyze(&self.peaks, t.samples);
        self.peaks_gen +%= 1;
    }

    pub fn pause(self: *Audio) void {
        if (self.player) |p| p.pause();
    }

    pub fn resumePlayback(self: *Audio) !void {
        if (self.player) |p| try p.play();
    }

    /// True while a zoto player exists (playing or paused). Without one the
    /// device is silent for reasons other than the track having ended.
    pub fn hasPlayer(self: *const Audio) bool {
        return self.player != null;
    }

    pub fn isPlaying(self: *Audio) bool {
        return if (self.player) |p| p.isPlaying() else false;
    }

    pub fn setVolume(self: *Audio, v: f64) void {
        if (v == self.volume) return;
        self.volume = v;
        if (self.player) |p| p.setVolume(v);
    }

    /// Seconds of the loaded track that have been handed to the audio device
    /// (bytes consumed from the source minus what zoto still has buffered).
    pub fn positionSeconds(self: *Audio) f64 {
        const t = self.track orelse return 0;
        const p = self.player orelse return 0;
        const consumed = t.reader.seek -| p.bufferedSize();
        return @as(f64, @floatFromInt(consumed / decoder.bytes_per_frame)) / @as(f64, decoder.sample_rate);
    }

    /// Jump to `secs` in the loaded track (the device buffer is flushed). A fresh zoto player is created at the new
    /// position (the old one is fully detached from the mixer first), which avoids
    /// racing the mixer thread over the shared reader. `keep_playing` resumes
    /// playback afterwards; otherwise the new player is left paused.
    pub fn seekSeconds(self: *Audio, secs: f64, keep_playing: bool) !void {
        const t = self.track orelse return;
        if (self.player) |p| {
            p.pause();
            p.deinit();
            self.player = null;
        }
        const total: f64 = @floatFromInt(t.frameCount());
        const frame: usize = @intFromFloat(std.math.clamp(secs * @as(f64, decoder.sample_rate), 0.0, total));
        self.limitReader(t, frame);

        const p = try self.ctx.newPlayer(&t.reader);
        errdefer p.deinit();
        p.setVolume(self.volume);
        if (keep_playing) try p.play();
        self.player = p;
        // Throw away what is already queued in the device buffer (old position)
        // so the new position is heard immediately. (The zoto Windows driver in
        // third_party/zoto provides `flush`.)
        if (builtin.os.tag == .windows) self.ctx.flush();
    }

    /// Position `t`'s reader at `frame` and, when silence is skipped, confine it
    /// to the audible part. Only call while no player uses the reader.
    fn limitReader(self: *const Audio, t: *decoder.Track, frame: usize) void {
        const all = t.frameCount();
        const lo = if (self.trim_silence) self.bounds.start else 0;
        const hi = if (self.trim_silence) self.bounds.end else all;
        t.reader.end = hi * decoder.bytes_per_frame;
        t.reader.seek = std.math.clamp(frame, lo, hi) * decoder.bytes_per_frame;
    }

    /// Turn silence skipping on or off. The loaded track follows at once, via a
    /// seek to where it is now (a new player), so a track playing in a silent
    /// tail ends immediately when it is switched on.
    pub fn setTrimSilence(self: *Audio, on: bool, keep_playing: bool) !void {
        if (self.trim_silence == on) return;
        self.trim_silence = on;
        if (self.track) |t| if (on) {
            self.bounds = decoder.audibleBounds(t.samples, self.silence_db, decoder.silence_window);
        };
        if (self.track != null) try self.seekSeconds(self.positionSeconds(), keep_playing);
    }

    pub fn durationSeconds(self: *Audio) f64 {
        return if (self.track) |t| t.durationSeconds() else 0;
    }
};
