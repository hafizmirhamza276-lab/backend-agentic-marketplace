---
name: micro-decompose
description: "Decompose a requirement into the smallest INDEPENDENTLY-VERIFIABLE units, then harden each with an explicit edge-case enumeration drawn from a fixed taxonomy plus the codebase-specific risks in MEMORY.md. Use during planning (to write the PLAN.md '## Tasks' breakdown) and during implementation/QA (to drive and verify the edge-case coverage map). Proportional by design: a one-line change is ONE task — never explode a trivial spec into dozens of tasks."
---

# micro-decompose

Large context is where small edge-case bugs hide: when a change is reasoned about
all-at-once, the boundary case gets lost behind the architecture. This skill fixes that by
(1) splitting a requirement into atomic, **independently-verifiable** tasks, and (2) forcing
every task's edge cases **onto the page** — never left only in the model's head — so they can
be implemented, traced to code/tests, and gated deterministically.

It is used in three places: the **planner** writes the breakdown into `PLAN.md`; the
**implementer** works it task-by-task and records a coverage map; **QA** verifies that map.

## Part 1 — Right-sized decomposition (proportionality is a HARD rule)

Split a requirement only as far as **each unit is independently verifiable** — no further.

- A unit is one **behavior** you could write a focused test for and check on its own.
- **A one-line change is ONE task.** A rename is ONE task. A config flip is ONE task. Never
  manufacture subtasks to look thorough.
- Split when a step has its own distinct success/failure criteria, its own edge cases, or
  touches a different symbol with a different contract.
- Do NOT split for its own sake. If two candidate tasks always pass or fail together and
  share the same edge cases, they are **ONE** task. **Over-splitting is a defect** — it
  fragments review, inflates cost, and hides the real seams.
- Calibration: the task count should track the number of **distinct behaviors** in the spec,
  not the lines of code. Trivial spec → 1–2 tasks. If a breakdown wants many tasks for a
  small spec, collapse it; if the spec genuinely needs many, say so in Assumptions — it is
  usually several specs wearing a trench coat.

Each task carries only **its own** intent + edge-case list, so the implementer can work it
with a small, focused context. That small context is the entire point: it is what stops a
boundary case from slipping while attention is elsewhere.

## Part 2 — Edge-case taxonomy (apply to EVERY task, then extend from MEMORY.md)

For each task, walk this taxonomy and keep the categories that genuinely apply to *that
task's* inputs, state, and contracts. Drop the irrelevant ones — don't pad. Then **extend**
with codebase-specific cases pulled from MEMORY.md's risk map / invariants, and cite them by
name so the link is auditable.

- **Inputs / boundaries:** empty, null/None, zero, negative, max / overflow, single-element,
  very large, malformed, wrong type, unicode / encoding, leading/trailing whitespace.
- **State / lifecycle:** uninitialized, already-exists, idempotency, re-entrancy, ordering,
  partial completion + rollback, concurrency / races, atomicity.
- **IO / external:** timeout, network / partial failure, retry, rate limit, missing file /
  permission, resource exhaustion, cleanup / leaks.
- **Errors:** exception propagation, clear error surfacing, and explicitly **FAIL-OPEN vs
  FAIL-CLOSED** — a guard or check that errors must default to the SAFE outcome. (This
  project was bitten by a fail-open guard: a parser crash let edits through. A check that
  cannot decide must BLOCK, not allow.)
- **Numeric:** off-by-one, overflow / underflow, float precision, divide-by-zero, rounding.
- **Security:** injection, path traversal, authz / authn, untrusted input, secrets in logs.
- **Portability / compat:** OS differences (this project was bitten by a Windows-only
  interpreter bug), language / runtime versions, locale, timezones, line endings.
- **Contract / invariants:** pre/postconditions, the **MEMORY.md invariants**, backward
  compatibility, API / data-shape contracts.

For each kept case, state the **intended handling**, not just the risk. "null order → throw
`ArgumentNullException` before any state mutation" beats "handle nulls." A case with no
handling is not enumerated — it is a TODO in disguise.

## Part 3 — Where this lands (the artifacts and the gate)

- **Planner** writes the breakdown into `.claude/builder/PLAN.md` under `## Tasks`, one block
  per task (schema below). `validate-plan.sh` deterministically requires — when
  `micro_decomposition` is on — a `## Tasks` section with ≥1 block, and that **each** block
  carries a non-empty `Edge cases:` list **and** a `Definition of Done:`. It names the exact
  offending task id when one is incomplete.
- **Implementer** works task-by-task and records an **edge-case coverage map** in
  `.claude/builder/CHANGELOG.md`: every enumerated case → `handled at file:line` |
  `covered by <test>` | `DEFERRED: <reason>`. No silent skips — an unhandled case is either
  handled or explicitly deferred with a reason.
- **QA** verifies that map: every case handled or justifiably deferred, flagging any that are
  neither. The QA score must reflect edge-case coverage, not just that the build is green.

### PLAN.md `## Tasks` block schema (FIXED — the gate parses it)
```
### Task <id> — <short intent>
- Files/functions: <exact repo-relative paths / symbols this unit touches>
- Behavior: <precise input → output; the ONE thing this unit does>
- Edge cases:
  - <case> → <intended handling>          (≥1 bullet; name any MEMORY.md risks you pulled in)
- Definition of Done: <observable, testable completion — includes the edge coverage, not just "compiles">
```
Keep ids stable and short (`1`, `2`, … or `1.1`) so the coverage map and QA can refer back to
them. When `micro_decomposition` is off, skip the breakdown and use the single-pass flow.
