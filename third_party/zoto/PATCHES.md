# Local patches to braheezy/zoto

Vendored from https://github.com/braheezy/zoto (see LICENSE) so the Windows build works on Zig 0.16 (it also builds unchanged on 0.17):

* `src/driver_windows.zig`: `std.Thread.Mutex`/`Condition` no longer exist -> small wrappers over
  `std.Io.Mutex`/`Condition` (same as mux.zig); `HRESULT` and `BOOL` defined locally
  (`std.os.windows` removed/changed them).
* `build.zig`: removed the Linux ALSA `translate_c` and `zig_objc` dependency wiring, so only the
  Windows driver is supported by this copy. `build.zig.zon`: no dependencies, min Zig 0.16.0.
* `src/driver_windows.zig`: the WASAPI buffer was requested as `10000000` (100 ns units = **1 second**); it is
  now 100 ms. Added `Context.flush()` (Stop/Reset/Start under a new `io_mutex`, which the audio thread now
  holds while filling) to discard queued audio, and the fill loop was moved into `pump()` (it also releases
  the render buffer on error paths).
