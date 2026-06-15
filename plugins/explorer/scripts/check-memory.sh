#!/usr/bin/env bash
# SessionStart: if a codebase memory exists, tell Claude to READ it (recall) instead of
# re-exploring, and warn if it is stale vs the current commit. Never blocks the session.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
MEM="$PROJECT_DIR/.claude/explorer/MEMORY.md"

if [[ ! -f "$MEM" ]]; then
  echo "[explorer] No codebase memory found at .claude/explorer/MEMORY.md. Run /explorer:start to create one."
  exit 0
fi

explored_commit="$(grep -m1 '^explored_commit:' "$MEM" 2>/dev/null | sed 's/^explored_commit:[[:space:]]*//')"
current_commit="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo '')"

echo "[explorer] Codebase memory EXISTS. Read .claude/explorer/MEMORY.md (use the recall-codebase skill) before exploring."
if [[ -n "$explored_commit" && -n "$current_commit" ]]; then
  if [[ "$explored_commit" == "$current_commit" ]]; then
    echo "[explorer] Memory is CURRENT (commit $current_commit). No re-exploration needed."
  else
    echo "[explorer] Memory may be STALE: explored=$explored_commit current=$current_commit. Run: git diff --name-only $explored_commit HEAD, then /explorer:start for an incremental refresh if relevant files changed."
  fi
fi
exit 0
