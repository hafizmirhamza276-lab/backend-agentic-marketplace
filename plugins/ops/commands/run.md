---
description: "Assess whether the codebase is ready to DEPLOY/RELEASE: confirm + record a build/test ledger, run the deterministic readiness checks, add breadth+depth ops sub-agents over the CI/deploy/observability surface, aggregate findings, and record a BLOCKING count the release gate enforces (0-blocking). Usage: /ops:run [\"<focus / target environment>\"]"
argument-hint: "[\"<focus area or target environment, e.g. staging>\"]"
---

# /ops:run — deploy/release readiness

You are the **ops** orchestrator running on Opus. Optional argument (focus area or target
environment): `$ARGUMENTS`. Follow the **`assess-readiness`** skill
(`${CLAUDE_PLUGIN_ROOT}/skills/assess-readiness/SKILL.md`) for methodology and the
**`deploy-checklist`** skill for the readiness dimensions + severity taxonomy. You **sequence** the
deterministic checks and the ops sub-agents; you never hand-wave a finding or downgrade a BLOCKING
to make the gate pass.

**Prime directive — deterministic first, judgment on top.** The deterministic surface is LEAN by
design: `scripts/lib-ops-checks.sh` only reads what can be read without guessing — a recorded
build/test result (O1) and version consistency across the manifest (O2). Everything fuzzy about
deploy/observability (CI config, Dockerfile, health checks, structured logging, rollback) is the
SUB-AGENTS' job — they write ADVISORY CONCERN/NOTE findings. Keep brittle static deploy detectors
OUT; a BLOCKING must stay trustworthy.

## Phase 0 — Read prior state (cheap)
1. Read `.claude/ops/STATUS.json` (or run `"${CLAUDE_PLUGIN_ROOT}"/scripts/ops-status.sh`) to see
   the last verdict. Decide focus from `$ARGUMENTS` (a target environment, or an area to weight).

## Phase 1 — Build/test ledger (side-effectful — propose, confirm, record)
2. Running build/tests changes state, so **verify-ops only READS the ledger; you write it.** Detect
   the project's build + test commands (from its README / package manifest / CI config). **Propose**
   them and get the user's explicit go-ahead before running anything. After each confirmed run,
   append one line per command to `.claude/ops/results.txt`, TAB-separated:
   `<kind>\t<status>\t<cmd>` where `<kind>` ∈ `build|test`, `<status>` ∈ `green|red` (the same shape
   as the bug-fix ledger). If the user declines to run them, leave the ledger absent — O1 records a
   CONCERN ("not verified"), which does not hard-block.

## Phase 2 — Deterministic checks (always)
3. Run `"${CLAUDE_PLUGIN_ROOT}"/scripts/verify-ops.sh`. It runs O1–O2, writes `.claude/ops/OPS.md`,
   and records `bd_status_write ops readiness <state> "" blocking=$B concern=$C`. Read the printed
   tally. A BLOCKING here is concrete: a recorded RED build/test. A CONCERN is unverified readiness
   (no ledger) or an inconsistent version across the manifest.

## Phase 3 — Ops sub-agents (add deploy/observability judgment)
4. For a non-trivial assessment, dispatch the two ops reviewers (read-only; they write findings to
   disk, so your context stays lean):
   - **ops-scout** (Sonnet, breadth): inventory the CI/CD, deploy, and observability surface —
     pipelines, Dockerfile/manifests, health checks, config/secrets handling, structured logging,
     migrations, rollback — grounded in `.claude/explorer/MEMORY.md` and the repo.
   - **ops-critical** (Opus, depth): reason hard about the few riskiest readiness gaps — a missing
     health check on a long-running service, an unguarded migration, secrets in source, no rollback
     path — and decide, with evidence, whether each is a real CONCERN.
   Each appends findings to `.claude/ops/findings/<name>.tsv`, ONE per line, TAB-separated
   `<SEVERITY>\t<check>\t<file:line-or-path>\t<message>` with `SEVERITY ∈ CONCERN|NOTE` (deploy
   judgment is advisory — see `deploy-checklist`). They must cite `path:line` and separate evidence
   from inference — never invent a BLOCKING to look thorough.

## Phase 4 — Aggregate + report (honest)
5. Re-run `"${CLAUDE_PLUGIN_ROOT}"/scripts/verify-ops.sh` so the agent findings fold into the tally
   + OPS.md + STATUS. The BLOCKING count is now authoritative for the release gate.
6. **0 BLOCKING:** report the tally + any CONCERN worth resolving before deploy; state that the
   release-gate ops check is satisfied (verify-release.sh reads `ops blocking`). Never claim
   "production-ready" outright — only "0 BLOCKING readiness checks + N concern(s) to weigh".
7. **BLOCKING > 0:** **STOP.** List each BLOCKING from `OPS.md` and the single next action to clear
   it (e.g. "make the failing test green and re-record the ledger"). Do not advance to release; the
   gate will block.

### Standing rules
- STATUS-driven: read `bd_status_read ops <key>`; don't re-derive what verify-ops recorded.
- Checks are calibrated to be SILENT on a verified, consistent tree — a BLOCKING means a real,
  recorded build/test failure.
- NOTE findings never gate and are excluded from the tally; surface them, don't block on them.
- Deploy/observability judgment is ADVISORY (CONCERN/NOTE) — push it to the agents, never into a
  brittle static detector that false-fires. Orthogonal to the auditor (whole-tree regressions) and
  the reviewer (change-vs-invariants); all three verdicts feed the gate independently.
