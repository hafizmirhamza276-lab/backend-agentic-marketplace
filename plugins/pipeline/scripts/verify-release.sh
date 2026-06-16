#!/usr/bin/env bash
# verify-release.sh — the deterministic RELEASE GATE for the pipeline conductor.
#
# Runs as the pipeline plugin's Stop hook and is also invoked directly by /pipeline:run.
# It reads ONLY existing artifacts + the per-module STATUS contract and renders a verdict:
# is this change safe to release? ADVISORY by default (always exit 0, just report); it
# hard-blocks (exit 2) on any REQUIRED failure only when enforce mode is on
# (PIPELINE_ENFORCE=1 or settings.enforce_release=true — see bd_release_enforce).
#
# DECISIONS ARE PURE SHELL/AWK — no python dependency — so the gate is identical on a
# python-less / Windows-stub host (bd_status_read / bd_setting_at carry their own grep
# fallback; nothing here branches on whether python exists). It NEVER crashes on a missing
# file: every absent artifact becomes a FAIL with a clear reason, never an error. NOT
# `set -e` (a single failing probe must shape the verdict, not abort the gate).
#
# Checks (REQUIRED unless noted):
#   1. explorer memory present AND fresh (explored_commit == git HEAD)
#   2. builder finished (STATUS state == done); if PLAN.md exists, every "## Tasks" item
#      has a CHANGELOG coverage-map line
#   3. if .claude/builder/BUG.md exists: repro green + characterization/linked green
#      (read from .claude/builder/bugfix/results.txt)
#   4. auditor (ADVISORY when absent / extensible): if auditor STATUS exists, require 0 high;
#      if absent, report "not run" and do NOT fail
#   5. CHANGELOG.md present and non-empty
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"

PROJECT="$(bd_project_dir)"
PIPE_DIR="$(bd_pipeline_dir)"
RELEASE_MD="$(bd_release_md)"
mkdir -p "$PIPE_DIR" 2>/dev/null || true

# Full HEAD for the freshness comparison (explored_commit is a full SHA; we also accept a
# short prefix). Empty when git is unavailable / not a work tree.
HEAD_FULL=""
if bd_have git && git -C "$PROJECT" rev-parse HEAD >/dev/null 2>&1; then
  HEAD_FULL="$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null || printf '')"
fi

# --- result accumulation -----------------------------------------------------
declare -a ROWS=()
REQ_FAIL=0
declare -a FAIL_REASONS=()
# record <name> <PASS|FAIL|SKIP> <required:0|1> <detail>
record() {
  local name="$1" verdict="$2" req="$3" detail="$4"
  ROWS+=("$(printf '%-18s %-4s %s' "$name" "$verdict" "$detail")")
  if [ "$verdict" = "FAIL" ] && [ "$req" = "1" ]; then
    REQ_FAIL=$((REQ_FAIL + 1))
    FAIL_REASONS+=("$detail")
  fi
}

# coverage_gaps <plan> <log> : print each PLAN "### Task <id>" whose id has NO matching
# coverage line ("Task <id> ...") in the CHANGELOG. Pure awk; ids are compared as whole
# tokens with trailing punctuation stripped, so `1` never matches `10` and `Task 1:` ==
# `Task 1`. Empty output => every task is covered (or there are no tasks / no log).
coverage_gaps() {
  local plan="$1" log="$2"
  [ -f "$log" ] || log=/dev/null
  awk -v logf="$log" '
    BEGIN{
      while ((getline line < logf) > 0) {
        if (match(line, /[Tt]ask[[:space:]]+[^[:space:]:,]+/)) {
          tok=substr(line, RSTART, RLENGTH); sub(/^[Tt]ask[[:space:]]+/,"",tok)
          gsub(/[:.,;]+$/,"",tok); if (tok!="") covered[tok]=1
        }
      }
    }
    /^##[[:space:]]/ && $0 !~ /^###/ { intasks = ($0 ~ /[Tt]asks/) ? 1 : 0; next }
    intasks && /^###[[:space:]]/ {
      l=$0; sub(/^###[[:space:]]+/,"",l); sub(/^[Tt]ask[[:space:]]+/,"",l)
      sub(/[[:space:]].*$/,"",l); gsub(/[:.,;]+$/,"",l)
      if (l!="" && !(l in covered)) print l
    }
  ' "$plan"
}

