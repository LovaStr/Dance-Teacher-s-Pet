// Stands in for SDL's src/video/windows/SDL_windowsgameinput.cpp in the static
// build, so no C++ runtime is needed. GameInput only feeds extra mouse/keyboard
// events to games; with these no-ops SDL keeps using the regular Win32 input path.
#include "SDL_internal.h"
#include "video/windows/SDL_windowsvideo.h"
#include "video/windows/SDL_windowsgameinput.h"

bool WIN_InitGameInput(SDL_VideoDevice *_this)
{
    (void)_this;
    return false;
}

bool WIN_UpdateGameInputEnabled(SDL_VideoDevice *_this)
{
    (void)_this;
    return false;
}

void WIN_UpdateGameInput(SDL_VideoDevice *_this)
{
    (void)_this;
}

void WIN_QuitGameInput(SDL_VideoDevice *_this)
{
    (void)_this;
}
