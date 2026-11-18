# Technical notes – DoW2 Retribution ultrawide front-end fix (`DoW2_MainMenuUltrawide.asi`)

User-facing install instructions are in [README.md](README.md). This file is for developers and
reviewers: root cause, exact changes, addresses, safety guards and how to rebuild.

A 1.5 KB ASI plugin that removes the 16:9 clipping from the main menu and the Army Painter on
screens wider than 16:9 (e.g. 3440×1440). It patches two function pointers in memory at
startup. **`DOW2.exe` on disk is not modified** (Steam restores modified exes on launch anyway).

## Symptoms it fixes

| Screen | Before (21:9) | After |
|---|---|---|
| Main menu (and other screens hosted by the same front-end movie: public lobby, match browser, post-match stats …) | Centered 16:9 strip with black side bars. Campaign/Multiplayer buttons, gamertag and the logo are cut off at the bar edges but still clickable behind the bars. | Full width. The 3D backdrop fills the screen, and buttons, gamertag and logo sit at the real screen edges. |
| Army Painter | Centered 16:9 strip. The army/unit selection panel is pushed left into the black bar. | Panel sits at the left screen edge, fully visible. |

The fix does nothing on 16:9, 16:10 or 4:3 screens, in matches, on the HUD, or in other menus. It
was tested in a custom match vs CPU, the main menu, the public lobby, the match browser, the
post-match stats and the Army Painter on 3440×1440.

## Root cause

* Each Scaleform screen has a virtual `ComputeViewport(W, H, uiScale, &x, &y, &w, &h)` (vtable
  slot 6, called from `0x682070` on show/resize). For the front-end host (`FormManager`,
  movie `front_end_fullscreen_display.gfx`) and `ArmyPainter`, the original fits the 2134×1200
  stage to screen height and **centers a 16:9 viewport** (`x = (W - w)/2`). Scaleform clips
  to the viewport, which produces the bars.
* The menus are already built for wider screens. `MainMenuForm` and `ArmyPainter` call
  `Receive_SetXOffset(x / scale)` on their movies, which moves the side panels out to the
  real screen edges. Those edges lie **outside** the 16:9 viewport, so they get clipped.

## What the plugin changes

It wraps both `ComputeViewport` methods. It calls the original first, so `Receive_SetXOffset`
etc. still run. Then, **only if `x > 0`**:

```
x = 0;  w = screenWidth;                 // viewport covers the whole screen
movie->ViewScaleMode = showAll;          // stage still fits height, centered, not stretched
```

With `showAll` the stage maps to exactly the same pixels as before. The only difference is that
content outside the 16:9 stage is no longer clipped. (`front_end_fullscreen_display.gfx` sets
`Stage.scaleMode = "exactFit"` in its first frame. The override is applied at layout time,
after the movie has loaded, so it wins.)

| Item | Address (this exe build) |
|---|---|
| `FormManager::vftable[6]` → original | `0x01090FFC` → `0x004A36FC` |
| `ArmyPainter::vftable[6]` → original | `0x01097610` → `0x00495B56` |
| `GFxMovieRoot::vftable` / `ViewScaleMode` field | `0x0104BBFC` / `+0x80` |
| panel → movie pointer | `panel + 0x4` |

## Safety guards

The plugin patches only if all of these hold. Otherwise it is a silent no-op:

* The host is `DOW2.exe` at `0x400000` with PE `TimeDateStamp 0x57080767` and
  `SizeOfImage 0x01375000`. That is the current Steam build: SHA-256
  `4ce6423d3d97528a784ede2a16bb9b671aac221fdde1fddee5bd060cfd38a50e`.
* Each vtable slot still holds the expected original pointer (so it can't clash with another
  plugin that already hooked it).
* At runtime it only acts when the screen is wider than the movie, and only if the movie
  object really is a `GFxMovieRoot`.

## Compatibility

The plugin doesn't read or modify any game data or UI files, and is keyed only to the
`DOW2.exe` build. It works for retail (unmodded) Retribution and should keep working as long
as `DOW2.exe` stays the same. A different exe build makes it a silent no-op until the
addresses are updated.

Mods are compatible as long as they don't change the front-end screens in a way that
interferes with the fix, for example by replacing the host movie
`front_end_fullscreen_display.gfx` with a different stage size or layout, or by hooking the same
two vtable slots. Mods whose menus place content outside the 16:9 stage will now have that
content visible at the screen sides.

## Install

