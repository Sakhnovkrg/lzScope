# lzScope — CLAP oscilloscope for Windows

![lzScope](preview.png)

A stereo oscilloscope [CLAP](https://cleveraudio.org/) plugin written entirely
in Free Pascal / Lazarus, with an OpenGL GUI inspired by the Cockos "Oscilloscope Meter" JSFX.

## Features

- Stereo waveform display — left and right channels overlaid
- Time zoom from 1 ms to 5 s (mouse wheel) and vertical zoom from -60 to +36 dB
  (ctrl+wheel), with adaptive dB and time/frequency grids
- Four trigger modes: instant, any, ascending, descending (right-click to cycle)
- Hold mode: click to freeze the exact view on screen, drag to scrub back through
  the history, wheel-zoom around the cursor while frozen
- Crosshair readout: level under the cursor plus per-channel peak dB at that point
- Lightweight and GPU-accelerated
