#!/usr/bin/env bash
# PreToolUse (Write|Edit|MultiEdit): the explorer is read-only EXCEPT for the memory it
# writes under .claude/explorer/. Block any write/edit whose target path is outside that
# directory. Exit code 2 blocks the tool call and feeds the reason back to Claude.
#
# Fail-open on parse errors (allow), so a malformed event never bricks a session. Flip
# DEFAULT to "block" below if you prefer fail-closed.
set -uo pipefail
DEFAULT="allow"

event="$(cat 2>/dev/null || true)"

extract_path() {
  # Prefer python3, then jq, then a permissive grep fallback.
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$event" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); ti=d.get("tool_input",{}) or {}
    print(ti.get("file_path") or ti.get("path") or "")
except Exception:
    print("")' 2>/dev/null
  elif command -v jq >/dev/null 2>&1; then
    printf '%s' "$event" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null
  else
    printf '%s' "$event" | grep -oE '"(file_)?path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
  fi
}

target="$(extract_path)"

# No path resolved -> obey DEFAULT.
if [[ -z "$target" ]]; then
  [[ "$DEFAULT" == "block" ]] && { echo "explorer: could not verify write target; blocking by policy." >&2; exit 2; }
  exit 0
fi

# Normalize to absolute.
case "$target" in
  /*) abs="$target" ;;
  *)  abs="${CLAUDE_PROJECT_DIR:-$PWD}/$target" ;;
esac

# Allow only paths under .claude/explorer/
if [[ "$abs" == *"/.claude/explorer/"* ]]; then
  exit 0
fi

echo "explorer is read-only: writes are only allowed under .claude/explorer/. Refusing to modify: $target. If you intended to change source code, switch off the explorer agent first." >&2
exit 2
