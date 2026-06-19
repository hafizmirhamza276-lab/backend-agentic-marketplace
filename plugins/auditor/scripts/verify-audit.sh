#!/usr/bin/env bash
# verify-audit.sh — the auditor's Stop gate + aggregator (section D).
#
# Runs as the auditor plugin's Stop hook and is invoked directly by /auditor:run. It runs the
# deterministic static detectors (lib-audit-checks.sh) AND folds in any findings the audit
# sub-agents wrote to .claude/auditor/findings/*.tsv (same SEV\tdetector\tloc\tmsg format),
# tallies HIGH/MEDIUM/LOW (ADVISORY is informational and EXCLUDED from the tally), renders
# .claude/auditor/FINDINGS.md, and records the per-module STATUS that the release gate
# consumes:  bd_status_write auditor audit <state> "" high=$H med=$M low=$L
# verify-release.sh enforces 0-high from that `high` count.
#
# ADVISORY by default (always exit 0, just report + record). It hard-blocks (exit 2) on a HIGH
# finding only in enforce mode (AUDITOR_ENFORCE=1 or settings.enforce_audit=true) — mirroring
# the builder/pipeline enforce pattern. Decisions are PURE shell/awk; never `set -e` (a single
# detector must shape the verdict, not abort the gate); never crashes on missing files.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"
# shellcheck source=./lib-audit-checks.sh
. "$DIR/lib-audit-checks.sh"

PROJECT="$(bd_project_dir)"
AUDIT_ROOT="$PROJECT"; export AUDIT_ROOT
AUD_DIR="$(bd_claude_dir)/auditor"
FINDINGS_MD="$AUD_DIR/FINDINGS.md"
AGENT_DIR="$AUD_DIR/findings"        # optional: per-agent finding files written by /auditor:run
mkdir -p "$AUD_DIR" 2>/dev/null || true

HEAD_FULL=""
if bd_have git && git -C "$PROJECT" rev-parse HEAD >/dev/null 2>&1; then
  HEAD_FULL="$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null || printf '')"
fi

# Enforce mode (advisory by default; mirrors bd_release_enforce / bd_enforce).
audit_enforce() {
  [ "${AUDITOR_ENFORCE:-}" = "1" ] && return 0
  [ "$(bd_setting_at "$AUD_DIR/settings.json" enforce_audit false)" = "true" ] && return 0
  return 1
}

# Collect findings: deterministic detectors + any well-formed agent-written lines.
RAW="$AUD_DIR/.findings.$$"
trap 'rm -f "$RAW"' EXIT INT TERM
: > "$RAW"
audit_run_all >> "$RAW" 2>/dev/null || true
if [ -d "$AGENT_DIR" ]; then
  for ff in "$AGENT_DIR"/*.tsv; do
    [ -f "$ff" ] || continue
    # keep only well-formed 4-field lines carrying a known severity (defends against a
    # half-written or free-text agent file polluting the tally).
    awk -F'\t' 'NF>=4 && ($1=="HIGH"||$1=="MEDIUM"||$1=="LOW"||$1=="ADVISORY")' "$ff" >> "$RAW" 2>/dev/null || true
  done
fi

# Tally — ADVISORY is excluded from the gate counts by construction.
HIGH=$(awk -F'\t' '$1=="HIGH"{n++}   END{print n+0}' "$RAW" 2>/dev/null); HIGH=${HIGH:-0}
MED=$(awk  -F'\t' '$1=="MEDIUM"{n++} END{print n+0}' "$RAW" 2>/dev/null); MED=${MED:-0}
LOW=$(awk  -F'\t' '$1=="LOW"{n++}    END{print n+0}' "$RAW" 2>/dev/null); LOW=${LOW:-0}
ADV=$(awk  -F'\t' '$1=="ADVISORY"{n++} END{print n+0}' "$RAW" 2>/dev/null); ADV=${ADV:-0}

if [ "$HIGH" -gt 0 ]; then STATE="failed"; VERDICT="BLOCKED ($HIGH high)"; else STATE="done"; VERDICT="CLEAN (0 high)"; fi
if audit_enforce; then MODE="enforce"; else MODE="advisory"; fi
NOW="$(date -u +%FT%TZ 2>/dev/null || printf 'unknown')"

# Record the per-module STATUS the release gate reads (Section A extras: high/med/low). Also STAMP the
# working tree this audit examined (F-A2), mirroring verify-build.sh: the release gate's tree_stale is
# now FAIL-CLOSED (a module with NO recorded tree reads STALE), so a fresh run must record its tree or
# it would be falsely stale. bd_tree_digest is pure-git (no python), identical on a stub-python host.
bd_status_write auditor audit "$STATE" "" high="$HIGH" med="$MED" low="$LOW" tree="$(bd_tree_digest)" >/dev/null 2>&1 || true

# Render FINDINGS.md (deterministic report, grouped by severity).
{
  printf '# Audit findings — %s\n\n' "$VERDICT"
  printf '%s\n' "- Generated: $NOW"
  printf '%s\n' "- HEAD: ${HEAD_FULL:-unknown}"
  printf '%s\n' "- Mode: $MODE"
  printf '%s\n' "- Tally: HIGH=$HIGH · MEDIUM=$MED · LOW=$LOW (ADVISORY=$ADV, excluded from the gate)"
  printf '%s\n\n' "- Gate: HIGH must be 0 to release — verify-release.sh reads \`auditor high\`."
  for sev in HIGH MEDIUM LOW ADVISORY; do
    n=$(awk -F'\t' -v s="$sev" '$1==s{c++} END{print c+0}' "$RAW" 2>/dev/null); n=${n:-0}
    printf '## %s (%s)\n\n' "$sev" "$n"
    if [ "$n" -eq 0 ]; then
      printf 'none\n\n'
    else
      printf '| Detector | Location | Finding |\n|---|---|---|\n'
      awk -F'\t' -v s="$sev" '$1==s{gsub(/\|/,"\\|",$4); printf "| %s | %s | %s |\n", $2, $3, $4}' "$RAW" 2>/dev/null
      printf '\n'
    fi
  done
} > "$FINDINGS_MD" 2>/dev/null || true

# STDOUT dashboard.
printf '[auditor] audit (%s) — %s\n' "$MODE" "$VERDICT"
printf '  tally: HIGH=%s  MEDIUM=%s  LOW=%s  (ADVISORY=%s)\n' "$HIGH" "$MED" "$LOW" "$ADV"
awk -F'\t' '$1=="HIGH"{printf "  HIGH  %s  %s — %s\n", $2, $3, $4}' "$RAW" 2>/dev/null
printf '  report: %s\n' "${FINDINGS_MD#"$PROJECT"/}"

# Enforce only when asked; otherwise advisory. The release gate is the authoritative 0-high
# enforcement regardless of this exit code (it reads the STATUS we just wrote).
if audit_enforce && [ "$HIGH" -gt 0 ]; then
  {
    printf '[auditor] BLOCKED: %s HIGH finding(s) must be 0 to release:\n' "$HIGH"
    awk -F'\t' '$1=="HIGH"{printf "  - %s: %s — %s\n", $2, $3, $4}' "$RAW" 2>/dev/null
    printf 'See %s. Fix the regressions (or unset enforce) before stopping.\n' "${FINDINGS_MD#"$PROJECT"/}"
  } >&2
  exit 2
fi
exit 0
