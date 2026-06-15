# Architecture — backend-agentic-marketplace / explorer

## Goal
Explore a backend codebase **once**, then write a durable knowledge base under the user's
repo (`.claude/explorer/`) so any future Claude Code session understands the code —
**what / why / how** — by *reading the memory*, not by re-scanning the tree.

## The durable-memory idea (the core)
Exploration output is written to `${CLAUDE_PROJECT_DIR}/.claude/explorer/`, **not** inside
the plugin. The plugin lives in an ephemeral cache (`~/.claude/plugins/cache`) and is wiped
on update; project files are permanent and git-trackable. So the "brain" rides with the repo.

Artifacts:
- `MEMORY.md`   — master summary; read this first. Carries `explored_commit` + `coverage`.
- `map/<area>.md` — per-module deep dives (read only what you need).
- `index.json`  — file → summary → symbols → deps, for targeted recall.
- `TRACK.md`    — coverage ledger + changelog + explicit blind spots.

## Flow (what `/explorer:start` does)
```
/explorer:start
   │
   ▼
[Phase 0] Freshness gate ── memory exists & commit matches? ──► load memory, STOP (no re-explore)
   │ (missing/stale)
   ▼
[Phase 1] Orchestrator (your Opus session) dispatches in parallel:
            ├─ explorer-scout  (Sonnet, breadth)  → Scout Report
            └─ explorer-sage   (Opus,  depth)     → Sage Report
            (each: own isolated context window, read-only, own model)
   │
   ▼
[Phase 2] Orchestrator synthesizes both reports → writes MEMORY.md / map/ / index.json / TRACK.md
   │
   ▼
[Phase 3] Reports coverage %, risks, and blind spots to the user
```
Sub-agents cannot see each other's context and report once to the orchestrator — so the
flow is strictly `sub-agents → orchestrator`, never peer-to-peer. Anything they must know
(repo root, focus, changed files) is passed inside the Task prompt.

## Hooks = deterministic control points
- **SessionStart** → `check-memory.sh`: if memory exists, nudge "recall, don't re-explore";
  warn if `explored_commit` ≠ current HEAD.
- **PreToolUse (Write|Edit|MultiEdit)** → `guard-readonly.sh`: blocks any write outside
  `.claude/explorer/`. Enforces "explorer analyzes, never mutates source."
- **SubagentStop** → `record-coverage.sh`: appends progress to TRACK.md.
- **Stop** → `verify-output.sh`: deterministic completeness check of the artifacts.
  Advisory by default; set `EXPLORER_ENFORCE=1` to make Claude keep working until complete.

## Honest limits (so expectations match reality)
1. **Not literally 100%.** Coverage is bounded by context, time, and cost. Memory always
   states a coverage % and lists `unverified` areas. "Near-100% understanding from one read"
   is the design target, not a guarantee.
2. **Determinism is in the gates, not the model.** Hooks deterministically validate/route;
   the LLM's analysis text is not bit-for-bit reproducible.
3. **Token cost.** Subagent-heavy runs can cost several times a single-thread session. The
   freshness gate exists precisely so you pay that cost *once*, then recall cheaply.
4. **Staleness.** Memory tracks the explored commit; when code drifts, recall flags it and
   prefers a *targeted* re-read over a full rescan.

## Builder — micro-level precision (decomposition + edge-case hardening)
The `builder` plugin reads this memory as ground truth and turns a spec into code through a
gated plan → implement → QA loop. Its headline correctness feature is **micro-level
precision**, which exists to kill the common failure where a large context lets a small
edge-case bug slip through. It is on by default (`micro_decomposition`,
`require_edge_case_coverage` in `.claude/builder/settings.json`); turn `micro_decomposition`
off to fall back to the original single-pass flow.

```
Plan ──► PLAN.md "## Tasks": atomic, independently-verifiable units, each with an
 │        explicit Edge cases list + Definition of Done  ──►  validate-plan.sh
 │        (deterministic floor: rejects a missing Tasks section, or any task lacking
 │         edge cases / a DoD, naming the exact task id)
 ▼
Implement ─► one task at a time (small, isolated context per unit); code handles EVERY
 │           enumerated edge case (fail-closed when a check can't decide); appends a
 │           per-task edge-case COVERAGE MAP to CHANGELOG.md:
 │             <case> → handled at file:line | covered by <test> | DEFERRED:<reason>
 ▼
QA ───────► verifies the coverage map — every enumerated case handled or justifiably
            deferred; score reflects edge-case coverage, not just a green build
```

- **Right-sized decomposition.** Split only as far as each unit is independently verifiable —
  proportional, never exploded: a one-line change is ONE task. Over-splitting is treated as a
  defect (it fragments review and hides the real seams).
- **Edge-case taxonomy** (in `skills/micro-decompose`): inputs/boundaries, state/lifecycle,
  IO/external, errors incl. **fail-open vs fail-closed**, numeric, security,
  portability (OS/locale/line-endings), and contract/invariants — then **extended with the
  codebase-specific risks named in `MEMORY.md`**, so edge cases are grounded in *this* code.
- **Externalized, traceable, gated.** Every edge case is written to disk (PLAN.md task →
  CHANGELOG.md coverage map), never held only "in the model's head," and the deterministic
  gate sits under the orchestrator's 9+/10 judgment — same philosophy as the rest of the
  system: gates for what must be true, LLM judgment on top.

### Harness reliability (Cursor-style closed loops)
On top of decomposition, the builder borrows reliability techniques from agentic coding
harnesses — all multi-ecosystem and graceful (only what's installed runs):

```
edit a file ─► PostToolUse lint-feedback.sh ─► auto-detect toolchain by ext + root markers
 │                                              run per-FILE checks (only installed tools)
 │                                              concise diagnostics ─► additionalContext ─► agent fixes next step
 ▼                                              (advisory; feedback_enforce ⇒ Stop gate blocks unaddressed findings)
per micro-task ─► targeted tests (touched files/symbols only, gated by feedback_run_tests) ─► coverage map
recall  ─► index.json by MEANING (summary/symbols/imports/callers) → grep concrete symbols → read precise ranges
```

- **Per-edit feedback loop** — `lint-feedback.sh` (PostToolUse, `Write|Edit|MultiEdit|NotebookEdit`)
  re-checks only the changed file and feeds lint/type errors back through the documented
  PostToolUse `hookSpecificOutput.additionalContext` channel (advisory, exit 0). It skips
  `.claude/*`, lockfiles, and non-code files; caps output; per-tool `timeout`. Under enforce it
  records findings the Stop gate refuses to pass with.
- **Hybrid retrieval** — index (semantic-ish) → grep (concrete symbols) → targeted reads; return
  summaries, not file dumps. Pure search runs at the low-effort tier.
- **Explore before change** — locate existing patterns + ALL callers of a changed symbol first;
  follow conventions (recorded per task as `Existing pattern:`) so a change doesn't duplicate
  code or break callers.
- **Always-on standards + cheap static context** — MEMORY.md conventions/invariants are
  non-negotiable for the implementer; SessionStart prints OS, git branch + dirty/clean, and
  recently-changed files so the orchestrator starts grounded.

## Roadmap slots (the other 3–4 plugins)
The marketplace is ready to hold siblings that all read the same memory:
- `builder` — implements changes using the explorer memory as ground truth.
- `reviewer` — reviews diffs against invariants/risks recorded in MEMORY.md.
- `ops` — runtime/deploy/observability tasks.
Each would be a folder under `plugins/` plus one entry in `.claude-plugin/marketplace.json`.
