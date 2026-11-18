# =====================================================================================
#  DoW2_MainMenuUltrawide.asi  —  ultrawide fix for the DoW2: Retribution front end
# =====================================================================================
#
#  Target   : DOW2.exe, Steam build, PE TimeDateStamp 0x57080767 (2016-04-08),
#             SizeOfImage 0x01375000, SHA-256 4ce6423d...a50e. Image base 0x00400000 (no ASLR).
#  Loader   : Ultimate ASI Loader (ThirteenAG), e.g. as msacm32.dll next to DOW2.exe.
#  Effect   : On screens wider than 16:9, two front-end Scaleform hosts get a full-width
#             viewport and "showAll" scaling instead of a centered 16:9 viewport:
#               - FormManager  (front_end_fullscreen_display: main menu, lobby, browser, stats ...)
#               - ArmyPainter  (army_painter)
#             Nothing else is touched: no gameplay/HUD code, no files on disk.
#
#  Background
#  ----------
#  Every Scaleform screen derives from a common panel class. When it is shown or the window
#  is resized, the shared routine at 0x682070 calls the panel's virtual "compute viewport"
#  method (vtable slot 6, offset 0x18):
#
#      void __thiscall ComputeViewport(int screenW, int screenH, float uiScale,
#                                      int* x, int* y, int* w, int* h);   // callee pops 0x1C
#
#  On entry *w,*h hold the movie's authored stage size (2134 x 1200 for these hosts). The
#  originals (0x4A36FC for FormManager, 0x495B56 for ArmyPainter) scale that to screen
#  height and centre it, i.e. a 16:9 viewport with x = (screenW - w) / 2. Scaleform clips
#  to the viewport, so on 21:9 everything outside the middle 16:9 strip is cut off — the
#  black bars.
#
#  The menus are already built for wider screens: MainMenuForm and ArmyPainter send
#  Receive_SetXOffset(x / scale) to their movies, which pushes the side panels (menu
#  buttons, gamertag, logo, army/unit list) out to the real screen edges — where they were
#  clipped.
#
#  The fix
#  -------
#  Wrap the two ComputeViewport methods: call the original (so every side effect, including
#  Receive_SetXOffset, still happens), then, only if x > 0 (screen wider than the movie):
#      x = 0, w = screenW                 -> viewport covers the whole screen
#      movie->ViewScaleMode = showAll     -> stage still fits screen height, centred, unstretched
#  With showAll the stage maps to exactly the same pixels as before; the difference is only
#  that content outside the 16:9 stage is no longer clipped. (front_end_fullscreen_display
#  sets Stage.scaleMode = "exactFit" in its first frame; we override it here, after load.)
#
#  Safety
#  ------
#  The patch is applied only if the host exe matches the expected build AND each vtable slot
#  still holds the expected original pointer. Otherwise the plugin does nothing.
#  16:9 / 16:10 / 4:3 screens: x <= 0, so the original result is returned unchanged.
#
#  Build (GNU binutils, any platform):
#      as --32 -o sec.o DoW2_MainMenuUltrawide.s
#      objcopy -O binary -j .text sec.o sec.bin
#      nm sec.o > syms.txt
#      python3 build_dll.py sec.bin DoW2_MainMenuUltrawide.asi syms.txt
#  The whole DLL is one RWX section; all code is position-independent (no relocations needed).
# =====================================================================================

.intel_syntax noprefix
.section .text

# ---- Addresses inside DOW2.exe (this exact build) ----
.set EXE_BASE,             0x00400000
.set EXE_LFANEW,           0x120          # PE header offset
.set EXE_TIMESTAMP,        0x57080767     # IMAGE_FILE_HEADER.TimeDateStamp   (at base + 0x128)
.set EXE_SIZEOFIMAGE,      0x01375000     # IMAGE_OPTIONAL_HEADER.SizeOfImage (at base + 0x170)

.set FORMMANAGER_SLOT,     0x01090FFC     # &FormManager::vftable[6]
.set FORMMANAGER_ORIG,     0x004A36FC     #  FormManager::ComputeViewport
.set ARMYPAINTER_SLOT,     0x01097610     # &ArmyPainter::vftable[6]
.set ARMYPAINTER_ORIG,     0x00495B56     #  ArmyPainter::ComputeViewport

.set GFXMOVIEROOT_VFTABLE, 0x0104BBFC     # GFxMovieRoot::vftable (Scaleform 2.x)
.set GFX_VIEWSCALEMODE,    0x80           # GFxMovieRoot::ViewScaleMode field offset
.set GFX_SM_SHOWALL,       1              # 0 noScale, 1 showAll, 2 exactFit, 3 noBorder
.set PANEL_MOVIE,          0x4            # panel->movie (GFxMovieView*)

.set PAGE_READWRITE,       0x04

.globl base
base:

# =====================================================================================
#  BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID)
# =====================================================================================
dllmain:
  cmp dword ptr [esp+8], 1                  # DLL_PROCESS_ATTACH?
  jne dm_ret
  push ebx
  push esi
  push edi
  call 1f                                   # ebx = runtime address of label 1 (PIC base)
