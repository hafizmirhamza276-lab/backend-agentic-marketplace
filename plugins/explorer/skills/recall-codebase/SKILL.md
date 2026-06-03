---
name: recall-codebase
description: Load an existing .claude/explorer/ codebase memory and answer from it WITHOUT re-exploring. Use at the start of any session that needs to understand this codebase, and before deciding to run a fresh exploration.
---

# Recall codebase memory (read, don't re-explore)

The whole point of explorer is: explore once, then **read the memory** forever. Before any
agent re-scans the code, it must check whether a fresh memory already answers the question.

## Procedure
1. Check for `.claude/explorer/MEMORY.md`. If absent, there is no memory — a full
   exploration is needed (run `/explorer:start`).
2. If present, read `MEMORY.md` fully. It is the authoritative summary (what / why / how).
3. Read the `explored_commit:` field at the top. Compare to current `git rev-parse HEAD`:
   - **Equal** → memory is current. Answer from memory + `map/<area>.md` + `index.json`.
     Do **not** re-explore.
   - **Different** → run `git diff --name-only <explored_commit> HEAD` to see what changed.
     If changes are unrelated to the question, still answer from memory but flag it. If they
     touch the relevant area, do a *targeted* re-read of just those files (not a full scan),
     or recommend `/explorer:start` for an incremental refresh.
4. To answer a specific question, use `index.json` to jump straight to the relevant files
   and their `map/<area>.md` deep-dive instead of reading the whole tree.
5. Trust `unverified:` markers: if the answer lives in an unverified area, say so rather
   than guessing.

## Output contract
When you recall, tell the user (briefly): whether memory was current, which files you used,
and any staleness caveat. This keeps the "understand by reading" path trustworthy.