# ---------------------------------------------------------------------------
# 1) explorer memory present AND fresh
# ---------------------------------------------------------------------------
MEM="$(bd_explorer_dir)/MEMORY.md"
if [ ! -f "$MEM" ]; then
  record "explorer-memory" FAIL 1 "explorer memory: MISSING (.claude/explorer/MEMORY.md) — run /explorer:start"
else
  EXPLORED="$(grep -oE '^explored_commit:[[:space:]]*[A-Za-z0-9]+' "$MEM" 2>/dev/null | head -n1 | sed -E 's/^explored_commit:[[:space:]]*//' || true)"
  if [ -z "$EXPLORED" ]; then
    record "explorer-memory" FAIL 1 "explorer memory: present but has no explored_commit line"
  elif [ -z "$HEAD_FULL" ]; then
    record "explorer-memory" FAIL 1 "explorer memory: cannot verify freshness (git HEAD unavailable)"
  else
    case "$HEAD_FULL" in
      "$EXPLORED"*) record "explorer-memory" PASS 1 "fresh: explored_commit matches HEAD" ;;
      *)            record "explorer-memory" FAIL 1 "explorer memory: STALE (explored=$EXPLORED, HEAD=$HEAD_FULL) — re-run /explorer:start" ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# 2) builder finished + (if PLAN.md) every task covered in the CHANGELOG
# ---------------------------------------------------------------------------
BSTATE="$(bd_status_read builder state 2>/dev/null || true)"
if [ "$BSTATE" != "done" ]; then
  record "builder-finished" FAIL 1 "builder: NOT done (STATUS state='${BSTATE:-<none>}')"
else
  PLAN="$(bd_plan)"
  if [ -f "$PLAN" ]; then
    GAPS="$(coverage_gaps "$PLAN" "$(bd_changelog)")"
    if [ -n "$GAPS" ]; then
      record "builder-finished" FAIL 1 "builder: task(s) missing CHANGELOG coverage map: $(printf '%s' "$GAPS" | tr '\n' ' ')"
    else
      record "builder-finished" PASS 1 "builder done; all PLAN tasks have a coverage-map line"
    fi
  else
    record "builder-finished" PASS 1 "builder done (no PLAN.md; coverage-map check N/A)"
  fi
fi

# ---------------------------------------------------------------------------
# 3) bug-fix verification net (only when a BUG.md is present)
# ---------------------------------------------------------------------------
BUG="$(bd_bug)"
if [ ! -f "$BUG" ]; then
  record "bugfix-net" SKIP 0 "bugfix: no BUG.md — not a bug-fix release (N/A)"
else
  LEDGER="$(bd_bugfix_dir)/results.txt"
  if [ ! -f "$LEDGER" ]; then
    record "bugfix-net" FAIL 1 "bugfix: results ledger MISSING (.claude/builder/bugfix/results.txt)"
  else
    COUNTS="$(awk '
      function norm(s){ s=tolower(s);
        if (s ~ /^(green|pass|passed|passing|ok|0|true)$/)  return "green";
        if (s ~ /^(red|fail|failed|failing|error|1|false)$/) return "red";
        return "unknown" }
      { k=$1; st=norm($2);
        if (k=="repro")               { rt++; if (st=="green") rg++ }
        else if (k=="char"||k=="linked"){ ct++; if (st=="red")  cr++ } }
      END{ printf "%d %d %d %d", rt+0, rg+0, ct+0, cr+0 }
    ' "$LEDGER" 2>/dev/null)"
    # shellcheck disable=SC2086
    set -- $COUNTS
    RT="${1:-0}"; RG="${2:-0}"; CT="${3:-0}"; CR="${4:-0}"
    if [ "$RT" -eq 0 ]; then
      record "bugfix-net" FAIL 1 "bugfix: no reproduction result recorded — repro is the cornerstone of the fix"
    elif [ "$RG" -lt "$RT" ]; then
      record "bugfix-net" FAIL 1 "bugfix: reproduction not green (red->green not proven)"
    elif [ "$CR" -gt 0 ]; then
      record "bugfix-net" FAIL 1 "bugfix: characterization/linked test regressed ($CR red)"
    else
      record "bugfix-net" PASS 1 "bugfix: repro green; characterization/linked green ($CT pinned)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4) auditor (extensible) — advisory when absent, required (0 high) when present
