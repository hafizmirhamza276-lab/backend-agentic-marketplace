#!/usr/bin/env bash
# regression-gate.sh — BUG-FIX MODE Stop / post-implement gate (Phase B5).
# Proves a bug fix is real AND regression-safe by checking the VERIFICATION NET:
#   1) the reproduction test now PASSES        (red→green = the bug is actually fixed)
#   2) the characterization + named linked/affected tests stay GREEN (nothing else broke)
#
# It is a SEPARATE script from verify-build.sh and does NOT touch it: outside a
# bug-fix session (no .claude/builder/BUG.md) it is a pure no-op, so the ordinary
# build-verify Stop gate is unaffected.
#
# Statuses come from one of two places (running tests is side-effectful, so we respect
# auto_run_tests):
#   - auto_run_tests == "auto"  → this gate runs the commands itself and judges exit codes.
#   - "ask" / "never"           → it reads the results LEDGER the orchestrator recorded
#                                  after confirmed runs (.claude/builder/bugfix/results.txt).
# Test COMMANDS are parsed from BUG.md. Pure shell/awk — no python dependency for the
# decision (bd_setting handles its own python/grep fallback), so it is robust on
# python-less / Windows-stub hosts.
#
# Advisory by default; under bugfix_enforce / BUILDER_ENFORCE it hard-blocks (exit 2)
# when the repro isn't green or a characterization/linked test regressed.
#
# NOT `set -e`: a failing test command must drive the verdict, never abort the gate.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"

BUGMD="$(bd_bug)"
[ -f "$BUGMD" ] || exit 0   # not a bug-fix session → no-op (doesn't disturb verify-build)

LEDGER="$(bd_bugfix_dir)/results.txt"
AUTO_RUN="$(bd_setting auto_run_tests ask)"
: "${REGR_TIMEOUT:=120}"

# --- parse expected test commands from BUG.md (kind<TAB>command) --------------
# Keys (fixed schema, see skills/diagnose-bug): a 'Repro command:' line under
# '## Reproduction'; 'Command:' lines under '## Characterization tests' and under
# '## Linked / affected tests'. Anchored at line start so the key sub never overreaches.
EXPECTED="$(awk '
  /^#{1,6}[[:space:]]/ { s=tolower($0); next }
  {
    if (match($0, /^[[:space:]]*-?[[:space:]]*[Rr]epro[[:space:]]+command[[:space:]]*:[[:space:]]*/)) {
      v=substr($0, RLENGTH+1); gsub(/`/,"",v); if(v!="") print "repro\t" v; next
    }
    if (match($0, /^[[:space:]]*-?[[:space:]]*[Cc]ommand[[:space:]]*:[[:space:]]*/)) {
      v=substr($0, RLENGTH+1); gsub(/`/,"",v)
      if (v!="") {
        if (s ~ /characterization/)    print "char\t"   v
        else if (s ~ /linked|affected/) print "linked\t" v
      }
      next
    }
  }
' "$BUGMD" 2>/dev/null)"

norm_status() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    green|pass|passed|passing|ok|0|true) printf 'green' ;;
    red|fail|failed|failing|error|1|false) printf 'red' ;;
    *) printf 'unknown' ;;
  esac
}
run_cmd() {  # run one test command, suppress output; exit status drives green/red
  if bd_have timeout; then timeout "$REGR_TIMEOUT" sh -c "$1" >/dev/null 2>&1
  else sh -c "$1" >/dev/null 2>&1; fi
}

STATUS_LINES=""   # normalized "<kind> <status>" per line
add_status() { STATUS_LINES="${STATUS_LINES}$1 $(norm_status "$2")"$'\n'; }

if [ "$AUTO_RUN" = "auto" ] && [ -n "$EXPECTED" ]; then
  # Run every parsed command ourselves and (re)write the ledger as the record.
  mkdir -p "$(bd_bugfix_dir)" 2>/dev/null || true
  : > "$LEDGER" 2>/dev/null || true
  while IFS=$'\t' read -r kind cmd; do
    [ -n "${kind:-}" ] && [ -n "${cmd:-}" ] || continue
    if run_cmd "$cmd"; then st=green; else st=red; fi
    add_status "$kind" "$st"
    printf '%s\t%s\t%s\n' "$kind" "$st" "$cmd" >> "$LEDGER" 2>/dev/null || true
  done <<EOF
$EXPECTED
EOF
elif [ -f "$LEDGER" ]; then
  # Read recorded results (orchestrator ran the tests with the user's confirmation).
  while read -r kind st _rest; do
    [ -n "${kind:-}" ] || continue
    case "$kind" in repro|char|linked) add_status "$kind" "$st" ;; esac
  done < "$LEDGER"
fi

# --- nothing to evaluate -----------------------------------------------------
if [ -z "$STATUS_LINES" ]; then
  msg="regression gate could not verify red→green: no recorded results at .claude/builder/bugfix/results.txt (auto_run_tests=$AUTO_RUN). Run the repro + characterization tests and record results, or set auto_run_tests=auto."
  if [ -n "$EXPECTED" ]; then
    printf '%s\n' "$msg" >&2
    printf '  proposed commands:\n' >&2
    printf '%s\n' "$EXPECTED" | sed -E 's/\t/  →  /; s/^/    - /' >&2
  fi
  if bd_bugfix_enforce; then bd_block "[builder] $msg"; fi
  bd_warn "$msg"; exit 0
fi

# --- evaluate ----------------------------------------------------------------
repro_total=$(printf '%s\n' "$STATUS_LINES" | awk 'NF&&$1=="repro"{n++}END{print n+0}')
repro_green=$(printf '%s\n' "$STATUS_LINES" | awk 'NF&&$1=="repro"&&$2=="green"{n++}END{print n+0}')
cl_total=$(printf '%s\n' "$STATUS_LINES"   | awk 'NF&&($1=="char"||$1=="linked"){n++}END{print n+0}')
cl_red=$(printf '%s\n' "$STATUS_LINES"     | awk 'NF&&($1=="char"||$1=="linked")&&$2=="red"{n++}END{print n+0}')

problems=0
note() { printf '  - %s\n' "$*" >&2; problems=$((problems+1)); }

if [ "$repro_total" -eq 0 ]; then
  note "no reproduction result recorded — the failing repro is the cornerstone of the fix; capture and run it."
elif [ "$repro_green" -lt "$repro_total" ] || [ "$repro_green" -eq 0 ]; then
  note "reproduction is NOT green (still RED) — red→green not achieved, so the bug is not proven fixed."
fi
if [ "$cl_red" -gt 0 ]; then
  note "$cl_red characterization/linked test(s) REGRESSED — they pinned correct behavior pre-fix and are now red."
fi

if [ "$problems" -eq 0 ]; then
  bd_say "regression gate passed: repro red→green ✓; characterization/linked green ✓ (${cl_total} pinned)."
  exit 0
fi

if bd_bugfix_enforce; then
  printf '[builder] regression gate FAILED with %s issue(s) above. The fix is not proven regression-safe — do not finish.\n' "$problems" >&2
  exit 2
fi
bd_warn "regression gate found $problems issue(s) above (advisory; set bugfix_enforce=true or BUILDER_ENFORCE=1 to hard-block)."
exit 0
