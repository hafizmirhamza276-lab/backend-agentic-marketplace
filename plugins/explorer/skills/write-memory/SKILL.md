---
name: write-memory
description: Write the durable .claude/explorer/ knowledge base (MEMORY.md, TRACK.md, index.json, map/) using a fixed schema. Use after synthesizing explorer sub-agent reports during /explorer:start.
---

# Write the durable codebase memory

Write everything under `${CLAUDE_PROJECT_DIR}/.claude/explorer/` so it lives in the user's
repo (git-trackable) — never inside the plugin (the plugin cache is ephemeral). Create the
directory if needed. Use the exact schemas below so a future agent can rely on the structure.

## File: MEMORY.md  (the master "read this and understand" file)
```markdown
---
explored_commit: <git HEAD sha at exploration time>
explored_at: <ISO8601>
coverage: <NN>%
stack: <one line: languages / frameworks / runtime>
---
# Codebase Memory

## TL;DR (read this first)
3–6 sentences: what this system does, its shape, and the one thing a newcomer must know.

## How it works (the runtime story)
Narrative from entry point to response/effect, naming the key modules in order.

## Why it's built this way
The decisions that explain the shape. One bullet per decision: choice / alternative /
trade-off / evidence(path:line | commit | inferred).

## Module map
Per major area: purpose, key files, how it connects. Link to `map/<area>.md` for depth.

## Data & interfaces
Datastores, core models, public routes/events/APIs (with handler@path:line).

## Conventions to follow
Error handling, logging, config, testing patterns actually used here.

## Risk map & gotchas
Fragile/security/perf areas. "If you change X, watch Y."

## Blind spots
Everything still marked unverified — copied from TRACK.md so the limits are visible.
```

## File: TRACK.md  (progress + coverage ledger)
```markdown
# Exploration Track
explored_commit: <sha>   last_run: <ISO8601>   coverage: <NN>%
## Done (read)
- <area> — <date>
## Sampled (partial)
- <area> — <what was/wasn't checked>
## Unverified (NOT explored)
- <area> — <why>
## Changelog
- <date> <sha> — <what this run added/refreshed>
```

## File: index.json  (machine-readable, for targeted **semantic-ish** recall)
Enrich each file entry so recall can be targeted by MEANING (what a thing does + how it
connects), not just by filename — this is the index half of the hybrid retrieval chain
(index → grep → targeted read). `summary` and `symbols` are required; `imports` and
`used_by` (callers) are recorded **where cheap to derive** (a file's own import block is
cheap; a full caller graph is not — sample it, don't chase every reference). `symbols` may be
bare names or `{ "name", "summary" }` objects when a per-symbol one-liner adds recall value.
```json
{
  "explored_commit": "<sha>",
  "files": [
    {
      "path": "src/...",
      "summary": "<one line: what this file is for>",
      "symbols": ["fnA", { "name": "ClassB", "summary": "<what it does, one line>" }],
      "imports": ["<modules/paths this file imports>"],
      "depends_on": ["path"],
      "used_by": ["<files/symbols that call into this one — callers, where cheap>"],
      "area": "<area>",
      "status": "read|sampled"
    }
  ],
  "areas": { "<area>": "map/<area>.md" }
}
```
Older entries with only `path/summary/symbols/depends_on/area/status` stay valid — the new
fields are additive (consumers, incl. `verify-build.sh`'s path check, only require `path`).

## Folder: map/<area>.md  (one deep-dive per major module)
A focused write-up per area so a future agent reads only what it needs. Same evidence-first
style: cite `path:line`, separate evidence from inference, end with the area's `unverified:` list.

## Rules
- Keep MEMORY.md skimmable; push detail into `map/`.
- Copy unverified items verbatim into MEMORY.md "Blind spots" — never silently drop them.
- Set `coverage` honestly (meaningful paths reviewed, not files touched). Never write 100%.
- Re-runs append to TRACK.md "Changelog" and update `explored_commit`.
