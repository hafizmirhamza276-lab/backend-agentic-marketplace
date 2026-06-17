---
description: "Conduct one change end-to-end: recall/refresh explorer memory, run the spec-driven builder flow honoring its gates, then the deterministic release gate; write a release report and STOP if the gate fails. Usage: /pipeline:run \"<spec or note>\""
argument-hint: "\"<spec or short note>\""
---

# /pipeline:run — conductor (feature / change)

You are the **pipeline conductor** running on Opus. Your argument (optional spec note):
`$ARGUMENTS`. Follow the **`orchestrate` skill**
(`${CLAUDE_PLUGIN_ROOT}/skills/orchestrate/SKILL.md`) as your sequencing contract.

**Prime directive — protect your own context window.** You coordinate; the sub-flows do
the heavy reading. Delegate to the existing `/explorer:start`, `/builder:start`,
`/auditor:run`, `/reviewer:run`, and `/ops:run` orchestrators, have them write detail under
`.claude/`, and read back only their STATUS + a ≤12-line summary. Never paste a sub-flow's
full transcript into your context. Same discipline as builder's `start.md`.

You **sequence** gates; you never bypass or hand-wave them. Deterministic gates live in the
scripts — your judgment sits on top of them, not instead of them. Run the modules in this
**exact order — explore → build → audit → review → ops → release-gate** — each delegated to its
own existing sub-flow (`/explorer:start`, `/builder:start`, `/auditor:run`, `/reviewer:run`,
`/ops:run`, then `verify-release.sh`), reading back only its STATUS + a ≤12-line summary.

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

## Phase 2.4 — Audit the change (auditor, before the reviewer)
6. Run the **auditor flow** (`/auditor:run`) on what the builder just changed — AFTER the build,
   BEFORE the reviewer and the gate. It runs this project's deterministic **F1–F13** regression
   detectors and (for a non-trivial change) breadth+depth audit sub-agents over the touched surface,
   then writes `.claude/auditor/FINDINGS.md` and records
   `bd_status_write auditor audit <done|failed> "" high=$H med=$M low=$L`. Honor its gate without
   shortcut: a HIGH is a real, reproducible regression of one of those failure classes. Treat a
   `failed` auditor STATUS as **not finished** — surface the HIGH(s) and let the gate enforce
   0-high; weigh any MEDIUM/LOW. The auditor owns whole-tree F-class regressions; the reviewer
   (next) owns the diff-vs-invariants review — orthogonal verdicts that feed the gate independently.

## Phase 2.5 — Review the change (reviewer, before the gate)
7. Run the **reviewer flow** (`/reviewer:run`) on what the builder just changed — AFTER the audit,
   BEFORE the release gate. It reviews the diff vs HEAD against the explorer `MEMORY.md`
   invariants/risk map, the approved `PLAN.md` scope, and surviving callers; it writes
   `.claude/reviewer/REVIEW.md` and records
   `bd_status_write reviewer review <done|failed> "" blocking=$B concern=$C`. Honor its gate
   without shortcut: a BLOCKING finding is a real breakage. Treat a `failed` reviewer STATUS as
   **not finished** — surface what broke and let the gate enforce 0-blocking; weigh any CONCERNs.
   The reviewer is orthogonal to the auditor — both verdicts feed the gate independently.

## Phase 2.6 — Assess deploy/release readiness (ops, before the gate)
8. Run the **ops flow** (`/ops:run`) — AFTER the reviewer, BEFORE the release gate, so the full
   sequence is explore → build → audit → review → ops → release-gate. It assesses deploy/release
   readiness: it (with your confirmation) records a build/test ledger and runs the deterministic
   checks — O1 test-ledger (a recorded RED build/test → BLOCKING; no ledger → CONCERN) and O2
   version-consistency — then adds advisory deploy/observability findings from its sub-agents. It
   writes `.claude/ops/OPS.md` and records
   `bd_status_write ops readiness <done|failed> "" blocking=$B concern=$C`. Honor its gate without
   shortcut: a BLOCKING means the codebase is provably not releasable (a failed build/test). Treat a
   `failed` ops STATUS as **not finished** — surface what's red and let the gate enforce 0-blocking;
   weigh any CONCERNs. Ops is orthogonal to the auditor and the reviewer — all three verdicts feed
   the gate independently.

## Phase 3 — Release gate (deterministic)
9. Invoke the gate: `"${CLAUDE_PLUGIN_ROOT}"/scripts/verify-release.sh`. It is pure
   shell/awk, writes `.claude/pipeline/RELEASE.md`, and records
   `bd_status_write pipeline release <done|failed>`. Read the PASS/FAIL table it prints.
   When reviewer, ops, and/or auditor STATUS is present, the gate requires reviewer `blocking == 0`
   and ops `blocking == 0` (and auditor `high == 0`); when absent, those checks SKIP (advisory) and
   do not block.
10. Advisory by default; under `PIPELINE_ENFORCE=1` / `settings.enforce_release=true` it
   exits 2 on any REQUIRED failure. **Regardless of mode, a `failed` release STATUS is a
   hard stop.**

## Phase 4 — Report (honest)
11. **If the gate passes:** **declare the change prod-ready** and write a short release report —
   what was built, files changed (paths), QA mode + score, and the release verdict + any advisory
   notes (e.g. "auditor: not run", "reviewer: not run", "ops: not run") from `RELEASE.md`. State an
   honest confidence; never "100%".
12. **If the gate fails:** **STOP**. Report the exact failing checks from `RELEASE.md` and
   the single next action to clear each (e.g. "re-run /explorer:start — memory is stale";
   "builder not done — finish QA"; "auditor HIGH — fix the F-class regression it named"; "reviewer
   BLOCKING — fix the broken caller"; "ops BLOCKING — make the failing test green and re-record the
   ledger"; "add the missing task's coverage line"). Do not claim the change is releasable.

### Standing rules
- STATUS-driven and precise: read `bd_status_read <module> <key>` + the artifacts; don't
  re-derive what a prior phase recorded.
- One spec set → one focused change. Implement the spec, nothing 1% beyond it.
- Keep your context lean: summaries in, detail to disk, sub-flows closed promptly.
