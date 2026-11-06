//! lmp3 — a small audio player.
//!
//!   UI        ddalcu/zigui        (single page: now playing + play list)
//!   decoding  mackron/dr_libs     (MP3 / FLAC / WAV, see decoder.zig)
//!   playback  braheezy/zoto       (see audio.zig)
//!
//! Usage:  lmp3 [file-or-folder ...]

const std = @import("std");
const zigui = @import("zigui");
const app = @import("zigui_app");
const decoder = @import("decoder.zig");
const util = @import("util.zig");
const transport = @import("transport.zig");
const waveform = @import("waveform.zig");
const Audio = @import("audio.zig").Audio;

const sdl = app.c;

// --- theme ------------------------------------------------------------------

var g_theme = zigui.default_theme;

fn themeProvider() zigui.Theme {
    g_theme = zigui.themeForScheme(.macos, app.colorScheme());
    return g_theme;
}

inline fn colors() zigui.Palette {
    return g_theme.colors;
}

// --- layout -----------------------------------------------------------------

/// Sizes and spacing used by the views (points). Untyped so they fit whichever
/// numeric type a zigui modifier expects.
const layout = struct {
    /// Initial and minimum window size.
    const window_w = 640;
    const window_h = 720;
    const window_min_w = 460;
    const window_min_h = 480;

    /// Left/right margin shared by the control strip, headers, rows and status bar.
    const margin_h = 16;
    const controls_v = 10;
    const header_v = 8;
    const row_v = 8;
    const status_v = 6;

    const now_playing_pad = 20;
    const now_playing_spacing = 8;
    const controls_spacing = 14;
    const header_spacing = 8;
    const row_spacing = 8;
    const empty_spacing = 6;

    /// Height of the loudness graph (left channel below, right above the centre line).
    const wave_h = 100;
    /// The graph is rendered at this many pixels per point, for sharp edges.
    const wave_scale = 2;
    const gear_icon = 20;
    const settings_w = 320;
    const settings_spacing = 10;
    const button_icon = 30;
    const volume_icon = 18;
    const row_icon = 14;
    /// Width of the row's leading column (track number or play/pause icon).
    const row_lead_w = 28;
    const volume_slider_w = 140;

    /// Opacity of a toggle button that is switched off.
    const dimmed = 0.35;
};

// --- state ------------------------------------------------------------------

const Entry = struct {
    path: []u8,
    /// File name without directory or extension.
    title: []u8,
};

const AppState = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Index of the track loaded into `audio` (playing or paused).
    current: ?usize = null,
    /// The user paused playback (as opposed to the track having ended).
    paused: bool = false,
    /// true: start the next track when one ends; false: stop after the current track.
    auto_advance: bool = false,
    /// true: the silence at the start and end of a track is skipped.
    skip_silence: bool = true,
    /// true: a track that has finished playing is removed from the play list.
    remove_played: bool = true,
    /// Track that play starts from when nothing is loaded (see `stopAndCueNext`).
    cue: usize = 0,
    audio: ?Audio = null,
    volume: zigui.State(f32),
    /// Settings dialog (gear button) and the loudness graph options it edits.
    show_settings: zigui.State(bool),
    wave_lines: zigui.State(f32),
    wave_line_w: zigui.State(f32),
    /// Index into `wave_scale_names` (and the `waveform.Scale` enum).
    wave_scale: zigui.State(i64),
    /// Index into `wave_display_names` (and the `waveform.Display` enum).
    wave_display: zigui.State(i64),
    /// Mean level (dBFS over one second) under which audio counts as silence.
    silence_db: zigui.State(f32),
    /// Window width seen by the previous frame (0 before the first one).
    last_window_w: f32 = 0,
    /// Cached picture of the loudness graph (see `waveView`).
    wave_img: WaveImage = .{},
    list_scroll: zigui.ScrollState = .{},
    /// `SDL_GetTicks` when the current track was first seen to have ended; the
    /// next track starts shortly after so the device can drain its buffer.
    ended_at: ?u64 = null,
    status_buf: [320]u8 = undefined,
    status_len: usize = 0,

    fn status(self: *const AppState) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    fn setStatus(self: *AppState, comptime f: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.status_buf, f, args) catch return;
        self.status_len = s.len;
    }

    fn isPlaying(self: *const AppState) bool {
        return self.current != null and !self.paused;
    }
};

var g_app: ?*AppState = null;

// --- play list --------------------------------------------------------------

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return util.pathLessThan(a.path, b.path);
}

