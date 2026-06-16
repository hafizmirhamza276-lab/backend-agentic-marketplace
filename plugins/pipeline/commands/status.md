---
description: "Print the consolidated conductor dashboard — module, phase, state, coverage, and freshness for explorer / builder / pipeline — read straight from the STATUS contract, without spawning any sub-agent."
---

# /pipeline:status — consolidated dashboard

Report the conductor's view of the world **without dispatching any sub-agent** (keep it
cheap). This is the `pipeline-status.sh` semantics:

1. Run `"${CLAUDE_PLUGIN_ROOT}"/scripts/pipeline-status.sh` and show its output. It reads
   each module's `STATUS.json` via the `bd_status_read` contract and prints one row per
   module — **module · phase · state · coverage · freshness · updated** — for
   **explorer**, **builder**, and **pipeline**, plus explorer memory **freshness**
   (`explored_commit` vs current `git HEAD`: `current` / `STALE` / `no-memory`).

2. Then add a one-line interpretation and the single recommended next step, e.g.:
   - explorer `STALE` / `no-memory` → "run `/explorer:start` (or `/pipeline:run`, which does
     it first)";
   - builder not `done` → "the build is mid-flight at phase `<phase>` — resume
     `/builder:start`";
   - pipeline release `failed` → "release gate failed — read `.claude/pipeline/RELEASE.md`
     for the failing checks";
   - pipeline release `done` → "release gate passed — ready to report/ship".

Do not change any files. The script never spawns sub-agents, never crashes on a missing
STATUS, and always exits 0, so this is safe to run anytime (it is also the SessionStart
nudge).
