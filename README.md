# Checkpoint Pace

Checkpoint Pace is an Openplanet plugin for Trackmania 2020.

It focuses on:

- clear in-run checkpoint comparison UI
- robust timing from engine + UI blending
- saved per-map best splits and PB run tracking
- optional WR split comparison when MLFeed data is available

## Dependency

- Optional: `MLFeedRaceData` (for automatic WR split data)

The plugin still works without the dependency; WR auto-sync is just disabled.

## Install

1. Install from Openplanet Plugin Manager, or copy this folder into your Openplanet `Plugins` directory.
2. Restart Trackmania or reload plugins in Openplanet.
3. Enable `Checkpoint Pace`.

## Notes

- Supports UI time formats `mm:ss.d`, `mm:ss.dd`, and `mm:ss.ddd`.
- Falls back to engine race time when UI timing is missing or suspicious.
- Multi-lap maps are handled as `checkpoints_per_lap * laps`.
