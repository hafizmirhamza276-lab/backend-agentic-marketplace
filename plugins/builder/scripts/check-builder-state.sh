#!/usr/bin/env bash
# check-builder-state.sh — SessionStart gate (advisory).
# 1) bootstrap .claude/builder/settings.json with safe defaults (once)
# 2) verify explorer memory exists & is fresh (builder depends on it)
# 3) nudge the orchestrator to RECALL rather than re-scan
# NOT errexit (F-A4): a SessionStart gate under `set -e` aborts on the first unexpected non-zero
# (a grep no-match, git in a non-repo, a bd_ helper returning 1) and the nudges below never emit.
set -uo pipefail
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
  "auto_run_tests": "ask",
  "micro_decomposition": true,
  "require_edge_case_coverage": true,
  "feedback_loop": true,
  "feedback_enforce": false,
  "feedback_run_tests": "ask",
  "bugfix_mode": "auto",
  "require_reproduction": true,
  "require_characterization": true,
  "bugfix_enforce": false,
  "bugfix_diagnosis_tier": "critical"
}
JSON
  bd_tell "initialized .claude/builder/settings.json (edit to tune gates / cost)"
fi

# Fresh slate for the per-edit feedback loop: lint debt is tracked within a session
# (records accrue from this session's edits), so clear last session's records.
rm -rf "$BUILDER_DIR/feedback" 2>/dev/null || true

# Cheap static context (Cursor "always" grounding) -> STDOUT so the orchestrator
# starts grounded without spending a turn re-deriving it.
PROJECT="$(bd_project_dir)"
OS_NAME="$(uname -s 2>/dev/null || printf '%s' "${OSTYPE:-unknown}")"
if bd_have git && git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BR="$(git -C "$PROJECT" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '?')"
  DIRTY="$(git -C "$PROJECT" status --porcelain 2>/dev/null | grep -c . || true)"
  if [ "${DIRTY:-0}" -gt 0 ]; then STATE="dirty (${DIRTY} change(s))"; else STATE="clean"; fi
  bd_tell "context: OS=${OS_NAME} · branch=${BR} · working tree ${STATE}"
  CHANGED="$(git -C "$PROJECT" diff --name-only HEAD 2>/dev/null | head -n 8 | tr '\n' ' ' || true)"
  [ -n "$CHANGED" ] && bd_tell "recently changed: ${CHANGED}"
else
  bd_tell "context: OS=${OS_NAME} · not a git work tree"
fi

# 2) explorer memory dependency
if [ ! -f "$EXPLORER_MEM" ]; then
  bd_tellwarn "no explorer memory at .claude/explorer/MEMORY.md — run /explorer:start before building."
  exit 0
fi

# `|| true`: a MEMORY.md without an explored_commit: line makes the grep pipeline exit
# non-zero, which under `set -euo pipefail` would abort the hook and skip the recall
# nudge below (F8).
EXPLORED_COMMIT="$(grep -oE 'explored_commit:[[:space:]]*[A-Za-z0-9]+' "$EXPLORER_MEM" 2>/dev/null | head -n1 | sed -E 's/.*:[[:space:]]*//' || true)"
HEAD="$(bd_git_head)"
if [ -n "$EXPLORED_COMMIT" ] && [ "$HEAD" != "unknown" ] && [ "$EXPLORED_COMMIT" != "$HEAD" ]; then
  bd_tellwarn "explorer memory is STALE (explored=$EXPLORED_COMMIT, HEAD=$HEAD). Re-run /explorer:start so the plan is grounded in current code."
fi

# 3) recall nudge — SessionStart context goes to STDOUT so Claude actually ingests it (F6).
bd_tell "builder ready. RECALL .claude/explorer/* via the context-finder sub-agent — do not re-scan the codebase."
if [ -f "$(bd_plan)" ]; then
  bd_tell "an in-progress plan exists at .claude/builder/PLAN.md — review it before starting new work."
fi
# Bug-fix mode: a lingering Bug Brief means reproduce-first may gate source edits
# (guard-bugfix.sh). Surface it so a stale Brief from a finished/abandoned bug is noticed.
if [ -f "$(bd_bug)" ]; then
  bd_tell "a Bug Brief exists at .claude/builder/BUG.md — BUG-FIX MODE is engaged (reproduce-first guard active). Resume the fix, or remove BUG.md if you're not fixing a bug."
fi
exit 0
