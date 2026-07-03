# Community announcement — copy & paste

Ready-to-post text for GitHub Issue and Trio Discord. Update `<issue link>` after you create the issue.

---

## GitHub Issue

**Repository:** https://github.com/nightscout/Trio/issues/new

**Title:**
```
Community plugins: EquilKit + LinxCGMKit for Trio (BLE pump + Linx CGM)
```

**Body:**
```markdown
## Summary
I've built and daily-drive two Trio plugins:

- **EquilKit** — Equil patch pump (BLE, connect-per-command, prime, temp basal, bolus, background keepalive)
- **LinxCGMKit** — Linx CGM via passive BLE scan (3 min loop gate, background scan watchdog)

Both are tested on iPhone with Trio v0.8.4 + my fork integrations. Equil and Linx work alongside standard Trio (OmnipodKit, etc.) as separate pump/CGM plugins.

## Repos (public)
- EquilKit: https://github.com/Hristos0527/EquilKit-Trio
- LinxCGMKit: https://github.com/Hristos0527/LinxCGMKit-Trio
- Integration guide: `INTEGRATION.md` in each repo

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
```

---

## Discord posts

Join via https://triodocs.org → Discord link.

### #pumps (Equil)
```
Built an EquilKit plugin for Trio (BLE patch pump, daily use ~2 weeks self-tested).
Repo: https://github.com/Hristos0527/EquilKit-Trio
Equil port based on AndroidAPS Equil driver → Trio PumpManager plugin.
Integration doc included. Looking for testers / feedback. Community sideload — own risk.
GitHub issue: <issue link>
```

### #cgms (Linx)
```
LinxCGMKit for Trio — passive BLE scan, 3 min loop heartbeat, background scan watchdog.
Original CGM plugin (not from AAPS). Self-tested ~2 weeks.
Repo: https://github.com/Hristos0527/LinxCGMKit-Trio — feedback welcome from builders.
GitHub issue: <issue link>
```

### #dev (summary)
```
Sharing two community Trio plugins: EquilKit + LinxCGMKit.
- EquilKit: https://github.com/Hristos0527/EquilKit-Trio
- LinxCGMKit: https://github.com/Hristos0527/LinxCGMKit-Trio
GitHub issue: <issue link>
Happy to align with upstream if maintainers want submodules.
```

---

## Suggested order

1. Push both public repos (done if you ran `gh repo create`)
2. Open the GitHub Issue with repo links
3. Post on Discord with the issue link
4. *(Optional)* Tag a GitHub Release `v1.0.0` on each repo
