---
description: One-shot codebase exploration. Checks for existing memory; if stale or missing, runs the breadth+depth explorer sub-agents and writes a durable .claude/explorer/ knowledge base.
argument-hint: "[optional: a path or module to focus on]"
---

# /start — Orchestrate a one-time codebase exploration

You are the **Orchestrator**. Your job is to produce (or refresh) a durable codebase
memory under `.claude/explorer/` so that any future session can understand this code —
**what** it does, **why** it was built this way, and **how** it works — by reading files
alone, with no re-exploration.

User focus argument (may be empty): `$ARGUMENTS`

Follow these phases **in order**. Do not skip the freshness check.

## Phase 0 — Freshness gate (avoid needless re-exploration)
1. Read the `recall-codebase` skill and follow it.
2. If `.claude/explorer/MEMORY.md` exists AND its recorded `explored_commit` matches the
   current `git rev-parse HEAD` (or the diff since then is trivial), then **stop here**:
   load the memory, tell the user it is already current, and summarize what is known.
   Do **not** spawn explorer sub-agents.
3. Otherwise continue. If memory exists but is stale, note which files changed since
   `explored_commit` so the sub-agents prioritize them (incremental update).

## Phase 1 — Dispatch the explorer sub-agents (parallel, isolated context)
Read the `explore-codebase` skill first so you know the coverage rules and report schema.
Then delegate, in parallel, to two sub-agents. Pass each one the focus argument, the repo
root, and (if incremental) the list of changed files **inside the Task prompt** — they
cannot see your context otherwise.

- **explorer-scout** (breadth, Sonnet): full structure, entry points, dependencies,
  conventions, data models, external interfaces — the "what" and "how".
- **explorer-sage** (depth, Opus): architectural rationale, non-obvious design decisions,
  trade-offs, invariants, gotchas, and risky areas — the "why".

Each returns a single structured Markdown report (schema defined in `explore-codebase`).

## Phase 2 — Synthesize and persist
1. Read both reports. Reconcile conflicts; prefer evidence (file + line) over assertion.
2. Follow the `write-memory` skill to write, under `.claude/explorer/`:
   - `MEMORY.md`   — the master "read this to understand everything" file
   - `TRACK.md`    — coverage ledger + what is still unverified
   - `index.json`  — machine-readable file→summary→symbols→deps index
   - `map/<area>.md` — one deep-dive per major module/area
3. Record `explored_commit` (current HEAD) and a coverage estimate in `MEMORY.md` and `TRACK.md`.

## Phase 3 — Report to the user
Summarize: coverage %, biggest risks, and the single command a future session should run
(`/explorer:start` re-checks freshness; reading `.claude/explorer/MEMORY.md` is enough to recall).

> Honesty rule: never claim 100% understanding. State coverage and list every area marked
> `unverified` in TRACK.md so the user knows the blind spots.
