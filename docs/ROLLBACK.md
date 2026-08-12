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
| Cross-copy modal (#953 `24a80879`) | `git revert 24a80879` → Pages redeploy |
| PD Support types + sync log (#955 `1f872a47`) | `git revert 1f872a47` → Pages + worker redeploy |
| Gergő hours / author-who / focus persist (`cursor/task-board-gergo-hours-activity-3f34`) | `git revert <merge-sha>` → Pages redeploy; next hourly sync rewrites who |
| Gergő Tegnap Done visibility (`cursor/task-board-gergo-activity-visible-3f34`) | `git revert <merge-sha>` → Pages redeploy |
| Email→GT / Tasks migrate flags (`EMAIL_TO_TASKS_ENABLED`) | set wrangler var `true` + `wrangler deploy` in `workers/task-board-api` |
| Sync script human-who / title_hu | same revert; next hourly sync rewrites JSON |

---

## Agent kötelezettség

Éles változtatás előtt agent log **Before** szekció:

- commit SHA / branch
- wrangler vars / secrets érintve-e
- backup fájl útvonal
- pontos rollback parancsok
