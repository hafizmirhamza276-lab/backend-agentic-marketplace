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

### Bug-fix mode (reproduce-first → regression-safe)
When a spec is a **bug report** (auto-detected by a `Bug:`/symptom shape, or marked by the user;
`bugfix_mode: "auto"|"on"|"off"`), `/builder:start` runs a dedicated workflow instead of the plain
feature flow. **The fix's accuracy is designed to come from a verification net, not from effort:**
the deep tier improves *diagnosis*; the gates prove *correctness and no-regression*.

```
symptom (vague, repro-less)
   │
[B0] intake ─► Bug Brief → .claude/builder/BUG.md (symptom, parent-AC = expected behavior + source,
   │           MISSING-INFO, regression boundary from linked tests, memory-recalled hypotheses)
   ▼
[B1] reproduce-first ─► a FAILING repro test (red on current code)        ── enforced by ──┐
   │                    "ideally a test that asserts expected behavior"                     │
   ▼                                                                       guard-bugfix.sh  │
[B2] root-cause (CRITICAL tier: Opus 4.8 @ effort xhigh, builder-diagnostician)  (PreToolUse): │
   │   trace reproduced failure → TRUE root cause (all callers, MEMORY.md invariants)  blocks  │
   ▼   — symptom-patching is a defect                                       source edits until │
[B3] characterization tests ─► pin CURRENT correct behavior of the blast    a repro test exists ┘
   │   radius (green pre-fix, must stay green post-fix)
   ▼
[B4] minimal scoped fix ─► micro-decompose (atomic, fail-closed) + scope guard + per-edit feedback
   ▼
[B5] regression-gate.sh (Stop): repro RED→GREEN ✓ AND characterization/linked GREEN ✓
   │   (advisory; bugfix_enforce / BUILDER_ENFORCE ⇒ hard-block exit 2). Separate from verify-build.sh.
   ▼
[B6] honest residual report (red→green proof, regression results, RESIDUAL-RISK, confidence ≠ 100%)
     + memory-sync records the bug+fix into the risk map
```

- **Reproduce-first is the cornerstone and it's deterministic.** `guard-bugfix.sh` (a *separate*
  PreToolUse hook from `guard-scope.sh`, so the scope contract and its F2/F3 fixes are untouched)
  blocks **source** edits while a Bug Brief exists and no repro test is on disk; test files and
  `.claude/*` stay writable so the net can be built. Outside a bug-fix session it's a pure no-op.
- **Reuse, not duplication.** The fix is planned in the same `PLAN.md`, gated by the same
  `validate-plan.sh`, scoped by the same scope guard, implemented by the same `builder-implementer`
  with the per-edit feedback loop, and QA'd by the same `builder-qa`. The only new pieces are the
  diagnosis tier (`builder-diagnostician`, the critical tier of the dynamic-effort router) and the
  two new scripts. Gate decisions are pure shell/awk — no python dependency — so they're robust on
  python-less / Windows-stub hosts (the class of failure the audit flagged).
- **Data contract.** Test commands live in BUG.md (fixed schema); statuses are recorded to the
  ledger `.claude/builder/bugfix/results.txt` (`kind  status  command`) after confirmed runs, or
  produced by the gate itself when `auto_run_tests="auto"`. Running tests is side-effectful, so the
  orchestrator proposes commands and confirms before any run.

## The ecosystem (built) — five modules + a conductor
What were roadmap slots are now **built plugins**, all reading the same `.claude/explorer/` memory
and composing through the STATUS contract (below):
- `explorer` — explore once; durable codebase memory (this document's core).
- `builder` — implements changes using the explorer memory as ground truth (above).
- `auditor` — deterministic **F1–F13** regression detectors + breadth/depth sub-agents; records a
  `high` count.
- `reviewer` — reviews *this change* (diff vs HEAD) against the MEMORY.md invariants/risk map, the
  approved scope, and surviving callers; records a `blocking` count.
- `ops` — deploy/release-readiness (build/test ledger + version consistency + deploy/observability
  sub-agents); records a `blocking` count.
- `pipeline` — the **conductor**: sequences explore → build → audit → review → ops and renders the
  release verdict. It does no exploring/building itself.

Each is a folder under `plugins/` plus one entry in `.claude-plugin/marketplace.json`, and each
vendors a byte-identical copy of `shared/lib/common.sh` (kept in sync by `scripts/sync-shared.sh`,
verified by `scripts/check-shared-sync.sh`).

## The STATUS contract + the release gate (how the modules compose)
The modules never call each other; they communicate through two durable channels under the user's
repo, so the conductor reads short machine-readable state instead of re-deriving anything:
- **STATUS contract** — each module writes `${CLAUDE_PROJECT_DIR}/.claude/<module>/STATUS.json` via
  `bd_status_write` (a fixed `module / phase / state / commit / coverage / updated_at` schema plus
  trailing `key=value` extras — e.g. auditor `high=`, reviewer/ops `blocking=`), read back with
  `bd_status_read`. Both the python and the pure-shell writers emit byte-identical JSON and degrade
  gracefully when python is absent, so the contract round-trips on a python-less / Windows host.
- **Durable artifacts** — `MEMORY.md`, the builder's `PLAN.md` / `CHANGELOG.md` / `BUG.md`, the
  auditor's `FINDINGS.md`, the reviewer's `REVIEW.md`, the ops `OPS.md`, and the gate's `RELEASE.md`.

The **release gate** (`plugins/pipeline/scripts/verify-release.sh`, pure shell/awk — no python
dependency) is where it all converges. It aggregates **seven** checks — explorer freshness · builder
done + full task coverage · bug-fix net (only when a `BUG.md` exists) · auditor `high == 0` ·
CHANGELOG present · reviewer `blocking == 0` · ops `blocking == 0` — into one **RELEASE READY /
BLOCKED** verdict, written to `.claude/pipeline/RELEASE.md` alongside `bd_status_write pipeline
release <done|failed>`. The auditor/reviewer/ops checks are **SKIP-when-absent** (advisory): a
module that hasn't run never fails the release, so the gate is purely additive — adding a module
only ever adds a check. Advisory by default; `PIPELINE_ENFORCE=1` / `settings.enforce_release` makes
any required failure hard-block (exit 2). The end-to-end "1–2 command → prod-ready" promise is proven
by `tests/e2e-ladder.sh`: a green-path fixture where all seven checks PASS, eight single-mutation
negatives that each block with the right reason, the consolidated dashboard, and a verdict mutation
sentinel.
