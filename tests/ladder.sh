#!/usr/bin/env sh
# ladder.sh — production-grade test ladder for this phase's hardenings + release gate.
# POSIX sh, `set -eu`, isolated mktemp dirs, crafted payloads. Each tier carries
# negative/mutation controls so a BROKEN check FAILS the suite (it is not vacuous).
#
# PERFORMANCE: wall-time is bound by process-spawn cost. Mitigations: lib-only work
# (normalize / STATUS / JSON-escape / path generation) is BATCHED into single bash processes
# that source common.sh once and avoid per-item `$(...)` subshells; the irreducible
# per-event guard/gate runs are dispatched in PARALLEL (background + wait); one throwaway git
# repo backs all release fixtures. On a typical Linux CI host (cheap fork) the full suite
# runs in well under ~30s. On Windows/cygwin fork is far costlier and each release-gate run
# itself spawns ~10 short-lived processes (git/grep/awk), so a cold box is slower; run with
# LADDER_PROFILE=1 to print per-tier timing.
#
# Tiers:
#   1. UNIT  — bd_normalize_path exact-output table (proves B: '\' -> '/' before collapse).
#   2. UNIT  — STATUS adversarial: shell writer escapes '"' '\' newline + unicode -> VALID
#              JSON, lossless python round-trip, python<->shell cross-path agreement (proves A).
#   3. INTEGRATION — release gate: one full PASS fixture (advisory+enforce exit 0) and one
#              fixture per failing condition (each FAILs enforce exit 2 with the reason in RELEASE.md).
#   4. ADVERSARIAL — both guards: traversal / mixed-sep / four-dot / trailing / long paths
#              BLOCKED; matching in-zone variants ALLOWED.
#   5. PROPERTY — ~50 generated paths: guard-readonly ALLOWS iff normalized path is in-zone.
#   6. PORTABILITY — python {real|stub|none} x jq {present|absent}: correct fallback, never
#              crash, never fail-open, for STATUS / guards / release gate.
#   7. MUTATION SENTINEL — sed out the core block/fail line of guard-scope + verify-release and
#              prove the matching adversarial/integration case WOULD pass the mutant (suite has teeth).
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
export ROOT

GUARD_READONLY="$ROOT/plugins/explorer/scripts/guard-readonly.sh"
GUARD_SCOPE="$ROOT/plugins/builder/scripts/guard-scope.sh"
VERIFY_RELEASE="$ROOT/plugins/pipeline/scripts/verify-release.sh"
LIB="$ROOT/shared/lib/common.sh"
export LIB
TAB=$(printf '\t')

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s  --  %s\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "expected != [$2]"; fi; }
skipnote()  { printf 'SKIP  %s\n' "$1"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
PARDIR="$WORK/par"; mkdir -p "$PARDIR"
# Optional per-section timing: run with LADDER_PROFILE=1 to print elapsed seconds per tier.
_T0=$(date +%s); tlog() { [ "${LADDER_PROFILE:-0}" = 1 ] && printf '   [+%ss] %s\n' "$(( $(date +%s) - _T0 ))" "$1" >&2 || true; }

# One throwaway git repo backs all release fixtures: fixtures are subdirs of $WORK, so
# `git -C <fixture> rev-parse HEAD` resolves to this single HEAD (no per-fixture git init).
git -C "$WORK" init -q >/dev/null 2>&1 || true
git -C "$WORK" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init >/dev/null 2>&1 || true
WORK_HEAD=$(git -C "$WORK" rev-parse HEAD 2>/dev/null || printf 'unknown')

# --- python conditions -------------------------------------------------------
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
for n in python3 python py; do printf '#!/bin/sh\nexit 49\n' > "$FAKEBIN/$n"; chmod +x "$FAKEBIN/$n"; done
HOST_PY=""
for c in python3 python "py -3"; do
  # shellcheck disable=SC2086
  if $c -c "pass" >/dev/null 2>&1; then HOST_PY="$c"; break; fi
done
host_has_python() { [ -n "$HOST_PY" ]; }
# A python-free PATH: dirs of bash + git only (on msys these exclude the Windows py/python
# launchers). If python is still resolvable there, mark NONE unavailable and SKIP — no false pass.
_bash_dir=$(dirname "$(command -v bash)")
_git_dir=$(command -v git >/dev/null 2>&1 && dirname "$(command -v git)" || printf '%s' "$_bash_dir")
NONEPATH="$_bash_dir:$_git_dir"
NONE_OK=1
for t in python3 python py; do
  if PATH="$NONEPATH" command -v "$t" >/dev/null 2>&1; then NONE_OK=0; fi
done
# Fake jq implementing ONLY the filter guard-readonly uses (so the jq branch is exercised).
JQBIN="$WORK/jqbin"; mkdir -p "$JQBIN"
cat > "$JQBIN/jq" <<'JQ'
#!/usr/bin/env bash
cat | grep -oE '"(file_path|path|notebook_path)"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
JQ
chmod +x "$JQBIN/jq"

# --- lib helper (bash; sources $LIB) — used for STATUS round-trips ------------
LIBHELPER="$WORK/libhelper.sh"
cat > "$LIBHELPER" <<'BASH'
#!/usr/bin/env bash
. "$LIB"
cmd="$1"; shift
case "$cmd" in
  swrite) bd_status_write "$@" ;;
  sread)  bd_status_read "$@" ;;
  *) exit 9 ;;
