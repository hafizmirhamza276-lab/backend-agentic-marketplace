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

if [[ -f "$DIR/index.json" ]] && command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$DIR/index.json" 2>/dev/null \
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
