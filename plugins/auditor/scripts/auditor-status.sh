#!/usr/bin/env bash
# auditor-status.sh — SessionStart dashboard for the auditor plugin.
#
# Prints the last recorded audit verdict to STDOUT (SessionStart injects stdout into Claude's
# context — F6), so a fresh session immediately knows whether the repo is release-clean or
# carries HIGH regressions. Read-only, never blocks, never crashes: `set -uo pipefail` (NOT
# -e) and every read is guarded, so a missing/garbled STATUS just yields a nudge, not an error.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"

STATUS_FILE="$(bd_claude_dir)/auditor/STATUS.json"
if [ ! -f "$STATUS_FILE" ]; then
  printf '[auditor] No audit recorded yet. Run /auditor:run to scan for the F1–F13 failure classes (fail-open, traversal, broken hook contracts, manifest/lib drift, …).\n'
  exit 0
fi

STATE="$(bd_status_read auditor state 2>/dev/null || true)"
HIGH="$(bd_status_read auditor high 2>/dev/null || true)"
MED="$(bd_status_read auditor med 2>/dev/null || true)"
LOW="$(bd_status_read auditor low 2>/dev/null || true)"
COMMIT="$(bd_status_read auditor commit 2>/dev/null || true)"
UPDATED="$(bd_status_read auditor updated_at 2>/dev/null || true)"

printf '[auditor] last audit: state=%s · HIGH=%s MEDIUM=%s LOW=%s · commit=%s · %s\n' \
  "${STATE:-?}" "${HIGH:-?}" "${MED:-?}" "${LOW:-?}" "${COMMIT:-?}" "${UPDATED:-?}"

# Staleness hint: compare the audited commit to current HEAD (short).
HEAD_SHORT="$(bd_git_head)"
if [ -n "${COMMIT:-}" ] && [ "$COMMIT" != "unknown" ] && [ "$HEAD_SHORT" != "unknown" ] && [ "$COMMIT" != "$HEAD_SHORT" ]; then
  printf '[auditor] audit is for commit %s but HEAD is %s — re-run /auditor:run to refresh.\n' "$COMMIT" "$HEAD_SHORT"
fi

if [ -n "${HIGH:-}" ] && [ "${HIGH:-0}" != "0" ]; then
  printf '[auditor] %s HIGH finding(s) — the release gate will BLOCK. See .claude/auditor/FINDINGS.md, fix, then re-run /auditor:run.\n' "$HIGH"
else
  printf '[auditor] 0 HIGH — the release-gate auditor check is satisfied. Re-run /auditor:run after changes.\n'
fi
exit 0
