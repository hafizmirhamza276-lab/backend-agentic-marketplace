# backend-agentic-marketplace

A Claude Code plugin marketplace for agentic backend engineering.

**Plugin #1 — `explorer`:** explore a codebase **once**, then any future session understands
it (what / why / how) by reading `.claude/explorer/` — no re-exploring.

## Install
```bash
cd backend-agentic-marketplace
git init
git add .
git commit -m "explorer plugin + marketplace"
git branch -M main
git remote add origin https://github.com/hafizmirhamza276-lab/backend-agentic-marketplace.git
git push -u origin main
```

### 2. Add plugin to the marketplace and install the plugin

## Use
```
/explorer:start            # explore once → writes .claude/explorer/ memory
/explorer:start src/auth   # focus a path/module
```
Next session, just open the repo: a SessionStart notice points Claude to the memory, and it
recalls instead of re-scanning. Commit `.claude/explorer/` so your whole team inherits it.

## What you get under .claude/explorer/
- `MEMORY.md` — read-this-first master summary (carries explored commit + coverage)
- `map/<area>.md` — per-module deep dives
- `index.json` — machine-readable file index for targeted recall
- `TRACK.md` — coverage ledger + blind spots

## How it works
See `ARCHITECTURE.md`. Two read-only sub-agents (Sonnet breadth + Opus depth) report to your
orchestrator session, which synthesizes and persists the memory. Hooks enforce read-only
behavior and verify the output.

## Notes & limits
- Coverage is honest, never claimed as 100%; blind spots are listed in `TRACK.md`/`MEMORY.md`.
- Hooks give deterministic *gates*, not deterministic model text.
- The one-time exploration is the expensive step by design; recall afterwards is cheap.
- Requires `git` for freshness tracking; `python3` improves hook JSON parsing (falls back gracefully).

## License
MIT
