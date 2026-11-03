# lmp3_v2

## What this project is

A desktop audio player (executable: `lmp3`), written in Zig. It is a single-window player for Windows. One page shows what is currently playing
(title, track N of M, elapsed/total time, a draggable seek slider), controls
(play-pause, a continuous-playback toggle, a remove-played-tracks toggle), a volume slider,
and the play list (with Random and Clear). There are no previous/next buttons. Clicking a
track plays it, the next track starts automatically when continuous playback is on, and
files or folders can be added from the
window or on the command line (`lmp3 [file-or-folder ...]`). Supported formats: MP3, FLAC, WAV.

## The problem it solves

A minimal, dependency-light player with a native-looking UI and no runtime, written
end to end in Zig on three small libraries. It is also a working example of combining
zigui (UI), dr_libs (decoding) and zoto (audio output) in one program.

## Tech stack

- **Language / toolchain:** Zig **0.16.0**. Do not move to 0.17: zigui uses `@cImport`, which 0.17 removed.
- **UI:** [ddalcu/zigui](https://github.com/ddalcu/zigui) (declarative views, SDL3 window layer from its `src/app.zig`, compiled from the dependency by path).
- **Decoding:** [mackron/dr_libs](https://github.com/mackron/dr_libs) (`dr_mp3`, `dr_flac`, `dr_wav`), compiled once in `src/lm_decode.c`, a small C shim exposing `lm_open` / `lm_read_f32` / `lm_close`.
- **Playback:** [braheezy/zoto](https://github.com/braheezy/zoto), **vendored and patched** in `third_party/zoto` (see `PATCHES.md`); Windows (WASAPI) only.
- **Windowing:** SDL3, **linked statically** into `lmp3.exe` (no `SDL3.dll`). The SDL3 sources ([libsdl-org/SDL](https://github.com/libsdl-org/SDL), zlib license) are an approved dependency, fetched with `zig fetch --save` and compiled by `build.zig` as a static library (source list in `third_party/sdl3_sources.zig`), together with the Windows system libraries SDL3 needs. Two small shims in `third_party/sdl3_shim/` work around zig's bundled MinGW headers: `winsdkver.h` hides the Windows 10-only backends, and `stub_gameinput.c` replaces SDL's C++ GameInput file with no-ops. SDL sources are never edited. This work lives on branch `feat/static-sdl3`; until it is merged, `main` still uses the MinGW dev package and ships `SDL3.dll`.
- **Build:** `zig build -Doptimize=ReleaseFast`; `-Dconsole=true` keeps a console window. `zigui`, `dr_libs` and SDL3 come from `zig fetch --save` (see `README.md`). Prebuilt binaries are not in the repo: `.github/workflows/release.yml` builds and tests on pull requests, and on every push to `main` publishes a GitHub Release with `lmp3-windows-x64.zip` (a single `lmp3.exe`, cross-compiled with `-Dtarget=x86_64-windows-gnu` on Linux).

## Architecture principles

- **Three layers, one direction:** `decoder.zig` (file -> PCM) -> `audio.zig` (PCM -> zoto player) -> `main.zig` (state + zigui views). The UI never touches decoder or zoto internals; it only calls `Audio` methods and reads `Audio` state.
- **One fixed output format:** the single zoto `Context` is stereo float32 @ 44.1 kHz. Every track is decoded fully into memory, folded to stereo and linearly resampled to that format, then served to zoto through a `std.Io.Reader` over the sample buffer.
- **Zoto context/player lifetime:** only one `Context` per process. One `Player` at a time; always `player.deinit()` before freeing the track whose reader it points to (`Audio.unload`).
- **Seeking = new player, not mutation:** never move the shared reader under a live player (the mixer thread reads it concurrently). `Audio.seekSeconds` detaches the old player, repositions the reader, creates a new player, then flushes the device buffer.
- **Main-thread UI, immediate-mode views:** `body()` rebuilds the view tree every frame from `AppState`; per-row callbacks allocate their context in zigui's build arena (`zigui.view.buildAlloc()`). Housekeeping (file-dialog results, volume, track-end detection) runs in the frame hook; `busyCheck` keeps redraws at ~60 fps only while playing.
- **Track end detection:** a track has ended when the user did not pause and `Audio.isPlaying()` is false; advance after a short (400 ms) grace period so the device can drain.
- **Keep the C surface tiny:** all dr_libs details stay behind `lm_decode.c`; Zig declares the three `extern "c"` functions by hand (no `@cImport` in our own code). Windows paths are converted UTF-8 -> UTF-16 in the shim.
- **Errors surface in the status bar** (`AppState.setStatus`), not as crashes; a missing audio device leaves the UI usable.

## Things the agent must NOT do

- Do **not** claim something builds or works unless it was actually compiled/run. State clearly what was only compiled and not run (this project is built by cross-compiling; playback is tested by the user).
- Do **not** upgrade Zig to 0.17 or change `minimum_zig_version` without verifying zigui builds on it.
- Do **not** edit the files in `~/.cache`/fetched dependencies; changes to zoto go in `third_party/zoto` and must be recorded in `third_party/zoto/PATCHES.md`. Do not modify zigui or dr_libs sources.
- Do **not** invent dependency hashes or fingerprints in `build.zig.zon`; use `zig fetch --save` output.
- Do **not** mutate a playing zoto `Player`'s reader, or free a track/reader before its player is deinitialized.
- Do **not** block the UI thread with long work or add threads without need; decoding is currently synchronous by design.
- Do **not** add new dependencies (beyond the approved static SDL3 source), `@cImport` in project code, or platform-specific code paths outside the existing `builtin.os.tag == .windows` guards without being asked.
- Do **not** commit, push, or delete files unless asked. Do not commit binaries (`dist/` is gitignored); releases are built by CI. Keep the Zig version in `release.yml` in step with `minimum_zig_version`.
- Do **not** leave the console window enabled in release builds (GUI subsystem is the default; `-Dconsole=true` is for debugging only).