const AddError = error{
    OutOfMemory,
    /// The path does not exist or cannot be accessed.
    NotFound,
    /// The folder exists but its contents could not be listed.
    FolderUnreadable,
};

/// A user-facing sentence for `err` (decoder errors are described by the decoder).
fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.NotFound => "Path does not exist or cannot be accessed",
        error.FolderUnreadable => "Folder contents could not be listed",
        else => decoder.describeError(err),
    };
}

/// Append one audio file to the play list (unsupported extensions are ignored).
fn addFile(st: *AppState, path: []const u8) error{OutOfMemory}!void {
    if (!decoder.isSupported(path)) return;
    const owned = try st.gpa.dupe(u8, path);
    errdefer st.gpa.free(owned);
    const title = try st.gpa.dupe(u8, util.titleOf(path));
    errdefer st.gpa.free(title);
    try st.entries.append(st.gpa, .{ .path = owned, .title = title });
}

/// Add a file, or every supported file found under a folder (sorted by path).
/// Files added before an error occurs stay in the play list.
fn addPath(st: *AppState, path: []const u8) AddError!void {
    const cpath = try st.gpa.dupeSentinel(u8, path, 0);
    defer st.gpa.free(cpath);

    var info: sdl.SDL_PathInfo = undefined;
    if (!sdl.SDL_GetPathInfo(cpath.ptr, &info)) return error.NotFound;
    if (info.type != sdl.SDL_PATHTYPE_DIRECTORY) return addFile(st, path);

    var count: c_int = 0;
    const list = sdl.SDL_GlobDirectory(cpath.ptr, null, 0, &count) orelse return error.FolderUnreadable;
    defer sdl.SDL_free(@ptrCast(list));

    const first_new = st.entries.items.len;
    defer std.mem.sort(Entry, st.entries.items[first_new..], {}, lessThan);
    var i: usize = 0;
    while (i < @as(usize, @intCast(count))) : (i += 1) {
        const rel = std.mem.span(list[i]);
        const full = try std.fmt.allocPrint(st.gpa, "{s}/{s}", .{ path, rel });
        defer st.gpa.free(full);
        try addFile(st, full);
    }
}

/// Add `path` and report the outcome in the status bar.
fn addPathReportingStatus(st: *AppState, path: []const u8) void {
    const before = st.entries.items.len;
    addPath(st, path) catch |err| {
        st.setStatus("Could not add \"{s}\": {s}", .{ util.baseName(path), describeError(err) });
        return;
    };
    const added = st.entries.items.len - before;
    if (added == 0) {
        st.setStatus("No supported audio files found in \"{s}\"", .{util.baseName(path)});
    } else {
        st.setStatus("Added {d} track(s)", .{added});
    }
}

fn freeEntries(st: *AppState) void {
    for (st.entries.items) |e| {
        st.gpa.free(e.path);
        st.gpa.free(e.title);
    }
    st.entries.clearRetainingCapacity();
}

fn clearPlaylist(st: *AppState) void {
    stopAudio(st);
    freeEntries(st);
    st.cue = 0;
    st.setStatus("Play list cleared", .{});
}

// --- transport --------------------------------------------------------------

fn stopAudio(st: *AppState) void {
    if (st.audio) |*au| au.unload();
    st.current = null;
    st.paused = false;
}

fn playIndex(st: *AppState, index: usize) void {
    if (index >= st.entries.items.len) return;
    const a = if (st.audio) |*au| au else {
        st.setStatus("No audio device available", .{});
        return;
    };
    const e = st.entries.items[index];
    a.trim_silence = st.skip_silence;
    a.load(e.path) catch |err| {
        a.unload();
        st.current = null;
        st.paused = false;
        st.setStatus("Could not play \"{s}\": {s}", .{ e.title, describeError(err) });
        return;
    };
    st.current = index;
    st.paused = false;
    st.setStatus("Playing", .{});
}

/// Stop after a track ended on its own and cue the track that follows it, so the
/// next press of play starts that one (wrapping to the first track past the end
/// of the list). If played tracks are removed, the finished one is dropped too.
fn stopAndCueNext(st: *AppState, finished: ?usize) void {
    stopAudio(st);
    st.cue = 0;
    const f = finished orelse return;
    if (st.remove_played) {
        removeEntry(st, f);
        st.cue = f;
    } else {
        st.cue = f + 1;
    }
}