1:
  pop ebx

  # --- Is the host process exactly the expected DOW2.exe build? ---
  push 0
  call dword ptr [ebx + (iat_GetModuleHandleA - 1b)]
  cmp eax, EXE_BASE
  jne dm_done
  cmp dword ptr [eax+0x3c], EXE_LFANEW
  jne dm_done
  cmp dword ptr [eax+EXE_LFANEW+0x08], EXE_TIMESTAMP
  jne dm_done
  cmp dword ptr [eax+EXE_LFANEW+0x50], EXE_SIZEOFIMAGE
  jne dm_done

  # --- Redirect the two vtable slots (each only if it still holds the original) ---
  mov edi, FORMMANAGER_SLOT
  mov edx, FORMMANAGER_ORIG
  lea eax, [ebx + (hook_formmanager - 1b)]
  call patch_slot
  mov edi, ARMYPAINTER_SLOT
  mov edx, ARMYPAINTER_ORIG
  lea eax, [ebx + (hook_armypainter - 1b)]
  call patch_slot
dm_done:
  pop edi
  pop esi
  pop ebx
dm_ret:
  mov eax, 1                                # always succeed; a no-op is fine
  ret 12

# =====================================================================================
#  patch_slot — in: edi = slot address, edx = expected original, eax = new target,
#                   ebx = PIC base.  Clobbers eax, ecx, edx, esi.
# =====================================================================================
patch_slot:
  cmp dword ptr [edi], edx
  jne ps_ret
  push eax                                  # keep new target across the API call
  lea esi, [ebx + (old_protect - 1b)]
  push esi                                  # lpflOldProtect
  push PAGE_READWRITE
  push 4                                    # dwSize
  push edi                                  # lpAddress
  call dword ptr [ebx + (iat_VirtualProtect - 1b)]
  pop edx
  test eax, eax
  jz ps_ret
  mov dword ptr [edi], edx                  # vftable[6] = hook
  lea eax, [ebx + (scratch - 1b)]
  push eax
  push dword ptr [esi]                      # restore the original protection
  push 4
  push edi
  call dword ptr [ebx + (iat_VirtualProtect - 1b)]
ps_ret:
  ret

# =====================================================================================
#  ComputeViewport hooks
#  void __thiscall hook(int W, int H, float scale, int* x, int* y, int* w, int* h)  ret 0x1C
# =====================================================================================
hook_formmanager:
  mov eax, FORMMANAGER_ORIG
  jmp hook_common
hook_armypainter:
  mov eax, ARMYPAINTER_ORIG
hook_common:
  push esi
  push edi
  mov esi, ecx                              # esi = this (panel)
  mov edi, eax                              # edi = original ComputeViewport
  # stack now: [esp+0x0C] W, +0x10 H, +0x14 scale, +0x18 x*, +0x1C y*, +0x20 w*, +0x24 h*
  push dword ptr [esp+0x24]                 # re-push the 7 arguments (h* ... W)
  push dword ptr [esp+0x24]
  push dword ptr [esp+0x24]
  push dword ptr [esp+0x24]
  push dword ptr [esp+0x24]
  push dword ptr [esp+0x24]
  push dword ptr [esp+0x24]
  mov ecx, esi
  call edi                                  # original: centred 16:9 rect (+ Receive_SetXOffset)

  mov eax, dword ptr [esp+0x18]             # eax = x*
  cmp dword ptr [eax], 0                    # x > 0 only when the screen is wider than the movie
  jle h_done
  mov ecx, dword ptr [esi+PANEL_MOVIE]      # ecx = this->movie
  test ecx, ecx
  jz h_done
  cmp dword ptr [ecx], GFXMOVIEROOT_VFTABLE # sanity: really a GFxMovieRoot?
  jne h_done
  mov dword ptr [ecx+GFX_VIEWSCALEMODE], GFX_SM_SHOWALL   # fit height, centre, no stretch
  mov dword ptr [eax], 0                    # *x = 0
  mov eax, dword ptr [esp+0x20]             # eax = w*
  mov edx, dword ptr [esp+0x0C]             # edx = W
  mov dword ptr [eax], edx                  # *w = W   (viewport now spans the whole screen)
h_done:
  pop edi
  pop esi
  ret 0x1c

# =====================================================================================
#  Data
# =====================================================================================
.balign 4
old_protect: .long 0
scratch:     .long 0

# =====================================================================================
#  Import table: KERNEL32.dll!GetModuleHandleA, VirtualProtect
#  (RVA = 0x1000 + offset from base; the section is mapped at RVA 0x1000)
# =====================================================================================
.balign 16
import_dir:
  .long 0x1000 + (ilt - base)               # OriginalFirstThunk
  .long 0, 0                                # TimeDateStamp, ForwarderChain
  .long 0x1000 + (dllname - base)           # Name
  .long 0x1000 + (iat - base)               # FirstThunk
  .long 0, 0, 0, 0, 0                       # terminator
ilt:
  .long 0x1000 + (hn_GetModuleHandleA - base)
  .long 0x1000 + (hn_VirtualProtect - base)
  .long 0
iat:
iat_GetModuleHandleA: .long 0x1000 + (hn_GetModuleHandleA - base)
iat_VirtualProtect:   .long 0x1000 + (hn_VirtualProtect - base)
  .long 0
hn_GetModuleHandleA: .short 0
  .asciz "GetModuleHandleA"
.balign 2
hn_VirtualProtect: .short 0
  .asciz "VirtualProtect"
dllname: .asciz "KERNEL32.dll"

# Minimal, empty base-relocation block (code is position-independent; allows rebasing).
.balign 4
reloc_block:
  .long 0x1000                              # PageRVA
  .long 8                                   # SizeOfBlock (header only, no entries)
end_of_section:
