#!/usr/bin/env bash
# Agent continuity check — find unmerged cursor/* branches and stale PRs.
#
# Usage:
#   ./scripts/agent-continuity-check.sh
#   ./scripts/agent-continuity-check.sh --strict   # exit 1 on critical findings
#   ./scripts/agent-continuity-check.sh --json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STRICT=false
JSON=false

for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=true ;;
    --json) JSON=true ;;
  esac
done

cd "$ROOT"

DEFAULT_BRANCH="master"
if git show-ref --verify --quiet refs/remotes/origin/main; then
  if ! git show-ref --verify --quiet refs/remotes/origin/master; then
    DEFAULT_BRANCH="main"
  fi
fi

git fetch origin "$DEFAULT_BRANCH" --quiet 2>/dev/null || true

WARNINGS=()
CRITICAL=()

# Uncommitted work
if ! git diff --quiet || ! git diff --cached --quiet; then
  CRITICAL+=("Uncommitted local changes — commit or stash before handoff")
fi

# Current branch behind default
CURRENT="$(git branch --show-current 2>/dev/null || echo "")"
if [[ -n "$CURRENT" && "$CURRENT" != "$DEFAULT_BRANCH" ]]; then
  BEHIND="$(git rev-list --count "HEAD..origin/${DEFAULT_BRANCH}" 2>/dev/null || echo 0)"
  if [[ "${BEHIND:-0}" -gt 0 ]]; then
    WARNINGS+=("Branch '$CURRENT' is ${BEHIND} commit(s) behind origin/${DEFAULT_BRANCH} — rebase or merge master")
  fi
  # Unpushed commits
  UNPUSHED="$(git rev-list --count "@{u}..HEAD" 2>/dev/null || echo 0)"
  if [[ "${UNPUSHED:-0}" -gt 0 ]]; then
    WARNINGS+=("Branch '$CURRENT' has ${UNPUSHED} unpushed commit(s)")
  fi
fi

# cursor/* branches not merged into default (remote)
while IFS= read -r branch; do
  [[ -z "$branch" ]] && continue
  short="${branch#origin/}"
  # Skip if merged
  if git merge-base --is-ancestor "$branch" "origin/${DEFAULT_BRANCH}" 2>/dev/null; then
    continue
  fi
  AHEAD="$(git rev-list --count "origin/${DEFAULT_BRANCH}..${branch}" 2>/dev/null || echo "?")"
  LAST="$(git log -1 --format='%cs %s' "$branch" 2>/dev/null || echo "?")"
  CRITICAL+=("Unmerged remote branch: ${short} (+${AHEAD} vs ${DEFAULT_BRANCH}) — last: ${LAST}")
done < <(git branch -r --list 'origin/cursor/*' 2>/dev/null | sed 's/^[[:space:]]*//' | grep -v HEAD || true)

# gh PR checks (optional)
if command -v gh >/dev/null 2>&1; then
  while IFS=$'\t' read -r num title draft updated; do
    [[ -z "$num" ]] && continue
    if [[ "$draft" == "true" ]]; then
      # Rough stale: updated field is ISO date
      WARNINGS+=("Draft PR #${num} still open: ${title}")
    fi
  done < <(gh pr list --state open --json number,title,isDraft,updatedAt \
    --jq '.[] | [.number, .title, .isDraft, .updatedAt] | @tsv' 2>/dev/null || true)
fi

# Required docs
for f in AGENTS.md docs/AGENT_CONTINUITY.md docs/AGENT_OPERATIONS.md; do
  if [[ ! -f "$ROOT/$f" ]]; then
    WARNINGS+=("Missing continuity doc: $f")
  fi
done

if $JSON; then
  printf '{"critical":%s,"warnings":%s}\n' \
    "$(printf '%s\n' "${CRITICAL[@]:-}" | jq -R -s -c 'split("\n") | map(select(length>0))')" \
    "$(printf '%s\n' "${WARNINGS[@]:-}" | jq -R -s -c 'split("\n") | map(select(length>0))')"
  if $STRICT && [[ ${#CRITICAL[@]} -gt 0 ]]; then exit 1; fi
  exit 0
fi

echo "=== Agent continuity check ==="
echo "Default branch: origin/${DEFAULT_BRANCH}"
echo "Current branch: ${CURRENT:-(detached)}"
echo ""

if [[ ${#CRITICAL[@]} -eq 0 && ${#WARNINGS[@]} -eq 0 ]]; then
  echo "OK — no critical continuity issues detected."
  echo "Reminder: session end still requires merge + deploy + agent log (see docs/AGENT_CONTINUITY.md)."
  exit 0
fi

if [[ ${#CRITICAL[@]} -gt 0 ]]; then
  echo "CRITICAL:"
  for item in "${CRITICAL[@]}"; do
    echo "  ✗ $item"
  done
  echo ""
fi

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo "WARNINGS:"
  for item in "${WARNINGS[@]}"; do
    echo "  ! $item"
  done
  echo ""
fi

echo "See docs/AGENT_CONTINUITY.md for recovery steps."

if $STRICT && [[ ${#CRITICAL[@]} -gt 0 ]]; then
  exit 1
fi
exit 0
