#!/usr/bin/env sh
# e2e-ladder.sh — CAPSTONE acceptance test for the whole pipeline. POSIX sh, `set -eu`,
# isolated mktemp fixtures (each a throwaway git repo so explorer freshness resolves).
#
# This is the "1–2 command -> prod-ready" PROOF. It does not unit-test any single module; it
# asserts the INTEGRATED verdict of the release gate (plugins/pipeline/scripts/verify-release.sh)
# — the deterministic heart of /pipeline:run and /pipeline:fix — over a fully-wired fixture where
# every module has run: explorer (fresh MEMORY.md) -> builder (STATUS done + PLAN covered in
# CHANGELOG) -> bug-fix net (BUG.md + green repro ledger) -> auditor (0 high) -> reviewer
# (0 blocking) -> ops (0 blocking) -> the gate. The gate is the single place all seven module
# verdicts are aggregated into RELEASE READY / BLOCKED.
#
# Tiers:
#   1. GREEN-PATH — ONE complete fixture where every check can PASS. Under PIPELINE_ENFORCE=1 the
#      gate exits 0, RELEASE.md reads "RELEASE READY", and ALL SEVEN checks show PASS (none SKIP).
#      (To drive bugfix-net to PASS rather than SKIP — it is one of the seven — the green fixture
#      also carries a BUG.md + a green repro ledger; without it that row would SKIP.)
#   2. PER-MODULE NEGATIVES — eight pass/fail pairs. For each, build a fresh green fixture, prove it
#      PASSES (exit 0) under enforce, then flip EXACTLY ONE thing and prove the gate BLOCKS (exit 2)
#      and RELEASE.md cites the right reason: (a) stale memory, (b) builder not done, (c) a PLAN task
#      missing its CHANGELOG coverage, (d) auditor high=1, (e) reviewer blocking=1, (f) ops
#      blocking=1, (g) missing CHANGELOG, (h) bug repro red. This is the gate's integrated
#      mutation-detection: one mutation each, each independently caught.
#   3. DASHBOARD — pipeline-status.sh on the green fixture: exit 0, never crashes (also on an EMPTY
#      project), and reflects each module's state correctly. The script rows explorer/builder/
#      pipeline directly; auditor/reviewer/ops readiness is consolidated by the release gate (the
#      seven PASS rows asserted in tier 1), and their STATUS is independently confirmed here.
#   4. MUTATION SENTINEL — sed the gate's verdict line (`REQ_FAIL -eq 0` -> always-true) and prove a
#      negative fixture (auditor high=1) flips from BLOCKED to "RELEASE READY" under the mutant ->
#      the integrated verdict is load-bearing.
#
# Keeps all five existing suites green (it adds a file; it never edits a script/lib). Summary line;
# exits nonzero on any FAIL.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
export ROOT
LIB="$ROOT/shared/lib/common.sh";                              export LIB
VERIFY_RELEASE="$ROOT/plugins/pipeline/scripts/verify-release.sh"
PIPE_STATUS="$ROOT/plugins/pipeline/scripts/pipeline-status.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s  --  %s\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
skipnote()  { printf 'SKIP  %s\n' "$1"; }
# RELEASE.md of fixture $1 matches extended-regex $2 (case-insensitive)?
rel_has() { grep -iE "$2" "$1/.claude/pipeline/RELEASE.md" >/dev/null 2>&1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT INT TERM

# Deterministic git fixture (autocrlf/fileMode off — throwaway repos) with one commit so HEAD resolves.
gitfix() {
  mkdir -p "$1"
  git -C "$1" init -q >/dev/null 2>&1
  git -C "$1" config core.autocrlf false
  git -C "$1" config core.fileMode false
  git -C "$1" config user.email t@e
  git -C "$1" config user.name t
  git -C "$1" commit -q --allow-empty -m init >/dev/null 2>&1 || true
}

# build_green <dir> : a COMPLETE release-ready fixture — every one of the seven gate checks can PASS.
# A real git repo (HEAD), fresh explorer memory (explored_commit == HEAD), a builder PLAN whose two
# tasks are both covered in the CHANGELOG, builder STATUS done, a bug-fix net (BUG.md + green repro
# ledger), and clean auditor/reviewer/ops STATUS. Writing STATUS goes through the canonical lib so it
# round-trips with the gate's vendored copy.
build_green() {
  d="$1"
  gitfix "$d"
  HEAD_FULL=$(git -C "$d" rev-parse HEAD 2>/dev/null || printf 'x')
  mkdir -p "$d/.claude/explorer" "$d/.claude/builder/bugfix"
  # explorer — fresh memory (explored_commit pinned to this fixture's HEAD).
  { printf 'explored_commit: %s\n' "$HEAD_FULL"; printf 'coverage: 90%%\n'; } > "$d/.claude/explorer/MEMORY.md"
  # builder — PLAN with two atomic tasks, both covered in the CHANGELOG. Coverage is proven by
  # the STRUCTURED per-task header the builder emits (### Task <id> — edge-case coverage), the
  # exact marker the gate scans for; a bare prose "Task <id>" line would NOT satisfy the gate.
  printf '# Plan\n\n## Scope\n- a\n- b\n\n## Tasks\n### Task 1: do A\n### Task 2: do B\n' > "$d/.claude/builder/PLAN.md"
  printf '# Changelog\n\n### Task 1 — edge-case coverage\n- nil -> handled at a:1\n### Task 2 — edge-case coverage\n- nil -> handled at b:1\n' > "$d/.claude/builder/CHANGELOG.md"
  CLAUDE_PROJECT_DIR="$d" bash -c '. "$LIB"; bd_status_write builder qa done' >/dev/null 2>&1 || true
  # bug-fix net — BUG.md present + a GREEN repro ledger, so bugfix-net PASSES (not SKIPs).
  printf '# Bug Brief\nSymptom: x\nRepro status: GREEN\n' > "$d/.claude/builder/BUG.md"
  printf 'repro green\nchar green\n' > "$d/.claude/builder/bugfix/results.txt"
  # auditor / reviewer / ops — all clean (0 high / 0 blocking / 0 blocking).
  CLAUDE_PROJECT_DIR="$d" bash -c '. "$LIB"; bd_status_write auditor  audit     done "" high=0 med=0 low=0'     >/dev/null 2>&1 || true
  CLAUDE_PROJECT_DIR="$d" bash -c '. "$LIB"; bd_status_write reviewer review    done "" blocking=0 concern=0'   >/dev/null 2>&1 || true
  CLAUDE_PROJECT_DIR="$d" bash -c '. "$LIB"; bd_status_write ops      readiness done "" blocking=0 concern=0'   >/dev/null 2>&1 || true
}

# --- the eight single-mutation flips (each takes the fixture dir) -------------
flip_a() { printf 'explored_commit: %s\ncoverage: 90%%\n' 0000000000000000000000000000000000000000 > "$1/.claude/explorer/MEMORY.md"; }  # stale
flip_b() { CLAUDE_PROJECT_DIR="$1" bash -c '. "$LIB"; bd_status_write builder qa running' >/dev/null 2>&1 || true; }                       # not done
flip_c() { printf '# Changelog\n\n### Task 1 — edge-case coverage\n- nil -> handled at a:1\n' > "$1/.claude/builder/CHANGELOG.md"; }          # Task 2 marker removed -> uncovered
flip_d() { CLAUDE_PROJECT_DIR="$1" bash -c '. "$LIB"; bd_status_write auditor  audit     done "" high=1 med=0 low=0'   >/dev/null 2>&1 || true; }
flip_e() { CLAUDE_PROJECT_DIR="$1" bash -c '. "$LIB"; bd_status_write reviewer review    done "" blocking=1 concern=0' >/dev/null 2>&1 || true; }
flip_f() { CLAUDE_PROJECT_DIR="$1" bash -c '. "$LIB"; bd_status_write ops      readiness done "" blocking=1 concern=0' >/dev/null 2>&1 || true; }
flip_g() { rm -f "$1/.claude/builder/CHANGELOG.md"; }                                                                                      # missing changelog
flip_h() { printf 'repro red\nchar green\n' > "$1/.claude/builder/bugfix/results.txt"; }                                                   # repro not green

echo "== e2e (capstone) test ladder =="
echo "ROOT=$ROOT"
HAVE_GIT=no; command -v git >/dev/null 2>&1 && HAVE_GIT=yes
HOSTPY=no; for c in python3 python "py -3"; do if $c -c "pass" >/dev/null 2>&1; then HOSTPY=yes; break; fi; done
echo "git: $HAVE_GIT | host working python: $HOSTPY"
echo ""

# The whole capstone needs a git work tree (the green fixture pins explored_commit to a real HEAD).
if [ "$HAVE_GIT" != yes ]; then
  skipnote "e2e capstone — git unavailable; cannot build a throwaway repo for freshness"
  echo "== e2e ladder summary: 0 passed, 0 failed (skipped: git required) =="
  exit 0
fi

# ===========================================================================
# TIER 1 — GREEN-PATH: the prod-ready proof. Every module ran and passed.
# ===========================================================================
echo "-- tier 1: GREEN-PATH (all seven checks PASS) --"
G="$WORK/green"; build_green "$G"
rc=0; out=$(CLAUDE_PROJECT_DIR="$G" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" 2>/dev/null) || rc=$?
assert_eq "T1 gate EXITS 0 on the complete green fixture under enforce" 0 "$rc"
printf '%s' "$out" | grep -q "RELEASE READY" && ok "T1 gate STDOUT verdict is RELEASE READY" || bad "T1 stdout verdict" "no RELEASE READY in: $out"
RELMD="$G/.claude/pipeline/RELEASE.md"
[ -f "$RELMD" ] && ok "T1 RELEASE.md written" || bad "T1 RELEASE.md" "missing"
grep -q "RELEASE READY" "$RELMD" 2>/dev/null && ok "T1 RELEASE.md reads RELEASE READY" || bad "T1 RELEASE.md verdict" "not RELEASE READY"
# Every one of the seven checks is a PASS row; none SKIP, none FAIL.
for chk in explorer-memory builder-finished bugfix-net auditor changelog reviewer ops; do
  grep -q "| $chk | PASS |" "$RELMD" 2>/dev/null && ok "T1 check '$chk' = PASS" || bad "T1 check $chk" "row not PASS in RELEASE.md"
done
np=$(grep -c "| PASS |" "$RELMD" 2>/dev/null || true)
ns=$(grep -c "| SKIP |" "$RELMD" 2>/dev/null || true)
nfl=$(grep -c "| FAIL |" "$RELMD" 2>/dev/null || true)
assert_eq "T1 exactly 7 PASS rows" 7 "$np"
assert_eq "T1 zero SKIP rows (every module ran)" 0 "$ns"
assert_eq "T1 zero FAIL rows" 0 "$nfl"
# The gate persists its own verdict for the dashboard/conductor.
ps=$(CLAUDE_PROJECT_DIR="$G" bash -c '. "$LIB"; bd_status_read pipeline state' 2>/dev/null || true)
assert_eq "T1 pipeline STATUS state=done after a green run" done "$ps"
echo ""

# ===========================================================================
# TIER 2 — PER-MODULE NEGATIVES: eight pass/fail pairs (one mutation each).
# ===========================================================================
echo "-- tier 2: PER-MODULE NEGATIVES (8 single-mutation pairs) --"
NEG=0
# pair <label> <flip-fn> <reason-regex> : green PASSES (exit 0), then the single flip BLOCKS (exit 2)
# with the reason cited in RELEASE.md. All under PIPELINE_ENFORCE=1 so a REQUIRED failure -> exit 2.
pair() {
  label="$1"; flipfn="$2"; pat="$3"
  NEG=$((NEG+1)); d="$WORK/neg$NEG"
  build_green "$d"
  rc=0; CLAUDE_PROJECT_DIR="$d" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" >/dev/null 2>&1 || rc=$?
  assert_eq "T2 $label — GREEN baseline PASSES (exit 0)" 0 "$rc"
  "$flipfn" "$d"
  rc=0; CLAUDE_PROJECT_DIR="$d" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" >/dev/null 2>&1 || rc=$?
  assert_eq "T2 $label — flip BLOCKS (exit 2)" 2 "$rc"
  if rel_has "$d" "$pat"; then ok "T2 $label — RELEASE.md cites the reason"; else bad "T2 $label reason" "pattern [$pat] absent from RELEASE.md"; fi
}
pair "(a) stale explorer memory"        flip_a 'STALE'
pair "(b) builder not done"             flip_b 'NOT done'
pair "(c) PLAN task uncovered"          flip_c 'missing CHANGELOG coverage'
pair "(d) auditor high=1"               flip_d '1 HIGH'
pair "(e) reviewer blocking=1"          flip_e 'reviewer:.*BLOCKING'
pair "(f) ops blocking=1"               flip_f 'ops:.*BLOCKING'
pair "(g) missing CHANGELOG"            flip_g 'missing or empty'   # also trips coverage (CHANGELOG is its input); we assert the changelog reason
pair "(h) bug repro red"                flip_h 'reproduction not green'
echo ""

# ===========================================================================
# TIER 3 — DASHBOARD: pipeline-status.sh reflects every module + never crashes.
# ===========================================================================
echo "-- tier 3: DASHBOARD (pipeline-status.sh) --"
# Refresh the pipeline verdict on the green fixture so the dashboard's pipeline row is current.
CLAUDE_PROJECT_DIR="$G" bash "$VERIFY_RELEASE" >/dev/null 2>&1 || true
rc=0; dout=$(CLAUDE_PROJECT_DIR="$G" bash "$PIPE_STATUS" 2>/dev/null) || rc=$?
assert_eq "T3 dashboard exits 0 on the green fixture" 0 "$rc"
[ -n "$dout" ] && ok "T3 dashboard prints output (never silent)" || bad "T3 dashboard output" "empty"
# The script rows explorer/builder/pipeline directly.
printf '%s\n' "$dout" | grep -E '^[[:space:]]*explorer' | grep -q 'current'  && ok "T3 explorer row reflects freshness=current" || bad "T3 explorer row" "no current freshness in: $dout"
printf '%s\n' "$dout" | grep -E '^[[:space:]]*builder'  | grep -q 'done'     && ok "T3 builder row reflects state=done"       || bad "T3 builder row"  "no done state in: $dout"
printf '%s\n' "$dout" | grep -E '^[[:space:]]*pipeline' | grep -q 'done'     && ok "T3 pipeline row reflects release=done"     || bad "T3 pipeline row" "no done state in: $dout"
# auditor/reviewer/ops readiness is consolidated by the release gate (tier 1's seven PASS rows);
# confirm their STATUS independently reflects the green state on the same fixture.
a_st=$(CLAUDE_PROJECT_DIR="$G" bash -c '. "$LIB"; bd_status_read auditor  state'    2>/dev/null || true)
a_hi=$(CLAUDE_PROJECT_DIR="$G" bash -c '. "$LIB"; bd_status_read auditor  high'     2>/dev/null || true)
r_st=$(CLAUDE_PROJECT_DIR="$G" bash -c '. "$LIB"; bd_status_read reviewer state'    2>/dev/null || true)
r_bl=$(CLAUDE_PROJECT_DIR="$G" bash -c '. "$LIB"; bd_status_read reviewer blocking' 2>/dev/null || true)
o_st=$(CLAUDE_PROJECT_DIR="$G" bash -c '. "$LIB"; bd_status_read ops      state'    2>/dev/null || true)
o_bl=$(CLAUDE_PROJECT_DIR="$G" bash -c '. "$LIB"; bd_status_read ops      blocking' 2>/dev/null || true)
[ "$a_st" = done ] && [ "$a_hi" = 0 ] && ok "T3 auditor STATUS reflects done / 0-high (gate-consolidated)"     || bad "T3 auditor STATUS"  "state=$a_st high=$a_hi"
[ "$r_st" = done ] && [ "$r_bl" = 0 ] && ok "T3 reviewer STATUS reflects done / 0-blocking (gate-consolidated)" || bad "T3 reviewer STATUS" "state=$r_st blocking=$r_bl"
[ "$o_st" = done ] && [ "$o_bl" = 0 ] && ok "T3 ops STATUS reflects done / 0-blocking (gate-consolidated)"       || bad "T3 ops STATUS"      "state=$o_st blocking=$o_bl"
# Never crashes on a bare project with no .claude STATUS at all.
EMPTY="$WORK/empty"; mkdir -p "$EMPTY"
rc=0; eout=$(CLAUDE_PROJECT_DIR="$EMPTY" bash "$PIPE_STATUS" 2>/dev/null) || rc=$?
assert_eq "T3 dashboard exits 0 on an EMPTY project (no STATUS — never crashes)" 0 "$rc"
printf '%s\n' "$eout" | grep -q 'no explorer memory' && ok "T3 dashboard nudges /pipeline:run when memory is absent" || bad "T3 empty nudge" "missing nudge in: $eout"
echo ""

# ===========================================================================
# TIER 4 — MUTATION SENTINEL: the integrated verdict line is load-bearing.
# ===========================================================================
echo "-- tier 4: MUTATION SENTINEL (verdict line) --"
# Mutant gate whose verdict computation always resolves to "done" / "RELEASE READY".
# Only line 232's `REQ_FAIL -eq 0` carries `; then RELEASE_STATE="done"`, so this targets the
# verdict line ALONE (the separate exit-2 `-ne 0` line is untouched — we compare verdicts, advisory).
MUTDIR="$WORK/mutverdict"; mkdir -p "$MUTDIR/scripts" "$MUTDIR/lib"
cp "$LIB" "$MUTDIR/lib/common.sh"
sed 's/\[ "$REQ_FAIL" -eq 0 \]; then RELEASE_STATE="done"/[ "$REQ_FAIL" -ge 0 ]; then RELEASE_STATE="done"/' "$VERIFY_RELEASE" > "$MUTDIR/scripts/verify-release.sh"
MN="$WORK/sentinel"; build_green "$MN"; flip_d "$MN"   # the ONLY failing check: auditor high=1
real_out=$(CLAUDE_PROJECT_DIR="$MN" bash "$VERIFY_RELEASE" 2>/dev/null) || true
mut_out=$(CLAUDE_PROJECT_DIR="$MN" bash "$MUTDIR/scripts/verify-release.sh" 2>/dev/null) || true
real_blocked=no; printf '%s' "$real_out" | grep -qE 'release gate.*BLOCKED' && real_blocked=yes
mut_ready=no;    printf '%s' "$mut_out"  | grep -qE 'release gate.*RELEASE READY' && mut_ready=yes
if [ "$real_blocked" = yes ] && [ "$mut_ready" = yes ]; then
  ok "T4 sentinel: real verdict BLOCKED, mutant verdict RELEASE READY -> the REQ_FAIL verdict is load-bearing"
else
  bad "T4 verdict sentinel" "real_blocked=$real_blocked (want yes) mut_ready=$mut_ready (want yes)"
fi
# Guard the mutation actually changed the file (a no-op sed would make the sentinel vacuous).
if ! cmp -s "$VERIFY_RELEASE" "$MUTDIR/scripts/verify-release.sh"; then ok "T4 mutant differs from the real gate (sed applied)"; else bad "T4 mutant" "sed was a no-op — sentinel would be vacuous"; fi
echo ""

echo "== e2e ladder summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