fn togglePlayPause(st: *AppState) void {
    if (st.current == null) {
        const len = st.entries.items.len;
        if (len > 0) playIndex(st, if (st.cue < len) st.cue else 0);
        return;
    }
    const a = if (st.audio) |*au| au else return;
    if (st.paused) {
        a.resumePlayback() catch |err| {
            st.setStatus("Resume failed: {s}", .{describeError(err)});
            return;
        };
        st.paused = false;
    } else {
        a.pause();
        st.paused = true;
    }
}

/// Remove one entry from the play list. `index` must not be the loaded track.
fn removeEntry(st: *AppState, index: usize) void {
    const e = st.entries.orderedRemove(index);
    st.gpa.free(e.path);
    st.gpa.free(e.title);
    if (st.current) |c| {
        if (c > index) st.current = c - 1;
    }
}

// --- callbacks --------------------------------------------------------------

fn onPlayPause(st: *AppState) void {
    togglePlayPause(st);
}
fn onClear(st: *AppState) void {
    clearPlaylist(st);
}
fn onToggleRemovePlayed(st: *AppState) void {
    st.remove_played = !st.remove_played;
    st.setStatus("{s}", .{if (st.remove_played) "Played tracks are removed from the list" else "Played tracks stay in the list"});
}
fn onToggleAutoAdvance(st: *AppState) void {
    st.auto_advance = !st.auto_advance;
    st.setStatus("{s}", .{if (st.auto_advance) "Continuous playback" else "Stop after current track"});
}

fn onToggleSkipSilence(st: *AppState) void {
    st.skip_silence = !st.skip_silence;
    st.setStatus("{s}", .{if (st.skip_silence) "Silence at the start and end is skipped" else "Silence at the start and end is played"});
    if (st.current == null) return;
    const a = if (st.audio) |*au| au else return;
    a.setTrimSilence(st.skip_silence, !st.paused) catch |err| {
        stopAudio(st);
        st.setStatus("Seek failed: {s}", .{describeError(err)});
    };
}

fn onOpenSettings(st: *AppState) void {
    st.show_settings.set(true);
}

fn onCloseSettings(st: *AppState) void {
    st.show_settings.set(false);
}

const audio_filters = [_]app.FileFilter{
    .{ .name = "Audio files (mp3, flac, wav)", .pattern = "mp3;flac;wav" },
    .{ .name = "All files", .pattern = "*" },
};

/// Shuffle the play list and cue (select, not start) the first track of the new order.
fn onRandom(st: *AppState) void {
    if (st.entries.items.len == 0) return;
    stopAudio(st);
    var prng = std.Random.DefaultPrng.init(sdl.SDL_GetPerformanceCounter());
    prng.random().shuffle(Entry, st.entries.items);
    st.cue = 0;
    st.setStatus("Play list shuffled", .{});
}

// zigui's file dialog only picks a single file, so "Add files" talks to SDL's
// multi-select dialog directly. SDL may call back on another thread: the
// callback only stores the picked paths (NUL-separated) and wakes the event
// loop; `frameHook` adds them on the main thread.
var g_files_open = false; // main thread only: a dialog is showing
var g_files_done: std.atomic.Value(bool) = .init(false);
var g_files_picked: ?[]u8 = null; // guarded by g_files_done

fn filesDialogThunk(_: ?*anyopaque, filelist: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    var picked: ?[]u8 = null;
    if (filelist != null and filelist[0] != null) {
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (filelist[i] != null) : (i += 1) {
            buf.appendSlice(std.heap.c_allocator, std.mem.span(filelist[i])) catch break;
            buf.append(std.heap.c_allocator, 0) catch break;
        }
        picked = buf.toOwnedSlice(std.heap.c_allocator) catch null;
    }
    g_files_picked = picked;
    g_files_done.store(true, .release);
    var ev = std.mem.zeroes(sdl.SDL_Event);
    ev.type = sdl.SDL_EVENT_USER;
    _ = sdl.SDL_PushEvent(&ev);
}

fn onAddFile(_: *AppState) void {
    if (g_files_open) return;
    g_files_open = true;
    g_files_done.store(false, .release);
    sdl.SDL_ShowOpenFileDialog(
        filesDialogThunk,
        null,
        sdl.SDL_GetKeyboardFocus(),
        &audio_filters,
        audio_filters.len,
        null,
        true, // allow_many
    );
}

