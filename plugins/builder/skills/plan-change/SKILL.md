---
name: plan-change
description: "Turn a spec (.claude/specs/specN.md) plus the explorer memory into (a) a clarity rating out of 10 and (b) a technical implementation plan that the orchestrator can rate. Use after recall-memory, before any code is written. Enforces evidence-first planning: every claim cites path:line, scope is an explicit file list, and the plan must respect the invariants and risks recorded in MEMORY.md. Used by both the Sonnet planner and the Opus escalation planner."
---

# plan-change

Two outputs, in order: a **clarity rating**, then (only if clear enough) a
**technical plan**.

## Step 1 — Clarity rating (gate, do not skip)
You already hold the full codebase context (via recall-memory). Read every
`.claude/specs/specN.md` in scope. Rate how confidently the spec can be
implemented **in the right place, without guessing**, 0–10:

- **9–10** — unambiguous *what* and *where*; you can name the exact files/symbols to change and predict the blast radius.
- **6–8** — intent clear but location/edge-cases uncertain; implementing now risks touching the wrong place.
- **≤5** — underspecified; high chance of "small mistake, whole-codebase damage."

If clarity **< threshold** (default 9, from `.claude/builder/settings.json`):
do **not** plan. Return the specific blocking questions and *why each matters in
code terms* (e.g. "spec says 'update the auth check' — RBAC lives in custom
middleware at `Startup.cs:228` AND per-controller attributes; which layer?").
The orchestrator surfaces these to the user; nothing is written until answered.

## Step 2 — Technical plan (only if clarity ≥ threshold)
Write to `.claude/builder/PLAN.md`. Required sections (the deterministic gate
`validate-plan.sh` checks these — missing any sends the plan back):

```
# builder plan — <spec id / short title>

Clarity: N/10

## Goal
What the spec asks for, in one or two sentences. No scope beyond the spec — not 1% extra.

## Scope (files this change may touch)
- path/to/file.ext        <- exact repo-relative paths, one per bullet, path first
- path/to/other.ext
(The PreToolUse guard blocks edits to anything not listed here.)

## Approach
Ordered steps. Each step cites evidence as path:line for anything it relies on
(e.g. "extend the handler at OrderService.cs:142"). Separate EVIDENCE (seen in
code) from INFERENCE (assumed) explicitly.

## Risks & invariants (from MEMORY.md)
- Invariants this change must preserve (cite the MEMORY.md risk map).
- New risks this change introduces and how the plan mitigates them.

## Test strategy
How the change will be verified (feature-level cases incl. edge cases; what
app-level regression matters). Names the existing harness if one exists.

## Assumptions & open questions
Anything still uncertain. If this list is non-trivial, clarity was over-rated —
drop the score and return to Step 1.
```

## Honesty rules
- Never claim certainty you can't cite. "100% understood" is not allowed; state coverage and assumptions.
- Implement only what the spec says. If you notice an unrelated improvement, list it under Assumptions as a *suggestion for the user*, never silently add it.

## Return to orchestrator (keep it short, ≤10 lines)
Clarity score; if clear: the Scope file list + the single riskiest step + your
self-rating of the plan vs. spec/standards. The orchestrator re-rates and runs
`validate-plan.sh` before any implementation.
