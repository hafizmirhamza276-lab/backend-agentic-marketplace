# backend-agentic-marketplace

A Claude Code plugin marketplace for agentic backend engineering.

**Plugin #1 — `explorer`:** explore a codebase **once**, then any future session understands
it (what / why / how) by reading `.claude/explorer/` — no re-exploring.

**Plugin #2 — `builder`:** spec-driven implementation that reads the explorer memory as
ground truth, gates the plan (clarity + technical plan, 9/10 each), implements only what the
spec says, runs hybrid QA, and keeps the durable memory in sync.

## How to install

In Claude Code, add the marketplace and install the plugins:

```bash
/plugin marketplace add hafizmirhamza276-lab/backend-agentic-marketplace
/plugin install explorer@backend-agentic-marketplace
/plugin install builder@backend-agentic-marketplace
```

Install only `explorer` if that's all you need — but `builder` depends on the explorer memory,
so run `explorer` first either way (see below).

## Plugin #1 — `explorer`

Map a backend codebase once with two read-only sub-agents (Sonnet breadth + Opus depth),
then persist a durable memory so future sessions recall instead of re-scanning.

```bash
/explorer:start            # explore once → writes .claude/explorer/ memory
/explorer:start src/auth   # focus a specific module/path
```

Local testing without installing from the marketplace:

```bash
claude --plugin-dir ./plugins/explorer
```

Next session, just open the repo: a SessionStart notice points Claude to the memory, and it
recalls instead of re-scanning. Commit `.claude/explorer/` so your whole team inherits it.

### What you get under `.claude/explorer/`
- `MEMORY.md` — read-this-first master summary (carries explored commit + coverage)
- `map/<area>.md` — per-module deep dives
- `index.json` — machine-readable file index for targeted recall
- `TRACK.md` — coverage ledger + blind spots

## Plugin #2 — `builder`

Spec-driven, gated implementation. `builder` reads the `explorer` memory as ground truth, so
**run `/explorer:start` first** — without an up-to-date `.claude/explorer/` memory, builder has
no codebase context to plan against.

1. Write your requirements as a spec at `.claude/specs/spec1.md` (then `spec2.md`, … for more).
2. Run the orchestrator:

```bash
/builder:start             # plan → gate → implement → QA → sync memory
/builder:status            # cheap state read (no sub-agents) to resume or inspect
```

