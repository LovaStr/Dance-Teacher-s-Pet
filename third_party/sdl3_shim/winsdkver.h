// Shadows MinGW's winsdkver.h for the SDL3 build only. zig's bundled MinGW
// headers lack windows.gaming.input.h, so report a Windows 8.1 SDK (0x0603):
// SDL then skips its Windows 10-only backends (Windows.Gaming.Input, DXGI 1.5/1.6).
#ifndef LMP3_WINSDKVER_H
#define LMP3_WINSDKVER_H
#include <winapifamily.h>
#define _WIN32_MAXVER 0x0603
#endif