1. Get Ultimate ASI Loader (ThirteenAG, MIT license) as `msacm32.dll` (Win32 build):
   https://github.com/ThirteenAG/Ultimate-ASI-Loader/releases (`Win32-latest/msacm32.zip`).
   This is the same setup the community "DoW2 high resolution UI scaling patch" uses.
2. Put `msacm32.dll` and `DoW2_MainMenuUltrawide.asi` next to `DOW2.exe`.
3. To uninstall, delete the `.asi`.

If bundling the loader with a mod or another package: MIT allows redistribution as long as its copyright and
license notice are included (ship the loader's `LICENSE` file alongside).

## Files

* `README.md`: user-facing description and install steps.
* `TECHNICAL.md`: this file.
* `LICENSE`: MIT license for this project.
* `bin/DoW2_MainMenuUltrawide.asi`: the plugin (SHA-256
  `1454be3d4f2fcff20cb1054516b18ecbcbb43572737018747cbc7b163459685c`).
* `src/DoW2_MainMenuUltrawide.s`: full commented source (GNU as, Intel syntax).
* `src/build_dll.py`: wraps the assembled code into a minimal PE DLL.
* `src/build.sh`: reproduces the binary byte-for-byte:
  `as --32` → `objcopy -O binary` → `nm` → `build_dll.py`.

## Equivalent C++ (reference only – not compiled or tested)

For readers who prefer C++ or want to fold this into an existing MSVC plugin. The shipped
binary is the assembly version above.

```cpp
#include <windows.h>
#include <cstdint>

namespace {
constexpr uintptr_t kFormManagerSlot = 0x01090FFC, kFormManagerOrig = 0x004A36FC;
constexpr uintptr_t kArmyPainterSlot = 0x01097610, kArmyPainterOrig = 0x00495B56;
constexpr uintptr_t kGFxMovieRootVftable = 0x0104BBFC;

using ComputeViewportFn = void(__thiscall*)(void* self, int W, int H, float scale,
                                            int* x, int* y, int* w, int* h);

void Widen(void* self, int W, int* x, int* w) {
    if (*x <= 0) return;                                       // not wider than the movie
    auto* movie = *reinterpret_cast<uint8_t**>(static_cast<uint8_t*>(self) + 0x4);
    if (!movie || *reinterpret_cast<uintptr_t*>(movie) != kGFxMovieRootVftable) return;
    *reinterpret_cast<int*>(movie + 0x80) = 1;                 // ViewScaleMode = showAll
    *x = 0;
    *w = W;
}

// __fastcall + dummy EDX mimics __thiscall (this in ECX, callee pops the stack args).
void __fastcall HookFormManager(void* self, void*, int W, int H, float s, int* x, int* y, int* w, int* h) {
    reinterpret_cast<ComputeViewportFn>(kFormManagerOrig)(self, W, H, s, x, y, w, h);
    Widen(self, W, x, w);
}
void __fastcall HookArmyPainter(void* self, void*, int W, int H, float s, int* x, int* y, int* w, int* h) {
    reinterpret_cast<ComputeViewportFn>(kArmyPainterOrig)(self, W, H, s, x, y, w, h);
    Widen(self, W, x, w);
}

void PatchSlot(uintptr_t slot, uintptr_t expected, void* hook) {
    auto* p = reinterpret_cast<uintptr_t*>(slot);
    if (*p != expected) return;
    DWORD old;
    if (!VirtualProtect(p, sizeof(*p), PAGE_READWRITE, &old)) return;
    *p = reinterpret_cast<uintptr_t>(hook);
    VirtualProtect(p, sizeof(*p), old, &old);
}

bool IsExpectedExe() {
    auto* base = reinterpret_cast<uint8_t*>(GetModuleHandleA(nullptr));
    if (base != reinterpret_cast<uint8_t*>(0x400000)) return false;
    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS32*>(base + reinterpret_cast<IMAGE_DOS_HEADER*>(base)->e_lfanew);
    return nt->FileHeader.TimeDateStamp == 0x57080767 && nt->OptionalHeader.SizeOfImage == 0x01375000;
}
} // namespace

BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH && IsExpectedExe()) {
        PatchSlot(kFormManagerSlot, kFormManagerOrig, reinterpret_cast<void*>(&HookFormManager));
        PatchSlot(kArmyPainterSlot, kArmyPainterOrig, reinterpret_cast<void*>(&HookArmyPainter));
    }
    return TRUE;
}
```

Note: the assembly version also checks `e_lfanew == 0x120` before reading the PE header.