/// Add the files picked in the multi-select dialog, once it has finished.
fn takePickedFiles(st: *AppState) void {
    if (!g_files_open or !g_files_done.load(.acquire)) return;
    g_files_open = false;
    const picked = g_files_picked orelse return;
    g_files_picked = null;
    defer std.heap.c_allocator.free(picked);

    const before = st.entries.items.len;
    var failed: ?[]const u8 = null;
    var failure: anyerror = undefined;
    var it = std.mem.splitScalar(u8, picked, 0);
    while (it.next()) |path| {
        if (path.len == 0) continue;
        addPath(st, path) catch |err| {
            failed = path;
            failure = err;
        };
    }
    if (failed) |path| {
        st.setStatus("Could not add \"{s}\": {s}", .{ util.baseName(path), describeError(failure) });
    } else if (st.entries.items.len == before) {
        st.setStatus("No supported audio files selected", .{});
    } else {
        st.setStatus("Added {d} track(s)", .{st.entries.items.len - before});
    }
}
fn onAddFolder(_: *AppState) void {
    _ = app.openFolderDialog(null);
}

const RowCtx = struct { st: *AppState, index: usize };

fn onRowTap(p: ?*anyopaque) void {
    const ctx: *RowCtx = @ptrCast(@alignCast(p.?));
    playIndex(ctx.st, ctx.index);
}

// --- per-frame housekeeping (main thread) ----------------------------------

fn frameHook() void {
    const st = g_app orelse return;

    // Finished file / folder pickers.
    takePickedFiles(st);
    switch (app.takeFileDialogResult(st.gpa)) {
        .none, .canceled => {},
        .picked => |path| {
            defer st.gpa.free(path);
            addPathReportingStatus(st, path);
        },
    }

    // The graph gets one line per point of window width (after a resize).
    const win_w = zigui.view.viewport().width;
    if (win_w != st.last_window_w) {
        if (st.last_window_w != 0) st.wave_lines.set(std.math.clamp(@round(win_w), waveform.min_bars, waveform.max_bars));
        st.last_window_w = win_w;
    }

    const a = if (st.audio) |*au| au else return;
    a.setVolume(st.volume.get());
    a.silence_db = st.silence_db.get();

    // A track that was playing and has stopped by itself has ended: advance
    // (after a short grace period so the device can play out its buffer). With
    // no player at all (e.g. a failed seek) nothing ended, so do not advance.
    if (!a.hasPlayer()) {
        st.ended_at = null;
        return;
    }
    const step = transport.trackEnd(.{
        .current = st.current,
        .paused = st.paused,
        .device_playing = a.isPlaying(),
        .now = sdl.SDL_GetTicks(),
        .ended_at = st.ended_at,
        .len = st.entries.items.len,
        .auto_advance = st.auto_advance,
    });
    st.ended_at = step.ended_at;
    const finished = st.current;
    switch (step.action) {
        .none => {},
        .play => |i| {
            // Start the next track first (this unloads the finished one), then drop
            // the finished entry, which sits before it in the list.
            playIndex(st, i);
            if (st.remove_played) if (finished) |f| removeEntry(st, f);
        },
        .stop_after_track => {
            stopAndCueNext(st, finished);
            st.setStatus("Stopped after current track", .{});
        },
        .stop_end_of_list => {
            stopAndCueNext(st, finished);
            st.setStatus("Reached the end of the play list", .{});
        },
    }
}

/// Keep the loop redrawing (~60 fps) while music plays so the clock and progress
/// bar move.
fn busyCheck() bool {
    const st = g_app orelse return false;
    return st.isPlaying();
}

// --- views ------------------------------------------------------------------

fn fmtTime(seconds: f64) []const u8 {
    const t = util.splitTime(seconds);
    return zigui.components.fmt("{d}:{d:0>2}", .{ t.minutes, t.seconds });
}

/// The seek slider's binding: reads the playback position as a 0..1 fraction and
/// seeks when the user clicks or drags it.
fn seekGet(ctx: *anyopaque) f32 {
    const st: *AppState = @ptrCast(@alignCast(ctx));
    if (st.current == null) return 0;
    const a = if (st.audio) |*au| au else return 0;
    const dur = a.durationSeconds();
    if (dur <= 0) return 0;
    return @floatCast(@min(a.positionSeconds() / dur, 1.0));
}

fn seekSet(ctx: *anyopaque, v: f32) void {
    const st: *AppState = @ptrCast(@alignCast(ctx));
    if (st.current == null) return;
    const a = if (st.audio) |*au| au else return;
    a.seekSeconds(@as(f64, v) * a.durationSeconds(), !st.paused) catch |err| {
        // The old player is already gone; stop instead of letting the track-end
        // detection mistake the missing player for a finished track.
        stopAudio(st);
        st.setStatus("Seek failed: {s}", .{describeError(err)});
    };
}

