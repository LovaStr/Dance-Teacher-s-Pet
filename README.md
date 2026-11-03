# lmp3_v2

A small, dependency-light audio player for Windows, written end to end in Zig, with a native-looking UI and no runtime to install.

Download: [latest release](../../releases/latest) (`lmp3-windows-x64.zip`: a single `lmp3.exe`, SDL3 is built in). Unzip and run `lmp3.exe`.

## What it does

Plays MP3, FLAC and WAV files in a single window. The window shows the current track (title, track N of M, elapsed/total time) with a draggable seek slider, play/pause, a continuous-playback toggle, a remove-played-tracks toggle, a volume slider and the play list. Add files or folders from the window or on the command line (`lmp3 [file-or-folder ...]`), click a track to play it, and shuffle or clear the list.

It is also a working example of combining [zigui](https://github.com/ddalcu/zigui) (UI), [dr_libs](https://github.com/mackron/dr_libs) (decoding) and [zoto](https://github.com/braheezy/zoto) (audio output) in one program.

## Getting started

### Requirements

* Windows (playback uses WASAPI; no other platform is supported)
* To run: nothing beyond the release zip
* To build from source:
  * **Zig 0.16.0** (do not use 0.17: zigui uses `@cImport`, which 0.17 removed)
  * Nothing else: SDL3 is fetched as source and compiled statically into the exe

No accounts, API keys or external services are needed.

### Installation

```sh
git clone https://github.com/LovaStr/lmp3_v2
cd lmp3_v2
```

Dependencies (zigui, dr_libs, SDL3) are pinned with hashes in `build.zig.zon`, so the first `zig build` fetches them.

### Configuration

There is no `.env` file. Configuration is done with build options:

| Option | Meaning |
|---|---|
| `-Doptimize=ReleaseFast` | Recommended for the UI |
| `-Dconsole=true` | Keep a console window for logs and errors (off by default) |
| `-Dtarget=x86_64-windows-gnu` | Cross-compile from another OS (what CI does) |

### Run

```sh
zig build -Doptimize=ReleaseFast
```

`lmp3.exe` ends up in `zig-out\bin`; it needs no other files. To build and start the player in one step:

```sh
zig build run -- "C:\Users\you\Music"
```

`zig build test` runs the unit tests; they need neither SDL3 nor a window.

## Using the player

* Click a track in the play list to play it.
* **Play/pause** button: pause and resume.
* **Arrow** button: full strength = continue with the next track when one ends; dimmed = stop after the current track (the next track is cued, press play to start it).
* **Trash** button: full strength = played tracks are removed from the list; dimmed = they stay.
* The progress bar is a slider: click or drag it to jump to another time in the song.
* **Random** shuffles the play list, stops any current playback and cues the first track of the new order; press play to start it.
* **Add files…** / **Add folder…** add audio files (a folder adds the supported files in it). **Clear** empties the play list.
* **Volume** slider on the right.
* Errors (unreadable files, a missing audio device, a failed seek) show in the status bar instead of crashing the player.

Defaults at start: volume 100 %, continuous playback off, remove played tracks on.

## Architecture

Three layers with one direction of dependency: `decoder.zig` turns a file into PCM, `audio.zig` feeds that PCM to the zoto player, and `main.zig` holds the application state and the zigui views. The UI only calls `Audio` methods and reads `Audio` state; it never touches decoder or zoto internals. Every track is decoded fully into memory, folded to stereo and linearly resampled to the single output format (stereo float32 @ 44.1 kHz). Logic that does not need SDL, zigui or an audio device lives in small pure modules so it can be unit-tested. All dr_libs details stay behind a tiny C shim (`lm_decode.c`).

```
lmp3_v2/
├── src/
│   ├── main.zig         # app state, zigui views, file dialogs, frame hook
│   ├── audio.zig        # PCM -> zoto player: play, pause, seek, volume
│   ├── decoder.zig      # file -> PCM, through the C shim
│   ├── lm_decode.c      # dr_libs wrapper: lm_open / lm_read_f32 / lm_close
│   ├── transport.zig    # pure track-end decision logic
│   └── util.zig         # pure helpers (file names, path order, time split)
├── tests/               # unit tests for decoder, transport and util
├── third_party/zoto/    # vendored, patched zoto (changes in PATCHES.md)
├── .github/workflows/   # CI: build, test, and publish releases from main
├── build.zig            # build script and options
└── build.zig.zon        # dependencies pinned with hashes
```

## Tech stack

| Component | Choice | Reason |
|---|---|---|
| Language | Zig 0.16.0 | One toolchain for the app, the C shim and cross-compilation |
| UI | [ddalcu/zigui](https://github.com/ddalcu/zigui) on [SDL3](https://github.com/libsdl-org/SDL), linked statically | Declarative views and a native-looking window without a runtime or extra DLL |
| Decoding | [mackron/dr_libs](https://github.com/mackron/dr_libs) (`dr_mp3`, `dr_flac`, `dr_wav`) | Small single-header decoders for all three formats |
| Playback | [braheezy/zoto](https://github.com/braheezy/zoto), vendored and patched | Minimal audio output; vendored so it can be trimmed to the WASAPI driver |
| Build / release | `zig build` + GitHub Actions | CI cross-compiles on Linux and publishes `lmp3-windows-x64.zip` on every merge to `main` |

## Limitations

* **Windows only.** zoto is vendored with just its WASAPI driver.
* **Whole tracks are decoded into memory** before playing, synchronously on the UI thread. Large files cause a short pause on load and use memory proportional to their length.
* **One fixed output format** (stereo float32 @ 44.1 kHz). Other sample rates are linearly resampled (not high-quality resampling) and sources with more than two channels use only the first two.
* **Only MP3, FLAC and WAV.** Other files are ignored when added.
* **No previous/next buttons, tags or cover art.** The title is derived from the file name.
* **Playback is tested by hand.** The unit tests cover decoding, track-end logic and helpers; actual audio output through WASAPI is not covered by automated tests.
* A missing audio device leaves the UI usable but silent.

## Built with

Claude Code (agent-driven development) as part of the course *Next-Generation Software Development with AI*.