What `/builder:start` does:
- **Plans** the change from your spec(s) + the explorer memory, rating clarity **9+/10** and the
  technical plan **9+/10** before any code is written (escalates to an Opus planner if the
  Sonnet planner can't clear the bar).
- **Implements** only what the spec says — edits are restricted to the files named in the
  approved plan's Scope (the PreToolUse scope guard enforces this).
- **Runs hybrid QA** — auto-detects a real test/build harness and runs feature-level edge cases
  plus app-level regression; falls back to rigorous static analysis when there's no harness.
- **Syncs the durable memory** so the next session stays accurate (refreshes the explorer
  `MEMORY.md`, `index.json`, `TRACK.md`, `map/*.md`, and the builder log).

Local testing without installing from the marketplace:

```bash
claude --plugin-dir ./plugins/builder
```

### Configuration

Builder settings live in `.claude/builder/settings.json`. The scope guard is **not**
advisory: once an approved `.claude/builder/PLAN.md` exists, edits to files outside its
Scope are **always hard-blocked**, regardless of `enforce_gates`. "Scope is law" is a hard
guarantee, not a setting.

`enforce_gates` (default **`false`**) controls only the two genuinely advisory gates:

- **editing before a plan exists** — warns by default; hard-blocks when enforced;
- **the build-verify Stop gate** — warns about failed verification by default; hard-blocks
  (keeps Claude working) only when enforced.

To turn those two into hard blocks, set:

```json
{ "enforce_gates": true }
```

or export `BUILDER_ENFORCE=1` for a single session.

More settings drive **micro-level precision mode** (both default `true`) and the
**harness reliability** features:

```json
{
  "micro_decomposition": true,
  "require_edge_case_coverage": true,
  "feedback_loop": true,
  "feedback_enforce": false,
  "feedback_run_tests": "ask"
}
```

Set `micro_decomposition` to `false` to fall back to the original single-pass plan/implement;
set `feedback_loop` to `false` to silence the per-edit lint/type loop.

### Micro-level precision mode

Big-context reasoning is where small edge-case bugs hide. This mode makes builder decompose a
requirement into the **smallest independently-verifiable tasks** and write precise code that
explicitly accounts for edge cases — instead of reasoning about everything at once and letting
a boundary case slip.

- **Right-sized decomposition.** The planner splits the change only as far as each unit is
  independently verifiable, and writes a `## Tasks` block per unit in `PLAN.md` (intent,
  files/functions, behavior, an explicit **edge-case list**, and a **Definition of Done**).
  Proportionality is enforced: a one-line change is **one task** — no over-splitting.
- **Edge-case taxonomy.** Each task is hardened against a fixed taxonomy — inputs/boundaries,
  state/lifecycle, IO/external, errors (incl. **fail-open vs fail-closed**), numeric, security,
  portability (incl. OS differences), and contract/invariants — then **extended with the
  codebase-specific risks named in `MEMORY.md`**. See `skills/micro-decompose`.
- **Context isolation.** The implementer works **one task at a time**, with only that task's
  intent + edge-case list in focus — a small context by design.
- **Coverage map + gate.** Every enumerated edge case is written down and provably addressed:
  the implementer records a map in `CHANGELOG.md` (each case → `handled at file:line` |
  `covered by <test>` | `DEFERRED:<reason>` — no silent skips), QA verifies it, and the
  deterministic gate `validate-plan.sh` rejects a plan whose tasks lack edge cases or a DoD,
  naming the exact offending task.

### Harness reliability (Cursor-style techniques)

Borrowed from agentic coding harnesses to raise accuracy and leave fewer leftover bugs:

- **Per-edit closed feedback loop.** A PostToolUse hook (`lint-feedback.sh`) re-checks **only the
  file just edited** with whatever toolchain is installed — auto-detected by extension + project
  markers (ESLint/tsc/Prettier, Ruff/flake8/mypy/black, gofmt/go vet/golangci-lint,
  rustfmt/cargo, or a project's pre-commit). It feeds **concise** diagnostics back to the agent via
  the PostToolUse `additionalContext` channel so they're fixed on the next step. Multi-ecosystem and
  graceful: it only runs tools that are present, prefers fast per-file checks, caps output, and
  skips `.claude/*`, lockfiles, and non-code files. Advisory by default; under `feedback_enforce`
  the Stop gate (`verify-build.sh`) won't pass while edited files still have unaddressed findings.
- **Per-task targeted tests.** After each micro-task, the orchestrator/QA can run tests **scoped to
  the touched files/symbols** (not the whole suite), gated by `feedback_run_tests` (default `"ask"`
  — proposes exact commands, you confirm). Results fold into the task's edge-case coverage map.
- **Hybrid retrieval chain.** Recall the explorer `index.json` by **meaning** (per-file/-symbol
  summaries + imports + callers) → narrow with grep/ripgrep on concrete symbols → read only the
  precise ranges. Index + grep, never whole-file dumps.
- **Explore before change.** Before writing code, the agent locates the existing pattern and **all
  callers** of any symbol it will change, and follows established conventions instead of inventing
  new ones — recorded per task as `Existing pattern:`.
- **Always-on standards + cheap static context.** The implementer always honors the MEMORY.md
  conventions/invariants as non-negotiable standards, and the SessionStart hook prints cheap
  grounding (OS, git branch + clean/dirty, recently-changed files) so the orchestrator starts
  oriented.

## How it works

See `ARCHITECTURE.md`. Read-only sub-agents report to your orchestrator session, which
synthesizes and persists the memory; gated builder sub-agents then plan, implement, and QA
against that memory. Hooks enforce read-only / in-scope behavior and verify the output.

## Notes & limits
- Coverage is honest, never claimed as 100%; blind spots are listed in `TRACK.md`/`MEMORY.md`.
- Hooks give deterministic *gates*, not deterministic model text.
- The one-time exploration is the expensive step by design; recall afterwards is cheap.
- Requires `git` for freshness tracking; `python3` improves hook JSON parsing (falls back gracefully).

## For maintainers — publishing this marketplace

Authoring this repo (not needed to *install* the plugins):

```bash
cd backend-agentic-marketplace
git init
git add .
git commit -m "explorer + builder plugins + marketplace"
git branch -M main
git remote add origin https://github.com/hafizmirhamza276-lab/backend-agentic-marketplace.git
git push -u origin main
```

## License
MIT — see [LICENSE](LICENSE).
