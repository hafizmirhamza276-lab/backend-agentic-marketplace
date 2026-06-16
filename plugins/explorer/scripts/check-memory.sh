#!/usr/bin/env bash
# SessionStart: if a codebase memory exists, tell Claude to READ it (recall) instead of
# re-exploring, and warn if it is stale vs the current commit. Never blocks the session.
#
# ALL guidance goes to STDOUT: SessionStart injects stdout into Claude's context, while
# stderr is surfaced only with --verbose. Shared helpers come from the vendored
# lib/common.sh. We keep `set -uo pipefail` (NOT -e).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SELF_DIR/../lib/common.sh"

PROJECT_DIR="$(bd_project_dir)"
MEM="$PROJECT_DIR/.claude/explorer/MEMORY.md"

if [[ ! -f "$MEM" ]]; then
  echo "[explorer] No codebase memory found at .claude/explorer/MEMORY.md. Run /explorer:start to create one."
  exit 0
fi

explored_commit="$(grep -m1 '^explored_commit:' "$MEM" 2>/dev/null | sed 's/^explored_commit:[[:space:]]*//')"
# Compare against the FULL HEAD: explored_commit is a full SHA (the recall-codebase skill
# compares it to `git rev-parse HEAD`). bd_git_head returns the SHORT head / "unknown",
# which would never equal a full SHA — so we read full HEAD here, guarded by bd_have, and
# keep the empty-string fallback that makes the staleness check skip when git is absent.
if bd_have git; then
  current_commit="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo '')"
else
  current_commit=""
fi

echo "[explorer] Codebase memory EXISTS. Read .claude/explorer/MEMORY.md (use the recall-codebase skill) before exploring."
if [[ -n "$explored_commit" && -n "$current_commit" ]]; then
  if [[ "$explored_commit" == "$current_commit" ]]; then
    echo "[explorer] Memory is CURRENT (commit $current_commit). No re-exploration needed."
  else
    echo "[explorer] Memory may be STALE: explored=$explored_commit current=$current_commit. Run: git diff --name-only $explored_commit HEAD, then /explorer:start for an incremental refresh if relevant files changed."
  fi
fi
exit 0
