# Rollback — visszaállítás éles változtatások után

Minden **éles hatású** agent munka dokumentálja a visszagörgetést az agent logban és itt, workstream szerint.

## Általános elvek

| Típus | Visszagörgetés |
|-------|----------------|
| **Git / kód** | `git revert <merge-commit-sha>` → új PR → deploy |
| **Cloudflare Worker** | Előző verzió: merge revert, vagy `wrangler.toml` env vissza + deploy |
| **Shopify theme** | `git revert` + `shopify theme push` duplicate theme-en először |
| **Shopify Admin API** | `backups/*.json` + `scripts/rollback_*.py` |
| **KV / runtime toggle** | Admin UI vagy dokumentált API — agent log „Before” szekció |

**Backup helyek:** `backups/`, `docs/backups/<type>/` (workstream szerint).

---

## glux-garancia (Cloudflare Worker)

**Deploy:** `integrations/glux-ai-brain/branches/glux-garancia/worker`

```bash
cd integrations/glux-ai-brain/branches/glux-garancia/worker
git revert <bad-merge-sha>   # vagy checkout előző build-info
npm run deploy
```

| Változtatás | Rollback |
|-------------|----------|
| Fotó AI modell (OpenAI ↔ Gemma) | `wrangler.toml`: `GARANCIA_VISION_MODEL`, `GARANCIA_TEXT_MODEL` → deploy |
| Auto-kredit runtime | Admin → Auto-kredit kapcsoló (`CONFIG:auto_mode`) |
| Auto-kredit delay / idősáv (2026-08-18) | Admin → késleltetés `0` + idősáv `0–24` (azonnali mód), vagy Auto-kredit KI; vagy `git revert <merge-sha>` → `npm run smoke && npm run deploy` |
| Admin closed-claims preload (2026-08-18) | `git revert 8c33de02` → `cd integrations/glux-ai-brain/branches/glux-garancia/worker && npm run smoke && npm run deploy` |
| Board card opens exact claim (2026-08-18) | `git revert <merge-sha>` → Pages + `npm run smoke && npm run deploy` in garancia worker |

**Smoke deploy előtt:** `npm run smoke`

---

## glux-brain / glux-chat / glux-email

**Deploy:** lásd [`AGENT_OPERATIONS.md`](./AGENT_OPERATIONS.md)

Rollback: `git revert` + `npx wrangler deploy` az adott worker könyvtárban.

| Deploy (2026-08-12) | Rollback |
|---------------------|----------|
| glux-chat personality/routing #975 (`244230d1`) — version `51cee98b` | `git revert 244230d1` → `cd integrations/glux-ai-brain/branches/glux-chat/worker && npx wrangler deploy` |
| glux-chat order correction (`6cac546c`) — version `edff7c39` | `git revert 6cac546c` → `cd integrations/glux-ai-brain/branches/glux-chat/worker && npx wrangler deploy` |
| glux-ai-admin SPA + greeting #975 — version `60af416f` | same revert → `cd integrations/glux-ai-brain/branches/glux-ai-admin/worker && npx wrangler deploy` |
| glux-garancia internal shopify #975 — version `28d44f31` | same revert → `cd integrations/glux-ai-brain/branches/glux-garancia/worker && npm run deploy` |

### GluX AI Agent V3 (staging only — 2026-08-13)

Production `glux-chat` is **not** on V3 (`GLUX_AGENT_VERSION` unset).

| Service | Rollback |
|---------|----------|
| `glux-chat-agent-v3-test` | Redeploy previous worker version from Cloudflare dashboard, or `git revert` V3 commit → `cd integrations/glux-ai-brain/branches/glux-chat/worker && npx wrangler deploy --config wrangler.agent-v3-test.toml` |
| `glux-ai-admin` (V3 routing + debug UI) | `git revert` admin commit → `cd integrations/glux-ai-brain/branches/glux-ai-admin/worker && npx wrangler deploy` |
| `glux-garancia` (internal agent routes) | `git revert` garancia commit → `cd integrations/glux-ai-brain/branches/glux-garancia/worker && npm run deploy` |
| `glux-pdf-extract` (per-page PDF) | Redeploy previous version → `cd integrations/glux-ai-brain/branches/glux-pdf-extract/worker && npx wrangler deploy` |
| Admin test → V3 | Unset `GLUX_AGENT_V3_TEST_CHAT_URL` on `glux-ai-admin` (falls back to V2 test URL) |
| D1 `page_number` migration | `0007_knowledge_page_number.sql` is additive; rollback = ignore column (re-index docs after revert) |