esac
BASH

# --- parallel dispatch -------------------------------------------------------
# guard_to_file <out> <script> <proj> <json> [pp] : run a guard, write its exit code.
guard_to_file() {
  _o=$1; _s=$2; _p=$3; _j=$4; _pp=${5:-}; _rc=0
  if [ -n "$_pp" ]; then
    printf '%s' "$_j" | PATH="$_pp:$PATH" CLAUDE_PROJECT_DIR="$_p" bash "$_s" >/dev/null 2>&1 || _rc=$?
  else
    printf '%s' "$_j" | CLAUDE_PROJECT_DIR="$_p" bash "$_s" >/dev/null 2>&1 || _rc=$?
  fi
  printf '%s' "$_rc" > "$_o"
}
# release_to_file <out> <proj> <enforce0|1> [pp] : run the gate, write its exit code.
release_to_file() {
  _o=$1; _p=$2; _e=$3; _pp=${4:-}; _rc=0
  if [ "$_e" = 1 ]; then
    if [ -n "$_pp" ]; then PATH="$_pp:$PATH" CLAUDE_PROJECT_DIR="$_p" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" >/dev/null 2>&1 || _rc=$?
    else CLAUDE_PROJECT_DIR="$_p" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" >/dev/null 2>&1 || _rc=$?; fi
  else
    if [ -n "$_pp" ]; then PATH="$_pp:$PATH" CLAUDE_PROJECT_DIR="$_p" bash "$VERIFY_RELEASE" >/dev/null 2>&1 || _rc=$?
    else CLAUDE_PROJECT_DIR="$_p" bash "$VERIFY_RELEASE" >/dev/null 2>&1 || _rc=$?; fi
  fi
  printf '%s' "$_rc" > "$_o"
}
# run_guard_cases <casefile>  (lines: label TAB expect TAB script TAB proj TAB json TAB pp)
# dispatches all guards in parallel (no wave cap — cygwin handles the fan-out fine, and a
# `wait` barrier per wave measurably SLOWS the suite), then asserts each exit code.
run_guard_cases() {
  rm -f "$PARDIR"/g*.rc; : > "$PARDIR/gidx"; _n=0
  while IFS="$TAB" read -r _lbl _exp _scr _prj _json _pp; do
    [ -n "$_lbl" ] || continue
    guard_to_file "$PARDIR/g$_n.rc" "$_scr" "$_prj" "$_json" "$_pp" &
    printf '%s\t%s\t%s\n' "$_lbl" "$_exp" "$_n" >> "$PARDIR/gidx"
    _n=$((_n+1))
  done < "$1"
  wait
  while IFS="$TAB" read -r _lbl _exp _i; do
    _got=X; [ -f "$PARDIR/g$_i.rc" ] && IFS= read -r _got < "$PARDIR/g$_i.rc" || true
    assert_eq "$_lbl" "$_exp" "$_got"
  done < "$PARDIR/gidx"
}
# spawn-free RELEASE.md substring check.
release_md_has() {
  _f="$1/.claude/pipeline/RELEASE.md"; _needle="$2"
  [ -f "$_f" ] || return 1
  while IFS= read -r _line; do case "$_line" in *"$_needle"*) return 0 ;; esac; done < "$_f"
  return 1
}

# --- fixture builders --------------------------------------------------------
mkproj() { d="$WORK/$1"; mkdir -p "$d"; printf '%s' "$d"; }
fresh_mem() { mkdir -p "$1/.claude/explorer"; { printf 'explored_commit: %s\n' "$WORK_HEAD"; printf 'coverage: 80%%\n'; } > "$1/.claude/explorer/MEMORY.md"; }
stale_mem() { mkdir -p "$1/.claude/explorer"; { printf 'explored_commit: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'; printf 'coverage: 1%%\n'; } > "$1/.claude/explorer/MEMORY.md"; }

echo "== production test ladder =="
echo "ROOT=$ROOT"
echo "host working python: $(host_has_python && echo "yes ($HOST_PY)" || echo no) | jq: $(command -v jq >/dev/null 2>&1 && echo present || echo absent) | NONE PATH usable: $([ "$NONE_OK" = 1 ] && echo yes || echo no)"
echo ""

