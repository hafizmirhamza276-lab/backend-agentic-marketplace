#!/usr/bin/env bash
# check-builder-state.sh — SessionStart gate (advisory).
# 1) bootstrap .claude/builder/settings.json with safe defaults (once)
# 2) verify explorer memory exists & is fresh (builder depends on it)
# 3) nudge the orchestrator to RECALL rather than re-scan
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"

BUILDER_DIR="$(bd_builder_dir)"
EXPLORER_MEM="$(bd_explorer_dir)/MEMORY.md"
SETTINGS="$(bd_settings)"

mkdir -p "$BUILDER_DIR" "$(bd_specs_dir)" 2>/dev/null || true

# 1) bootstrap settings.json (defaults; never overwrite an existing file)
if [ ! -f "$SETTINGS" ]; then
  cat > "$SETTINGS" <<'JSON'
{
  "opus_escalation": true,
  "max_planner_loops": 2,
  "max_qa_loops": 2,
  "rating_threshold": 9,
  "clarity_threshold": 9,
  "enforce_gates": false,
  "auto_run_tests": "ask"
}
JSON
  bd_say "initialized .claude/builder/settings.json (edit to tune gates / cost)"
fi

# 2) explorer memory dependency
if [ ! -f "$EXPLORER_MEM" ]; then
  bd_warn "no explorer memory at .claude/explorer/MEMORY.md — run /explorer:start before building."
  exit 0
fi

EXPLORED_COMMIT="$(grep -oE 'explored_commit:[[:space:]]*[A-Za-z0-9]+' "$EXPLORER_MEM" 2>/dev/null | head -n1 | sed -E 's/.*:[[:space:]]*//')"
HEAD="$(bd_git_head)"
if [ -n "$EXPLORED_COMMIT" ] && [ "$HEAD" != "unknown" ] && [ "$EXPLORED_COMMIT" != "$HEAD" ]; then
  bd_warn "explorer memory is STALE (explored=$EXPLORED_COMMIT, HEAD=$HEAD). Re-run /explorer:start so the plan is grounded in current code."
fi

# 3) recall nudge
bd_say "builder ready. RECALL .claude/explorer/* via the context-finder sub-agent — do not re-scan the codebase."
if [ -f "$(bd_plan)" ]; then
  bd_say "an in-progress plan exists at .claude/builder/PLAN.md — review it before starting new work."
fi
exit 0
