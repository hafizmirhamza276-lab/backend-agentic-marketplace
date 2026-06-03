---
name: recall-memory
description: "Load the durable codebase memory written by the explorer plugin (.claude/explorer/MEMORY.md, index.json, TRACK.md, map/*.md) and turn it into a compact, build-ready context brief. Use this BEFORE planning or changing any code. Never re-scan the codebase when valid memory exists — recall is cheap, re-exploration is the expensive step the explorer already paid."
---

# recall-memory

Ground truth for `builder` is the explorer memory, not a fresh scan. Your job is
to read it, confirm it is usable, and hand the orchestrator a short brief.

## Inputs (read, do not write code)
- `.claude/explorer/MEMORY.md` — master summary + frontmatter (`explored_commit`, `coverage`).
- `.claude/explorer/index.json` — `{ explored_commit, areas, files[] }`.
- `.claude/explorer/TRACK.md` — Done / Sampled / Unverified ledger.
- `.claude/explorer/map/<area>.md` — per-module deep dives (read only the areas relevant to the spec).

## Procedure
1. **Existence + freshness.** If `MEMORY.md` is missing, STOP and report: "run `/explorer:start` first." If `explored_commit` ≠ current `git HEAD`, flag the memory as STALE and name what may have drifted; recommend re-exploring before a risky change.
2. **Targeted read.** Read `MEMORY.md` fully (it is small by design). From `index.json`, pull only the `files[]` and `areas` the spec is likely to touch. Open the matching `map/<area>.md` for those areas only — do not read every map.
3. **Trust calibration.** Note each relevant file's `status` (Done / Sampled / Unverified) and the reported `coverage`. Treat `Unverified` / off-repo logic (e.g. SQL stored procedures) as assumptions, not facts.
4. **Path sanity.** index.json paths have been wrong before (right file, wrong folder). For any path you will rely on, confirm it resolves with `find`/glob; record corrected paths in your brief.

## Output
Write the full brief to `.claude/builder/CONTEXT.md` with these sections:
- **Relevant areas & files** — `path` · `status` · one-line role (only what touches the spec).
- **Invariants & conventions** — from MEMORY.md (naming, error handling, data access patterns) the change must preserve.
- **Risks & gotchas** — the MEMORY.md risk map items in/near the change area.
- **Blind spots & assumptions** — coverage gaps, off-repo logic, `Unverified` files.
- **Freshness** — `explored_commit` vs HEAD; STALE or current.

**Return to the orchestrator only a ≤12-line summary**: freshness verdict, the
relevant file list, the top 3 risks, and any blind spot that blocks confident
implementation. Keep the orchestrator's context lean — detail lives in CONTEXT.md.
