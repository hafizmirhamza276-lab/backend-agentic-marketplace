---
name: diagnose-bug
description: "BUG-FIX MODE: turn a vague, repro-less bug report (e.g. 'the search field is not working', empty repro steps) into a verified, regression-safe fix via a deterministic symptom→reproduce→root-cause→characterize→fix→regression-gate workflow. Use when a spec is a bug report (auto-detected by a 'Bug:'/symptom shape, or marked by the user). The fix's accuracy comes from a VERIFICATION NET — a failing reproduction + characterization tests + a regression gate — NOT from thinking budget; effort only improves diagnosis quality. Builds on explorer recall, micro-decompose, the per-edit feedback loop, and the scope guard."
---

# diagnose-bug — BUG-FIX MODE

A feature spec says *what to build*; a bug report says *something is wrong* — often vaguely,
with no steps to reproduce ("the search field is not working", repro steps empty). Guessing a
patch from a vague symptom is how a "fix" both misses the real defect and breaks a neighbor.

**Core principle (this is encoded in the gates, not just advised): the fix's accuracy comes
from a VERIFICATION NET, not from effort.** The net is three things:
1. a **failing reproduction** (ideally a test) that FAILS on the pre-fix code — the "red",
2. **characterization tests** that pin the current *correct* behavior of the blast radius — they
   are green before the fix and must stay green after,
3. a **regression gate** (`regression-gate.sh`) that deterministically proves repro red→green
   AND characterization/linked tests still green.

Higher effort (the critical diagnosis tier) buys a better *diagnosis*; the gates prove
*correctness and no-regression*. A fix with no failing repro is a guess, however confident.

## When this runs (detection)
`bugfix_mode` in `.claude/builder/settings.json`: `"auto"` (default), `"on"`, `"off"`.
- **auto** — treat a spec as a bug report when it has a bug/symptom shape: a leading `Bug:`
  marker, a `## Symptom` / `Symptom:` line, frontmatter `type: bug`, or wording like
  "not working / broken / error / regression / unexpected" with no build-a-feature intent.
- A user may also explicitly mark a spec as a bug (e.g. a `Bug:` line, or telling the
  orchestrator). `"on"` forces this workflow; `"off"` disables it (plain feature flow).

When engaged, run B0–B6 below **instead of** the plain feature flow. Stay **proportional**:
a genuinely tiny, well-specified bug isn't forced through heavy ceremony — but reproduce-first
and the regression gate still apply (they are cheap and they are the whole point).

---

