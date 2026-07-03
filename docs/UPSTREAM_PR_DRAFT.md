# Draft: Upstream PR to nightscout/Trio

> **Not submitted.** Copy and adapt this text when opening a PR against [nightscout/Trio](https://github.com/nightscout/Trio). Maintainer approval is required before merge.

---

## PR title

```
Add optional EquilKit + LinxCGMKit community pump/CGM plugins (submodules)
```

## PR description

### Summary

This PR adds **optional** community-maintained device plugins as git submodules, following the same pattern as MedtrumKit, DanaKit, and OmnipodKit:

| Submodule | Role | Upstream repo |
|-----------|------|---------------|
| `EquilKit/` | Equil patch pump (`PumpManager`) | https://github.com/Hristos0527/EquilKit-Trio |
| `LinxCGMKit/` | Linx BLE CGM (`CGMManager`) | https://github.com/Hristos0527/LinxCGMKit-Trio |

Both plugins are **AGPL-3.0**, self-contained frameworks with `.loopplugin` bundles. They do not change default Trio behaviour unless the user selects Equil pump or Linx CGM in settings.

### Motivation

- **Equil patch pump** users need a Trio-native `PumpManager` (BLE connect-per-command, priming, temp basal, bolus).
- **Linx CGM** users need passive BLE scan integration with Trio's loop heartbeat model.
- Community repos already document integration (`INTEGRATION.md`); submodule inclusion reduces fork drift for experienced builders.

### Real-world testing

Community maintainer **Hristos (@Hristos0527)** has daily-driven Equil + Linx + Trio on iPhone for ~2 weeks before publishing. This is **n=1 sideload testing**, not clinical validation.

### Integration changes (Trio app)

Minimal glue already documented in each kit's `INTEGRATION.md`:

1. Add submodules and Xcode workspace file refs.
2. Link + embed `EquilKit.framework` / `LinxCGMKit.framework` (+ UI frameworks).
3. Register in `DeviceDataManager.swift`:
   - `EquilPumpManager.self` in `staticPumpManagers`
   - `LinxCGMManager.self` in static CGM manager lists
4. Optional: reservoir/battery HUD wiring for Equil (see INTEGRATION.md).

### Architectural notes

- **EquilKit**: ported from AndroidAPS Equil driver behaviour, reimplemented as LoopKit `PumpManager`. Background keepalive ping (`CmdRunningModeGet`, 60–90 s jitter) mitigates iOS background BLE throttling.
- **LinxCGMKit**: original CGM plugin (not from AAPS). Passive scan of service `181F`, manufacturer `0x0059`, 3-minute loop gate, background scan watchdog (~4 min stale restart).
- Neither plugin vendors LoopKit; they depend on the host Trio workspace.

### Suggested submodule commits

Pin to tagged releases when merging:

- `EquilKit-Trio` → `v1.0.0`
- `LinxCGMKit-Trio` → `v1.0.0`

### Out of scope for this PR

- Enabling plugins by default
- App Store / TestFlight distribution
- Medical or regulatory claims
- Official support commitments from Equil or Linx

### Test plan

- [ ] Clean clone with submodules init builds in Xcode (simulator + device)
- [ ] Equil appears in pump picker; pairing + priming flow completes
- [ ] Linx appears in CGM picker; scan + calibration + glucose delivery
- [ ] Existing Omnipod / Dexcom / Libre integrations unaffected
- [ ] CI builds kit frameworks against LoopKit (see community repo workflows)

### Maintainer questions

1. Accept as optional submodules (like MedtrumKit) or prefer documentation-only linking?
2. Any naming / bundle ID requirements before merge?
3. Preferred location for user-facing docs (Trio wiki vs triodocs.org)?

### Disclaimer

Community contribution — build and use at your own risk. Not medical advice or approved therapy software.

---

## Files to include in the actual PR

```
.gitmodules
Trio.xcworkspace/contents.xcworkspacedata
Trio/Sources/APS/DeviceDataManager.swift  (registration snippets)
Trio.xcodeproj/project.pbxproj             (framework link/embed)
```

Reference integration guides:

- https://github.com/Hristos0527/EquilKit-Trio/blob/master/INTEGRATION.md
- https://github.com/Hristos0527/LinxCGMKit-Trio/blob/master/INTEGRATION.md
