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
    /// Play only the loudest `window_secs` of a track, faded in and out over
    /// `fade_secs` at the two ends of that part (a track's own start and end are
    /// not touched). While on, it takes the place of silence skipping.
    dancer: bool = true,
    window_secs: u32 = 90,
    fade_secs: f32 = 2,
    /// The samples under the fade slopes, as they were before the fade was applied
    /// to the track's buffer (see `applyFade`).
    fade_saved: SavedFade = .{},
    /// `dancer`, `fade_secs` or `trim_silence` changed: `bounds` and the faded
    /// samples are rebuilt by the next `seekSeconds`, while no player is attached.
    dirty: bool = false,

    const SavedFade = struct {
        head_start: usize = 0,
        head: []f32 = &.{},
        tail_start: usize = 0,
        tail: []f32 = &.{},
    };

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
        self.freeFade();
        if (self.track) |t| {
            t.destroy(self.gpa);
            self.track = null;
        }
    }

    fn freeFade(self: *Audio) void {
        self.gpa.free(self.fade_saved.head);
        self.gpa.free(self.fade_saved.tail);
        self.fade_saved = .{};
    }

    /// Put back the samples `applyFade` changed.
    fn restoreFade(self: *Audio, t: *decoder.Track) void {
        const s = &self.fade_saved;
        @memcpy(t.samples[s.head_start * decoder.channels ..][0..s.head.len], s.head);
        @memcpy(t.samples[s.tail_start * decoder.channels ..][0..s.tail.len], s.tail);
        self.freeFade();
    }

    /// Recompute `bounds` for the current settings (the fade must be restored).
    fn updateBounds(self: *Audio, t: *decoder.Track) void {
        self.bounds = if (self.dancer)
            decoder.loudestWindow(t.samples, @as(usize, self.window_secs) * decoder.sample_rate)
        else if (self.trim_silence)
            decoder.audibleBounds(t.samples, self.silence_db, decoder.silence_window)
        else
            .{ .start = 0, .end = t.frameCount() };
    }

    /// Fade the first and last `fade_secs` of `bounds` in the track's buffer, after
    /// saving the samples it overwrites. Only call while no player uses the
    /// buffer. Running out of memory just leaves the part unfaded.
    fn applyFade(self: *Audio, t: *decoder.Track) void {
        if (!self.dancer) return;
        const len = self.bounds.end - self.bounds.start;
        const want: usize = @intFromFloat(@max(self.fade_secs, 0) * @as(f32, decoder.sample_rate));
        const n = @min(want, len / 2);
        if (n == 0) return;
        const ch = decoder.channels;
        const tail_start = self.bounds.end - n;
        const head = self.gpa.dupe(f32, t.samples[self.bounds.start * ch ..][0 .. n * ch]) catch return;
        const tail = self.gpa.dupe(f32, t.samples[tail_start * ch ..][0 .. n * ch]) catch {
            self.gpa.free(head);
            return;
        };
        self.fade_saved = .{ .head_start = self.bounds.start, .head = head, .tail_start = tail_start, .tail = tail };
        const nf: f32 = @floatFromInt(n);
        for (0..n) |i| {
            const x: f32 = @as(f32, @floatFromInt(i)) / nf * (std.math.pi / 2.0);
            const up = @sin(x);
            const down = @cos(x);
            for (0..ch) |c| {
                t.samples[(self.bounds.start + i) * ch + c] *= up;
                t.samples[(tail_start + i) * ch + c] *= down;
            }
        }
    }

    /// Rebuild `bounds` and the fade from the current settings.
    fn refresh(self: *Audio, t: *decoder.Track) void {
        self.restoreFade(t);
        self.updateBounds(t);
        self.applyFade(t);
        self.dirty = false;
    }

    /// Decode `path` and start playing it from the beginning.
    pub fn load(self: *Audio, path: []const u8) !void {
        self.unload();
        const t = try decoder.load(self.gpa, path);
        errdefer t.destroy(self.gpa);
        // The loudness graph shows the track as it is, before any fade.
        waveform.analyze(&self.peaks, t.samples);
        self.peaks_gen +%= 1;
        self.updateBounds(t);
        self.applyFade(t);
        errdefer self.freeFade();
        self.dirty = false;
        self.limitReader(t, 0);
        const p = try self.ctx.newPlayer(&t.reader);
        errdefer p.deinit();
        p.setVolume(self.volume);
        try p.play();
        self.track = t;
        self.player = p;
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
        if (self.dirty) self.refresh(t);
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
        const lo = self.bounds.start;
        const hi = self.bounds.end;
        t.reader.end = hi * decoder.bytes_per_frame;
        t.reader.seek = std.math.clamp(frame, lo, hi) * decoder.bytes_per_frame;
    }

    /// Turn silence skipping on or off. The loaded track follows at once, via a
    /// seek to where it is now (a new player), so a track playing in a silent
    /// tail ends immediately when it is switched on.
    pub fn setTrimSilence(self: *Audio, on: bool, keep_playing: bool) !void {
        if (self.trim_silence == on) return;
        self.trim_silence = on;
        self.dirty = true;
        if (self.track != null) try self.seekSeconds(self.positionSeconds(), keep_playing);
    }

    /// Turn the loudest-part-with-fades mode on or off, and set the length of
    /// that part (same mechanism as `setTrimSilence`).
    pub fn setDancer(self: *Audio, on: bool, secs: u32, keep_playing: bool) !void {
        if (self.dancer == on and self.window_secs == secs) return;
        self.dancer = on;
        self.window_secs = secs;
        self.dirty = true;
        if (self.track != null) try self.seekSeconds(self.positionSeconds(), keep_playing);
    }

    pub fn setFadeSeconds(self: *Audio, secs: f32, keep_playing: bool) !void {
        if (self.fade_secs == secs) return;
        self.fade_secs = secs;
        if (!self.dancer) return;
        self.dirty = true;
        if (self.track != null) try self.seekSeconds(self.positionSeconds(), keep_playing);
    }

    pub fn durationSeconds(self: *Audio) f64 {
        return if (self.track) |t| t.durationSeconds() else 0;
    }
};
