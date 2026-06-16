#!/usr/bin/env bash
# PreToolUse (Write|Edit|MultiEdit|NotebookEdit): the explorer is read-only EXCEPT for
# the memory it writes under .claude/explorer/. Block any write/edit whose target path
# is outside that directory. Exit code 2 blocks the tool call and feeds the reason back
# to Claude.
#
# Fail-open on parse errors (allow), so a malformed event never bricks a session. Flip
# DEFAULT to "block" below if you prefer fail-closed.
#
# Shared helpers (the working-python resolver and the lexical path normalizer) now come
# from the vendored lib/common.sh — canonical source is shared/lib/common.sh. We keep
# `set -uo pipefail` (NOT -e); sourcing the lib must not introduce -e here.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SELF_DIR/../lib/common.sh"
DEFAULT="allow"

# Read the hook payload; skip when stdin is a terminal so a missing payload can't block (F11).
if [ -t 0 ]; then event=""; else event="$(cat 2>/dev/null || true)"; fi

extract_path() {
  # Prefer a WORKING python ($BD_PYTHON, resolved by the lib so the Windows Store
  # `python3` stub can't make this fail open), then jq, then a permissive grep fallback.
  # Reads file_path, path, and notebook_path (NotebookEdit) so a notebook write is
  # guarded too (F9).
  if bd_have_python; then
    printf '%s' "$event" | $BD_PYTHON -c 'import sys,json
try:
    d=json.load(sys.stdin); ti=d.get("tool_input",{}) or {}
    print(ti.get("file_path") or ti.get("path") or ti.get("notebook_path") or "")
except Exception:
    print("")' 2>/dev/null
  elif command -v jq >/dev/null 2>&1; then
    printf '%s' "$event" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.notebook_path // empty' 2>/dev/null
  else
    printf '%s' "$event" | grep -oE '"(file_path|path|notebook_path)"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
  fi
}

target="$(extract_path)"

# No path resolved -> obey DEFAULT.
if [[ -z "$target" ]]; then
  [[ "$DEFAULT" == "block" ]] && { echo "explorer: could not verify write target; blocking by policy." >&2; exit 2; }
  exit 0
fi

# Normalize to absolute, then collapse '.'/'..' (bd_normalize_path) so a `..` segment
# can't keep the allow-zone as a substring while resolving elsewhere (F2).
case "$target" in
  /*) abs="$target" ;;
  *)  abs="$(bd_project_dir)/$target" ;;
esac
abs="$(bd_normalize_path "$abs")"

# Allow only paths under .claude/explorer/
if [[ "$abs" == *"/.claude/explorer/"* ]]; then
  exit 0
fi

echo "explorer is read-only: writes are only allowed under .claude/explorer/. Refusing to modify: $target. If you intended to change source code, switch off the explorer agent first." >&2
exit 2
