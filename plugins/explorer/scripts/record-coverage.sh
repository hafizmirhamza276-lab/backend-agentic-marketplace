#!/usr/bin/env bash
# SubagentStop: record that a sub-agent finished, so TRACK.md reflects progress even if a
# run is interrupted. Best-effort; never blocks.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
DIR="$PROJECT_DIR/.claude/explorer"
TRACK="$DIR/TRACK.md"
mkdir -p "$DIR" 2>/dev/null || true

event="$(cat 2>/dev/null || true)"
name=""
if command -v python3 >/dev/null 2>&1; then
  name="$(printf '%s' "$event" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get("subagent_type") or d.get("agent") or d.get("name") or "subagent")
except Exception:
    print("subagent")' 2>/dev/null)"
fi
[[ -z "$name" ]] && name="subagent"

[[ -f "$TRACK" ]] || printf '# Exploration Track\n## Changelog\n' > "$TRACK"
printf -- '- %s — sub-agent finished: %s\n' "$(date -u +%FT%TZ)" "$name" >> "$TRACK"
exit 0
