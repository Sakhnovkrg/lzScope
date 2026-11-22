# lzScope — CLAP oscilloscope for Windows and macOS

![lzScope](preview.png)

A stereo oscilloscope [CLAP](https://cleveraudio.org/) plugin written entirely
in Free Pascal / Lazarus, with an OpenGL GUI inspired by the Cockos "Oscilloscope Meter" JSFX.

## Installation

1. Download the zip for your system from the
   **[latest release](https://github.com/Sakhnovkrg/lzScope/releases/latest)**
   and unpack it (Windows: right-click → Extract All; macOS: double-click).
2. Copy the plugin from it into the CLAP folder (create the folder if it is
   not there):

   | System | Zip | Plugin inside | Folder |
   |---|---|---|---|
   | Windows | `lzScope-…-windows.zip` | `lzscope.clap` | `C:\Program Files\Common Files\CLAP` |
   | macOS | `lzScope-…-macos.zip` | `lzScope.clap` | `~/Library/Audio/Plug-Ins/CLAP` |

   On macOS, `~/Library` is hidden: in Finder press **Shift+Cmd+G**, paste
   the folder path and press Return.
3. Restart your DAW or rescan plugins (in REAPER: Options → Preferences →
   Plug-ins → CLAP → Re-scan). lzScope is listed under the vendor DsgDnB.

## Features

- Stereo waveform display — left and right channels overlaid
- Time zoom from 1 ms to 5 s (mouse wheel) and vertical zoom from -60 to +36 dB
  (ctrl+wheel, cmd+wheel on macOS), with adaptive dB and time/frequency grids
- Four trigger modes: instant, any, ascending, descending (right-click or
  control-click to cycle)
- Hold mode: click to freeze the exact view on screen, drag to scrub back through
  the history, wheel-zoom around the cursor while frozen
- Crosshair readout: level under the cursor plus per-channel peak dB at that point
- Lightweight and GPU-accelerated

## System requirements

- A CLAP host: REAPER, Bitwig Studio, FL Studio and others
- **Windows**: 7 or later, 64-bit
- **macOS**: 10.13 High Sierra or later on Intel, 11 Big Sur or later on
  Apple Silicon (one universal binary)
- OpenGL

## Building

Free Pascal 3.2.2 (with Lazarus, or just `fpc`). Each script builds the
plugin and the test host, runs the tests and installs the plugin only if
they pass.

- **Windows**: `build.ps1` installs `lzscope.clap` into
  `%LOCALAPPDATA%\Programs\Common\CLAP`
- **macOS**: `brew install fpc`, then `./build.sh` installs `lzScope.clap`
  into `~/Library/Audio/Plug-Ins/CLAP`. For a universal (Apple Silicon +
  Intel) binary, run `tools/setup-x86_64.sh` once first: it builds the
  x86_64 cross compiler from the FPC sources (it finds the copy that ships
  with Lazarus, or takes their path as an argument), and from then on
  `build.sh` builds both and tests the Intel half under Rosetta. The bundle
  is signed ad hoc: it loads on the Mac that built it.
  `tools/release-macos.sh` makes the release: signs it with your Developer
  ID, notarizes and staples it, and zips it into `dist/`

`tests/testhost -i` opens the editor in a window with a test signal.

## Layout

The DSP, the CLAP glue and the editor are portable. Everything that touches
the OS is behind `src/gui/scope_gui_os.pas`, implemented once per platform:

- `src/gui/os/scope_os_win32.inc`: child window, WGL, GDI text
- `src/gui/os/scope_os_cocoa.inc`: NSView, NSOpenGLContext driven through
  CGL from the render thread, CoreText

`scope_gui_input.pas` turns mouse events from either into editor actions.