/// What the cached loudness picture was rendered from. The picture is only
/// rebuilt when one of these changes (window width, settings, colour, track).
const WaveKey = struct {
    w: u32,
    h: u32,
    bars: usize,
    scale: waveform.Scale,
    display: waveform.Display,
    line_w: f32,
    rgb: [3]u8,
    gen: u32,
};

/// Labels of the "Scale" picker, in `waveform.Scale` order.
const wave_scale_names = [_][]const u8{ "dB", "Linear" };

/// Labels of the "Show" picker, in `waveform.Display` order.
const wave_display_names = [_][]const u8{ "Peak", "RMS", "Peak + RMS" };

/// Address and size of every pixel buffer ever handed to the renderer. zigui
/// caches an image's texture by (address, size), so a new picture must never
/// reuse that pair for different pixels.
const PixelKey = struct { addr: usize, w: u32, h: u32 };

const WaveImage = struct {
    pixels: []u8 = &.{},
    key: ?WaveKey = null,
    used: std.ArrayList(PixelKey) = .empty,

    fn deinit(self: *WaveImage, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        self.used.deinit(gpa);
    }

    fn seen(self: *const WaveImage, k: PixelKey) bool {
        for (self.used.items) |u| {
            if (u.addr == k.addr and u.w == k.w and u.h == k.h) return true;
        }
        return false;
    }

    /// Render `peaks` into a fresh buffer and make it the current picture.
    fn rebuild(self: *WaveImage, gpa: std.mem.Allocator, key: WaveKey, peaks: *const waveform.Peaks) !void {
        const len = @as(usize, key.w) * key.h * 4;
        // Buffers whose address was used before at this size are held back
        // (so the allocator hands out another) and released afterwards.
        var rejected: std.ArrayList([]u8) = .empty;
        defer {
            for (rejected.items) |r| gpa.free(r);
            rejected.deinit(gpa);
        }
        const buf = while (true) {
            const b = try gpa.alloc(u8, len);
            if (!self.seen(.{ .addr = @intFromPtr(b.ptr), .w = key.w, .h = key.h })) break b;
            rejected.append(gpa, b) catch {
                gpa.free(b);
                return error.OutOfMemory;
            };
        };
        errdefer gpa.free(buf);
        try self.used.append(gpa, .{ .addr = @intFromPtr(buf.ptr), .w = key.w, .h = key.h });
        waveform.render(buf, key.w, key.h, peaks, key.bars, key.scale, key.display, key.line_w, key.rgb);
        gpa.free(self.pixels);
        self.pixels = buf;
        self.key = key;
    }
};

/// The "Number of lines" setting as a whole number inside its allowed range.
fn waveBars(st: *const AppState) usize {
    const v = std.math.clamp(@round(st.wave_lines.get()), waveform.min_bars, waveform.max_bars);
    return @intFromFloat(v);
}

fn waveScale(st: *const AppState) waveform.Scale {
    return std.enums.fromInt(waveform.Scale, st.wave_scale.get()) orelse .db;
}

fn waveDisplay(st: *const AppState) waveform.Display {
    return std.enums.fromInt(waveform.Display, st.wave_display.get()) orelse .peak;
}

fn rgbOf(c: zigui.Color) [3]u8 {
    return .{
        @intFromFloat(@round(std.math.clamp(c.r, 0, 1) * 255)),
        @intFromFloat(@round(std.math.clamp(c.g, 0, 1) * 255)),
        @intFromFloat(@round(std.math.clamp(c.b, 0, 1) * 255)),
    };
}

/// Loudness graph: one vertical line per window, growing up from the (invisible)
/// centre line for the right channel and down from it for the left channel.
/// Drawn as a picture that is only re-rendered when its inputs change, not on
/// every frame while the track plays.
fn waveView(st: *AppState) zigui.View {
    const empty = zigui.Spacer().frameMaxWidth().frameHeight(layout.wave_h);
    const a = if (st.audio) |*au| au else return empty;
    if (st.current == null) return empty;
    const width_pt = @floor(zigui.viewport().width - 2 * layout.now_playing_pad);
    if (width_pt < 1) return empty;

    const key: WaveKey = .{
        .w = @intFromFloat(width_pt * layout.wave_scale),
        .h = layout.wave_h * layout.wave_scale,
        .bars = waveBars(st),
        .scale = waveScale(st),
        .display = waveDisplay(st),
        .line_w = st.wave_line_w.get() * layout.wave_scale,
        .rgb = rgbOf(colors().accent),
        .gen = a.peaks_gen,
    };
    const same = if (st.wave_img.key) |k| std.meta.eql(k, key) else false;
    if (!same) st.wave_img.rebuild(st.gpa, key, &a.peaks) catch return empty;

    const ctx = zigui.view.buildAlloc().create(WavePaint) catch return empty;
    ctx.* = .{ .image = .{ .width = key.w, .height = key.h, .pixels = st.wave_img.pixels } };
    return zigui.Drawing(WavePaint, ctx, paintWave).frameMaxWidth().frameHeight(layout.wave_h);
}

