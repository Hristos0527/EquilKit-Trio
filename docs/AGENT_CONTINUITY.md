# Agent continuity — ne vesszen el munka merge nélkül

Ez a dokumentum azért van, mert **többször előfordult**: egy agent jól megcsinált valamit egy branch-en, **nem merge-elték**, a következő agent a **master régi kódjából** indult, és a projekt „szétesett” (elveszett funkció, dupla implementáció, rossz alap).

**Cél:** bármelyik új agent ugyanazt a **master + éles deploy** igazságot lássa; minden munka **merge-elve** és **visszagörgethető** legyen.

Kapcsolódó: [`AGENT_OPERATIONS.md`](./AGENT_OPERATIONS.md), [`USER_PREFERENCES.md`](./USER_PREFERENCES.md), [`ROLLBACK.md`](./ROLLBACK.md).

---

## Mi a gyökérok? (röviden)

| Probléma | Példa (garancia) |
|----------|------------------|
| Branch-en maradt a kód | OpenAI fotó AI a `garancia-dev-photo-lab` branch-en, master Gemmát futtatott |
| Repo-átszervezés merge nélkül | `integrations/glux-garancia` → `branches/glux-garancia` — funkció nem portolódott |
| Sok párhuzamos `cursor/*` branch | `docs/AGENT_STATUS.md` táblában 20+ nyitott ág |
| Agent „kész” üzenet merge nélkül | „Nyisd meg a PR-t” — te nem akarsz GitHubon kattintgatni |

---

## Hol van beállítva? (nem kell agentenként bemásolni)

| Szint | Hol | Mit csinál |
|-------|-----|------------|
| **Minden team repo (auto)** | `scripts/sync_agent_continuity_to_repos.sh` | Ráírja a `.cursor/rules`, `AGENTS.md`, hookokat, CI-t |
| **Repo (git)** | `.cursor/rules/*.mdc`, `AGENTS.md` | Cursor **automatikusan** betölti (alwaysApply) |
| **Git hook** | `./scripts/install-git-hooks.sh` | Egyszer / klón — push előtt riport |
| **GitHub Actions** | `agent-continuity.yml` + `sync-agent-continuity-repos.yml` | Hygiene + szétterítés master merge után |
| **Cursor Team (dashboard)** | `docs/CURSOR_TEAM_RULES.md` | **Egyszer** a dashboardon → extra védelem minden projektre |

### Mely repókra?

- **Igen:** minden repo a `.github/task-board-repos.json` `repos[]` listában + nyilvános GitHub repók
- **Nem:** `private-hristos-personal`, bármely `*private*` név, és a `exclude_repos` lista

Részletek: `task-board-repos.json` → `agent_continuity` szekció.

**Team Rules (opcionális, 1×):** [Cursor Dashboard → Team → Rules](https://cursor.com/dashboard/team-content) — `docs/CURSOR_TEAM_RULES.md`

---

## Kötelező agent ciklus (minden feladatra)

### Induláskor

1. `git fetch origin master && git checkout master && git pull`
2. Olvasd: `docs/AGENT_STATUS.md`
3. Keress régi munkát: `git branch -a | grep cursor/`, `gh pr list`, `git log --oneline --all --grep="kulcsszó"`
4. Ha van releváns nyitott branch/PR → **folytasd azt**, ne új branch-et.

### Munka közben

- Egy workstream = egy branch = egy PR
- Kis commitok, push gyakran
- Éles API előtt: backup (`docs/backups/` vagy `backups/`) — lásd [`ROLLBACK.md`](./ROLLBACK.md)

### Befejezéskor (addig NEM kész)

1. Push
2. PR create/update
3. **Merge masterbe** (agent, nem te)
4. **Deploy** ha érint live szolgáltatást
5. Agent log: `docs/agent-log/<workstream>/` + [`HANDOFF_TEMPLATE.md`](./agent-log/HANDOFF_TEMPLATE.md)
6. `docs/AGENT_STATUS.md` manual note frissítés
7. Magyar összefoglaló: PR, merge SHA, éles URL, rollback

---

## Új agent indításakor (opcionális)

Nem kell szöveget bemásolni — a `.cursor/rules` automatikusan érvényes. Ha mégis adsz kontextust:

```text
Olvasd: docs/AGENT_CONTINUITY.md. Folytasd meglévő cursor/* branch-et, ne írd újra. Merge + deploy kötelező.
```

---

## Gépi ellenőrzés

```bash
./scripts/agent-continuity-check.sh          # riport
./scripts/agent-continuity-check.sh --strict # CI: exit 1 ha kritikus probléma
./scripts/install-git-hooks.sh               # egyszer / klón — push előtt automatikus riport
./scripts/install-git-hooks.sh --strict      # push tiltás kritikus continuity esetén
```

**Nem kell handoff szöveget bemásolni** minden agentnél, ha:
- a repóban van `.cursor/rules` (alwaysApply) — Cursor automatikusan betölti;
- egyszer beállítottad a **Cursor Team Rules**-t a dashboardon (lásd `docs/CURSOR_TEAM_RULES.md`);
- fut a git hook (`install-git-hooks.sh`) vagy a GitHub Actions workflow.

Mit néz:

- `cursor/*` branch-ek, amik **nincsenek** merge-elve masterbe
- Branch-ek commitjaik masterhez képest (elavult / orphan)
- Nyitott draft PR-ek 7+ napja
- Lokális uncommitted változás

---

## Régi branch-ek takarítása (emberi döntés)

Ne törölj branch-et automatikusan. Sorrend:

1. Van-e benne olyan commit, ami **nincs** masterben? → `git log master..origin/cursor/xyz`
2. Ha igen → **merge vagy portolás** masterre, aztán agent log „superseded by PR #…”
3. Ha nem → branch törölhető remote-on

Garancia példa (2026-08): `cursor/garancia-dev-photo-lab-20260729` OpenAI logika → portolva `cursor/garancia-openai-restore-aadf`-re.

---

## Checklist — „szétesett a projekt” recovery

1. Mi az **éles** verzió? (build-info, deploy log, worker URL)
2. Mi van **masterben**?
3. `git branch -a --no-merged master | grep cursor` — mi maradt ki?
4. Prioritás: kritikus funkció branch-ek merge/port **előbb**, mint új feature
5. Egy recovery branch: `cursor/recovery-<topic>-aadf` — csak port, ne rewrite
