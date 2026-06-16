---
description: "Conduct a bug fix end-to-end: recall/refresh explorer memory, route through the builder's reproduce-first BUG-FIX MODE (failing repro -> root cause -> characterization -> minimal fix -> regression gate), then the deterministic release gate; report honestly and STOP if the gate fails. Usage: /pipeline:fix \"<bug>\""
argument-hint: "\"<bug symptom / report>\""
---

# /pipeline:fix — conductor (bug fix)

You are the **pipeline conductor** running on Opus. Your argument (the bug): `$ARGUMENTS`.
This is the same conductor contract as `/pipeline:run` (follow the **`orchestrate` skill**,
`${CLAUDE_PLUGIN_ROOT}/skills/orchestrate/SKILL.md`), but Phase 2 routes through the
builder's **BUG-FIX MODE** instead of the plain feature flow.

**Prime directive — protect your own context window.** Coordinate; delegate the heavy
reading; read back STATUS + ≤12-line summaries. Never bypass a gate.

## Phase 0 — Read state cheaply
1. Get the dashboard (`pipeline-status.sh` / `/pipeline:status`). Note: a lingering
   `.claude/builder/BUG.md` means a bug fix is already in flight — resume it rather than
   starting a new one.

## Phase 1 — Memory freshness (explorer first, only if needed)
2. If `.claude/explorer/MEMORY.md` is missing or STALE (`explored_commit` ≠ `git HEAD`),
   run `/explorer:start` first; otherwise recall, don't re-explore.

## Phase 2 — Fix via builder BUG-FIX MODE (reproduce-first, regression-safe)
3. Route the bug to the **builder flow in BUG-FIX MODE** (`/builder:start` with the report
   recorded as a bug spec — a `Bug:`/`## Symptom` shape — or by setting `bugfix_mode` so the
   builder classifies it as a bug). Honor BUG-FIX MODE's gates **without shortcut**:
   - **reproduce-first** — no source edit until a FAILING reproduction exists
     (`guard-bugfix.sh` enforces this while `BUG.md` exists); never blind-fix a guess;
   - **root cause, not symptom** — trace to the true cause with `path:line`;
   - **characterization tests** pin the blast radius (green pre- and post-fix);
   - **minimal scoped fix** under the scope guard + per-edit feedback loop;
   - **regression gate** (`regression-gate.sh`) proves repro red→green + characterization/
     linked green; results are recorded to `.claude/builder/bugfix/results.txt`.
4. The builder records its STATUS `state == done` and updates `BUG.md` (`Repro status:
   GREEN`). Treat non-`done` as not finished.

## Phase 3 — Release gate (deterministic)
5. Invoke `"${CLAUDE_PLUGIN_ROOT}"/scripts/verify-release.sh`. Because `BUG.md` exists, the
   gate additionally requires the bug-fix net to be green (repro green + characterization/
   linked green from `results.txt`). It writes `RELEASE.md` + the pipeline STATUS. Advisory
   by default; enforce via `PIPELINE_ENFORCE=1` / `settings.enforce_release=true`. A
   `failed` release STATUS is a hard stop.

## Phase 4 — Honest residual report
6. **If the gate passes:** report the fix with the **repro red→green** proof, which
   regression tests passed, an explicit **RESIDUAL-RISK** section (untested paths the fix
   touches; integration/runtime/concurrency cases not exercised; memory blind spots), and a
   confidence statement — **never "100%"**. After the user accepts, the builder clears the
   bug-fix state (`BUG.md` + `bugfix/`) and memory-sync records the defect in the risk map.
7. **If the gate fails:** **STOP** and report the exact failing checks from `RELEASE.md`
   (e.g. "bugfix: reproduction not green") and the next action to clear each.

### Standing rules
- A fix with no failing repro is a guess — the gate will not call it releasable, and
  neither should you.
- STATUS-driven and precise; keep your context lean; never bypass a gate.
