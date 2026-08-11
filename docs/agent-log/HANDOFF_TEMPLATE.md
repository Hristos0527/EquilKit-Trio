# Handoff template (copy for every agent session end)

**Workstream:**  
**Branch:**  
**PR:**  
**Merge commit (master):**  
**Deployed:** yes / no — URL / version:  

## What changed

- 

## Before (live state — for rollback)

- Commit / version on production before this work:
- Backup path (if any):
- Rollback commands:

```bash
# paste exact revert/deploy commands
```

## Superseded / related branches

| Branch / PR | Status |
|-------------|--------|
| | merged / port pending / abandoned |

## Next agent MUST

1. `git pull origin master`
2. `./scripts/agent-continuity-check.sh`
3. Read this file + `docs/AGENT_STATUS.md`
4. Do **not** re-implement — continue from merge commit above

## User message (Hungarian, sent in chat)

> Kész: merge-elve a masterbe (`<sha>`), deploy: `<url>` `<version>`. Rollback: `<one line>`. PR: `<link>`.
