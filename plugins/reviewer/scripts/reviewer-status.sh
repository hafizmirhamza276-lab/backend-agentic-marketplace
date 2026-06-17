#!/usr/bin/env bash
# reviewer-status.sh — SessionStart dashboard for the reviewer plugin.
#
# Prints the last recorded review verdict to STDOUT (SessionStart injects stdout into Claude's
# context — F6), so a fresh session immediately knows whether the current change is review-clean or
# carries BLOCKING breakage. Read-only, never blocks, never crashes: `set -uo pipefail` (NOT -e)
# and every read is guarded, so a missing/garbled STATUS just yields a nudge, not an error.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"

STATUS_FILE="$(bd_claude_dir)/reviewer/STATUS.json"
if [ ! -f "$STATUS_FILE" ]; then
  printf '[reviewer] No review recorded yet. Run /reviewer:run to review the current change against the MEMORY.md invariants/risk map, surviving callers, and the PLAN scope.\n'
  exit 0
fi

STATE="$(bd_status_read reviewer state 2>/dev/null || true)"
BLOCK="$(bd_status_read reviewer blocking 2>/dev/null || true)"
CONCERN="$(bd_status_read reviewer concern 2>/dev/null || true)"
COMMIT="$(bd_status_read reviewer commit 2>/dev/null || true)"
UPDATED="$(bd_status_read reviewer updated_at 2>/dev/null || true)"

printf '[reviewer] last review: state=%s · BLOCKING=%s CONCERN=%s · commit=%s · %s\n' \
  "${STATE:-?}" "${BLOCK:-?}" "${CONCERN:-?}" "${COMMIT:-?}" "${UPDATED:-?}"

# Staleness hint: compare the reviewed commit to current HEAD (short).
HEAD_SHORT="$(bd_git_head)"
if [ -n "${COMMIT:-}" ] && [ "$COMMIT" != "unknown" ] && [ "$HEAD_SHORT" != "unknown" ] && [ "$COMMIT" != "$HEAD_SHORT" ]; then
  printf '[reviewer] review is for commit %s but HEAD is %s — re-run /reviewer:run to refresh.\n' "$COMMIT" "$HEAD_SHORT"
fi

if [ -n "${BLOCK:-}" ] && [ "${BLOCK:-0}" != "0" ]; then
  printf '[reviewer] %s BLOCKING finding(s) — the release gate will BLOCK. See .claude/reviewer/REVIEW.md, fix, then re-run /reviewer:run.\n' "$BLOCK"
else
  printf '[reviewer] 0 BLOCKING — the release-gate reviewer check is satisfied. Re-run /reviewer:run after changes.\n'
fi
exit 0