const WavePaint = struct { image: zigui.canvas.Image };

/// Stretch the cached picture over exactly the area the view got, which is the
/// same width as the seek slider below it (both fill the column).
fn paintWave(ctx: *const WavePaint, pen: *zigui.Pen, r: zigui.Rect) std.mem.Allocator.Error!void {
    try pen.canvas.drawImage(r, ctx.image);
}

fn nowPlaying(st: *AppState) zigui.View {
    const c = colors();

    var title: []const u8 = "Nothing playing";
    var subtitle: []const u8 = "Add some music, then pick a track";
    var pos: f64 = 0;
    var dur: f64 = 0;
    if (st.current) |i| {
        title = st.entries.items[i].title;
        subtitle = zigui.components.fmt("{s} · track {d} of {d}", .{
            if (st.paused) "Paused" else "Now playing",
            i + 1,
            st.entries.items.len,
        });
        if (st.audio) |*au| {
            pos = au.positionSeconds();
            dur = au.durationSeconds();
        }
    }

    return zigui.VStack(.{
        zigui.HStack(.{
            zigui.Spacer(),
            zigui.IconButton(.settings, layout.gear_icon, zigui.actionCtx(AppState, st, onOpenSettings)),
        }),
        waveView(st),
        zigui.Text(title).font(.title2).truncated(),
        zigui.Text(subtitle).font(.subheadline).foreground(c.secondary_label),
        zigui.Slider(.{ .ctx = st, .getFn = seekGet, .setFn = seekSet }, 0, 1).frameMaxWidth(),
        zigui.HStack(.{
            zigui.Text(fmtTime(pos)).font(.caption).foreground(c.secondary_label),
            zigui.Spacer(),
            zigui.Text(fmtTime(dur)).font(.caption).foreground(c.secondary_label),
        }),
    }).spacing(layout.now_playing_spacing).padding(layout.now_playing_pad).frameMaxWidth();
}

fn settingsView(st: *AppState) zigui.View {
    const c = colors();
    return zigui.VStack(.{
        zigui.Text("Settings").font(.title3),
        zigui.Text(zigui.components.fmt("Number of lines: {d}", .{waveBars(st)})).font(.subheadline).foreground(c.secondary_label),
        zigui.Slider(st.wave_lines.binding(), waveform.min_bars, waveform.max_bars).frameMaxWidth(),
        zigui.Text(zigui.components.fmt("Line width: {d:.1}", .{st.wave_line_w.get()})).font(.subheadline).foreground(c.secondary_label),
        zigui.Slider(st.wave_line_w.binding(), 0.1, 5.0).frameMaxWidth(),
        zigui.Text("Scale").font(.subheadline).foreground(c.secondary_label),
        zigui.Picker(st.wave_scale.binding(), &wave_scale_names),
        zigui.Text("Show").font(.subheadline).foreground(c.secondary_label),
        zigui.Picker(st.wave_display.binding(), &wave_display_names),
        zigui.Text(zigui.components.fmt("Silence below: {d:.0} dB (1 s average)", .{st.silence_db.get()})).font(.subheadline).foreground(c.secondary_label),
        zigui.Slider(st.silence_db.binding(), -80, -20).frameMaxWidth(),
        zigui.HStack(.{
            zigui.Spacer(),
            zigui.Button("Close", zigui.actionCtx(AppState, st, onCloseSettings)),
        }).frameMaxWidth(),
    }).alignment(.leading).spacing(layout.settings_spacing).padding(layout.now_playing_pad).frameWidth(layout.settings_w);
}

