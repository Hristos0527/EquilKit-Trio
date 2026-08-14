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
| Claim / SN registry | `POST /admin/discard-claim` — lásd agent log; **ne** vond vissza kreditet discard nélkül |

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

Detailed validation and commands: [`agent-log/glux-ai/20260814T103701Z-smooth-chat-v3.md`](./agent-log/glux-ai/20260814T103701Z-smooth-chat-v3.md).

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
| Email→GT / Tasks migrate flags (`EMAIL_TO_TASKS_ENABLED`) | set wrangler var `true` + `wrangler deploy` in `workers/task-board-api` |
| Phase 2 people/thread/focus-meta (`cursor/task-board-phase2-people-thread-c4c9`) | `git revert <merge-sha>` → Pages + `cd workers/task-board-api && npm run deploy`. KV `people:*` / `thread:*` / `focus_meta:*` megmarad (ártalmatlan). |
| Sync script human-who / title_hu | same revert; next hourly sync rewrites JSON |

---

## Agent kötelezettség

Éles változtatás előtt agent log **Before** szekció:

- commit SHA / branch
- wrangler vars / secrets érintve-e
- backup fájl útvonal
- pontos rollback parancsok
