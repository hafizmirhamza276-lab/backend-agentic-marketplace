#!/usr/bin/env bash
# verify-ops.sh — the ops plugin's Stop gate + aggregator (section C).
#
# Runs as the ops plugin's Stop hook and is invoked directly by /ops:run. It runs the deterministic
# readiness checks (lib-ops-checks.sh) AND folds in any findings the ops sub-agents wrote to
# .claude/ops/findings/*.tsv (same SEV\tcheck\tloc\tmsg format — the agents contribute the fuzzy
# deploy/observability judgment as advisory CONCERN/NOTE), tallies BLOCKING/CONCERN (NOTE is
# informational and EXCLUDED from the gate tally), renders .claude/ops/OPS.md, and records the
# per-module STATUS the release gate consumes:
#   bd_status_write ops readiness <state> "" blocking=$B concern=$C
# verify-release.sh enforces 0-blocking from that `blocking` count (mirroring how it reads
# `auditor high` and `reviewer blocking`).
#
# ADVISORY by default (always exit 0, just report + record). It hard-blocks (exit 2) on a BLOCKING
# finding only in enforce mode (OPS_ENFORCE=1 or settings.enforce_ops=true) — mirroring the
# auditor/reviewer/builder/pipeline enforce pattern. Decisions are PURE shell/awk; never `set -e`
# (a single check must shape the verdict, not abort the gate); never crashes on missing files.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"
# shellcheck source=./lib-ops-checks.sh
. "$DIR/lib-ops-checks.sh"

PROJECT="$(bd_project_dir)"
OPS_ROOT="$PROJECT"; export OPS_ROOT
OPS_DIR="$(bd_claude_dir)/ops"
OPS_MD="$OPS_DIR/OPS.md"
AGENT_DIR="$OPS_DIR/findings"        # optional: per-agent finding files written by /ops:run
mkdir -p "$OPS_DIR" 2>/dev/null || true

HEAD_FULL=""
if bd_have git && git -C "$PROJECT" rev-parse HEAD >/dev/null 2>&1; then
  HEAD_FULL="$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null || printf '')"
fi

# Enforce mode (advisory by default; mirrors audit_enforce / review_enforce / bd_release_enforce).
ops_enforce() {
  [ "${OPS_ENFORCE:-}" = "1" ] && return 0
  [ "$(bd_setting_at "$OPS_DIR/settings.json" enforce_ops false)" = "true" ] && return 0
  return 1
}

# Collect findings: deterministic checks + any well-formed agent-written lines.
RAW="$OPS_DIR/.findings.$$"
trap 'rm -f "$RAW"' EXIT INT TERM
: > "$RAW"
ops_run_all >> "$RAW" 2>/dev/null || true
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

if [ "$BLOCK" -gt 0 ]; then STATE="failed"; VERDICT="NOT READY ($BLOCK blocking)"; else STATE="done"; VERDICT="READY (0 blocking)"; fi
if ops_enforce; then MODE="enforce"; else MODE="advisory"; fi
NOW="$(date -u +%FT%TZ 2>/dev/null || printf 'unknown')"

# Record the per-module STATUS the release gate reads (extras: blocking/concern). Also STAMP the working
# tree this readiness check examined (F-A2), mirroring verify-build/verify-audit/verify-review: the
# release gate's tree_stale is now FAIL-CLOSED (a module with NO recorded tree reads STALE), so a fresh
# run must record its tree or it would be falsely stale. bd_tree_digest is pure-git (identical w/o python).
bd_status_write ops readiness "$STATE" "" blocking="$BLOCK" concern="$CONCERN" tree="$(bd_tree_digest)" >/dev/null 2>&1 || true

# Render OPS.md (deterministic report, grouped by severity).
{
  printf '# Deploy/release readiness — %s\n\n' "$VERDICT"
  printf '%s\n' "- Generated: $NOW"
  printf '%s\n' "- HEAD: ${HEAD_FULL:-unknown}"
  printf '%s\n' "- Mode: $MODE"
  printf '%s\n' "- Tally: BLOCKING=$BLOCK · CONCERN=$CONCERN (NOTE=$NOTE, excluded from the gate)"
  printf '%s\n\n' "- Gate: BLOCKING must be 0 to release — verify-release.sh reads \`ops blocking\`."
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
} > "$OPS_MD" 2>/dev/null || true

# STDOUT dashboard.
printf '[ops] readiness (%s) — %s\n' "$MODE" "$VERDICT"
printf '  tally: BLOCKING=%s  CONCERN=%s  (NOTE=%s)\n' "$BLOCK" "$CONCERN" "$NOTE"
awk -F'\t' '$1=="BLOCKING"{printf "  BLOCKING  %s  %s — %s\n", $2, $3, $4}' "$RAW" 2>/dev/null
printf '  report: %s\n' "${OPS_MD#"$PROJECT"/}"

# Enforce only when asked; otherwise advisory. The release gate is the authoritative 0-blocking
# enforcement regardless of this exit code (it reads the STATUS we just wrote).
if ops_enforce && [ "$BLOCK" -gt 0 ]; then
  {
    printf '[ops] NOT READY: %s BLOCKING finding(s) must be 0 to release:\n' "$BLOCK"
    awk -F'\t' '$1=="BLOCKING"{printf "  - %s: %s — %s\n", $2, $3, $4}' "$RAW" 2>/dev/null
    printf 'See %s. Resolve the readiness blocker (or unset enforce) before stopping.\n' "${OPS_MD#"$PROJECT"/}"
  } >&2
  exit 2
fi
exit 0
