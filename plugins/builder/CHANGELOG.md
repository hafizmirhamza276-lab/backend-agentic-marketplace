# Changelog — builder

## 0.3.0 — harness reliability (Cursor-style closed loops)
- **Per-edit feedback loop** — new `scripts/lint-feedback.sh`, wired as a PostToolUse hook
  (`Write|Edit|MultiEdit|NotebookEdit`, timeout 20s). After each edit it re-checks ONLY the
  changed file with the auto-detected, installed toolchain (ESLint/tsc/Prettier · Ruff/flake8/
  mypy/black · gofmt/go vet/golangci-lint · rustfmt/cargo · pre-commit fallback), and feeds
  concise diagnostics back via the PostToolUse `hookSpecificOutput.additionalContext` channel.
  Multi-ecosystem + graceful (only runs installed tools), per-file (fast), output-capped, per-tool
  `timeout`. Skips `.claude/*`, lockfiles, and non-code files. Advisory by default; under
  `feedback_enforce`/`BUILDER_ENFORCE` it records findings the Stop gate (`verify-build.sh`)
  refuses to pass with. New `bd_feedback_enforce` helper in `lib/common.sh`.
- **Per-task targeted tests** — after a micro-task, the orchestrator/QA runs tests scoped to the
  touched files/symbols (not the whole suite), gated by `feedback_run_tests` (default `"ask"`),
  folded into the task's edge-case coverage map.
- **Hybrid retrieval chain** — `index.json` enriched (per-file/-symbol summaries + `imports` +
  `used_by` callers, additive/back-compatible); context-finder + recall-memory now recall by
  meaning → grep concrete symbols → read precise ranges, returning summaries not dumps.
- **Explore before change** — plan-change/apply-change require locating existing patterns + ALL
  callers of a changed symbol before writing; recorded per task as `Existing pattern:`.
- **Always-on standards + cheap static context** — implementer always honors MEMORY.md
  conventions/invariants; SessionStart prints OS, git branch + clean/dirty, and recently-changed
  files to stdout. Feedback records are cleared at SessionStart (per-session lint debt).
- New settings (bootstrap defaults): `feedback_loop` (true), `feedback_enforce` (false),
  `feedback_run_tests` ("ask").

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
