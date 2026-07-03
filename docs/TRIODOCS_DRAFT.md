# Draft: TrioDocs documentation page

> **Not submitted.** Proposed outline for [triodocs.org](https://triodocs.org) or Trio wiki. Submit via TrioDocs PR when maintainers agree on placement.

---

## Suggested page title

**Community devices: Equil pump & Linx CGM**

## Suggested URL slug

`/community/equil-linx` or `/devices/community-equil-linx`

## Audience

Experienced Trio builders who sideload the iOS app and want optional hardware beyond officially documented devices.

## Page outline

### 1. Overview

- Two **community plugins** (not core Trio):
  - **EquilKit** — Equil patch pump over BLE
  - **LinxCGMKit** — Linx CGM via passive BLE advertisements
- Maintained by **Hristos (@Hristos0527)**; AGPL-3.0
- Requires self-build with Xcode; not App Store software

### 2. Disclaimer (prominent callout)

- Not a medical device; not regulatory approved
- Community sideload at your own risk
- Cross-check CGM readings; keep backup therapy
- Link to full disclaimer in each repo README

### 3. Supported hardware

| Device | Plugin | Connection |
|--------|--------|------------|
| Equil patch (5.3 / 5.4 tested) | EquilKit | BLE connect-per-command |
| Linx CGM sensor | LinxCGMKit | Passive BLE scan (service 181F) |

### 4. Getting the code

**Option A — One-command build (beginners)**

- Repo: https://github.com/Hristos0527/Trio-Equil-Linx-Build
- `./scripts/build.sh` (when published)

**Option B — Integrate into your Trio fork**

- EquilKit: https://github.com/Hristos0527/EquilKit-Trio
- LinxCGMKit: https://github.com/Hristos0527/LinxCGMKit-Trio
- Follow `INTEGRATION.md` in each repo

### 5. Build requirements

- macOS, Xcode 15+
- iOS 17+ (match your Trio fork)
- LoopKit from Trio workspace (not vendored in kit repos)

### 6. EquilKit highlights

- Pairing, priming, activation UI (SwiftUI)
- Bolus, temp basal, scheduled basal
- Background keepalive ping (reduces “no connection” alarms)
- Behaviour reference: AndroidAPS Equil driver (reimplemented for LoopKit)

### 7. LinxCGMKit highlights

- Passive scan + serial filter + nearby picker
- Two-point calibration in-plugin
- 3-minute loop gate for Trio heartbeat
- Background scan watchdog (~4 min stale restart)

### 8. Known limitations

- iOS background BLE throttling (mitigations exist; not perfect)
- n=1 community testing — verify on your setup
- No official Equil / Linx / Trio support unless stated

### 9. Troubleshooting

- **Equil disconnect alarms in background** → check keepalive build (#53+); export `EquilLogBuffer`
- **Linx stale readings when backgrounded** → scan watchdog (#52+); confirm Bluetooth permission
- **Build errors** → ensure LoopKit built first; see kit repo CI workflow

### 10. Feedback & upstream path

- GitHub Issues on kit repos (bug report template)
- Trio GitHub Discussion / Discord `#pumps` / `#cgms` (community announcement)
- Upstream submodule PR possible — see `docs/UPSTREAM_PR_DRAFT.md` in EquilKit-Trio

### 11. Related links

- [EquilKit-Trio releases](https://github.com/Hristos0527/EquilKit-Trio/releases)
- [LinxCGMKit-Trio releases](https://github.com/Hristos0527/LinxCGMKit-Trio/releases)
- [Nightscout Trio repo](https://github.com/nightscout/Trio)
- [Trio Discord](https://triodocs.org) (join link from site)

---

## TrioDocs PR checklist (when submitting)

- [ ] Confirm page location with TrioDocs maintainers
- [ ] Add nav entry under Devices or Community section
- [ ] Include disclaimer callout component if available
- [ ] Link to repos and INTEGRATION.md — not duplicate full integration steps
- [ ] English only; avoid medical efficacy claims