### V3 smooth-chat pipeline (2026-08-14)

Pre-release Worker versions:

| Service | Previous version |
|---------|------------------|
| `glux-chat` | `0ab53197-0ffc-4f81-a46b-7b03aa89e589` |
| `glux-chat-agent-v3-test` | `df8c5bba-98c9-4394-ad93-6507ed48f5e8` |
| `glux-garancia` | `f8b65e8f-8409-4740-9150-216ca5e6f4ba` |
| `glux-ai-admin` | `b9c104eb-648d-47ed-9e14-f78fca76734f` |

Use `wrangler rollback <version>` in the matching worker directory; for V3 staging add `--config wrangler.agent-v3-test.toml`. The additive `glux-chat-knowledge` Vectorize index may remain after rollback and can be rebuilt from Dashboard knowledge. Do not delete the index during an incident rollback.

| glux-chat semantic index best-effort delete (`84ee212d`) — version from deploy gate `0ad09f5e` | `git revert 84ee212d` → redeploy glux-chat + glux-ai-admin |
| glux-chat fatigue/credit routing (`528de774`) — `fe6dd21e` / v3-test `36433968` | `git revert 528de774` → redeploy glux-chat + `wrangler.agent-v3-test.toml` |

Detailed validation and commands: [`agent-log/glux-ai/20260814T103701Z-smooth-chat-v3.md`](./agent-log/glux-ai/20260814T103701Z-smooth-chat-v3.md).

### V3 target architecture flag (`GLUX_V3_ARCH_ENABLED`) — **production is on** (updated 2026-08-18)

Korábban ez a szakasz „staging only"-t írt. **Ez elavult:** `wrangler.toml` (production `glux-chat`) is `GLUX_V3_ARCH_ENABLED = "1"` értéken áll, tehát az arch path éles forgalmat szolgál ki. A rollback célpont a legacy V3 runner, nem a V1 smooth-chat.

| Action | Command / setting |
|--------|-------------------|
| **Disable arch on staging** | `wrangler.agent-v3-test.toml` → `GLUX_V3_ARCH_ENABLED = "0"` → `cd integrations/glux-ai-brain/branches/glux-chat/worker && npm run deploy:agent-v3-test` |
| **Disable arch on production** | `wrangler.toml` → `GLUX_V3_ARCH_ENABLED = "0"` → `npm run deploy` (a `GLUX_AGENT_VERSION = "v3"` marad; ez a legacy V3 runnert választja) |
| **Redeploy previous Worker** | `npx wrangler rollback <version> [--config wrangler.agent-v3-test.toml]` |
| **Acceptance re-check** | `node scripts/glux-ai/run-glux-acceptance-tests.mjs` (static 44/44 routing) |

### V3.2 pipeline flag (`GLUX_V3_2_ENABLED`) — opt-in (2026-08-18)

A V3.2 az arch path tetejére épül, és alapértelmezetten **ki van kapcsolva**. Terv: [`glux-ai/V3_2_PLAN.md`](./glux-ai/V3_2_PLAN.md).

| Action | Command / setting |
|--------|-------------------|
| **Disable V3.2 (teljes visszaállás V3.1-re)** | `GLUX_V3_2_ENABLED = "0"` vagy a változó törlése → deploy. Nincs adatmigráció, nincs egyéb teendő. |
| **Egy tenant kivétele** | tenant config `features.v32 = false` → publish. A globális kapcsoló a külső kapu: ha az „0", a tenant beállítás nem tudja bekapcsolni. |
| **Verzió ellenőrzése** | A válasz `build.agentVersion` mezője `v3.1` vagy `v3.2`; a trace `orchestratorTrace.pipelineVersion` ugyanezt mutatja. |

Staging saját Vectorize indexet kapott (`glux-chat-agent-v3-knowledge`), hogy a V3.2 kísérletek ne írjanak a produkciós vektorokba. Az indexet a `scripts/deploy-worker.mjs` hozza létre az első staging deploynál; utána a tudásbázist újra kell publikálni, hogy a szemantikus keresés visszaálljon (addig lexikálisra esik vissza, hibaüzenet nélkül).

### Retrieval observability (F5) — nincs flag mögött (2026-08-18)

Az F5 szándékosan **nem** a `GLUX_V3_2_ENABLED` mögött van: ez a mérőműszer, amivel a V3.1 és a V3.2 összehasonlítható, tehát mindkét úton jelentenie kell. Csak diagnosztikai mezőket ad hozzá — az ágens bemenete, eszközválasztása és válaszszövege változatlan.

