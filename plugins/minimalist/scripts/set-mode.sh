#!/usr/bin/env bash
# set-mode.sh — set (or show) the `minimalist` intensity mode.
#
# Writes the one word off|lite|full|ultra to ${CLAUDE_PROJECT_DIR}/.claude/minimalist/mode and mirrors
# it into STATUS.json via bd_status_write, so BOTH the node injector hooks (minimalist-activate.js /
# minimalist-turn.js) and the pipeline dashboards read the SAME value. Pure shell — no python
# dependency (bd_status_write carries its own pure-shell fallback, identical on python-less hosts).
#
# Advisory by default: an INVALID mode is rejected FAIL-CLOSED — the current (or default 'full') mode
# is preserved, NOTHING is written, and the script still exits 0. Only under MINIMALIST_ENFORCE=1 does
# an invalid mode exit 2. NEVER crashes: `set -uo pipefail` (NOT -e); every side effect is guarded.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"

MIN_DIR="$(bd_claude_dir)/minimalist"
MODE_FILE="$MIN_DIR/mode"
DEFAULT_MODE="full"

say()  { printf '[minimalist] %s\n' "$*"; }
warn() { printf '[minimalist] %s\n' "$*" >&2; }

min_valid()   { case "$1" in off|lite|full|ultra) return 0 ;; *) return 1 ;; esac; }
min_enforce() { [ "${MINIMALIST_ENFORCE:-}" = "1" ]; }

# Normalize a candidate: strip ALL whitespace, lowercase. Keeps comparison robust to a stray newline
# or padding in the mode file / argument.
min_norm() { printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'; }

# Current persisted mode, or the default when the file is absent/garbled (mirrors the node readMode).
min_current() {
  local v=""
  [ -f "$MODE_FILE" ] && v="$(min_norm "$(cat "$MODE_FILE" 2>/dev/null)")"
  if min_valid "$v"; then printf '%s' "$v"; else printf '%s' "$DEFAULT_MODE"; fi
}

# Mirror the mode into STATUS.json (module=minimalist, phase=mode, state=done, mode=<v>). Guarded so a
# STATUS write failure can never abort the toggle.
min_status() { bd_status_write minimalist mode done "" "mode=$1" >/dev/null 2>&1 || true; }

REQ_RAW="${1:-}"

# No argument -> report the current mode (and refresh STATUS so the dashboard is current). Exit 0.
if [ -z "$REQ_RAW" ]; then
  CUR="$(min_current)"
  say "mode: $CUR  (valid: off|lite|full|ultra).  Usage: /minimize <off|lite|full|ultra>"
  min_status "$CUR"
  exit 0
fi

REQ="$(min_norm "$REQ_RAW")"

# Invalid -> fail-closed: keep the current mode, write NOTHING. Advisory (exit 0) unless enforcing.
if ! min_valid "$REQ"; then
  CUR="$(min_current)"
  warn "invalid mode '$REQ_RAW' — keeping '$CUR'. Valid: off|lite|full|ultra."
  if min_enforce; then exit 2; fi
  exit 0
fi

# Valid -> persist the mode + mirror STATUS. Guarded writes; never crash.
mkdir -p "$MIN_DIR" 2>/dev/null || true
printf '%s\n' "$REQ" > "$MODE_FILE" 2>/dev/null || warn "could not write $MODE_FILE"
min_status "$REQ"
say "mode set to '$REQ'."
exit 0
