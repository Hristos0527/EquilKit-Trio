#!/usr/bin/env bash
# Install repo git hooks (one-time per clone). No agent paste required.
#
# Usage:
#   ./scripts/install-git-hooks.sh
#   ./scripts/install-git-hooks.sh --strict   # block push on critical continuity issues

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_SRC="$ROOT/scripts/git-hooks"
GIT_HOOKS="$ROOT/.git/hooks"
STRICT=false

for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=true ;;
  esac
done

mkdir -p "$GIT_HOOKS"

install_hook() {
  local name="$1"
  local src="$HOOKS_SRC/$name"
  local dest="$GIT_HOOKS/$name"
  if [[ ! -f "$src" ]]; then
    echo "Missing $src" >&2
    exit 1
  fi
  cp "$src" "$dest"
  chmod +x "$dest"
  echo "Installed $dest"
}

install_hook pre-push

if $STRICT; then
  # Patch pre-push to use --strict (simple marker file)
  echo "strict" > "$ROOT/.git/hooks/.continuity-strict"
else
  rm -f "$ROOT/.git/hooks/.continuity-strict"
fi

echo ""
echo "Git hooks installed. Agents and humans get continuity reminders on git push."
echo "Optional stricter mode: ./scripts/install-git-hooks.sh --strict"
