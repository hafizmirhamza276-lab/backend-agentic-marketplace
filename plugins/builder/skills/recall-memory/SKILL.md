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

## Hybrid retrieval chain (recall → grep → targeted read — do it in this order)
This mirrors a fast index+grep workflow: cheap memory first, precise search second, narrow
reads last. Never start by dumping whole files into context.
1. **Recall (semantic-ish):** read `MEMORY.md`, and from `index.json` select the `files[]` whose
   `summary` / `symbols` / `imports` / `used_by` match the spec by **meaning**, not just filename.
   This is the index half of the chain and is cheap — it can run at the low-effort search tier.
2. **Grep/ripgrep (concrete):** narrow with a search for the **exact symbols** the change touches
   (definitions AND callers/usages, e.g. `rg -n 'OrderService\\b'`), so you find every site that
   matters — not just the one the spec named.
3. **Targeted read:** open only the **precise ranges** the grep hits point to (and the matching
   `map/<area>.md`), never whole files end-to-end. Return **summaries with `path:line` cites** to
   the orchestrator — never raw file dumps.

## Procedure
1. **Existence + freshness.** If `MEMORY.md` is missing, STOP and report: "run `/explorer:start` first." If `explored_commit` ≠ current `git HEAD`, flag the memory as STALE and name what may have drifted; recommend re-exploring before a risky change.
2. **Targeted read.** Read `MEMORY.md` fully (it is small by design). From `index.json`, pull only the `files[]` and `areas` the spec is likely to touch (by meaning — use `summary`/`symbols`/`used_by`). Open the matching `map/<area>.md` for those areas only — do not read every map.
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
