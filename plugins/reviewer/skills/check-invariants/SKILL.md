---
name: check-invariants
description: The severity taxonomy for change-review findings — how to assign BLOCKING / CONCERN / NOTE so the release gate enforces the right things and never false-blocks, and how to ground invariant/risk reasoning in the explorer MEMORY.md. Use when a reviewer sub-agent or /reviewer:run records a finding.
---

# Classify a change-review finding's severity

Severity decides what GATES. The pipeline release gate enforces **0 BLOCKING**; CONCERN is
recorded but does not block; NOTE is informational and excluded from the tally. Assign
deliberately — an inflated BLOCKING blocks a clean change; a buried BLOCKING ships a real breakage.

Ground every judgment in the explorer memory. `.claude/explorer/MEMORY.md` records the
**invariants** ("<assumption> — breaks if: <…>") and the **Risk map**
("- <area> — <risk> — <severity> — <evidence>"). A finding is strongest when it cites the exact
invariant the change violates, with `path:line` evidence from the diff.

## BLOCKING — the change breaks something concrete
Use for: a dangling caller, a dropped safety contract, or a violated invariant the codebase
relies on to stay correct.
- A function REMOVED/RENAMED in the diff that still has surviving call-sites. [R1]
- A changed `.sh` that dropped `set -uo pipefail`, stopped sourcing `../lib/common.sh`, or
  (re)introduced `set -e` — the house preamble that prevents fail-open. [R2]
- (Sub-agents) the change violates an invariant the explorer memory says must hold; a
  producer/consumer contract drift that silently mis-feeds a gate (e.g. a STATUS key renamed on
  one side only); a destructive op a refactor introduced without a guard.

## CONCERN — warrants a human look, does NOT hard-block
Use for: risk-mapped surface and scope discipline.
- A changed file named in the explorer `MEMORY.md` Risk map — re-read the recorded risk. [R3]
- A changed file outside the approved `PLAN.md` Scope — possible scope creep. [R4]
- (Sub-agents) a plausible-but-unproven invariant concern; a behavioral change that is probably
  fine but deserves a second reader; missing test coverage for the changed path.

## NOTE — informational only (NEVER gates; EXCLUDED from the tally)
Use for stylistic observations and context that should travel with the review without affecting
the verdict: a naming nit, a "consider documenting this", a heads-up for the next reader.

## Tie-breakers
- "Does this change leave a caller broken, drop a fail-open guard, or violate a must-hold
  invariant?" → **BLOCKING**.
- "Is it on recorded-risk surface, or outside the approved scope, or a real-but-soft concern?"
  → **CONCERN**.
- "Is it cosmetic or a heads-up?" → **NOTE**.
- When uncertain between BLOCKING and CONCERN, prefer **CONCERN** unless you can name the concrete
  breakage (the dangling caller, the dropped contract, the violated invariant) — the gate must
  stay trustworthy, not trigger-happy.
