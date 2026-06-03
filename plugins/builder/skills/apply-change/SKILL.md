---
name: apply-change
description: "Implement an APPROVED plan (.claude/builder/PLAN.md) exactly as written — edit only the files listed in the plan's Scope, follow the conventions recorded in MEMORY.md, keep diffs minimal, and produce a change report. Use only after the orchestrator has rated the plan 9+/10 and validate-plan.sh has passed. The PreToolUse scope guard will block any edit outside the plan."
---

# apply-change

You implement; you do not re-plan and you do not expand scope.

## Preconditions (assume the orchestrator checked, but verify)
- `.claude/builder/PLAN.md` exists and is the approved plan.
- The change matches the plan's Goal and the spec. If reality contradicts the
  plan (e.g. a cited `path:line` no longer matches), STOP and report back — do
  not improvise. The plan goes back to planning.

## Rules
1. **Scope is law.** Edit only files in the plan's `## Scope` list. The PreToolUse guard blocks the rest; if you hit a real need to touch something new, stop and ask the orchestrator to amend the plan + re-confirm with the user.
2. **Match the codebase.** Follow the conventions in MEMORY.md (naming, error-handling style, data-access pattern, layering). Do not introduce a new style. Mirror neighboring code.
3. **Minimal, reviewable diffs.** Smallest change that satisfies the spec. No drive-by refactors, no reformatting unrelated lines, no "while I'm here" extras — not 1% beyond the spec.
4. **Preserve invariants.** Honor every invariant the plan listed from MEMORY.md's risk map.
5. **Tests.** If the plan's test strategy names existing tests or a harness, add/adjust tests alongside the change. (Running them is QA's job — see qa-verify.)

## Output
- The code edits themselves (only within scope).
- Append a **change report** to `.claude/builder/CHANGELOG.md`:
  - spec id, plan step(s) implemented, exact files + functions touched (path:line),
    new/changed tests, and anything that diverged from the plan and why.

## Return to orchestrator (≤10 lines)
Done/blocked; files changed (paths); tests added/changed; any divergence from
the plan. Detail stays in CHANGELOG.md to keep the orchestrator's context lean.
