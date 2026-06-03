#!/usr/bin/env bash
# validate-plan.sh — deterministic floor under the orchestrator's 9+/10 rating.
# The LLM rating is non-deterministic; this script enforces the structural
# minimums a plan MUST satisfy regardless of how the model "feels" about it.
#
# Usage: validate-plan.sh [path-to-PLAN.md]   (defaults to .claude/builder/PLAN.md)
# Exit 0 = structurally valid; exit 1 = fails (orchestrator must send it back).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"

PLAN="${1:-$(bd_plan)}"
EXPLORER_MEM="$(bd_explorer_dir)/MEMORY.md"
fail=0
note() { printf '  - %s\n' "$*" >&2; }

if [ ! -f "$PLAN" ]; then
  bd_warn "validate-plan: no plan file at $PLAN"; exit 1
fi
bd_say "validating plan: $PLAN"

# 1) clarity score present and >= threshold
THRESH="$(bd_setting clarity_threshold 9)"
CLARITY="$(grep -oiE 'clarity[^0-9]*([0-9]{1,2})' "$PLAN" | grep -oE '[0-9]{1,2}' | head -n1 || true)"
if [ -z "$CLARITY" ]; then
  note "missing 'Clarity: N/10' line"; fail=1
elif [ "$CLARITY" -lt "$THRESH" ]; then
  note "clarity $CLARITY/10 is below threshold $THRESH — do not implement; raise concerns with the user"; fail=1
fi

# 2) a Scope section with at least one file path
if ! awk '/^#{1,6}[[:space:]].*[Ss]cope/{g=1;next}/^#{1,6}[[:space:]]/{g=0}g&&/^[[:space:]]*[-*][[:space:]]/{c++}END{exit !(c>0)}' "$PLAN"; then
  note "Scope section has no file list (need '## Scope' with '- path' bullets)"; fail=1
fi

# 3) at least one path:line evidence citation (file.ext:NN)
if ! grep -qE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+:[0-9]+' "$PLAN"; then
  note "no path:line evidence citations found (cite where in the code you rely on)"; fail=1
fi

# 4) a Risks/Invariants section that references the explorer memory
if ! grep -qiE '^#{1,6}[[:space:]].*(risk|invariant|gotcha)' "$PLAN"; then
  note "missing a Risks / Invariants section"; fail=1
fi
if [ -f "$EXPLORER_MEM" ] && ! grep -qiE 'MEMORY\.md|risk map|invariant' "$PLAN"; then
  note "plan does not reference MEMORY.md risks/invariants — confirm the change respects them"; fail=1
fi

if [ "$fail" -ne 0 ]; then
  bd_warn "plan FAILED structural validation (see above). Return exact items to the planner."
  exit 1
fi
bd_say "plan passed structural validation."
exit 0
