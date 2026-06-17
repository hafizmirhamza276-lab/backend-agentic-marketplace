---
name: apply-change
description: "Implement an APPROVED plan (.claude/builder/PLAN.md) exactly as written — edit only the files listed in the plan's Scope, follow the conventions recorded in MEMORY.md, keep diffs minimal, and produce a change report. Use only after the orchestrator has rated the plan 9+/10 and validate-plan.sh has passed. The PreToolUse scope guard will block any edit outside the plan."
---

# apply-change

You implement; you do not re-plan and you do not expand scope.

## Always-on standards (non-negotiable, load these FIRST — Cursor "Always" rules)
Before touching code, load a short **standards block** and keep it in view for every edit —
these are not optional and they override your own stylistic instincts:
- **MEMORY.md "Conventions to follow"** — the codebase's actual naming, error-handling,
  logging, config, data-access, and layering patterns. Mirror them; do not introduce a new style.
- **MEMORY.md "Risk map & gotchas" invariants** — the assumptions that must hold; the
  "if you change X, watch Y" notes. Preserve every one that touches your change.
- **`.claude/builder/STANDARDS.md`** if it exists (project-specific coding standards).
- The **per-edit feedback loop** (PostToolUse `lint-feedback.sh`) re-checks each file you
  write and feeds lint/type errors back as `additionalContext`. Treat that feedback as part
  of the standards: **fix what it surfaces before moving on** — don't accumulate lint debt.

## Preconditions (assume the orchestrator checked, but verify)
- `.claude/builder/PLAN.md` exists and is the approved plan.
- The change matches the plan's Goal and the spec. If reality contradicts the
  plan (e.g. a cited `path:line` no longer matches), STOP and report back — do
  not improvise. The plan goes back to planning.

## Rules
1. **Scope is law.** Edit only files in the plan's `## Scope` list. The PreToolUse guard blocks the rest; if you hit a real need to touch something new, stop and ask the orchestrator to amend the plan + re-confirm with the user.
2. **Match the codebase (explore before change).** Before writing or altering code, locate the existing pattern for what you're adding and grep for **all callers/usages** of any symbol you change (start from the task's `Existing pattern:` line + MEMORY.md, then ripgrep concrete symbols). Follow the established pattern — never invent a parallel one — and update/verify every caller a change affects. Mirror neighboring code; do not introduce a new style.
3. **Minimal, reviewable diffs.** Smallest change that satisfies the spec. No drive-by refactors, no reformatting unrelated lines, no "while I'm here" extras — not 1% beyond the spec.
4. **Preserve invariants.** Honor every invariant the plan listed from MEMORY.md's risk map.
5. **Tests.** If the plan's test strategy names existing tests or a harness, add/adjust tests alongside the change. (Running them is QA's job — see qa-verify.)

## Task-by-task (when `micro_decomposition` is on — the default)
The orchestrator dispatches you per task (or a small batch of tightly-related tasks), passing
ONLY that task's `## Tasks` block — its intent, `Files/functions`, `Behavior`, `Edge cases`,
and `Definition of Done`. Keep your focus on that one unit; do not pull the rest of the plan
into view (small context is what stops a boundary case slipping).

For each task:
1. Implement the `Behavior` precisely, and write code that **explicitly handles EVERY
   enumerated edge case** — fail-closed where a check can't decide (default to the SAFE
   outcome; a guard that errors must BLOCK, not allow).
2. Self-verify the task against its `Definition of Done` BEFORE moving on — do not start the
   next task while this one's edges are unhandled.
3. Stay in Scope; if reality contradicts the task, STOP and report (it goes back to planning).

## Output
- The code edits themselves (only within scope).
- Append a **change report** to `.claude/builder/CHANGELOG.md`:
  - spec id, plan step(s) / task id(s) implemented, exact files + functions touched
    (path:line), new/changed tests, and anything that diverged from the plan and why.
- Append a per-task **edge-case coverage map** to `.claude/builder/CHANGELOG.md` (when
  `micro_decomposition` is on). Lead each task's map with the **structured coverage header**
  below, verbatim — emit **one `### Task <id> — edge-case coverage` header per PLAN task id**.
  This exact H3 header (an H3 that names `Task <id>` and contains the word `coverage`) is the
  marker the release gate `plugins/pipeline/scripts/verify-release.sh` scans for to count a PLAN
  task as covered; a bare in-prose "Task <id>" mention does **not** satisfy the gate, so the
  header is mandatory, not decorative. Every enumerated edge case then gets exactly one line —
  **no silent skips**:
  ```
  ### Task <id> — edge-case coverage
  - <case> → handled at <file:line>
  - <case> → covered by <test name>
  - <case> → DEFERRED: <reason it is safe to defer>
  ```
  An unhandled case is either handled or explicitly `DEFERRED:` with a reason — never dropped.
  QA reads this map; anything neither handled nor justifiably deferred is a defect.

## Return to orchestrator (≤10 lines)
Done/blocked; files changed (paths); tests added/changed; any divergence from
the plan. Detail stays in CHANGELOG.md to keep the orchestrator's context lean.