# ===========================================================================
# TIER 1 — UNIT: bd_normalize_path exact-output table (proves B). Batched: one bash
# process normalizes every input; ladder asserts each output.
# ===========================================================================
tlog "tier1 start"; echo "-- tier 1: UNIT bd_normalize_path --"
T1IN="$WORK/t1.in"
{
  printf 'a\\..\\b\tb\n'
  printf '.claude\\explorer\\..\\..\\evil\tevil\n'
  printf '....//x\t..../x\n'
  printf 'a/b\\..\\c\ta/c\n'
  printf 'a/b/\ta/b\n'
  printf 'a b/c\ta b/c\n'
  printf '\303\245/\317\200/c\t\303\245/\317\200/c\n'         # å/π/c  (unicode)
  printf 'x/../../y\t../y\n'
  printf '../a\t../a\n'
  printf '/p/../q\t/q\n'
  printf '/proj/.claude/explorer/n.md\t/proj/.claude/explorer/n.md\n'
} > "$T1IN"
bash -c '. "$LIB"; while IFS="$(printf "\t")" read -r inp exp; do printf "%s\t%s\t%s\n" "$(bd_normalize_path "$inp")" "$exp" "$inp"; done' < "$T1IN" > "$WORK/t1.out"
while IFS="$TAB" read -r got exp inp; do assert_eq "T1 norm [$inp]" "$exp" "$got"; done < "$WORK/t1.out"
# Mutation control: without B, '\' is not a separator, so 'a\..\b' would normalize to itself.
t1raw=$(bash -c '. "$LIB"; bd_normalize_path "a\\..\\b"')
assert_ne "T1 (control) B converts backslashes (output != raw input)" 'a\..\b' "$t1raw"
echo ""

# ===========================================================================
# TIER 2 — UNIT: STATUS adversarial escaping + cross-path (proves A).
# ===========================================================================
tlog "tier2 start"; echo "-- tier 2: UNIT STATUS adversarial --"
PA=$(mkproj st_adv); PB=$(mkproj st_nl); C1=$(mkproj st_x1); C2=$(mkproj st_x2)
ADV_PHASE='a"b\c ünîçødé'      # quote + backslash + space + unicode (no newline => lossless)
ADV_STATE='x"y\z'
NL_PHASE=$(printf 'aa\nbb')    # embedded newline -> must be neutralized

# (shell side, FAKEBIN -> forces the pure-shell writer) — one process for all shell writes.
ADV_PHASE="$ADV_PHASE" ADV_STATE="$ADV_STATE" NL_PHASE="$NL_PHASE" PA="$PA" PB="$PB" C2="$C2" \
PATH="$FAKEBIN:$PATH" bash -c '
  . "$LIB"
  CLAUDE_PROJECT_DIR="$PA" bd_status_write advml "$ADV_PHASE" "$ADV_STATE" 50
  CLAUDE_PROJECT_DIR="$PB" bd_status_write advml "$NL_PHASE" ok 1
  CLAUDE_PROJECT_DIR="$C2" bd_status_write xp plan running 7
' >/dev/null 2>&1 || true
ADVFILE="$PA/.claude/advml/STATUS.json"; NLFILE="$PB/.claude/advml/STATUS.json"

# (2a) python-free control: the newline must be neutralized so the file keeps 8 lines.
# (Both writers terminate every line with '\n', so a plain line count is exact. Use a
# named var — NOT '_', which collides with bash's special $_ and never tests empty.)
lc=0; while IFS= read -r ln; do lc=$((lc+1)); done < "$NLFILE"
assert_eq "T2 newline neutralized -> fixed 8-line JSON (python-free control)" 8 "$lc"

if host_has_python; then
  # (python side, real interpreter) — one process: py-write C1, py-read A + C2, emit values.
  # `tr -d '\r'`: Windows python print emits CRLF; strip CR so `read` recovers exact bytes.
  ADVFILE="$ADVFILE" PA="$PA" C1="$C1" C2="$C2" bash -c '
    . "$LIB"
    CLAUDE_PROJECT_DIR="$C1" bd_status_write xp plan running 7
    CLAUDE_PROJECT_DIR="$PA" bd_status_read advml phase
    CLAUDE_PROJECT_DIR="$PA" bd_status_read advml state
    CLAUDE_PROJECT_DIR="$C2" bd_status_read xp phase
    CLAUDE_PROJECT_DIR="$C2" bd_status_read xp state
    CLAUDE_PROJECT_DIR="$C2" bd_status_read xp coverage
  ' 2>/dev/null | tr -d '\r' > "$WORK/pyout" || true
  { IFS= read -r v_Aphase; IFS= read -r v_Astate; IFS= read -r v_C2p; IFS= read -r v_C2s; IFS= read -r v_C2c; } < "$WORK/pyout" || true
  # (shell side, FAKEBIN) — shell-read C1 (python-written). The grep reader prints NO trailing
  # newline, so add one per field; tr drops any CR from the python-written CRLF file.
  C1="$C1" PATH="$FAKEBIN:$PATH" bash -c '
    . "$LIB"
    CLAUDE_PROJECT_DIR="$C1" bd_status_read xp phase; echo
    CLAUDE_PROJECT_DIR="$C1" bd_status_read xp state; echo
    CLAUDE_PROJECT_DIR="$C1" bd_status_read xp coverage; echo
  ' 2>/dev/null | tr -d '\r' > "$WORK/shout" || true
  { IFS= read -r v_C1p; IFS= read -r v_C1s; IFS= read -r v_C1c; } < "$WORK/shout" || true

  # (2c) lossless round-trip via the python reader (un-escapes \\ and \").
  assert_eq "T2 adversarial phase round-trips losslessly (python reader)" "$ADV_PHASE" "$v_Aphase"
  assert_eq "T2 adversarial state round-trips losslessly (python reader)" "$ADV_STATE" "$v_Astate"
  # (2d) cross-path: python-write -> shell-read AND shell-write -> python-read both recover inputs.
  if [ "$v_C1p" = plan ] && [ "$v_C1s" = running ] && [ "$v_C1c" = 7 ] \
     && [ "$v_C2p" = plan ] && [ "$v_C2s" = running ] && [ "$v_C2c" = 7 ]; then
    ok "T2 cross-path agree (py-write->shell-read == shell-write->py-read)"
  else
    bad "T2 cross-path" "pyW/shR=[$v_C1p,$v_C1s,$v_C1c] shW/pyR=[$v_C2p,$v_C2s,$v_C2c]"
  fi
  # (2b)+(2e) validity has teeth: A & B valid, an UNescaped doc rejected. One python process.
  printf '{\n  "phase": "a"b",\n  "state": "x"\n}\n' > "$WORK/bad.json"
  vrc=0; $HOST_PY - "$ADVFILE" "$NLFILE" "$WORK/bad.json" <<'PY' >/dev/null 2>&1 || vrc=$?
