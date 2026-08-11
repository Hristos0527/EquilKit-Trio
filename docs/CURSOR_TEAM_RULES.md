# Cursor Team Rules — másold be a Team Dashboardba

**Hol:** [Cursor Dashboard → Team → Rules](https://cursor.com/dashboard/team-content) → **Add Rule** → **Enforce this rule** (ajánlott)

Ez a szöveg **minden repóra** vonatkozik, ahol a csapat Cursor agentet használ. A projekt-specifikus részletek a repó `AGENTS.md` és `.cursor/rules/` fájljaiban vannak.

---

## GluX / Cursor agent — globális szabályok

### Nyelv
- Felhasználóval **magyarul** beszélj. Kód és komment **angol**.

### Merge és deploy — nem opcionális
- Te csinálod: branch, commit, push, PR, **merge masterbe**, **deploy** (ha érint éles szolgáltatást).
- A feladat **nem kész**, amíg a kód csak egy `cursor/*` branch-en él.
- Ne zárd le „nyisd meg a PR-t” / „deployold te” üzenettel.

### Continuity — új munka előtt
- `git fetch` + legfrissebb default branch.
- Keress meglévő `cursor/*` branch-et és nyitott PR-t ugyanarra a témára — **folytasd**, ne írd újra.
- Repo átszervezésnél **portolj**, ne hagyj funkciót a régi útvonalon.

### Befejezés
- Agent log a repóban (`docs/agent-log/`).
- Rollback út dokumentálva éles változtatásnál.
- Handoff: branch, PR link, merge SHA, éles URL.

### Új agent / nagy kontextus
- Jelezd, ha új agentet érdemes indítani.
- Handoff template kitöltése kötelező session végén.

### Fejlesztési stílus
- Plan előbb új feature-nél; kis commitok; ne buildelj újra appot minden lépésnél.
- Egy workstream = egy branch = egy PR.
- Működő mastert ne írd felül — illeszd be az új funkciót.

---

*Verzió: 2026-08-11 — forrás: linx-presentation-site `docs/CURSOR_TEAM_RULES.md`*
