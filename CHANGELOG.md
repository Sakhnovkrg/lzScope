# Changelog

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