import json, sys
json.load(open(sys.argv[1])); json.load(open(sys.argv[2]))   # must parse
try:
    json.load(open(sys.argv[3])); sys.exit(7)                # bad.json MUST raise
except ValueError:
    pass
PY
  assert_eq "T2 shell-written adversarial+newline files VALID & unescaped REJECTED (A)" 0 "$vrc"
else
  skipnote "T2 python validity/round-trip/cross-path (host has no working python; newline control ran)"
  C3=$(mkproj st_x3)
  PATH="$FAKEBIN:$PATH" CLAUDE_PROJECT_DIR="$C3" LIB="$LIB" bash "$LIBHELPER" swrite xp plan running 7 >/dev/null 2>&1 || true
  v=$(PATH="$FAKEBIN:$PATH" CLAUDE_PROJECT_DIR="$C3" LIB="$LIB" bash "$LIBHELPER" sread xp state 2>/dev/null || true)
  assert_eq "T2 shell write/read safe round-trip (no python)" running "$v"
fi
echo ""

# ===========================================================================
# TIER 3 — INTEGRATION: release gate PASS fixture + one fixture per failure.
# ===========================================================================
tlog "tier3 start"; echo "-- tier 3: INTEGRATION release gate --"
PASSP=$(mkproj rel_pass); fresh_mem "$PASSP"; mkdir -p "$PASSP/.claude/builder"
printf '# Plan\nClarity: 9/10\n## Scope\n- src/a.py\n## Tasks\n### Task 1 — do thing\nEdge cases:\n- none\nDefinition of Done: works\n' > "$PASSP/.claude/builder/PLAN.md"
printf '# Changelog\n### Task 1 — edge-case coverage map\n- nil -> handled at src/a.py:10\n' > "$PASSP/.claude/builder/CHANGELOG.md"
ST=$(mkproj rel_stale); stale_mem "$ST"; mkdir -p "$ST/.claude/builder"; printf '# c\n' > "$ST/.claude/builder/CHANGELOG.md"
ND=$(mkproj rel_nd); fresh_mem "$ND"; mkdir -p "$ND/.claude/builder"; printf '# c\n' > "$ND/.claude/builder/CHANGELOG.md"
BR=$(mkproj rel_bug); fresh_mem "$BR"; mkdir -p "$BR/.claude/builder/bugfix"; printf '# c\n' > "$BR/.claude/builder/CHANGELOG.md"
printf '# BUG\n' > "$BR/.claude/builder/BUG.md"; printf 'repro\tred\tpytest x\nchar\tgreen\tpytest y\n' > "$BR/.claude/builder/bugfix/results.txt"
NC=$(mkproj rel_nc); fresh_mem "$NC"; mkdir -p "$NC/.claude/builder"
GAP=$(mkproj rel_gap); fresh_mem "$GAP"; mkdir -p "$GAP/.claude/builder"
printf '# Plan\n## Tasks\n### Task 1 a\n### Task 2 b\n' > "$GAP/.claude/builder/PLAN.md"; printf '# Changelog\nTask 1 covered\n' > "$GAP/.claude/builder/CHANGELOG.md"
# Batch all builder STATUS writes in one process (done everywhere except the not-done
# fixture). Under FAKEBIN so it's fast (shell writer); the gate's verdict is python-free and
# tier 6 separately covers the gate under real/stub/none python.
printf '%s\tdone\n%s\tdone\n%s\trunning\n%s\tdone\n%s\tdone\n%s\tdone\n' "$PASSP" "$ST" "$ND" "$BR" "$NC" "$GAP" \
  | PATH="$FAKEBIN:$PATH" bash -c '. "$LIB"; while IFS="$(printf "\t")" read -r prj st; do CLAUDE_PROJECT_DIR="$prj" bd_status_write builder qa "$st" >/dev/null 2>&1 || true; done' || true