| Action | Command / setting |
|--------|-------------------|
| **Teljes visszaállás** | `git revert 432f46bd` → `npm run deploy` a `glux-ai-admin` és a `glux-chat` workerben. Nincs séma-, KV- vagy Vectorize-írás, csak redeploy. |
| **Csak a chat worker visszaállítása** | Biztonságos: a `/admin/v1/retrieval-health` továbbra is működik, `corpus.pressure.state` `unknown` lesz, a turn panelen pedig nem lesz `topScores`. |
| **Élő ellenőrzés** | `GET /admin/v1/retrieval-health` → `state`, `missingCount`, `indexLagMs`, `corpus.pressure`. |

### GYIK retrieval recall (F3 / PR-2a) — kapuzott (2026-08-18)

A GYIK chunkok mostantól `documentId`-t is hordoznak, de ezt **csak a V3.2 út használja fel**. Flag nélkül a `documentKey` pontosan a korábbi kulcsot állítja elő, tehát az újrapublikálás önmagában nem mozdítja a produkciós találatokat.

| Action | Command / setting |
|--------|-------------------|
| **Gyors mitigáció (ha a V3.2 be van kapcsolva és romlik a recall)** | `GLUX_V3_2_ENABLED = "0"` → `glux-chat` deploy. Újrapublikálás **nem** kell: a mező flag nélkül inaktív. |
| **Teljes visszaállás** | `git revert 84db004a` → `npm run deploy` a `glux-ai-admin` és a `glux-chat` workerben. |
| **Séma** | `0019_faqs_priority.sql` csak hozzáad egy oszlopot alapértelmezett értékkel, a régi worker is elfut az új sémán. Down-migráció nincs és nem is kell. |
| **Élő ellenőrzés** | `GET /admin/v1/retrieval-health` → `state: ready`, `missingCount: 0`. Újrapublikálás után az index ~60 s alatt épül újra. |

### Admin auth — `ALLOW_DEV_AUTH` (2026-08-18)

A korábbi `workers_preview` mód a hosztnév `.workers.dev` végződésére engedett be token nélkül. Mivel a `glux-ai-admin` egyetlen éles hosztneve `glux-ai-admin.gluxshop.workers.dev`, ez minden `/admin/v1/*` végpontot nyilvánosan olvashatóvá és írhatóvá tett. A mód megszűnt.

| Action | Command / setting |
|--------|-------------------|
| **Belépés a dashboardra** | Egyszer megnyitni: `https://glux-ai-admin.gluxshop.workers.dev/admin/login?key=<KEY>` → HttpOnly cookie-t állít és átirányít a `/`-re. Utána a kulcs nem kell újra. |
| **Kulcs cseréje / kompromittálódás** | `wrangler secret put ADMIN_DEV_AUTH_KEY` új értékkel → deploy. A régi cookie-k azonnal érvénytelenek. |
| **Teljes zárás (cél állapot)** | `ALLOW_DEV_AUTH = "0"` → deploy. **Csak akkor**, ha az App Bridge be van kötve, különben a dashboard elérhetetlen (a `window.shopify` ma nem létezik, így a SPA nem küld JWT-t). |
| **Vészhelyzeti visszaállás** | `git revert <merge-sha>` → deploy. Ez visszahozza a nyilvános hozzáférést, ezért csak végszükség esetén. |

A kulcs helye lokálisan: `artifacts/admin-auth/ADMIN_DEV_AUTH_KEY.txt` (gitignored). A secret soha nem kerül a `wrangler.toml`-ba — a smoke check ezt ellenőrzi.

---

## Shopify theme

1. Duplicate theme preview
2. `git revert` a theme commitra
3. `shopify theme push` — csak jóváhagyás után live theme-re

---

## task-board (GitHub Pages)

**Live:** https://hristos0527.github.io/linx-presentation-site/task-board.html  
**Board JSON:** `task-board-data.json` (hourly sync to default branch)

