# Ready to paste — GitHub Issue body

Open: **https://github.com/nightscout/Trio/issues/new**

**Title:**
```
Community plugins: EquilKit + LinxCGMKit for Trio (BLE pump + Linx CGM)
```

**Body** (copy everything below this line):

---

## Summary
I've built and daily-drive two Trio plugins:

- **EquilKit** — Equil patch pump (BLE, connect-per-command, prime, temp basal, bolus, background keepalive)
- **LinxCGMKit** — Linx CGM via passive BLE scan (3 min loop gate, background scan watchdog)

Both are tested on iPhone with Trio v0.8.4 + my fork integrations. Equil and Linx work alongside standard Trio (OmnipodKit, etc.) as separate pump/CGM plugins.

## Repos (public)
- **One-command build (recommended for beginners):** https://github.com/Hristos0527/Trio-Equil-Linx-Build — pre-wired Trio + Equil + Linx, `./scripts/build.sh`
- EquilKit: https://github.com/Hristos0527/EquilKit-Trio
- LinxCGMKit: https://github.com/Hristos0527/LinxCGMKit-Trio
- Integration guide: `INTEGRATION.md` in each kit repo (only needed if you build upstream Trio yourself)

## Real-world testing
**Hristos (@Hristos0527)** has **self-hosted daily use for ~2 weeks** (Equil + Linx + Trio on iPhone) before sharing.

**EquilKit** implementation references the **AndroidAPS Equil integration** (BLE command model, prime/dosing behaviour), reimplemented as a Trio PumpManager plugin. **LinxCGMKit** is an original CGM plugin (passive BLE scan); not from AAPS.

## Status
- Community / sideload build — not requesting immediate upstream merge
- Looking for testers and feedback from experienced Trio builders
- Happy to discuss submodule / upstream PR path if maintainers are interested

## Hardware
- Equil patch (BLE)
- Linx CGM sensor (BLE service 181F, passive advertisements)

## Known limitations
- iOS background BLE throttling (mitigations: Linx scan watchdog, Equil keepalive ping)
- Requires self-build (Xcode)

## Disclaimer
Community sideload only — build and use at your own risk. Not medical advice or approved therapy software.

## Questions for maintainers
1. Would you accept these as optional submodules (like MedtrumKit)?
2. Any architectural requirements before a PR?