fn controls(st: *AppState) zigui.View {
    const playing = st.isPlaying();
    return zigui.HStack(.{
        zigui.IconButton(if (playing) .pause else .play, layout.button_icon, zigui.actionCtx(AppState, st, onPlayPause)),
        autoAdvanceToggle(st),
        skipSilenceToggle(st),
        removePlayedToggle(st),
        zigui.Spacer(),
        zigui.Icon(.volume, layout.volume_icon, null),
        zigui.Slider(st.volume.binding(), 0, 1).frameWidth(layout.volume_slider_w),
    }).spacing(layout.controls_spacing).paddingInsets(.{ .top = layout.controls_v, .leading = layout.margin_h, .bottom = layout.controls_v, .trailing = layout.margin_h });
}

/// Arrow button: full strength while playback continues with the next track,
/// dimmed grey (like the trash button) while it stops after the current one.
fn autoAdvanceToggle(st: *AppState) zigui.View {
    const btn = zigui.IconButton(.arrow_right, layout.button_icon, zigui.actionCtx(AppState, st, onToggleAutoAdvance));
    return if (st.auto_advance) btn else btn.opacity(layout.dimmed);
}

/// Waveform button: full strength while the silence at the start and end of a
/// track is skipped, dimmed grey while it is played.
fn skipSilenceToggle(st: *AppState) zigui.View {
    const btn = zigui.IconButton(.audio_waveform, layout.button_icon, zigui.actionCtx(AppState, st, onToggleSkipSilence));
    return if (st.skip_silence) btn else btn.opacity(layout.dimmed);
}

/// Trash button: dimmed grey while played tracks stay in the list, full strength
/// while they are removed. Same size as the play/pause button.
fn removePlayedToggle(st: *AppState) zigui.View {
    const btn = zigui.IconButton(.trash, layout.button_icon, zigui.actionCtx(AppState, st, onToggleRemovePlayed));
    return if (st.remove_played) btn else btn.opacity(layout.dimmed);
}

fn playlistHeader(st: *AppState) zigui.View {
    return zigui.HStack(.{
        zigui.Text(zigui.components.fmt("Play list · {d}", .{st.entries.items.len})).font(.headline),
        zigui.Spacer(),
        zigui.Button("Random", zigui.actionCtx(AppState, st, onRandom)),
        zigui.Button("Add files…",zigui.actionCtx(AppState, st, onAddFile)),
        zigui.Button("Add folder…", zigui.actionCtx(AppState, st, onAddFolder)),
        zigui.Button("Clear", zigui.actionCtx(AppState, st, onClear)),
    }).spacing(layout.header_spacing).paddingInsets(.{ .top = layout.header_v, .leading = layout.margin_h, .bottom = layout.header_v, .trailing = layout.margin_h });
}

/// Shown instead of the play list when the per-frame build arena is exhausted.
fn outOfMemoryView() zigui.View {
    return zigui.VStack(.{
        zigui.Spacer(),
        zigui.Text("Out of memory: cannot draw the play list").font(.headline).foreground(colors().secondary_label),
        zigui.Spacer(),
    }).frameMaxWidth().frameMaxHeight();
}

fn playlist(st: *AppState) zigui.View {
    const c = colors();
    if (st.entries.items.len == 0) {
        return zigui.VStack(.{
            zigui.Spacer(),
            zigui.Text("The play list is empty").font(.headline).foreground(c.secondary_label),
            zigui.Text("Use “Add files…” or “Add folder…”, or start lmp3 with paths.")
                .font(.subheadline).foreground(c.tertiary_label),
            zigui.Spacer(),
        }).spacing(layout.empty_spacing).frameMaxWidth().frameMaxHeight();
    }

    // zigui registers a tap region for every row, clipped or not, and the last
    // region under the pointer wins. Rows scrolled out of view sit on top of the
    // controls above the list (e.g. the seek slider) and would steal their clicks,
    // so only rows lying fully inside the viewport are made tappable. Row pitch
    // comes from the content height measured on the previous frame.
    const n = st.entries.items.len;
    const hair = g_theme.metrics.hairline;
    const content_h = st.list_scroll.content_h;
    const view_h = st.list_scroll.viewport_h;
    const measured = content_h > 0 and view_h > 0;
    const pitch: f32 = if (measured) (content_h + hair) / @as(f32, @floatFromInt(n)) else 0;
    const row_h = pitch - hair;

    const arena = zigui.view.buildAlloc();
    const rows = arena.alloc(zigui.View, st.entries.items.len * 2) catch return outOfMemoryView();
    for (st.entries.items, 0..) |e, i| {
        const top = @as(f32, @floatFromInt(i)) * pitch - st.list_scroll.offset;
        const interactive = !measured or (top >= -0.5 and top + row_h <= view_h + 0.5);
        const ctx = arena.create(RowCtx) catch return outOfMemoryView();
        ctx.* = .{ .st = st, .index = i };
        const is_current = st.current != null and st.current.? == i;

        const lead = if (is_current)
            zigui.Icon(if (st.paused) .pause else .play, layout.row_icon, c.accent)
        else
            zigui.Text(zigui.components.fmt("{d}", .{i + 1})).font(.caption).foreground(c.tertiary_label);

        var row = zigui.HStack(.{
            lead.frameWidth(layout.row_lead_w),
            zigui.Text(e.title).truncated(),
            zigui.Spacer(),
        }).spacing(layout.row_spacing)
            .paddingInsets(.{ .top = layout.row_v, .leading = layout.margin_h, .bottom = layout.row_v, .trailing = layout.margin_h })
            .frameMaxWidth();
        if (interactive) row = row.hoverFill(c.hover).onTap(.{ .ctx = ctx, .func = onRowTap });
        // Blue: the loaded track, or with nothing loaded the one play will start.
        const is_cued = st.current == null and i == (if (st.cue < st.entries.items.len) st.cue else 0);
        if (is_current or is_cued) row = row.background(c.selection);

        rows[i * 2] = row;
        rows[i * 2 + 1] = zigui.Divider();
    }

    return zigui.ScrollViewState(&st.list_scroll, zigui.VStack(rows[0 .. rows.len - 1]).spacing(0))
        .frameMaxWidth()
        .frameMaxHeight();
}

