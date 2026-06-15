#!/usr/bin/env bash
# SubagentStop: record that a sub-agent finished, so TRACK.md reflects progress even if a
# run is interrupted. Best-effort; never blocks.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
DIR="$PROJECT_DIR/.claude/explorer"
TRACK="$DIR/TRACK.md"
mkdir -p "$DIR" 2>/dev/null || true

# Resolve a WORKING python interpreter (skip the Windows Store `python3` stub, which is
# on PATH but exits non-zero with empty stdout).
resolve_python() {
  local c
  for c in python3 python "py -3"; do
    if $c -c "pass" >/dev/null 2>&1; then printf '%s' "$c"; return 0; fi
  done
  return 0
}
PY_BIN="$(resolve_python)"

# Read the payload; skip when stdin is a terminal so a missing payload can't block (F11).
if [ -t 0 ]; then event=""; else event="$(cat 2>/dev/null || true)"; fi
name=""
if [[ -n "$PY_BIN" ]]; then
  # SubagentStop's documented key is agent_type; fall back to subagent_type for older
  # Claude Code builds (F7).
  name="$(printf '%s' "$event" | $PY_BIN -c 'import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get("agent_type") or d.get("subagent_type") or d.get("agent") or d.get("name") or "subagent")
except Exception:
    print("subagent")' 2>/dev/null)"
fi
[[ -z "$name" ]] && name="subagent"

[[ -f "$TRACK" ]] || printf '# Exploration Track\n## Changelog\n' > "$TRACK"
printf -- '- %s — sub-agent finished: %s\n' "$(date -u +%FT%TZ)" "$name" >> "$TRACK"
exit 0
