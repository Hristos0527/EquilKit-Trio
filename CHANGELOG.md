# Changelog

All notable changes to EquilKit-Trio are documented here.

## [1.0.0] - 2026-07-04

Initial public community release (Trio Build #55 state).

### Added

- Full Equil patch `PumpManager` plugin for Trio (BLE connect-per-command)
- Onboarding UI: pairing, base settings, patch priming and activation
- Bolus, temp basal, scheduled basal, suspend/resume
- Reservoir and patch battery state sync
- Debug log buffer export for support

### Fixed / improved

- **Background keepalive** (Build #53): lightweight BLE ping (`CmdRunningModeGet`) every 60–90 s while the app is backgrounded, reducing Equil “no connection” alarms
- Patch battery percent passed through correctly (0–100 from `CmdHistoryGet`, not voltage-derived)
- Priming flow latch to avoid heartbeat overwriting in-progress priming

### Notes

- Behavioral reference: [AndroidAPS Equil driver](https://github.com/nightscout/AndroidAPS)
- Author self-tested ~2 weeks daily use before release (n=1)
