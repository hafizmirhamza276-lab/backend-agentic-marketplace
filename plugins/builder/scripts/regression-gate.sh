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

PROJECT="$(bd_project_dir)"
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

run_cmd() {  # run one test command, suppress output; exit status drives green/red
  if bd_have timeout; then timeout "$REGR_TIMEOUT" sh -c "$1" >/dev/null 2>&1
  else sh -c "$1" >/dev/null 2>&1; fi
}

problems=0
note() { printf '  - %s\n' "$*" >&2; problems=$((problems+1)); }

# --- pre-fix RED capture + ledger persistence (external review F-C) -----------
# The OLD auto path did `: > "$LEDGER"` then recorded ONLY the post-fix run, so a no-op /
# always-green "repro" sailed through — red→green was never OBSERVED. We now PERSIST a pre-fix RED
# for the repro and KEEP it in the ledger (we stop truncating it away), so the release gate
# (verify-release.sh) can demand a real RED→GREEN TRANSITION rather than mere terminal green.
# The pre-fix red comes from up to two kept sources:
#   (1) a RECORDED PRE-EDIT RUN — any `repro … red` already in the ledger (an earlier Stop-gate
#       firing while the repro still failed, or an orchestrator-recorded run): preserved verbatim.
#   (2) AUTO mode only — an ACTIVE probe: set the fix aside with `git stash` and run the repro
#       against the pre-fix tree. Best-effort and FULLY DEFENSIVE: only when git is present, we are
#       inside a work tree, the tree is dirty (a fix to set aside) and NO recorded red exists yet;
#       the stash is ALWAYS restored (a failed pop leaves the change safely in `git stash list` and
#       merely warns). On ANY doubt the probe does nothing — it can neither corrupt the tree nor
#       crash this advisory gate. (Test command-string side effects are the only edge — documented,
#       and even then never fatal: the work is recoverable, the gate continues.)
REPRO_CMD="$(printf '%s\n' "$EXPECTED" | awk -F'\t' '$1=="repro"{print $2; exit}')"
PRIOR_REDS=""
[ -f "$LEDGER" ] && PRIOR_REDS="$(awk '$1=="repro" && tolower($2) ~ /^(red|fail|failed|failing|error|1|false)$/ {print}' "$LEDGER" 2>/dev/null)"

if [ "$AUTO_RUN" = "auto" ] && [ -n "$EXPECTED" ]; then
  mkdir -p "$(bd_bugfix_dir)" 2>/dev/null || true
  PROBE_RED=""
  if [ -z "$PRIOR_REDS" ] && [ -n "$REPRO_CMD" ] && bd_have git \
     && git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && [ -n "$(git -C "$PROJECT" status --porcelain 2>/dev/null)" ]; then
    if git -C "$PROJECT" stash push -q -m "regression-gate F-C pre-fix probe" >/dev/null 2>&1; then
      run_cmd "$REPRO_CMD" || PROBE_RED="$(printf 'repro\tred\t%s' "$REPRO_CMD")"   # repro RED on the pre-fix tree
      git -C "$PROJECT" stash pop -q >/dev/null 2>&1 \
        || bd_warn "regression-gate: could not auto-restore the pre-fix stash — your changes are SAFE in 'git stash list'; run 'git stash pop' manually."
    fi
  fi
  # Rewrite the ledger: kept pre-fix RED(s) FIRST (the transition evidence), then THIS run's rows.
  # We never blindly `: > "$LEDGER"` anymore — that truncation is exactly what dropped the red (F-C).
  {
    [ -n "$PRIOR_REDS" ] && printf '%s\n' "$PRIOR_REDS"   #PREFIX_RED_KEEP carry the recorded pre-fix red forward
    [ -n "$PROBE_RED" ]  && printf '%s\n' "$PROBE_RED"
    true
  } > "$LEDGER" 2>/dev/null || true
  while IFS=$'\t' read -r kind cmd; do
    [ -n "${kind:-}" ] && [ -n "${cmd:-}" ] || continue
    if run_cmd "$cmd"; then st=green; else st=red; fi
    printf '%s\t%s\t%s\n' "$kind" "$st" "$cmd" >> "$LEDGER" 2>/dev/null || true
  done <<EOF
$EXPECTED
EOF
fi
# (ask/never mode: the orchestrator recorded the ledger — including any pre-fix red — and we read it
#  as-is below; we must NOT discard that red, so there is no truncation on this path either.)

# --- nothing to evaluate -----------------------------------------------------
if [ ! -s "$LEDGER" ]; then
  msg="regression gate could not verify red→green: no recorded results at .claude/builder/bugfix/results.txt (auto_run_tests=$AUTO_RUN). Run the repro + characterization tests and record results, or set auto_run_tests=auto."
  if [ -n "$EXPECTED" ]; then
    printf '%s\n' "$msg" >&2
    printf '  proposed commands:\n' >&2
    printf '%s\n' "$EXPECTED" | sed -E 's/\t/  →  /; s/^/    - /' >&2
  fi
  if bd_bugfix_enforce; then bd_block "[builder] $msg"; fi
  bd_warn "$msg"; exit 0
fi

# --- evaluate (CURRENT health) -----------------------------------------------
# Verdict keys on the LATEST status per repro/char/linked command — a historical `repro red` is
# EVIDENCE of the pre-fix state, not a current failure. (verify-release.sh additionally enforces the
# red→green TRANSITION before release; this Stop gate checks current health and persists the red.)
COUNTS="$(awk '
  function norm(s){ s=tolower(s);
    if (s ~ /^(green|pass|passed|passing|ok|0|true)$/)  return "green";
    if (s ~ /^(red|fail|failed|failing|error|1|false)$/) return "red";
    return "unknown" }
  { k=$1; st=norm($2);
    id=""; for(i=3;i<=NF;i++) id=id (i>3?" ":"") $i
    if (k=="repro")                  { rlatest[id]=st; rseen[id]=1 }
    else if (k=="char"||k=="linked") { clatest[id]=st } }
  END{
    for (x in rseen)   { rt++; if (rlatest[x]!="green") rng++ }
    for (y in clatest) { if (clatest[y]=="red") cr++ }
    printf "%d %d %d", rt+0, rng+0, cr+0 }
' "$LEDGER" 2>/dev/null)"
# shellcheck disable=SC2086
set -- $COUNTS
repro_total="${1:-0}"; repro_not_green="${2:-0}"; cl_red="${3:-0}"

if [ "$repro_total" -eq 0 ]; then
  note "no reproduction result recorded — the failing repro is the cornerstone of the fix; capture and run it."
elif [ "$repro_not_green" -gt 0 ]; then
  note "reproduction is NOT green (still RED) — red→green not achieved, so the bug is not proven fixed."
fi
if [ "$cl_red" -gt 0 ]; then
  note "$cl_red characterization/linked test(s) REGRESSED — they pinned correct behavior pre-fix and are now red."
fi

if [ "$problems" -eq 0 ]; then
  bd_say "regression gate passed: repro green (red→green kept in the ledger) ✓; characterization/linked green ✓."
  exit 0
fi

if bd_bugfix_enforce; then
  printf '[builder] regression gate FAILED with %s issue(s) above. The fix is not proven regression-safe — do not finish.\n' "$problems" >&2
  exit 2
fi
bd_warn "regression gate found $problems issue(s) above (advisory; set bugfix_enforce=true or BUILDER_ENFORCE=1 to hard-block)."
exit 0
