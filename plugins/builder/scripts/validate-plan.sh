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

# 5) micro-decomposition floor (only when enabled): a '## Tasks' section with >=1
# '### Task <id>' block, and EACH block carries a non-empty 'Edge cases:' list AND
# a 'Definition of Done:'. One task is valid — no minimum count. awk emits one
# human-readable problem line per offending task id (or a section-level problem);
# any output means the floor failed. Reuses the awk/grep style of the checks above;
# no python needed (the working-interpreter detection in common.sh stays optional).
if [ "$(bd_setting micro_decomposition true)" = "true" ]; then
  while IFS= read -r problem; do
    [ -n "$problem" ] || continue
    note "$problem"; fail=1
  done < <(awk '
    function endtask(){
      if(cur!=""){
        ntasks++
        if(ec<1)       printf("Task %s — empty or missing \"Edge cases:\" list\n", cur)
        else if(!dod)  printf("Task %s — missing \"Definition of Done:\"\n", cur)
      }
      cur=""; ec=0; ecmode=0; dod=0
    }
    # level-2 heading toggles the Tasks section (### is level-3, excluded)
    /^##[[:space:]]/ && $0 !~ /^###/ { endtask(); if($0 ~ /[Tt]asks/){intasks=1;seen=1}else intasks=0; next }
    # level-3 heading inside Tasks starts a task block; capture the id (first token)
    /^###[[:space:]]/ {
      endtask()
      if(intasks){ l=$0; sub(/^###[[:space:]]+/,"",l); sub(/^[Tt]ask[[:space:]]+/,"",l); sub(/[[:space:]].*$/,"",l); cur=l }
      next
    }
    intasks && cur!="" {
      if($0 ~ /[Ee]dge[[:space:]]+cases[[:space:]]*:/){
        ecmode=1; t=$0; sub(/.*[Ee]dge[[:space:]]+cases[[:space:]]*:/,"",t); gsub(/[[:space:]]/,"",t); if(t!="")ec++; next
      }
      if($0 ~ /[Dd]efinition[[:space:]]+of[[:space:]]+[Dd]one[[:space:]]*:/){
        ecmode=0; t=$0; sub(/.*[Dd]one[[:space:]]*:/,"",t); gsub(/[[:space:]]/,"",t); if(t!="")dod=1; next
      }
      if(ecmode && $0 ~ /^[[:space:]]+[-*][[:space:]]+[^[:space:]]/){ ec++; next }   # an edge-case sub-bullet
      if($0 ~ /^[-*][[:space:]]/){ ecmode=0 }                                        # a new top-level field ends the list
    }
    END{
      endtask()
      if(!seen)            print "micro_decomposition is on but PLAN.md has no \"## Tasks\" section (set micro_decomposition=false for single-pass)"
      else if(ntasks<1)    print "\"## Tasks\" section has no \"### Task <id>\" blocks"
    }
  ' "$PLAN")
fi

if [ "$fail" -ne 0 ]; then
  bd_warn "plan FAILED structural validation (see above). Return exact items to the planner."
  exit 1
fi
bd_say "plan passed structural validation."
exit 0