fn statusBar(st: *AppState) zigui.View {
    return zigui.HStack(.{
        zigui.Text(st.status()).font(.caption).foreground(colors().secondary_label).truncated(),
        zigui.Spacer(),
    }).paddingInsets(.{ .top = layout.status_v, .leading = layout.margin_h, .bottom = layout.status_v, .trailing = layout.margin_h });
}

fn body(st: *AppState) zigui.View {
    return zigui.VStack(.{
        nowPlaying(st),
        controls(st),
        zigui.Divider(),
        playlistHeader(st),
        zigui.Divider(),
        playlist(st),
        zigui.Divider(),
        statusBar(st),
    }).spacing(0).frameMaxWidth().frameMaxHeight()
        .alert(st.show_settings.binding(), settingsView(st));
}

// --- entry point ------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var st = AppState{
        .gpa = gpa,
        .volume = zigui.State(f32).init(gpa, 1.0),
        .show_settings = zigui.State(bool).init(gpa, false),
        .wave_lines = zigui.State(f32).init(gpa, waveform.default_bars),
        .wave_line_w = zigui.State(f32).init(gpa, 1.5),
        .wave_scale = zigui.State(i64).init(gpa, @intFromEnum(waveform.Scale.linear)),
        .wave_display = zigui.State(i64).init(gpa, @intFromEnum(waveform.Display.peak)),
        .silence_db = zigui.State(f32).init(gpa, -34),
    };
    defer {
        freeEntries(&st);
        st.entries.deinit(gpa);
        st.volume.deinit();
        st.show_settings.deinit();
        st.wave_lines.deinit();
        st.wave_line_w.deinit();
        st.wave_scale.deinit();
        st.wave_display.deinit();
        st.silence_db.deinit();
        st.wave_img.deinit(gpa);
    }
    g_app = &st;

    st.audio = Audio.init(gpa) catch |err| blk: {
        st.setStatus("Audio output unavailable: {s}", .{describeError(err)});
        break :blk null;
    };
    defer if (st.audio) |*au| au.deinit();
    if (st.audio != null) st.setStatus("Ready", .{});

    // Files and folders given on the command line fill the play list.
    var args = try std.process.Args.iterateAllocator(init.args, gpa);
    defer args.deinit();
    _ = args.next(); // argv[0]
    var arg_failed = false;
    while (args.next()) |arg| {
        addPath(&st, arg) catch |err| {
            arg_failed = true;
            st.setStatus("Could not add \"{s}\": {s}", .{ util.baseName(arg), describeError(err) });
        };
    }
    // Keep the error message if any argument failed; otherwise summarize.
    if (!arg_failed and st.entries.items.len > 0) st.setStatus("Loaded {d} track(s)", .{st.entries.items.len});

    app.setThemeProvider(themeProvider);
    app.setFrameHook(frameHook);
    app.setBusyCheck(busyCheck);

    try app.run(gpa, AppState, &st, .{
        .title = "lmp3 — audio player",
        .width = layout.window_w,
        .height = layout.window_h,
        .min_width = layout.window_min_w,
        .min_height = layout.window_min_h,
    }, body, null);
}
