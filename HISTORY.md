# EquilKit-Trio — Fork timeline

Full development timeline for the Equil patch pump plugin ported from LoopWorkspace to Nightscout Trio.

Author: **Hristos** ([@Hristos0527](https://github.com/Hristos0527))

---

## Context

| | |
|---|---|
| **Origin** | LoopWorkspace Equil handoff (`loop-equil-fork-handoff-*.md`) |
| **Target** | [nightscout/Trio](https://github.com/nightscout/Trio) iOS OS-AID |
| **Protocol** | AndroidAPS Equil BLE opcodes — **unchanged** in port |
| **Integration repo** | [Trio-Equil-Linx-Build](https://github.com/Hristos0527/Trio-Equil-Linx-Build) |
| **Sibling plugin** | [LinxCGMKit-Trio](https://github.com/Hristos0527/LinxCGMKit-Trio) (same fork, independent kit) |

LoopWorkspace handoff work (Jun 15–21) preceded but is **not** part of Trio build numbering — it informed the port source.

---

## Timeline

### Jun 15, 2026 — Fork baseline (Trio Build #0)

- Cloned `nightscout/Trio` @ **v0.8.2** (`86e4f4c`)
- No Equil, no LinxCGMKit

### Jun 22, 2026 — Partial integration (Build #1)

- First EquilKit files from Loop handoff: `EquilPumpManager`, `EquilCommandQueue` beginnings
- Simulator build succeeded; LinxCGMKit directory scaffolded same night

### Jun 23, 2026 — Full port (Builds #2–5)

- Upstream fast-forward to **v0.8.3** with handoff fixes preserved
- Complete **EquilCommandQueue** architecture integrated
- First successful iPhone install with Equil pairing UI

### Jun 24, 2026 — Device hardening (Builds #6–14)

- Post-priming crash fixes, Equil branding, battery % display
- Dashboard alarm modes, reservoir HUD, connection/reconnect fixes
- Co-developed with Linx 3 min loop experiments (Trio-level config)

### Jun 24–25, 2026 — Stability pass (Builds #15–19)

- Low-battery notifications, suspend/resume crash fix
- Patch dashboard notification modes

### Jun 25–26, 2026 — Priming & power (Builds #20–25)

- RUN-mode gate, unpair sequence, temporary mute during suspend
- Ack-driven priming steps, serial command queue race fixes
- Battery sync optimization (5 min gate, reduced routine commands)
- Connect-per-command direction established (held-open reverted)

### Jun 27, 2026 — Priming milestone (Build #26)

- Connect-per-command priming stable (~72 steps, ~6 s/step)
- Silent alarm restore after temp-0
- Key rollback anchor for later Build #51 restore

### Jun 28, 2026 — BLE reliability (Build #28)

- 25 s connect timeout, retries, persisted pump UUID
- Oldest surviving full Trio `.app` backup

### Jun 30, 2026 — Loop integration (Builds #30–32)

- `prepareForLoopCycle`, pump sync wait before loop cycle
- Memory trim in app delegate paths

### Jun 30, 2026 — Intentional restore (Build #51)

- EquilKit reset to Build #26 checkpoint after Garmin/hypo timer instability
- Paired with Linx 3 min loop restore (see LinxCGMKit-Trio HISTORY)

### Jul 3, 2026 — Background keepalive (Build #53)

- Jittered 60–90 s `CmdRunningModeGet` ping in background
- `beginBackgroundTask` per ping; skip during priming/bolus/suspend
- Independent of loop/CGM timing — fixes overnight “no connection” alarms

### Jul 3, 2026 — Public release (Build #55 state)

- Upstream Trio **v0.8.4** merged; EquilKit diff vs pre-merge: **0**
- Published as **EquilKit-Trio 1.0.0**

---

## Architecture notes

- **Connect-per-command**: each BLE operation opens connection, sends one opcode, closes — avoids held-open GATT stalls during priming
- **EquilCommandQueue**: serial ack-driven queue with preempt for urgent commands (bolus, suspend)
- **Background keepalive**: read-only `CmdRunningModeGet` — no dosing side effects
- **Battery**: percent from `CmdHistoryGet` (0–100), not derived from patch voltage

---

## Related documents

- Trio build log (Hungarian source): `loop/patches/trio-build-changelog.hu.md`
- Git workflow: `loop/patches/trio-git-versioning.hu.md`
- Detailed per-build entries: [CHANGELOG.md](./CHANGELOG.md)
