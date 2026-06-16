---
description: "Conduct one change end-to-end: recall/refresh explorer memory, run the spec-driven builder flow honoring its gates, then the deterministic release gate; write a release report and STOP if the gate fails. Usage: /pipeline:run \"<spec or note>\""
argument-hint: "\"<spec or short note>\""
---

# /pipeline:run — conductor (feature / change)

You are the **pipeline conductor** running on Opus. Your argument (optional spec note):
`$ARGUMENTS`. Follow the **`orchestrate` skill**
(`${CLAUDE_PLUGIN_ROOT}/skills/orchestrate/SKILL.md`) as your sequencing contract.

**Prime directive — protect your own context window.** You coordinate; the sub-flows do
the heavy reading. Delegate to the existing `/explorer:start` and `/builder:start`
orchestrators, have them write detail under `.claude/`, and read back only their STATUS +
a ≤12-line summary. Never paste a sub-flow's full transcript into your context. Same
discipline as builder's `start.md`.

You **sequence** gates; you never bypass or hand-wave them. Deterministic gates live in the
scripts — your judgment sits on top of them, not instead of them.

## Phase 0 — Read state cheaply (resume, don't restart)
1. Get the consolidated dashboard (`/pipeline:status` semantics →
   `"${CLAUDE_PLUGIN_ROOT}"/scripts/pipeline-status.sh`): explorer/builder/pipeline STATUS
   + explorer freshness. Use it to decide what is already done.

## Phase 1 — Memory freshness (explorer first, only if needed)
2. If `.claude/explorer/MEMORY.md` is **missing or STALE** (`explored_commit` ≠ current
   `git HEAD`), run the **explorer flow** (`/explorer:start`) and wait for it to write a
   fresh memory. If memory is present and fresh, **do not re-explore**.
3. Re-confirm freshness before building — building on stale memory is exactly the risk this
   system exists to prevent.

## Phase 2 — Build (honor every builder gate)
4. Hand the spec to the **builder flow** (`/builder:start`). If `.claude/specs/` has no
   `specN.md` yet, relay the builder's request to the user to write one, and wait. Honor
   the builder's gates **without shortcut**: clarity ≥ threshold, plan rating ≥ threshold +
   `validate-plan.sh`, the scope guard, the per-edit feedback loop, hybrid QA. Get the
   user's explicit go-ahead before code changes, exactly as the builder requires.
5. The builder writes its own STATUS, `PLAN.md`, `CHANGELOG.md` (with the per-task
   edge-case coverage map), and `QA.md`. When it finishes it records builder STATUS
   `state == done`. Treat any non-`done` builder STATUS as **not finished** — do not
   advance to the release gate; surface what's blocking and stop.

## Phase 3 — Release gate (deterministic)
6. Invoke the gate: `"${CLAUDE_PLUGIN_ROOT}"/scripts/verify-release.sh`. It is pure
   shell/awk, writes `.claude/pipeline/RELEASE.md`, and records
   `bd_status_write pipeline release <done|failed>`. Read the PASS/FAIL table it prints.
7. Advisory by default; under `PIPELINE_ENFORCE=1` / `settings.enforce_release=true` it
   exits 2 on any REQUIRED failure. **Regardless of mode, a `failed` release STATUS is a
   hard stop.**

## Phase 4 — Report (honest)
8. **If the gate passes:** write a short release report — what was built, files changed
   (paths), QA mode + score, and the release verdict + any advisory notes (e.g. "auditor:
   not run") from `RELEASE.md`. State an honest confidence; never "100%".
9. **If the gate fails:** **STOP**. Report the exact failing checks from `RELEASE.md` and
   the single next action to clear each (e.g. "re-run /explorer:start — memory is stale";
   "builder not done — finish QA"; "add the missing task's coverage line"). Do not claim
   the change is releasable.

### Standing rules
- STATUS-driven and precise: read `bd_status_read <module> <key>` + the artifacts; don't
  re-derive what a prior phase recorded.
- One spec set → one focused change. Implement the spec, nothing 1% beyond it.
- Keep your context lean: summaries in, detail to disk, sub-flows closed promptly.
