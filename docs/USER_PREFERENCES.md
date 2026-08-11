# User preferences (global — all agents)

**Always follow these.**

## Language

- **Always reply in Hungarian** in chat, even when the user writes in English.

## GitHub & deploy workflow

- **The agent does everything on GitHub:** branch, commit, push, open/update PR, **merge to the default branch** (`main` or `master`).
- **The agent also deploys** after merge when the change affects a live service.
- The user does **not** merge, push, or deploy manually — zero manual steps unless explicitly asked.
- Do **not** end tasks with “open a PR” / “please merge” — do it yourself, then report what is live.

## Continuity

- Read [`AGENT_CONTINUITY.md`](./AGENT_CONTINUITY.md); run `./scripts/agent-continuity-check.sh`.
- Search for existing `cursor/*` branches/PRs before re-implementing.
- Session end: merge + deploy (if live) + agent log (`docs/agent-log/HANDOFF_TEMPLATE.md`).

## Development style

- Plan before new features; small commits; one workstream per branch (`cursor/<workstream>-<task>-<suffix>`).
- Protect the default branch: port/integrate, do not overwrite working code.
