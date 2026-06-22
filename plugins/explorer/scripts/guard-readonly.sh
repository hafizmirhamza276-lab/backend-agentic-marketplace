#!/usr/bin/env bash
# PreToolUse (Write|Edit|MultiEdit|NotebookEdit): the explorer is read-only EXCEPT for
# the memory it writes under .claude/explorer/. Block any write/edit whose target path
# is outside that directory. Exit code 2 blocks the tool call and feeds the reason back
# to Claude.
#
# FAIL-CLOSED on an unverifiable target (F-B1): a hook payload whose write target cannot be resolved
# is BLOCKED (exit 2), matching guard-bash-write's conservative stance — an unverifiable write must not
# slip through. (Previously DEFAULT=allow waved these through: a fail-open, the same hole F-B1 closes
# in the bash-write guard.)
#
# Shared helpers (the working-python resolver and the lexical path normalizer) now come
# from the vendored lib/common.sh — canonical source is shared/lib/common.sh. We keep
# `set -uo pipefail` (NOT -e); sourcing the lib must not introduce -e here.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SELF_DIR/../lib/common.sh"
DEFAULT="block"   #READONLY_DEFAULT fail-closed (F-B1): an unresolved write target is REFUSED, not allowed

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

# No path resolved -> obey DEFAULT, now "block" (F-B1): an unverifiable target is refused fail-closed
# rather than waved through. (A well-formed Write/Edit/NotebookEdit always carries a path, resolved by
# python/jq/grep above; an empty target means a malformed/opaque payload, exactly what to refuse.)
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

# Allow only paths strictly UNDER this project's OWN .claude/explorer/ zone. Resolve the zone
# from bd_project_dir — the SAME base used to resolve a relative target above, so the two agree —
# and normalize it the SAME way as $abs, then require $abs to sit under it as an anchored path
# PREFIX. A bare substring test (the old form, *"/.claude/explorer/"*) also allowed an ABSOLUTE
# path OUTSIDE this project that merely CONTAINED "/.claude/explorer/" (e.g. another project's
# memory under /other/.claude/explorer/); anchoring to $ZONE closes that hole (#3).
PROJECT="$(bd_project_dir)"
ZONE="$(bd_normalize_path "$PROJECT/.claude/explorer")"
case "$abs" in
  "$ZONE"/*) exit 0 ;;
esac

echo "explorer is read-only: writes are only allowed under .claude/explorer/. Refusing to modify: $target. If you intended to change source code, switch off the explorer agent first." >&2
exit 2