# Run all gate invocations in parallel (FAKEBIN -> the gate's python-free path).
release_to_file "$PARDIR/r_pass_a.rc" "$PASSP" 0 "$FAKEBIN" &
release_to_file "$PARDIR/r_pass_e.rc" "$PASSP" 1 "$FAKEBIN" &
release_to_file "$PARDIR/r_stale.rc"  "$ST" 1 "$FAKEBIN" &
release_to_file "$PARDIR/r_nd.rc"     "$ND" 1 "$FAKEBIN" &
release_to_file "$PARDIR/r_bug.rc"    "$BR" 1 "$FAKEBIN" &
release_to_file "$PARDIR/r_nc.rc"     "$NC" 1 "$FAKEBIN" &
release_to_file "$PARDIR/r_gap.rc"    "$GAP" 1 "$FAKEBIN" &
wait
rc=X; IFS= read -r rc < "$PARDIR/r_pass_a.rc" || true; assert_eq "T3 PASS fixture advisory exit 0" 0 "$rc"
rc=X; IFS= read -r rc < "$PARDIR/r_pass_e.rc" || true; assert_eq "T3 PASS fixture enforce  exit 0 (no false-fail — control)" 0 "$rc"
release_md_has "$PASSP" "RELEASE READY" && ok "T3 PASS RELEASE.md says READY" || bad "T3 PASS verdict" "not READY"
rc=X; IFS= read -r rc < "$PARDIR/r_stale.rc" || true; assert_eq "T3 stale memory enforce exit 2" 2 "$rc"
release_md_has "$ST" "STALE" && ok "T3 stale reason in RELEASE.md" || bad "T3 stale reason" "no STALE"
rc=X; IFS= read -r rc < "$PARDIR/r_nd.rc" || true; assert_eq "T3 builder-not-done enforce exit 2" 2 "$rc"
release_md_has "$ND" "NOT done" && ok "T3 not-done reason in RELEASE.md" || bad "T3 not-done reason" "no NOT done"
rc=X; IFS= read -r rc < "$PARDIR/r_bug.rc" || true; assert_eq "T3 bug-repro-red enforce exit 2" 2 "$rc"
release_md_has "$BR" "reproduction not green" && ok "T3 repro-red reason in RELEASE.md" || bad "T3 repro reason" "missing"
rc=X; IFS= read -r rc < "$PARDIR/r_nc.rc" || true; assert_eq "T3 missing-changelog enforce exit 2" 2 "$rc"
release_md_has "$NC" "CHANGELOG: missing" && ok "T3 missing-changelog reason in RELEASE.md" || bad "T3 changelog reason" "missing"
rc=X; IFS= read -r rc < "$PARDIR/r_gap.rc" || true; assert_eq "T3 coverage-gap enforce exit 2" 2 "$rc"
release_md_has "$GAP" "missing CHANGELOG coverage" && ok "T3 coverage-gap reason in RELEASE.md" || bad "T3 coverage reason" "missing"
echo ""

# ===========================================================================
# TIER 4 — ADVERSARIAL/SECURITY across BOTH guards. Paths are JSON-escaped via the lib
# (one batch process) so backslashes form VALID hook JSON, then guards run in parallel.
# ===========================================================================
tlog "tier4 start"; echo "-- tier 4: ADVERSARIAL both guards --"
RP=$(mkproj t4ro)
SP=$(mkproj t4sc); mkdir -p "$SP/.claude/builder"; printf '# Plan\n## Scope\n- src/allowed.py\n' > "$SP/.claude/builder/PLAN.md"
# raw spec: kind(ro|sc) TAB label TAB expect TAB rawpath
T4RAW="$WORK/t4.raw"
{
  printf 'ro\tbackslash ..\\..\\evil\t2\t..\\..\\evil\n'
  printf 'ro\tfour-dot ....//evil\t2\t....//evil\n'
  printf 'ro\tmixed-sep zone escape\t2\t.claude\\explorer\\..\\..\\evil\n'
  printf 'ro\ttrailing .. escape\t2\t.claude/explorer/..\n'
  printf 'ro\tvery long escaping\t2\t.claude/explorer/../../../../../../../../../../../../evil\n'
  printf 'ro\tplain in-zone\t0\t.claude/explorer/notes.md\n'
  printf 'ro\tmixed-sep in-zone (B twin)\t0\t.claude\\explorer\\notes.md\n'
  printf 'ro\tlong in-zone\t0\t.claude/explorer/a/a/a/a/a/a/a/a/a/a/f.md\n'
  printf 'sc\tbackslash escape\t2\tsrc\\..\\..\\..\\evil.py\n'
  printf 'sc\tfour-dot ....//evil.py\t2\t....//evil.py\n'
  printf 'sc\tforward escape\t2\tsrc/../../evil.py\n'
  printf 'sc\tin-scope src/allowed.py\t0\tsrc/allowed.py\n'
  printf 'sc\tmixed-sep in-scope (B twin)\t0\tsrc\\allowed.py\n'
  printf 'sc\tplugin memory .claude/*\t0\t.claude/builder/notes.md\n'
} > "$T4RAW"
# Batch: JSON-escape the rawpath field (lib bd_json_escape), preserving the other fields.
bash -c '. "$LIB"; while IFS="$(printf "\t")" read -r k l e rp; do printf "%s\t%s\t%s\t%s\n" "$k" "$l" "$e" "$(bd_json_escape "$rp")"; done' < "$T4RAW" > "$WORK/t4.esc"
# Build the parallel guard casefile.
T4CASES="$WORK/t4.cases"; : > "$T4CASES"
while IFS="$TAB" read -r k l e jp; do
  if [ "$k" = ro ]; then
    printf 'T4 readonly %s\t%s\t%s\t%s\t{"tool_input":{"file_path":"%s"}}\t%s\n' "$l" "$e" "$GUARD_READONLY" "$RP" "$jp" "$FAKEBIN" >> "$T4CASES"
  else
    printf 'T4 scope %s\t%s\t%s\t%s\t{"tool_name":"Edit","tool_input":{"file_path":"%s/%s"}}\t%s\n' "$l" "$e" "$GUARD_SCOPE" "$SP" "$SP" "$jp" "$FAKEBIN" >> "$T4CASES"
  fi
