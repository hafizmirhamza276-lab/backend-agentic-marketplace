#!/usr/bin/env bash
# verify-review.sh — the reviewer's Stop gate + aggregator (section D).
#
# Runs as the reviewer plugin's Stop hook and is invoked directly by /reviewer:run. It runs the
# deterministic change-review checks (lib-review-checks.sh) AND folds in any findings the review
# sub-agents wrote to .claude/reviewer/findings/*.tsv (same SEV\tcheck\tloc\tmsg format), tallies
# BLOCKING/CONCERN (NOTE is informational and EXCLUDED from the gate tally), renders
# .claude/reviewer/REVIEW.md, and records the per-module STATUS the release gate consumes:
#   bd_status_write reviewer review <state> "" blocking=$B concern=$C
# verify-release.sh enforces 0-blocking from that `blocking` count (mirroring how it reads
# `auditor high`). Reviewer and auditor stay ORTHOGONAL — this gate never sources the auditor lib.
#
# ADVISORY by default (always exit 0, just report + record). It hard-blocks (exit 2) on a BLOCKING
# finding only in enforce mode (REVIEWER_ENFORCE=1 or settings.enforce_review=true) — mirroring the
# auditor/builder/pipeline enforce pattern. Decisions are PURE shell/awk; never `set -e` (a single
# check must shape the verdict, not abort the gate); never crashes on missing files.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"
# shellcheck source=./lib-review-checks.sh
. "$DIR/lib-review-checks.sh"

PROJECT="$(bd_project_dir)"
REVIEW_ROOT="$PROJECT"; export REVIEW_ROOT
REV_DIR="$(bd_claude_dir)/reviewer"
REVIEW_MD="$REV_DIR/REVIEW.md"
AGENT_DIR="$REV_DIR/findings"        # optional: per-agent finding files written by /reviewer:run
mkdir -p "$REV_DIR" 2>/dev/null || true

HEAD_FULL=""
if bd_have git && git -C "$PROJECT" rev-parse HEAD >/dev/null 2>&1; then
  HEAD_FULL="$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null || printf '')"
fi

# Enforce mode (advisory by default; mirrors audit_enforce / bd_release_enforce / bd_enforce).
review_enforce() {
  [ "${REVIEWER_ENFORCE:-}" = "1" ] && return 0
  [ "$(bd_setting_at "$REV_DIR/settings.json" enforce_review false)" = "true" ] && return 0
  return 1
}

# Collect findings: deterministic checks + any well-formed agent-written lines.
RAW="$REV_DIR/.findings.$$"
trap 'rm -f "$RAW"' EXIT INT TERM
: > "$RAW"
review_run_all >> "$RAW" 2>/dev/null || true
if [ -d "$AGENT_DIR" ]; then
  for ff in "$AGENT_DIR"/*.tsv; do
    [ -f "$ff" ] || continue
    # keep only well-formed 4-field lines carrying a known severity (defends against a
    # half-written or free-text agent file polluting the tally).
    awk -F'\t' 'NF>=4 && ($1=="BLOCKING"||$1=="CONCERN"||$1=="NOTE")' "$ff" >> "$RAW" 2>/dev/null || true
  done
fi

# Tally — NOTE is excluded from the gate counts by construction.
BLOCK=$(awk   -F'\t' '$1=="BLOCKING"{n++} END{print n+0}' "$RAW" 2>/dev/null); BLOCK=${BLOCK:-0}
CONCERN=$(awk -F'\t' '$1=="CONCERN"{n++}  END{print n+0}' "$RAW" 2>/dev/null); CONCERN=${CONCERN:-0}
NOTE=$(awk    -F'\t' '$1=="NOTE"{n++}     END{print n+0}' "$RAW" 2>/dev/null); NOTE=${NOTE:-0}

if [ "$BLOCK" -gt 0 ]; then STATE="failed"; VERDICT="BLOCKED ($BLOCK blocking)"; else STATE="done"; VERDICT="CLEAN (0 blocking)"; fi
if review_enforce; then MODE="enforce"; else MODE="advisory"; fi
NOW="$(date -u +%FT%TZ 2>/dev/null || printf 'unknown')"

# Record the per-module STATUS the release gate reads (extras: blocking/concern).
bd_status_write reviewer review "$STATE" "" blocking="$BLOCK" concern="$CONCERN" >/dev/null 2>&1 || true

# Render REVIEW.md (deterministic report, grouped by severity).
{
  printf '# Change review — %s\n\n' "$VERDICT"
  printf '%s\n' "- Generated: $NOW"
  printf '%s\n' "- HEAD: ${HEAD_FULL:-unknown}"
  printf '%s\n' "- Mode: $MODE"
  printf '%s\n' "- Tally: BLOCKING=$BLOCK · CONCERN=$CONCERN (NOTE=$NOTE, excluded from the gate)"
  printf '%s\n\n' "- Gate: BLOCKING must be 0 to release — verify-release.sh reads \`reviewer blocking\`."
  for sev in BLOCKING CONCERN NOTE; do
    n=$(awk -F'\t' -v s="$sev" '$1==s{c++} END{print c+0}' "$RAW" 2>/dev/null); n=${n:-0}
    printf '## %s (%s)\n\n' "$sev" "$n"
    if [ "$n" -eq 0 ]; then
      printf 'none\n\n'
    else
      printf '| Check | Location | Finding |\n|---|---|---|\n'
      awk -F'\t' -v s="$sev" '$1==s{gsub(/\|/,"\\|",$4); printf "| %s | %s | %s |\n", $2, $3, $4}' "$RAW" 2>/dev/null
      printf '\n'
    fi
  done
} > "$REVIEW_MD" 2>/dev/null || true

# STDOUT dashboard.
printf '[reviewer] review (%s) — %s\n' "$MODE" "$VERDICT"
printf '  tally: BLOCKING=%s  CONCERN=%s  (NOTE=%s)\n' "$BLOCK" "$CONCERN" "$NOTE"
awk -F'\t' '$1=="BLOCKING"{printf "  BLOCKING  %s  %s — %s\n", $2, $3, $4}' "$RAW" 2>/dev/null
printf '  report: %s\n' "${REVIEW_MD#"$PROJECT"/}"

# Enforce only when asked; otherwise advisory. The release gate is the authoritative 0-blocking
# enforcement regardless of this exit code (it reads the STATUS we just wrote).
if review_enforce && [ "$BLOCK" -gt 0 ]; then
  {
    printf '[reviewer] BLOCKED: %s BLOCKING finding(s) must be 0 to release:\n' "$BLOCK"
    awk -F'\t' '$1=="BLOCKING"{printf "  - %s: %s — %s\n", $2, $3, $4}' "$RAW" 2>/dev/null
    printf 'See %s. Resolve the breakage (or unset enforce) before stopping.\n' "${REVIEW_MD#"$PROJECT"/}"
  } >&2
  exit 2
fi
exit 0
