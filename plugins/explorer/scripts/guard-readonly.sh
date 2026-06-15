#!/usr/bin/env bash
# PreToolUse (Write|Edit|MultiEdit|NotebookEdit): the explorer is read-only EXCEPT for
# the memory it writes under .claude/explorer/. Block any write/edit whose target path
# is outside that directory. Exit code 2 blocks the tool call and feeds the reason back
# to Claude.
#
# Fail-open on parse errors (allow), so a malformed event never bricks a session. Flip
# DEFAULT to "block" below if you prefer fail-closed.
set -uo pipefail
DEFAULT="allow"

# Resolve a WORKING python interpreter. On Windows `python3` is often the Microsoft
# Store "App Execution Alias" stub: it is on PATH but exits non-zero with EMPTY stdout
# instead of running, which would make this guard fail open. Require each candidate to
# actually execute `-c "pass"` (exit 0); first that works wins, "" if none.
resolve_python() {
  local c
  for c in python3 python "py -3"; do
    if $c -c "pass" >/dev/null 2>&1; then printf '%s' "$c"; return 0; fi
  done
  return 0
}
PY_BIN="$(resolve_python)"

# normalize_path: collapse '.' and '..' segments LEXICALLY (no filesystem access; works
# for non-existent paths). Keeps a leading '/' for absolute inputs. Used so a `..` segment
# can't keep the allow-zone as a substring while resolving elsewhere (F2).
normalize_path() {
  local input="$1" lead="" seg n=0
  local -a parts=()
  case "$input" in /*) lead="/" ;; esac
  set -f
  local IFS='/'
  for seg in $input; do
    case "$seg" in
      ''|.) ;;
      ..)
        if [ "$n" -gt 0 ] && [ "${parts[n-1]}" != ".." ]; then
          n=$((n-1))
        elif [ -z "$lead" ]; then
          parts[n]=".."; n=$((n+1))
        fi ;;
      *) parts[n]="$seg"; n=$((n+1)) ;;
    esac
  done
  set +f
  local out="" i=0
  while [ "$i" -lt "$n" ]; do
    if [ -z "$out" ]; then out="${parts[i]}"; else out="$out/${parts[i]}"; fi
    i=$((i+1))
  done
  printf '%s' "$lead$out"
}

# Read the hook payload; skip when stdin is a terminal so a missing payload can't block (F11).
if [ -t 0 ]; then event=""; else event="$(cat 2>/dev/null || true)"; fi

extract_path() {
  # Prefer a working python3, then jq, then a permissive grep fallback. Reads file_path,
  # path, and notebook_path (NotebookEdit) so a notebook write is guarded too (F9).
  if [[ -n "$PY_BIN" ]]; then
    printf '%s' "$event" | $PY_BIN -c 'import sys,json
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

# Normalize to absolute, then collapse '.'/'..' so traversal can't escape the allow-zone (F2).
case "$target" in
  /*) abs="$target" ;;
  *)  abs="${CLAUDE_PROJECT_DIR:-$PWD}/$target" ;;
esac
abs="$(normalize_path "$abs")"

# Allow only paths under .claude/explorer/
if [[ "$abs" == *"/.claude/explorer/"* ]]; then
  exit 0
fi

echo "explorer is read-only: writes are only allowed under .claude/explorer/. Refusing to modify: $target. If you intended to change source code, switch off the explorer agent first." >&2
exit 2