# ---------------------------------------------------------------------------
AUD="$(bd_claude_dir)/auditor/STATUS.json"
if [ ! -f "$AUD" ]; then
  record "auditor" SKIP 0 "auditor: not run (advisory — does not block release)"
else
  ASTATE="$(bd_status_read auditor state 2>/dev/null || true)"
  AHIGH="$(bd_status_read auditor high 2>/dev/null || true)"   # future auditor may record a 'high' count
  if [ -n "$AHIGH" ] && [ "$AHIGH" != "0" ]; then
    record "auditor" FAIL 1 "auditor: $AHIGH HIGH finding(s) — must be 0 to release"
  elif [ "$ASTATE" = "failed" ] || [ "$ASTATE" = "blocked" ]; then
    record "auditor" FAIL 1 "auditor: STATUS state='$ASTATE'"
  else
    record "auditor" PASS 1 "auditor: state='${ASTATE:-?}', 0 high"
  fi
fi

# ---------------------------------------------------------------------------
# 5) CHANGELOG present and non-empty
# ---------------------------------------------------------------------------
LOG="$(bd_changelog)"
if [ -s "$LOG" ]; then
  record "changelog" PASS 1 "CHANGELOG present and non-empty"
else
  record "changelog" FAIL 1 "CHANGELOG: missing or empty (.claude/builder/CHANGELOG.md)"
fi

# --- verdict -----------------------------------------------------------------
if [ "$REQ_FAIL" -eq 0 ]; then RELEASE_STATE="done"; VERDICT="RELEASE READY"; else RELEASE_STATE="failed"; VERDICT="BLOCKED"; fi
if bd_release_enforce; then MODE="enforce"; else MODE="advisory"; fi
NOW="$(date -u +%FT%TZ 2>/dev/null || printf 'unknown')"

# Persist the module STATUS so the dashboard + conductor can read the verdict.
bd_status_write pipeline release "$RELEASE_STATE" >/dev/null 2>&1 || true

# Write RELEASE.md (deterministic report).
{
  printf '# Release gate — %s\n\n' "$VERDICT"
  # NB: a printf FORMAT beginning with '-' is parsed as an option flag, so the leading
  # bullet '-' lives in the ARGUMENT (format is '%s\n'), not the format string.
  printf '%s\n' "- Generated: $NOW"
  printf '%s\n' "- HEAD: ${HEAD_FULL:-unknown}"
  printf '%s\n' "- Mode: $MODE"
  printf '%s\n\n' "- Required failures: $REQ_FAIL"
  printf '## Checks\n\n'
  printf '| Check | Result | Detail |\n'
  printf '|---|---|---|\n'
  for r in "${ROWS[@]}"; do
    nm="${r%% *}"; rest="${r#"$nm"}"; rest="${rest#"${rest%%[![:space:]]*}"}"
    vd="${rest%% *}"; dt="${rest#"$vd"}"; dt="${dt#"${dt%%[![:space:]]*}"}"
    printf '| %s | %s | %s |\n' "$nm" "$vd" "$dt"
  done
  printf '\n## Required failures\n\n'
  if [ "$REQ_FAIL" -eq 0 ]; then
    printf 'none\n'
  else
    for f in "${FAIL_REASONS[@]}"; do printf -- '- %s\n' "$f"; done
  fi
} > "$RELEASE_MD" 2>/dev/null || true

# --- emit to STDOUT (visible dashboard) + decide exit ------------------------
printf '[pipeline] release gate (%s) — %s\n' "$MODE" "$VERDICT"
printf '  %-18s %-4s %s\n' "CHECK" "RES" "DETAIL"
for r in "${ROWS[@]}"; do printf '  %s\n' "$r"; done
printf '  report: %s\n' "${RELEASE_MD#"$PROJECT"/}"

if bd_release_enforce && [ "$REQ_FAIL" -ne 0 ]; then
  {
    printf '[pipeline] RELEASE BLOCKED: %s required check(s) failed:\n' "$REQ_FAIL"
    for f in "${FAIL_REASONS[@]}"; do printf '  - %s\n' "$f"; done
    printf 'Resolve the above (or unset enforce) before releasing. See %s.\n' "${RELEASE_MD#"$PROJECT"/}"
  } >&2
  exit 2
fi
exit 0
