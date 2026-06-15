# Changelog — builder

## 0.2.0 — micro-level precision
- New mode (default on) that decomposes a requirement into the smallest
  independently-verifiable tasks and writes precise, edge-case-hardened code — solving the
  failure where a large context lets small edge-case bugs slip through.
- New skill `micro-decompose`: right-sizing rules (proportional — a one-line change is ONE
  task; over-splitting is a defect) + a reusable edge-case taxonomy (inputs/boundaries,
  state/lifecycle, IO/external, errors incl. fail-open vs fail-closed, numeric, security,
  portability, contract/invariants), extended per task with the codebase-specific risks named
  in `MEMORY.md`.
- Planner (`plan-change` + agent) now writes a `## Tasks` breakdown in `PLAN.md` — one block
  per task with `Files/functions`, `Behavior`, an `Edge cases:` list, and a `Definition of Done`.
- Gate `validate-plan.sh` extended: when `micro_decomposition` is on, requires a `## Tasks`
  section with ≥1 task block, each carrying a non-empty `Edge cases:` list AND a
  `Definition of Done:` — fails (exit 1) naming the exact offending task id. No minimum task
  count (one is valid). Reuses the awk/grep style; python-optional via the working-interpreter
  detection in `common.sh`.
- Implementer (`apply-change` + agent) works task-by-task with an isolated per-task context,
  and appends a per-task **edge-case coverage map** to `.claude/builder/CHANGELOG.md`
  (each case → handled at file:line | covered by test | DEFERRED:reason; no silent skips).
- QA (`qa-verify` + agent) verifies the coverage map; the score reflects edge-case coverage,
  not just a green build.
- Orchestrator `/builder:start` weaves the task loop into Plan/Implement/QA, keeping the
  confirm-before-code and gated-test-run steps.
- New settings (default `true`): `micro_decomposition`, `require_edge_case_coverage`. Off →
  the original single-pass flow.

## 0.1.0
- Initial release of the spec-driven `builder` plugin.
- Command: `/builder:start` (orchestrator) + `/builder:status` (cheap state read).
- Agents: context-finder, planner (+ Opus deep escalation), implementer, QA (+ Opus deep escalation), memory-sync.
- Skills: recall-memory, plan-change, apply-change, qa-verify, sync-memory.
- Hooks: SessionStart (state/freshness + settings bootstrap), PreToolUse scope guard, SubagentStop progress log, Stop completeness gate.
- Deterministic gates: `validate-plan.sh` (plan structure) and `verify-build.sh` (carries over the explorer `index.json` path-resolution fix).
- Config via `.claude/builder/settings.json`: Opus escalation (default on, last-resort), loop limits, rating/clarity thresholds, `auto_run_tests` (default "ask"), `enforce_gates`.