done < "$WORK/t4.esc"
run_guard_cases "$T4CASES"
echo ""

# ===========================================================================
# TIER 5 — PROPERTY: guard-readonly ALLOWS iff normalized path is in-zone. ~50 generated
# paths; the oracle (normalize + membership) + JSON-escape are batched in ONE process; the
# guards run in parallel.
# ===========================================================================
tlog "tier5 start"; echo "-- tier 5: PROPERTY (no over/under-blocking) --"
PP=$(mkproj t5)
# Deterministic generator (LCG) -> 50 relative paths, ~first 14 seeded in-zone.
# Fork-free: helpers set variables instead of echoing (a `$(...)` per segment would be a
# subshell fork — ~650 of them here — which dominates wall time on cygwin).
seed=1234567
nextrand() { seed=$(( (seed * 1103515245 + 12345) % 2147483648 )); }
segof() { case "$1" in 0) SEG=.;; 1) SEG=..;; 2) SEG=a;; 3) SEG=b;; 4) SEG=explorer;; 5) SEG=.claude;; *) SEG=evil;; esac; }
T5PATHS="$WORK/t5.paths"; : > "$T5PATHS"
i=0
while [ "$i" -lt 30 ]; do
  if [ "$i" -lt 9 ]; then rp=".claude/explorer/"; else rp=""; fi
  nextrand; nseg=$(( seed % 4 + 2 )); j=0
  while [ "$j" -lt "$nseg" ]; do
    nextrand; segof "$(( seed % 7 ))"
    nextrand; sepbit=$(( seed % 2 ))
    if [ -z "$rp" ] || [ "${rp%/}" != "$rp" ]; then rp="$rp$SEG"
    elif [ "$sepbit" = 0 ]; then rp="$rp/$SEG"
    else rp="$rp\\$SEG"; fi
    j=$((j+1))
  done
  printf '%s\n' "$rp" >> "$T5PATHS"
  i=$((i+1))
