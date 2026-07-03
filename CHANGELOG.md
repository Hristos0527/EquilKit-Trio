# Changelog

All notable changes to EquilKit-Trio. Fork development **Jun 2026 – Jul 2026**.

Author: **Hristos** ([@Hristos0527](https://github.com/Hristos0527))

---

## [1.0.0] - 2026-07-03 — Public release

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
- Opcode/BLE payloads unchanged from AndroidAPS protocol (handoff port)

---

## Development history (pre-release)

Reconstructed from Trio working-tree builds, backup `.app` snapshots, and `git stash create` checkpoints. Not every Trio build touched EquilKit — entries below are Equil-specific only.

### 2026-06-22 — Partial handoff integration (Build #1)

- **EquilPumpManager**: temp-0, `basalDeliveryState`, `ensureCurrentPumpData`, `reportPumpDataReconciled`
- Auto-resume, temp cancel→set chain, bolus progress ring
- **EquilCommandQueue**: preempt logic, `zeroValueAck` beginnings
- Simulator **BUILD SUCCEEDED**; no physical device install yet

### 2026-06-23 — Upstream sync, handoff fixes preserved (Build #2)

- Trio fast-forwarded to upstream **v0.8.3** (`7b8db13`)
- EquilKit handoff fixes restored from `backup/pre-full-port-20260623`
- Pre-full-port safety checkpoint before complete integration

### 2026-06-23 — Full Equil handoff port (Build #3)

- Complete handoff → **EquilCommandQueue** architecture (see `loop-equil-fork-handoff-integration.md`)
- All handoff table items integrated; simulator + `Debug-iphoneos` **BUILD SUCCEEDED**
- First successful iPhone install with Equil scanner/pairing UI (Build #5)

### 2026-06-24 — Intensive device testing (Builds #6–14)

- **Crash fixes** after priming: `notifyStateDidChange` → `state.clone()`, safe `Data(hex:)`
- **UI**: Medtrum pump image replaced with Equil icon (`equil_ic_pump.png`)
- **Battery**: display 33.0 V → **percent** (CmdHistoryGet pattern)
- **Dashboard**: sound/vibration/silent alarm modes (`CmdAlarmSet`), Patch Maintenance
- `connectionInRange`, Reconnect → sync, bolus-not-starting fix
- Reservoir HUD 200 U, battery row in UI

### 2026-06-24 – 2026-06-25 — Equil maturity (Builds #15–19)

- Battery notifications at 20 / 10 / 5 %
- Suspend/Resume crash fix
- Loop patch dashboard + notification mode (Sound / Vibration / Silent)

### 2026-06-25 — Priming, run-gate, mute, HUD battery (Build #20)

- Priming speed-up (held-open connection — later reverted)
- **RUN-mode gate** until priming complete
- Unpair sequence: retract → stop → unpair
- Temporary mute during suspend/zero-temp, restore on resume
- HUD battery 100 % bug: removed voltage-derived `saveEquilPatchBattery` formula

### 2026-06-25 – 2026-06-26 — Priming stability & battery optimization (Builds #21–25)

- Priming ack-driven steps (crash fix)
- Zero-temp/mute race fix — serial ack-driven command queue
- Silent-restore fix (do not switch Sound after Silent)
- Coarse-to-fine priming removed → flat 320-step priming
- Battery optimization: 5 min sync gate, `CmdTimeSet` removed from routine sync, RUN-wake gate, reconcileHistory disabled after temp
- GATT revert, nav-guard, pump swap, fail-fast, Stop button

### 2026-06-27 — Priming held-open fix (Build #26)

- **Connect-per-command** replaces held-open BLE connection during priming
- Silent restore after temp-0 — alarm stays silent
- Priming UI navigation to completed state
- Delete/retract queue fix (may not be in this binary — transcript note)
- Installed; ~72 priming steps, ~6 s/step average

### 2026-06-28 — BLE / loop reliability (Build #28)

- Connect timeout **25 s**, retry logic, pump UUID persistence
- Overnight loop reliability improvements
- Oldest surviving full Trio backup from this build

### 2026-06-30 — Fix build sessions (Builds #30–31)

- Incremental Equil fixes between Jun 28 and the feature build below
- Exact per-build diffs not reconstructable (backup name only)

### 2026-06-30 — Loop integration & memory (Build #32)

- `prepareForLoopCycle` hook for loop cycle prep
- Memory trim in `AppDelegate`, `NightscoutManager`
- **APSManager**: pump sync wait before loop cycle

### 2026-06-30 — Build #26 state restored (Build #51)

- EquilKit working tree reset to Build #26 checkpoint (`d50bed1f`)
- Priming connect-per-command, silent restore after temp-0, priming UI navigation, delete/retract queue
- Garmin/hypo changes reverted to pre-hypo-timer state (Equil unaffected)

### 2026-07-03 — Background keepalive (Build #53)

- **Background keepalive timer**: jittered 60–90 s `CmdRunningModeGet` ping when app is backgrounded
- `beginBackgroundTask` around each ping for iOS background execution window
- Skip conditions: foreground, unpaired, priming incomplete, intentional suspend, active bolus/priming fill
- Uses existing `pingPumpReachability` — connect-per-command, no dosing opcode changes
- Fixes Jul 3 00:33 “no connection” pump alarm independent of loop/CGM cycle

### Builds with no Equil changes

Builds **#27**, **#29**, **#52**, **#54**, **#55** did not modify EquilKit (verified by diff or changelog attribution).
