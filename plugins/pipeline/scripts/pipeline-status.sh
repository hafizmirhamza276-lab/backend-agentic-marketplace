#!/usr/bin/env bash
# pipeline-status.sh — consolidated conductor dashboard.
#
# Runs as the pipeline plugin's SessionStart hook (so its output goes to STDOUT and is
# injected into Claude's context) and provides the semantics behind /pipeline:status. It
# reads each module's STATUS.json via the bd_status_read contract and prints one row per
# module — module · phase · state · coverage · freshness/updated — plus explorer memory
# freshness vs the current commit.
#
# It is purely a reporter: it ALWAYS exits 0 and NEVER crashes when a STATUS file is absent
# (bd_status_read returns "" for a missing file/key). NOT `set -e`.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"

PROJECT="$(bd_project_dir)"

# Current full HEAD (for explorer freshness). Empty when git is unavailable.
HEAD_FULL=""
if bd_have git && git -C "$PROJECT" rev-parse HEAD >/dev/null 2>&1; then
  HEAD_FULL="$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null || printf '')"
fi

# explorer freshness from MEMORY.md's explored_commit (accepts a short-SHA prefix).
explorer_freshness() {
  local mem="$(bd_explorer_dir)/MEMORY.md" explored
  [ -f "$mem" ] || { printf 'no-memory'; return; }
  explored="$(grep -oE '^explored_commit:[[:space:]]*[A-Za-z0-9]+' "$mem" 2>/dev/null | head -n1 | sed -E 's/^explored_commit:[[:space:]]*//' || true)"
  [ -n "$explored" ] || { printf 'memory(no-commit)'; return; }
  [ -n "$HEAD_FULL" ] || { printf 'memory(git?)'; return; }
  case "$HEAD_FULL" in "$explored"*) printf 'current' ;; *) printf 'STALE' ;; esac
}

# row <module> <extra-freshness-or-->
row() {
  local m="$1" extra="$2" phase state cov updated
  phase="$(bd_status_read "$m" phase 2>/dev/null || true)"
  state="$(bd_status_read "$m" state 2>/dev/null || true)"
  cov="$(bd_status_read "$m" coverage 2>/dev/null || true)"
  updated="$(bd_status_read "$m" updated_at 2>/dev/null || true)"
  [ -n "$state" ] || state="(no STATUS)"
  [ -n "$phase" ] || phase="-"
  [ -n "$cov" ] || cov="-"
  [ -n "$updated" ] || updated="-"
  printf '  %-9s %-12s %-9s %-9s %-10s %s\n' "$m" "$phase" "$state" "$cov" "$extra" "$updated"
}

printf '[pipeline] consolidated status dashboard\n'
printf '  %-9s %-12s %-9s %-9s %-10s %s\n' "MODULE" "PHASE" "STATE" "COVERAGE" "FRESHNESS" "UPDATED"
row explorer "$(explorer_freshness)"
row builder  "-"
row pipeline "-"

# A one-line nudge so a fresh session knows the entry points (SessionStart context).
if [ ! -f "$(bd_explorer_dir)/MEMORY.md" ]; then
  printf '[pipeline] no explorer memory yet — /pipeline:run will bootstrap exploration first.\n'
fi
printf '[pipeline] commands: /pipeline:run "<spec>" · /pipeline:fix "<bug>" · /pipeline:status\n'
exit 0