done
# Batch oracle+escape: emit "expect TAB jsonpath" per path (PP via env, lib normalize/escape).
PP="$PP" bash -c '
  . "$LIB"
  while IFS= read -r rp; do
    nabs="$(bd_normalize_path "$PP/$rp")"
    case "$nabs" in */.claude/explorer/*) ex=0 ;; *) ex=2 ;; esac
    printf "%s\t%s\n" "$ex" "$(bd_json_escape "$rp")"
  done
' < "$T5PATHS" > "$WORK/t5.oracle"
# Build casefile + count allow/block for the non-vacuous controls.
T5CASES="$WORK/t5.cases"; : > "$T5CASES"; t5_allow=0; t5_block=0; k=0
while IFS="$TAB" read -r ex jp; do
  # JSON built INLINE in the printf (no `json=$(...)` subshell fork per path).
  printf 'T5 path#%s expect=%s\t%s\t%s\t%s\t{"tool_input":{"file_path":"%s"}}\t%s\n' "$k" "$ex" "$ex" "$GUARD_READONLY" "$PP" "$jp" "$FAKEBIN" >> "$T5CASES"
  if [ "$ex" = 0 ]; then t5_allow=$((t5_allow+1)); else t5_block=$((t5_block+1)); fi
  k=$((k+1))
done < "$WORK/t5.oracle"
# Dispatch in parallel; tally mismatches (instead of one assert per path, to keep output terse).
rm -f "$PARDIR"/g*.rc; : > "$PARDIR/gidx"; _n=0
while IFS="$TAB" read -r _lbl _exp _scr _prj _json _pp; do
  [ -n "$_lbl" ] || continue
  guard_to_file "$PARDIR/g$_n.rc" "$_scr" "$_prj" "$_json" "$_pp" &
  printf '%s\t%s\t%s\n' "$_lbl" "$_exp" "$_n" >> "$PARDIR/gidx"
  _n=$((_n+1))
done < "$T5CASES"
wait
t5_mismatch=0; t5_total=0
while IFS="$TAB" read -r _lbl _exp _i; do
  _got=X; [ -f "$PARDIR/g$_i.rc" ] && IFS= read -r _got < "$PARDIR/g$_i.rc" || true
  t5_total=$((t5_total+1)); [ "$_got" = "$_exp" ] || { t5_mismatch=$((t5_mismatch+1)); printf '      %s got=%s\n' "$_lbl" "$_got"; }
done < "$PARDIR/gidx"
assert_eq "T5 guard matches normalize-oracle on all $t5_total paths (0 mismatches)" 0 "$t5_mismatch"
[ "$t5_allow" -gt 0 ] && ok "T5 (control) generated >=1 in-zone ALLOW case ($t5_allow)" || bad "T5 allow coverage" "none"
[ "$t5_block" -gt 0 ] && ok "T5 (control) generated >=1 out-of-zone BLOCK case ($t5_block)" || bad "T5 block coverage" "none"
echo ""

# ===========================================================================
# TIER 6 — PORTABILITY MATRIX: python {real|stub|none} x jq {present|absent}.
# ===========================================================================
tlog "tier6 start"; echo "-- tier 6: PORTABILITY matrix --"
GP=$(mkproj t6)
# Guard cases across all python x jq cells, dispatched in parallel.
T6CASES="$WORK/t6.cases"; : > "$T6CASES"
add_cell_guards() {  # <label> <pp>
  _lab=$1; _pp=$2
  printf 'T6 [%s] out-of-zone BLOCKED\t2\t%s\t%s\t%s\t%s\n' "$_lab" "$GUARD_READONLY" "$GP" '{"tool_input":{"file_path":"src/evil.py"}}' "$_pp" >> "$T6CASES"
  printf 'T6 [%s] in-zone ALLOWED\t0\t%s\t%s\t%s\t%s\n'    "$_lab" "$GUARD_READONLY" "$GP" '{"tool_input":{"file_path":".claude/explorer/n.md"}}' "$_pp" >> "$T6CASES"
}
[ -n "$HOST_PY" ] && add_cell_guards "py=real jq=absent" "" || skipnote "T6 py=real (host has no working python)"
[ -n "$HOST_PY" ] && add_cell_guards "py=real jq=present" "$JQBIN"
add_cell_guards "py=stub jq=absent"  "$FAKEBIN"
add_cell_guards "py=stub jq=present" "$FAKEBIN:$JQBIN"
if [ "$NONE_OK" = 1 ]; then
  add_cell_guards "py=none jq=absent"  "$NONEPATH"
  add_cell_guards "py=none jq=present" "$JQBIN:$NONEPATH"
else
  skipnote "T6 py=none (could not build a python-free PATH on this host)"
fi
run_guard_cases "$T6CASES"

# STATUS round-trip per python condition (parallel): write blocked/5, read back == blocked.
status_rt() {  # <id> <label> <pp>
  _id=$1; _lab=$2; _pp=$3; _d="$WORK/t6s_$_id"; mkdir -p "$_d"
  (
    _r=FAIL
    if [ -n "$_pp" ]; then
      PATH="$_pp:$PATH" CLAUDE_PROJECT_DIR="$_d" LIB="$LIB" bash "$LIBHELPER" swrite builder plan blocked 5 >/dev/null 2>&1 || true
      _v=$(PATH="$_pp:$PATH" CLAUDE_PROJECT_DIR="$_d" LIB="$LIB" bash "$LIBHELPER" sread builder state 2>/dev/null || true)
    else
      CLAUDE_PROJECT_DIR="$_d" LIB="$LIB" bash "$LIBHELPER" swrite builder plan blocked 5 >/dev/null 2>&1 || true
      _v=$(CLAUDE_PROJECT_DIR="$_d" LIB="$LIB" bash "$LIBHELPER" sread builder state 2>/dev/null || true)
    fi
    [ "$_v" = blocked ] && _r=PASS
    printf '%s\t%s' "$_r" "$_lab" > "$PARDIR/st_$_id.res"
  ) &
}
rm -f "$PARDIR"/st_*.res
[ -n "$HOST_PY" ] && status_rt real "py=real" ""
status_rt stub "py=stub" "$FAKEBIN"
[ "$NONE_OK" = 1 ] && status_rt none "py=none" "$NONEPATH"
wait
for f in "$PARDIR"/st_*.res; do
  [ -e "$f" ] || continue
  IFS="$TAB" read -r res lab < "$f" || true
  if [ "$res" = PASS ]; then ok "T6 [$lab] STATUS write/read round-trip"; else bad "T6 STATUS [$lab]" "round-trip failed"; fi
done

# Release-gate portability: the critical claim is "never fail-open without python", so run a
# FAILING fixture under enforce per python condition and require exit 2. (The PASS path under
# no-python is already proven by tier 3, which runs the whole gate under FAKEBIN.)
RGF=$(mkproj t6rgf); fresh_mem "$RGF"; mkdir -p "$RGF/.claude/builder"   # no changelog -> fail
printf '%s\tdone\n' "$RGF" | PATH="$FAKEBIN:$PATH" bash -c '. "$LIB"; while IFS="$(printf "\t")" read -r prj st; do CLAUDE_PROJECT_DIR="$prj" bd_status_write builder qa "$st" >/dev/null 2>&1 || true; done' || true
release_to_file "$PARDIR/t6_stub_fe.rc" "$RGF" 1 "$FAKEBIN" &
[ "$NONE_OK" = 1 ] && release_to_file "$PARDIR/t6_none_fe.rc" "$RGF" 1 "$NONEPATH" &
wait
rc=X; IFS= read -r rc < "$PARDIR/t6_stub_fe.rc" || true; assert_eq "T6 release gate py=stub FAIL enforce exit 2 (no fail-open)" 2 "$rc"
if [ "$NONE_OK" = 1 ]; then
  rc=X; IFS= read -r rc < "$PARDIR/t6_none_fe.rc" || true; assert_eq "T6 release gate py=none FAIL enforce exit 2 (no fail-open)" 2 "$rc"
fi
echo ""

# ===========================================================================
# TIER 7 — MUTATION SENTINEL: prove the suite is not vacuous.
# ===========================================================================
tlog "tier7 start"; echo "-- tier 7: MUTATION SENTINELS --"
# (a) guard-scope: sed the out-of-scope block line to 'exit 0'. The same adversarial edit the
# REAL guard BLOCKS (exit 2) must then PASS (0) against the mutant.
T=$WORK/mut_scope; mkdir -p "$T/scripts" "$T/lib"; cp "$LIB" "$T/lib/common.sh"
sed 's/.*NOT in the approved PLAN.md scope.*/exit 0/' "$GUARD_SCOPE" > "$T/scripts/guard-scope.sh"
MS=$(mkproj mut_sc); mkdir -p "$MS/.claude/builder"; printf '# Plan\n## Scope\n- src/allowed.py\n' > "$MS/.claude/builder/PLAN.md"
EVIL=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/src/secret/evil.py"}}' "$MS")
real_rc=0; printf '%s' "$EVIL" | PATH="$FAKEBIN:$PATH" CLAUDE_PROJECT_DIR="$MS" bash "$GUARD_SCOPE"        >/dev/null 2>&1 || real_rc=$?
mut_rc=0;  printf '%s' "$EVIL" | PATH="$FAKEBIN:$PATH" CLAUDE_PROJECT_DIR="$MS" bash "$T/scripts/guard-scope.sh" >/dev/null 2>&1 || mut_rc=$?
if [ "$real_rc" = 2 ] && [ "$mut_rc" = 0 ]; then ok "T7 guard-scope sentinel: real BLOCKS(2), mutant PASSES(0) -> block line load-bearing"; else bad "T7 guard-scope sentinel" "real=$real_rc(want 2) mut=$mut_rc(want 0)"; fi

