---
name: orchestrate
description: "The sequencing contract for the pipeline CONDUCTOR. Drives one change end-to-end: recall/refresh the explorer codebase memory, run the spec-driven builder flow (or BUG-FIX MODE) honoring its own gates, then verify release-readiness with the deterministic release gate (verify-release.sh) and STOP if it fails. Everything is STATUS-driven (.claude/<module>/STATUS.json) so each phase reads the previous phase's machine-readable verdict instead of re-deriving it. Use when conducting /pipeline:run or /pipeline:fix; the conductor coordinates and delegates — it never does the heavy reading itself."
---

# orchestrate — the conductor's sequencing contract

The `pipeline` plugin is a **conductor**: it does not explore, plan, or implement itself.
It sequences the existing `explorer` and `builder` plugins and then renders a **release
verdict**. Each stage communicates through two durable channels — the **STATUS contract**
(`.claude/<module>/STATUS.json`, written by `bd_status_write`, read by `bd_status_read`)
and the **durable memory / artifacts** under `.claude/` — so the conductor reads short,
machine-readable state rather than re-deriving anything.

**Prime directive — protect your own context window.** You coordinate; the sub-flows do
the heavy reading. Delegate via the existing `/explorer:start` and `/builder:start`
orchestrators (or their sub-agents), have them write detail to `.claude/`, and read back
only their STATUS + a ≤12-line summary. Never paste a sub-agent transcript into your
context. Same discipline as `builder`'s `start.md`.

## The contract you follow (in order)

### Phase 0 — Read state cheaply
1. Run the dashboard semantics (`scripts/pipeline-status.sh` / `/pipeline:status`): read
   `explorer`, `builder`, and `pipeline` STATUS and explorer freshness. This tells you
   what (if anything) is already done so you can resume rather than restart.

### Phase 1 — Memory freshness (explorer first, only if needed)
2. Memory is ground truth for the build. If `.claude/explorer/MEMORY.md` is **missing or
   STALE** (its `explored_commit` ≠ current `git HEAD`), run the **explorer flow first**
   (`/explorer:start`). If memory is present and fresh, **do not re-explore** — recall is
   cheap, re-exploration is the expensive step the explorer already paid.
3. Confirm freshness from STATUS/memory before proceeding. Building on stale memory risks
   the "small mistake, whole-codebase damage" failure this whole system exists to prevent.

### Phase 2 — Build (honor the builder's own gates)
4. Run the **builder flow** (`/builder:start` for a feature spec; **BUG-FIX MODE** via
   `/pipeline:fix` → builder's reproduce-first flow for a bug). Do **not** bypass any
   builder gate: clarity ≥ threshold, plan rating ≥ threshold + `validate-plan.sh`, the
   scope guard, per-edit feedback loop, hybrid QA, and (for bugs) the regression gate.
   The builder writes its own STATUS, `PLAN.md`, `CHANGELOG.md` (with the per-task
   **edge-case coverage map**), `QA.md`, and — for bugs — `BUG.md` + `bugfix/results.txt`.
5. When the builder finishes, it records `bd_status_write builder <phase> done`. Treat a
   non-`done` builder STATUS as **not finished** — do not advance to the release gate.

### Phase 3 — Release gate (deterministic, you do not hand-judge it)
6. Invoke the **release gate**: `"${CLAUDE_PLUGIN_ROOT}"/scripts/verify-release.sh`. It is
   pure shell/awk (no python dependency) and checks, against existing artifacts/STATUS:
   - explorer memory present **and fresh** (`explored_commit == git HEAD`);
   - builder **done**, and — if `PLAN.md` exists — **every** `## Tasks` item has a
     coverage-map line in `CHANGELOG.md`;
   - if `BUG.md` exists, the bug-fix net is green (repro red→green + characterization/linked
     green, from `bugfix/results.txt`);
   - `CHANGELOG.md` present and non-empty;
   - auditor (extensible): 0 high **if** an auditor STATUS exists; otherwise reported as
     "not run" and **not** failed.
   It writes `.claude/pipeline/RELEASE.md` + `bd_status_write pipeline release <done|failed>`.
7. **Advisory vs enforce.** By default the gate is advisory (exit 0 + report). Under
   `PIPELINE_ENFORCE=1` or `settings.enforce_release=true` it exits 2 on any REQUIRED
   failure. **Regardless of mode, treat a `failed` release STATUS as a hard stop**: do not
   claim the change is releasable.

### Phase 4 — Report (honest)
8. If the gate passes: write a short release report (what was built/fixed, files changed,
   QA mode + score, and the release verdict from `RELEASE.md`). If it fails: **STOP and
   report** the exact failing checks from `RELEASE.md` and the single next action to clear
   each — never overclaim. Never state "100%".

## Standing rules
- **STATUS-driven:** read `bd_status_read <module> <key>` and the artifacts; don't
  re-derive what a previous phase already recorded.
- **Don't bypass gates:** the conductor's job is to *sequence* gates, never to skip them.
  Deterministic gates live in the hooks/scripts; your judgment sits on top, not instead.
- **Resume, don't restart:** if explorer memory is fresh and the builder is mid-flight,
  pick up where STATUS says you are.
- **Lean context:** summaries in, detail to disk, sub-flows closed promptly.
