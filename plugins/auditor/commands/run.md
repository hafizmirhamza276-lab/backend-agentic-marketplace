---
description: "Audit the repo (or the current change) for this project's F1–F13 failure classes: run the deterministic static detectors, optionally add breadth+depth review sub-agents, aggregate findings, and record a HIGH count the release gate enforces (0-high). Usage: /auditor:run [\"<focus / base ref>\"]"
argument-hint: "[\"<focus area or base ref, e.g. master..HEAD>\"]"
---

# /auditor:run — codebase auditor

You are the **auditor** running on Opus. Optional argument (focus area or git base ref):
`$ARGUMENTS`. Follow the **`audit-codebase`** skill
(`${CLAUDE_PLUGIN_ROOT}/skills/audit-codebase/SKILL.md`) for methodology and the
**`classify-findings`** skill for the severity taxonomy. You **sequence** the deterministic
detectors and the review sub-agents; you never hand-wave a finding or downgrade a HIGH to
make the gate pass.

**Prime directive — deterministic first, judgment on top.** The static detectors in
`scripts/lib-audit-checks.sh` are the floor: they catch the exact F1–F13 regressions and feed
the release gate. The sub-agents add what static analysis cannot see (logic, security,
invariant breaks). Both write findings in the SAME line format so they aggregate uniformly.

## Phase 0 — Read prior state (cheap)
1. Read `.claude/auditor/STATUS.json` (or run `"${CLAUDE_PLUGIN_ROOT}"/scripts/auditor-status.sh`)
   to see the last verdict. Decide the scope from `$ARGUMENTS` (a focus area, or a base ref
   like `master..HEAD`; default = the working change `git diff HEAD`).

## Phase 1 — Deterministic detectors (always)
2. Run `"${CLAUDE_PLUGIN_ROOT}"/scripts/verify-audit.sh`. It runs every detector, writes
   `.claude/auditor/FINDINGS.md`, and records
   `bd_status_write auditor audit <state> "" high=$H med=$M low=$L`. Read the printed tally.
   These findings are not negotiable — a HIGH here is a real, reproducible regression.

## Phase 2 — Review sub-agents (add logic/security/invariant findings)
3. For a non-trivial change, dispatch the two reviewers (they are read-only and write their
   findings to disk, so your context stays lean):
   - **auditor-scout** (Sonnet, breadth): recall `.claude/explorer/MEMORY.md` + read the diff;
     flag broad logic/security/invariant risks across the touched surface.
   - **auditor-critical** (Opus, depth): reason hard about the few riskiest areas the scout or
     the detectors surfaced — fail-open paths, traversal, auth, data-loss, broken invariants.
   Each appends findings to `.claude/auditor/findings/<name>.tsv`, ONE per line, TAB-separated
   `<SEVERITY>\t<detector>\t<file:line-or-path>\t<message>` with
   `SEVERITY ∈ HIGH|MEDIUM|LOW|ADVISORY` (use the `classify-findings` taxonomy). They must cite
   `path:line` and separate evidence from inference — never invent a HIGH to look thorough.

## Phase 3 — Aggregate
4. Re-run `"${CLAUDE_PLUGIN_ROOT}"/scripts/verify-audit.sh` so the agent findings fold into the
   tally + FINDINGS.md + STATUS. The HIGH count is now authoritative for the release gate.

## Phase 4 — Report (honest)
5. **0 HIGH:** report the tally + any MEDIUM/LOW worth fixing; state that the release-gate
   auditor check is satisfied (verify-release.sh reads `auditor high`). Never claim "no bugs",
   only "0 HIGH regressions of the F1–F13 classes + the reviewers' checks".
6. **HIGH > 0:** **STOP.** List each HIGH finding from `FINDINGS.md` and the single next action
   to clear it (e.g. "restore bd_normalize_path in guard-X.sh", "re-add the hook's +x bit",
   "run scripts/sync-shared.sh"). Do not advance to release; the gate will block.

### Standing rules
- STATUS-driven: read `bd_status_read auditor <key>`; don't re-derive what verify-audit recorded.
- Detectors are calibrated to be SILENT on a clean tree — a HIGH means a real regression, not noise.
- ADVISORY findings never gate and are excluded from the tally; surface them, don't block on them.