| Változtatás | Rollback |
|-------------|----------|
| HTML / labels / `task-board-github-display.json` | `git revert <merge-sha>` → push `master` → Pages redeploy |
| Done scroll + load-more 25 (#948 `f7bd28b5`) | `git revert f7bd28b5` → Pages redeploy (restores accordion UX) |
| PD details modal (#951 `3bfceea1`) | `git revert 3bfceea1` → Pages + `cd workers/task-board-api && npm run deploy` |
| PD tz + focus hide + create-open + details HTML (`cursor/task-board-pd-budapest-tz-focus-3f34`) | `git revert <merge-sha>` → Pages + `cd workers/task-board-api && npm run deploy` |
| Pending board fixes (PD local close, hide btn, OAuth persist, group collapse) (`cursor/task-board-pending-fixes-3f34`) | Revert merge → Pages workflow + worker redeploy |
| Ma auto-focus GT + calendar (`cursor/task-board-ma-auto-focus-gt-cal-3f34`, merge `0eed2d85`) | `git revert 0eed2d85` → push `master` → Pages redeploy |
| Transfer move = delete source (#1027 `47a9881a`) | `git revert 47a9881a` → Pages + `cd workers/task-board-api && npm run deploy` |
| Cross-copy modal (#953 `24a80879`) | `git revert 24a80879` → Pages redeploy |
| PD Support types + sync log (#955 `1f872a47`) | `git revert 1f872a47` → Pages + worker redeploy |
| Gergő hours / author-who / focus persist (`cursor/task-board-gergo-hours-activity-3f34`) | `git revert <merge-sha>` → Pages redeploy; next hourly sync rewrites who |
| Gergő Tegnap Done visibility (`cursor/task-board-gergo-activity-visible-3f34`) | `git revert <merge-sha>` → Pages redeploy |
| Gergő GitHub auto-merge who (#1109 `46c0bdc6`) | `git revert 46c0bdc6` → push `master` → re-run `sync-agent-status.yml` |
| Agenda now-line / 00–24 / Átütemezés + Terület 7 kategória (`cursor/task-board-agenda-now-reschedule`) | `git revert <merge-sha>` → push `master` → Pages redeploy |
| Agenda scroll today+tomorrow + wrapped titles (`cursor/task-board-agenda-scroll-nextday`) | `git revert <merge-sha>` → push `master` → Pages redeploy |
| Email→GT / Tasks migrate flags (`EMAIL_TO_TASKS_ENABLED`) | set wrangler var `true` + `wrangler deploy` in `workers/task-board-api` |
| Focus height + GT Kanban off + email images (`cursor/task-board-focus-email-fix-bfcf`) | `git revert <merge-sha>` → Pages + `cd workers/task-board-api && npm run deploy`. Local: clear `glux-task-board-settings-*` / purge flag `glux-task-board-purge-gt-manual-v1-*` if needed. |
| Phase 2 people/thread/focus-meta (`cursor/task-board-phase2-people-thread-c4c9`) | `git revert <merge-sha>` → Pages + `cd workers/task-board-api && npm run deploy`. KV `people:*` / `thread:*` / `focus_meta:*` megmarad (ártalmatlan). |
| Sync script human-who / title_hu | same revert; next hourly sync rewrites JSON |
| Version footer at board bottom (#1060 `dc9d7c22`) | `git revert dc9d7c22` → push `master` → Pages redeploy |
| Focus agenda timeline (#1092 `eaff9f4a`) | `git revert eaff9f4a` → push `master` → Pages + `cd workers/task-board-api && npm run deploy` |
| Email thumbs + Shopify secrets (#1094 `e012f9ba`) | `git revert e012f9ba` → push `master` → Pages + worker deploy |
| GitHub board scan one repo (#1097 `c97acf1c`) | `git revert c97acf1c` → push `master` → next `sync-agent-status.yml` scans all `repos[]` again |
| GitHub PRs only + skip orphan cursor branches (#1098 `8af0add5`) | `git revert 8af0add5` → push `master` |
| Agenda calendar picker on focus strip | `git revert <merge-sha>` → push `master` → Pages redeploy |
| Email attachment thumb preview vs filename download | `git revert <merge-sha>` → push `master` → Pages redeploy |

---

## repo-maintenance (git refs)

| Változtatás | Rollback |
|---|---|
| Remote branch cleanup 2026-08-18 (241 → 85 ref, 157 törölve) | PR oldalon **Restore branch**, vagy `gh api -X POST repos/Hristos0527/linx-presentation-site/git/refs -f ref='refs/heads/<branch>' -f sha='<sha>'`. A 34 megtartott egyedi branch bundle-je: `artifacts/branch-cleanup-20260818/bundles/unique-work-34-branches.bundle` (lokális, gitignored). Részletek: `docs/agent-log/repo-maintenance/20260818T112000Z-remote-branch-cleanup.md` |

---

## Agent kötelezettség

Éles változtatás előtt agent log **Before** szekció:

- commit SHA / branch
- wrangler vars / secrets érintve-e
- backup fájl útvonal
- pontos rollback parancsok
