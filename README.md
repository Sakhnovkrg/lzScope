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

- Stereo waveform display — left and right channels overlaid or split
- Sync mode: the view is locked to the host's bars, from 1/4 bar to 8 bars
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
