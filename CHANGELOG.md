# Changelog

## 1.2.0 — 2026-11-22

- Linux version (x86_64, X11 and XWayland)
- Sync mode: the grid is labelled with the song's bars, not from 1 each cycle
- Sync mode: the cycle start is labelled too
- Split view: one dB line and label where the lanes meet, not two
- "save default": new instances start with the current settings
- Header, dB scale and time labels no longer overlap the waveform
- Crosshair shows time and frequency instead of the grid
- Sync mode: no old audio on the wrong bars after a seek or in a short loop

## 1.1.0 — 2026-11-22

- macOS version
- Sync mode: the view is locked to the host bars, from 1/4 bar to 8 bars
- Split view: left and right channels in separate lanes
- Red 0 dB lines when the range goes above 0 dB
- Correct size and look at any UI scale

## 1.0.1 — 2026-11-22

- Status line is interactive: drag len/range, click trig, double-click to reset
- Hold is released when playback starts
- No envelope shimmer on long views
- Antialiased text
- No CPU/GPU use while idle, held or minimized
- Faster drawing of long views
- Fixed: torn waveform frames (audio/GUI race on the ring buffer)
- Fixed: possible use-after-free on editor close
- Fixed: possible host crash on NaN values
- Fixed: state could fail to load in some hosts

## 1.0.0 — 2026-08-01

- Initial release