## Phase B0 — SYMPTOM INTAKE (no code yet)
Ingest the FULL context, not just the bug title:
- the **symptom** (verbatim);
- the **parent user story's acceptance criteria** — the de-facto spec of correct behavior;
- **linked tests** — they define the regression boundary (e.g. "verify the UI is intact while
  filtering and sorting" means the fix must NOT break filter/sort);
- **attachments** if readable.

**Ingestion source.** Read these from the spec. IF a work-item / issue-tracker connector is
available (e.g. an Azure Boards MCP server), pull the parent AC + linked tests + attachment by
work-item ID. ELSE they must be present in the spec — and if they aren't, **say so** and add
them to the MISSING-INFO list (don't invent expected behavior).

**Recall, don't re-scan** (hybrid retrieval): pull root-cause hypotheses from the explorer
memory — recall `index.json`/`MEMORY.md` by meaning → grep the concrete symbols → read only the
precise ranges. Note the MEMORY.md invariants near the symptom's area.

Write a structured **Bug Brief** to `.claude/builder/BUG.md` using the schema below. The Brief
**must** include an explicit MISSING-INFO list and flag any place where the expected behavior is
**not** specified (e.g. the symptom's feature isn't covered by the parent AC).

## Phase B1 — REPRODUCE-FIRST GATE (the cornerstone)
**No source edit until the symptom is captured as a DETERMINISTIC reproduction** — ideally a
FAILING test that asserts the expected behavior. The repro MUST FAIL on the pre-fix code
(captures the "red"). This is enforced deterministically by `guard-bugfix.sh` (PreToolUse):
while BUG.md exists and `require_reproduction` is true, edits to **source** files are blocked
until the declared repro **test file exists on disk** (or a reporter-confirmed override marker
is written). Writing the repro/characterization **tests** is always allowed.

- If it can't be reproduced from available info: surface the MISSING-INFO via the clarity gate
  and **STOP for the reporter**, OR construct the most-likely repro and get explicit user
  **CONFIRMATION** before proceeding (then the orchestrator writes
  `.claude/builder/bugfix/repro.confirmed`). **Never blind-fix a guess.**
- Running tests is side-effectful: **propose the exact repro command and confirm before running**
  (respect `auto_run_tests` / `feedback_run_tests`). Record the repro command + RED status in BUG.md.

## Phase B2 — ROOT-CAUSE (critical tier)
Diagnosis is routed to the **critical tier** — Opus 4.8 at effort **xhigh** (Anthropic's
recommended setting for agentic coding) via the dynamic-effort router: the orchestrator
dispatches the **builder-diagnostician** agent (its frontmatter pins `model: opus`,
`effort: xhigh`) when `bugfix_diagnosis_tier` is `"critical"` (default).

Trace from the **reproduced failure** to the **TRUE root cause**, not the symptom: find ALL
callers/usages of the involved symbols (blast radius), respect the MEMORY.md invariants, and
document the causal chain in BUG.md (reproduced failure → … → root cause, with `path:line`).
**Symptom-patching is a defect** — if the change only silences the symptom, you have not found
the root cause.

## Phase B3 — CHARACTERIZATION TESTS BEFORE THE FIX (regression net)
**Before changing any code**, write/confirm tests that PIN the current *correct* behavior of the
blast radius — the affected area + its callers + the linked-test boundary from B0. These must
pass **GREEN pre-fix** and stay **GREEN post-fix**. If the area has weak coverage, writing them
is **required** (`require_characterization: true`). Record their commands/names in BUG.md.
(They are test files, so the reproduce-first guard allows them.)

## Phase B4 — MINIMAL SCOPED FIX
The smallest change that fixes the **ROOT cause** (not the symptom). This reuses the normal
build spine:
- **micro-decompose** the fix into atomic, independently-verifiable task(s), each with its own
  edge-case enumeration + Definition of Done, written into `.claude/builder/PLAN.md`'s `## Tasks`
  (the `validate-plan.sh` floor applies). Proportional: a one-line fix is ONE task.
- **fail-closed** by default (a guard/check that can't decide must default to the SAFE outcome —
  this project was bitten by a fail-open guard).
- the **scope guard** (`guard-scope.sh`) restricts edits to the PLAN.md `## Scope`; list the
  source files **and** the repro/characterization test files there.
- the **per-edit feedback loop** (`lint-feedback.sh`) applies — fix lint/type findings before moving on.

## Phase B5 — REGRESSION GATE (deterministic)
`regression-gate.sh` (Stop / post-implement) requires:
- the **repro test now PASSES** (red→green = bug fixed);
- the **characterization tests + named linked/affected tests stay GREEN** (nothing else broke).

It parses the test commands from BUG.md and gets statuses by **running them** when
`auto_run_tests=="auto"`, otherwise from the results ledger the orchestrator records after
**confirmed** runs (`.claude/builder/bugfix/results.txt`, one `kind  status  command` line per
test, `kind ∈ {repro,char,linked}`, `status ∈ {green,red}`). Advisory by default; under
`bugfix_enforce` / `BUILDER_ENFORCE` it hard-blocks (exit 2) if the repro isn't green or any
characterization/linked test regressed.

## Phase B6 — HONEST RESIDUAL REPORT
Report, without overclaiming:
- **bug fixed** — with the repro **red→green** proof and which regression tests passed;
- **RESIDUAL RISK** (explicit section) — untested paths the fix touches, integration / runtime /
  concurrency cases not exercised, and memory blind spots;
- a **confidence statement** — **never "100%"**.

Then **memory-sync** records the bug + fix into the durable risk map (MEMORY.md / index.json /
TRACK.md) so this defect is known next time. When the fix is accepted, clear the bug-fix state
(remove `.claude/builder/BUG.md` and `.claude/builder/bugfix/`) so a stale Brief doesn't gate
future work.

---

## BUG.md schema (FIXED — `guard-bugfix.sh` and `regression-gate.sh` parse these keys)
The `Repro test:`, `Repro command:`, and the `Command:` lines under
`## Characterization tests` / `## Linked / affected tests` are machine-read — keep them on
their own lines exactly as shown.

```
# builder BUG — <id / short symptom title>

Bug: <one-line symptom, verbatim>

## Symptom
<the reported symptom + candidate interpretations of the vague wording>

## Expected behavior (+ source)
<what correct looks like> — source: parent AC <cite the acceptance criterion / work item>
(If the symptom's feature is NOT covered by the parent AC, say so and list it under Missing info.)

## Missing info
- <each gap that blocks a confident repro/fix>      (or "none")

## Regression boundary (linked tests / blast radius)
- <linked test names that must keep passing; affected area + callers from MEMORY.md>

## Root-cause hypotheses
- <hypothesis> — from explorer memory: <index.json/MEMORY.md cite>

## Root cause
<causal chain: reproduced failure → … → TRUE root cause, citing path:line. Not the symptom.>

## Reproduction
- Repro test: <repo-relative test file path>::<test id>
- Repro command: <exact command, e.g. pytest tests/test_search.py::test_filters_results>
- Repro status: RED        # RED pre-fix (required); update to GREEN after the fix

## Characterization tests
- Command: <command that runs the pinning set, e.g. pytest tests/test_search.py -k "sort or filter">
- <test name> — pins <behavior> (e.g. "results stay sorted while filtering")

## Linked / affected tests (must stay green)
- Command: <command that runs the linked/regression-boundary tests>
- <linked test name>
```

The fix itself is planned in `.claude/builder/PLAN.md` (`## Goal`, `## Scope` listing source +
test files, `## Approach` with `path:line`, `## Tasks` with edge cases + DoD, `## Risks &
invariants` referencing MEMORY.md) so the existing `validate-plan.sh` + scope guard + QA all
apply unchanged.

## Honesty rules
- A fix with no failing repro is a guess — do not ship it as a fix.
- Don't claim certainty you can't cite; "100%" is never allowed. State residual risk plainly.
- Fix the root cause, not the symptom; if the change only silences the symptom, it's a defect.
