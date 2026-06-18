---
description: "Set or show the always-on minimalist intensity: off | lite | full | ultra (default full). Persists .claude/minimalist/mode and mirrors STATUS.json; BOTH injector hooks and the minimal-code skill read it. Usage: /minimize [off|lite|full|ultra]"
argument-hint: "[off|lite|full|ultra]"
---

# /minimize — set the minimal-code intensity

Set (or show) how strict the always-on **minimal-code** discipline is for this project. Optional
argument: `$ARGUMENTS`. The single word is persisted to `.claude/minimalist/mode` and mirrored into
`.claude/minimalist/STATUS.json`, so the SessionStart injector (`minimalist-activate.js`), the per-turn
reminder (`minimalist-turn.js`), and the dashboards all read the **same** value.

## Levels
- **off** — disable the capability. SessionStart injects nothing; the per-turn reminder is silent. The
  `minimal-code` skill is still available on demand.
- **lite** — a gentle nudge: prefer the smaller option, apply light judgment; `bd:min:` markers optional.
- **full** *(default)* — apply the whole ladder, the rules, and output discipline every time; leave a
  `bd:min:` marker on every intentional shortcut.
- **ultra** — strictest: justify every new file/dependency, lead with deletion, question an over-complex
  request before writing it; a `bd:min:` marker is mandatory for any non-obvious amount of code.

## Usage
Run the toggle (advisory by default — an invalid value is rejected fail-closed and the current mode is
kept; only `MINIMALIST_ENFORCE=1` makes an invalid value exit 2):

- **Show the current mode** (and refresh STATUS):

  ```
  "${CLAUDE_PLUGIN_ROOT}"/scripts/set-mode.sh
  ```

- **Set a level / turn it off** — pass one of `off|lite|full|ultra`:

  ```
  "${CLAUDE_PLUGIN_ROOT}"/scripts/set-mode.sh ultra
  "${CLAUDE_PLUGIN_ROOT}"/scripts/set-mode.sh off
  ```

Then read back what was recorded — the STATUS contract surfaces the mode for the dashboards:

```
bd_status_read minimalist mode      # -> off | lite | full | ultra
bd_status_read minimalist state     # -> done
```

## Notes
- The toggle is **pure shell** (no python dependency); the node injector hooks are node-guarded and
  fail-quiet, so on a node-less host the mode still persists and the `minimal-code` skill still works.
- These hooks **inject context only** — they make no gate decision. Every gate in this marketplace stays
  pure shell/awk. `/minimize` changes how much guidance is injected, never what a gate enforces.
- See the **`minimal-code`** skill (`${CLAUDE_PLUGIN_ROOT}/skills/minimal-code/SKILL.md`) for the ladder
  itself. Ladder adapted from Ponytail by Dietrich Gebert (MIT).
