# Agent instructions (all Cursor agents — local & cloud)

**Hungarian chat with the user. Code and comments in English.**

## Read first (every session)

1. [`docs/USER_PREFERENCES.md`](docs/USER_PREFERENCES.md)
2. [`docs/AGENT_CONTINUITY.md`](docs/AGENT_CONTINUITY.md) — **how we avoid lost merges**

GluX monorepo (deploy commands, garancia/brain): [linx-presentation-site](https://github.com/Hristos0527/linx-presentation-site)

## Non-negotiable

- **You** branch, commit, push, open/update PR, **merge to the repo default branch** (`main` or `master`), and **deploy** live services.
- A task is incomplete if code exists only on a `cursor/*` branch.
- Before re-implementing a feature, search for existing branches/PRs and prior commits.
- End every session with an agent log (`docs/agent-log/HANDOFF_TEMPLATE.md`) and rollback notes when live-impacting.

## Quick check

```bash
./scripts/agent-continuity-check.sh
```
