# Publishing guide — community announcement

Step-by-step instructions for sharing EquilKit + LinxCGMKit with the Trio community.  
Automated setup (CI, releases, docs) is already done in the repos — this guide covers **manual clicks only**.

---

## Already done (automated)

| Item | Status | Link |
|------|--------|------|
| EquilKit-Trio v1.0.0 release | ✅ | https://github.com/Hristos0527/EquilKit-Trio/releases/tag/v1.0.0 |
| LinxCGMKit-Trio v1.0.0 release | ✅ | https://github.com/Hristos0527/LinxCGMKit-Trio/releases/tag/v1.0.0 |
| CI workflow (EquilKit) | ✅ | https://github.com/Hristos0527/EquilKit-Trio/actions/workflows/ci.yml |
| CI workflow (LinxCGMKit) | ✅ | https://github.com/Hristos0527/LinxCGMKit-Trio/actions/workflows/ci.yml |
| One-command build repo | ✅ | https://github.com/Hristos0527/Trio-Equil-Linx-Build |
| Build repo CI | ✅ | https://github.com/Hristos0527/Trio-Equil-Linx-Build/actions/workflows/simulator-build.yml |
| CONTRIBUTING.md | ✅ | In each kit repo |
| Issue templates | ✅ | `.github/ISSUE_TEMPLATE/bug_report.yml` |
| Upstream PR draft | 📝 draft | [docs/UPSTREAM_PR_DRAFT.md](docs/UPSTREAM_PR_DRAFT.md) |
| TrioDocs draft | 📝 draft | [docs/TRIODOCS_DRAFT.md](docs/TRIODOCS_DRAFT.md) |

---

## Step 1 — GitHub Issue (nightscout/Trio)

**Where to click:**

1. Open **https://github.com/nightscout/Trio/issues/new**
2. Paste the **title** and **body** from [ISSUE_BODY_READY.md](ISSUE_BODY_READY.md) (or [COMMUNITY_ANNOUNCEMENT.md](COMMUNITY_ANNOUNCEMENT.md))
3. Click **Submit new issue**
4. Copy the issue URL — you need it for Discord posts

---

## Step 2 — Discord (Trio community)

**Where to click:**

1. Open **https://triodocs.org**
2. Click the **Discord** link (top navigation or support section)
3. Accept the Discord invite
4. Post in these channels (replace `<issue link>` with your GitHub issue URL):

| Channel | What to post |
|---------|--------------|
| **#pumps** | EquilKit announcement — text in [COMMUNITY_ANNOUNCEMENT.md](COMMUNITY_ANNOUNCEMENT.md) § Discord #pumps |
| **#cgms** | LinxCGMKit announcement — text in [COMMUNITY_ANNOUNCEMENT.md](COMMUNITY_ANNOUNCEMENT.md) § Discord #cgms |
| **#dev** | Summary with all repo links — text in [COMMUNITY_ANNOUNCEMENT.md](COMMUNITY_ANNOUNCEMENT.md) § Discord #dev |

---

## Step 3 — Upstream PR (draft only, later)

**Do not submit yet** unless Trio maintainers ask for it.

**Where to click (when ready):**

1. Open **https://github.com/nightscout/Trio/compare**
2. Set **base:** `main` (or branch maintainers specify)
3. Set **compare:** your fork branch with submodule integration
4. Copy title + description from [docs/UPSTREAM_PR_DRAFT.md](docs/UPSTREAM_PR_DRAFT.md)
5. Click **Create pull request**

---

## Step 4 — TrioDocs contribution (draft only, later)

**Where to click (when ready):**

1. Read the outline in [docs/TRIODOCS_DRAFT.md](docs/TRIODOCS_DRAFT.md)
2. Open **https://triodocs.org** → find the documentation contribution / GitHub source link
3. Propose a new page: *Community devices — Equil pump & Linx CGM*
4. Link to `Trio-Equil-Linx-Build` as the beginner path

---

## Step 5 — Verify releases & CI

**Where to click:**

| Repo | Releases tab | Actions tab |
|------|--------------|-------------|
| EquilKit-Trio | https://github.com/Hristos0527/EquilKit-Trio/releases | https://github.com/Hristos0527/EquilKit-Trio/actions |
| LinxCGMKit-Trio | https://github.com/Hristos0527/LinxCGMKit-Trio/releases | https://github.com/Hristos0527/LinxCGMKit-Trio/actions |
| Trio-Equil-Linx-Build | https://github.com/Hristos0527/Trio-Equil-Linx-Build/releases | https://github.com/Hristos0527/Trio-Equil-Linx-Build/actions |

Confirm **v1.0.0** exists on both kit repos and CI shows green on the latest push.

---

## Quick reference — all public repos

- https://github.com/Hristos0527/EquilKit-Trio
- https://github.com/Hristos0527/LinxCGMKit-Trio
- https://github.com/Hristos0527/Trio-Equil-Linx-Build
- https://github.com/Hristos0527/trio-equil-linx *(optional integration fork)*

See also: [WHERE_TO_CLICK.md](WHERE_TO_CLICK.md) for a one-page numbered checklist.
