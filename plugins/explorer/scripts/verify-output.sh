#!/usr/bin/env bash
# Stop: deterministic verification that the memory artifacts are complete and well-formed.
# Advisory by default (exit 0) so it never blocks normal turns. Only speaks up when a
# .claude/explorer/ directory exists, i.e. an exploration has been attempted.
#
# To ENFORCE (make Claude keep working until the memory is complete), set ENFORCE=1.
# When enforcing, an incomplete memory exits 2, which feeds the reason back to Claude.
set -uo pipefail
ENFORCE="${EXPLORER_ENFORCE:-0}"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
DIR="$PROJECT_DIR/.claude/explorer"

# Resolve a WORKING python interpreter for JSON validation. On Windows `python3` is
# often the Microsoft Store stub: on PATH but exits non-zero with empty stdout. Trusting
# it would make `json.load` "fail" on perfectly valid JSON and (under ENFORCE) block the
# Stop. Require the interpreter to actually run; "" means none works → skip the check (F4).
resolve_python() {
  local c
  for c in python3 python "py -3"; do
    if $c -c "pass" >/dev/null 2>&1; then printf '%s' "$c"; return 0; fi
  done
  return 0
}
PY_BIN="$(resolve_python)"

# Nothing to verify if exploration was never started.
[[ -d "$DIR" ]] || exit 0

problems=()
[[ -f "$DIR/MEMORY.md" ]]   || problems+=("MEMORY.md missing")
[[ -f "$DIR/TRACK.md" ]]    || problems+=("TRACK.md missing")
[[ -f "$DIR/index.json" ]]  || problems+=("index.json missing")

if [[ -f "$DIR/MEMORY.md" ]]; then
  for h in "## TL;DR" "## How it works" "## Why it's built this way" "## Module map" "## Risk map" "## Blind spots"; do
    grep -qF "$h" "$DIR/MEMORY.md" || problems+=("MEMORY.md missing section: $h")
  done
  grep -qE '^explored_commit:' "$DIR/MEMORY.md" || problems+=("MEMORY.md missing explored_commit")
  grep -qE '^coverage:' "$DIR/MEMORY.md"        || problems+=("MEMORY.md missing coverage")
fi

if [[ -f "$DIR/index.json" ]] && [[ -n "$PY_BIN" ]]; then
  $PY_BIN -c 'import json,sys; json.load(open(sys.argv[1]))' "$DIR/index.json" 2>/dev/null \
    || problems+=("index.json is not valid JSON")
fi

if [[ ${#problems[@]} -eq 0 ]]; then
  exit 0
fi

msg="explorer memory incomplete: $(IFS='; '; echo "${problems[*]}")"
if [[ "$ENFORCE" == "1" ]]; then
  echo "$msg — finish writing the memory per the write-memory skill before stopping." >&2
  exit 2
else
  echo "[explorer] $msg" >&2
  exit 0
fi