# (b) verify-release: sed the enforce 'exit 2' to 'exit 0'. A failing fixture the REAL gate
# blocks (exit 2 under enforce) must then PASS (0) against the mutant.
T2=$WORK/mut_rel; mkdir -p "$T2/scripts" "$T2/lib"; cp "$LIB" "$T2/lib/common.sh"
sed 's/^\([[:space:]]*\)exit 2$/\1exit 0/' "$VERIFY_RELEASE" > "$T2/scripts/verify-release.sh"
MR=$(mkproj mut_rel_fx)   # empty project -> multiple required failures
( _r=0; PATH="$FAKEBIN:$PATH" CLAUDE_PROJECT_DIR="$MR" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE"               >/dev/null 2>&1 || _r=$?; printf '%s' "$_r" > "$PARDIR/t7_real.rc" ) &
( _r=0; PATH="$FAKEBIN:$PATH" CLAUDE_PROJECT_DIR="$MR" PIPELINE_ENFORCE=1 bash "$T2/scripts/verify-release.sh" >/dev/null 2>&1 || _r=$?; printf '%s' "$_r" > "$PARDIR/t7_mut.rc" ) &
wait
real_rc=X; IFS= read -r real_rc < "$PARDIR/t7_real.rc" || true
mut_rc=X;  IFS= read -r mut_rc  < "$PARDIR/t7_mut.rc"  || true
if [ "$real_rc" = 2 ] && [ "$mut_rc" = 0 ]; then ok "T7 verify-release sentinel: real BLOCKS(2), mutant PASSES(0) -> fail line load-bearing"; else bad "T7 verify-release sentinel" "real=$real_rc(want 2) mut=$mut_rc(want 0)"; fi
echo ""

# ===========================================================================
tlog "all tiers done"
echo "== ladder summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
