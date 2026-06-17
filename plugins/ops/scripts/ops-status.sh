#!/usr/bin/env bash
# ops-status.sh — SessionStart dashboard for the ops plugin.
#
# Prints the last recorded readiness verdict to STDOUT (SessionStart injects stdout into Claude's
# context — F6), so a fresh session immediately knows whether the codebase is deploy/release-ready
# or carries a BLOCKING readiness gap. Read-only, never blocks, never crashes: `set -uo pipefail`
# (NOT -e) and every read is guarded, so a missing/garbled STATUS just yields a nudge, not an error.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"

STATUS_FILE="$(bd_claude_dir)/ops/STATUS.json"
if [ ! -f "$STATUS_FILE" ]; then
  printf '[ops] No readiness assessment recorded yet. Run /ops:run to assess deploy/release readiness (build/test ledger, version consistency, and the deploy/observability surface).\n'
  exit 0
fi

STATE="$(bd_status_read ops state 2>/dev/null || true)"
BLOCK="$(bd_status_read ops blocking 2>/dev/null || true)"
CONCERN="$(bd_status_read ops concern 2>/dev/null || true)"
COMMIT="$(bd_status_read ops commit 2>/dev/null || true)"
UPDATED="$(bd_status_read ops updated_at 2>/dev/null || true)"

printf '[ops] last readiness: state=%s · BLOCKING=%s CONCERN=%s · commit=%s · %s\n' \
  "${STATE:-?}" "${BLOCK:-?}" "${CONCERN:-?}" "${COMMIT:-?}" "${UPDATED:-?}"

# Staleness hint: compare the assessed commit to current HEAD (short).
HEAD_SHORT="$(bd_git_head)"
if [ -n "${COMMIT:-}" ] && [ "$COMMIT" != "unknown" ] && [ "$HEAD_SHORT" != "unknown" ] && [ "$COMMIT" != "$HEAD_SHORT" ]; then
  printf '[ops] assessment is for commit %s but HEAD is %s — re-run /ops:run to refresh.\n' "$COMMIT" "$HEAD_SHORT"
fi

if [ -n "${BLOCK:-}" ] && [ "${BLOCK:-0}" != "0" ]; then
  printf '[ops] %s BLOCKING finding(s) — the release gate will BLOCK. See .claude/ops/OPS.md, resolve, then re-run /ops:run.\n' "$BLOCK"
else
  printf '[ops] 0 BLOCKING — the release-gate ops check is satisfied. Re-run /ops:run after changes.\n'
fi
exit 0
