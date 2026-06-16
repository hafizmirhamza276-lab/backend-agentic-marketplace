#!/usr/bin/env bash
# Stop: deterministic verification that the memory artifacts are complete and well-formed.
# Advisory by default (exit 0) so it never blocks normal turns. Only speaks up when a
# .claude/explorer/ directory exists, i.e. an exploration has been attempted.
#
# To ENFORCE (make Claude keep working until the memory is complete), set EXPLORER_ENFORCE=1.
# When enforcing, an incomplete memory exits 2, which feeds the reason back to Claude.
#
# The working-python resolution now comes from the vendored lib/common.sh (so the Windows
# Store `python3` stub can't false-fail valid JSON). We keep `set -uo pipefail` (NOT -e).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SELF_DIR/../lib/common.sh"
ENFORCE="${EXPLORER_ENFORCE:-0}"

PROJECT_DIR="$(bd_project_dir)"
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

# Validate index.json ONLY with a working interpreter. When none is resolvable (a
# python-less host, or the Windows Store `python3` stub) the check is SKIPPED, never
# failed — so valid JSON is not false-flagged (F4).
if [[ -f "$DIR/index.json" ]] && bd_have_python; then
  $BD_PYTHON -c 'import json,sys; json.load(open(sys.argv[1]))' "$DIR/index.json" 2>/dev/null \
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
