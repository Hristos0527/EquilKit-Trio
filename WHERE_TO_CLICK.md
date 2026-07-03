# Where to click — manual publishing checklist

Everything automatable is already pushed. Complete these **5 manual steps** in order.

---

## 1. Open GitHub Issue

**URL:** https://github.com/nightscout/Trio/issues/new

1. Paste **title** + **body** from [ISSUE_BODY_READY.md](ISSUE_BODY_READY.md)
2. Click **Submit new issue**
3. **Copy the issue URL** (needed for Discord)

---

## 2. Join Discord

**URL:** https://triodocs.org

1. Click the **Discord** invite link on the site
2. Accept invite in Discord app/browser

---

## 3. Post on Discord (3 channels)

Use texts from [COMMUNITY_ANNOUNCEMENT.md](COMMUNITY_ANNOUNCEMENT.md). Replace `<issue link>` with your issue URL from step 1.

| # | Channel | URL hint |
|---|---------|----------|
| 3a | **#pumps** | EquilKit post — see COMMUNITY_ANNOUNCEMENT § #pumps |
| 3b | **#cgms** | LinxCGMKit post — see COMMUNITY_ANNOUNCEMENT § #cgms |
| 3c | **#dev** | Summary with all repo links — see COMMUNITY_ANNOUNCEMENT § #dev |

Discord server: https://discord.triodocs.org

---

## 4. Verify releases (optional sanity check)

| Repo | Click here |
|------|------------|
| EquilKit v1.0.0 | https://github.com/Hristos0527/EquilKit-Trio/releases/tag/v1.0.0 |
| LinxCGMKit v1.0.0 | https://github.com/Hristos0527/LinxCGMKit-Trio/releases/tag/v1.0.0 |

---

## 5. Watch CI (optional)

| Repo | Actions tab |
|------|-------------|
| EquilKit-Trio | https://github.com/Hristos0527/EquilKit-Trio/actions |
| LinxCGMKit-Trio | https://github.com/Hristos0527/LinxCGMKit-Trio/actions |
| Trio-Equil-Linx-Build | https://github.com/Hristos0527/Trio-Equil-Linx-Build/actions |

---

## Later (drafts ready — do not click yet)

| Task | Draft file | URL when ready |
|------|------------|----------------|
| Upstream Trio PR | [docs/UPSTREAM_PR_DRAFT.md](docs/UPSTREAM_PR_DRAFT.md) | https://github.com/nightscout/Trio/compare |
| TrioDocs page | [docs/TRIODOCS_DRAFT.md](docs/TRIODOCS_DRAFT.md) | https://triodocs.org |

---

## All repos (for sharing)

- **Beginner build:** https://github.com/Hristos0527/Trio-Equil-Linx-Build
- **EquilKit:** https://github.com/Hristos0527/EquilKit-Trio
- **LinxCGMKit:** https://github.com/Hristos0527/LinxCGMKit-Trio
- **Integration fork:** https://github.com/Hristos0527/trio-equil-linx

Full guide: [PUBLISH.md](PUBLISH.md)
