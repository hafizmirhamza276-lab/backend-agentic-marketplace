#!/usr/bin/env sh
# review-ladder.sh — production test ladder for the `reviewer` plugin. POSIX sh, `set -eu`,
# isolated mktemp fixtures (each a throwaway git repo so `git diff HEAD` has something to read).
# Every check carries a FIRE control (a crafted bad diff -> the right SEVERITY/slug) AND a SILENT
# twin (an in-spec variant -> nothing), so a broken check FAILS the suite (it is never vacuous).
# Mutation sentinels prove the load-bearing lines are load-bearing.
#
# Tiers:
#   1. SILENT — R1–R4 are silent on a clean diff AND on a realistic in-spec change (no false fires).
#   2. FIRE — per-check positive control + silent twin: R1 (removed fn + surviving caller, BLOCKING);
#      R2 (drop set -uo / stop sourcing lib / add set -e, BLOCKING — each tested); R3 (changed file in
#      a fixture MEMORY.md Risk map, CONCERN); R4 (changed file outside PLAN Scope, CONCERN).
#   3. AGGREGATE — verify-review folds agent BLOCKING/CONCERN into STATUS, EXCLUDES NOTE from the
#      blocking tally, writes REVIEW.md (listing the blocking), state=failed when blocking>0 else done.
#   4. CROSS-MODULE — release-ready fixture: reviewer blocking=1 -> verify-release enforce FAILS
#      (exit 2, reason mentions reviewer); blocking=0 -> that check PASSES; AND auditor high=2 still
#      blocks (no regression of the Phase-2 wiring).
#   5. PORTABILITY — review gate under python {real|stub|none}: deterministic checks + tally stable;
#      never crash, never fail-open. (stub ≡ none: both yield BD_PYTHON="" -> the python-free path.)
#   6. NOTE/advisory — a NOTE-only finding emits + lands in REVIEW.md but never gates (exit 0 even
#      under enforce; excluded from the blocking tally).
#   7. MUTATION SENTINEL — neuter R1's caller-grep emit line -> a broken-caller fixture PASSES the
#      mutant (R1 emit load-bearing); neuter verify-release's NEW reviewer fail/exit-2 path -> a
#      reviewer-blocking>0 fixture PASSES the mutant (the reviewer gate wiring is load-bearing).
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
export ROOT
LIB="$ROOT/shared/lib/common.sh";                            export LIB
CHECKS="$ROOT/plugins/reviewer/scripts/lib-review-checks.sh"; export CHECKS
VERIFY_REVIEW="$ROOT/plugins/reviewer/scripts/verify-review.sh"
VERIFY_RELEASE="$ROOT/plugins/pipeline/scripts/verify-release.sh"
TAB=$(printf '\t')

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s  --  %s\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
skipnote()  { printf 'SKIP  %s\n' "$1"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT INT TERM

# Run ONE check function against a fixture root; print its findings (stdout only).
run_check() { REVIEW_ROOT="$2" bash -c '. "$LIB"; . "$CHECKS"; '"$1" 2>/dev/null || true; }
# Match / count finding lines "<SEV>\t<slug-prefix>".
has() { printf '%s\n' "$1" | grep -q "^$2$TAB$3" 2>/dev/null; }
cnt() { printf '%s\n' "$1" | grep -c "^$2$TAB$3" 2>/dev/null || true; }

# --- git fixture helpers -----------------------------------------------------
# Deterministic config: autocrlf off (so `git show HEAD:..` returns the LF blob R2 compares) and
# fileMode off (so exec-bit noise never matters inside a throwaway fixture).
gitfix() {
  mkdir -p "$1"
  git -C "$1" init -q >/dev/null 2>&1
  git -C "$1" config core.autocrlf false
  git -C "$1" config core.fileMode false
  git -C "$1" config user.email t@e
  git -C "$1" config user.name t
}
gcommit() {
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.email=t@e -c user.name=t commit -qm "${2:-c}" >/dev/null 2>&1 || true
}

echo "== reviewer test ladder =="
echo "ROOT=$ROOT"
HAVE_GIT=no; command -v git >/dev/null 2>&1 && HAVE_GIT=yes
HOSTPY=no; for c in python3 python "py -3"; do if $c -c "pass" >/dev/null 2>&1; then HOSTPY=yes; break; fi; done
echo "git: $HAVE_GIT | host working python: $HOSTPY | shellcheck: $(command -v shellcheck >/dev/null 2>&1 && echo present || echo absent)"
echo ""

if [ "$HAVE_GIT" != yes ]; then
  echo "git unavailable — the reviewer's diff-based checks cannot be exercised. Skipping."
  echo "== reviewer ladder summary: $PASS passed, $FAIL failed =="
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

# ===========================================================================
# TIER 1 — SILENT on a clean diff AND on a realistic in-spec change.
# ===========================================================================
echo "-- tier 1: SILENT (clean + in-spec) --"
# A fixture wired with active machinery: a MEMORY.md Risk map (naming a file we will NOT touch) and
# a PLAN.md Scope (listing the file we WILL touch) — so silence proves no false positives, not an
# inert checker. scripts/feature.sh keeps the house preamble; danger.sh is the risk-mapped file.
F="$WORK/t1"; gitfix "$F"
mkdir -p "$F/scripts" "$F/.claude/explorer" "$F/.claude/builder"
printf '# Memory\n\n## Risk map\n- scripts/danger.sh — corrupts state on retry — high — scripts/danger.sh:10\n\n## Next\n- x\n' > "$F/.claude/explorer/MEMORY.md"
printf '# Plan\n\n## Scope\n- scripts/feature.sh\n\n## Risks / Invariants\n- respects MEMORY.md risk map\n' > "$F/.claude/builder/PLAN.md"
printf '#!/usr/bin/env bash\nset -uo pipefail\nDIR=x\n. "$DIR/../lib/common.sh"\nhelper() { echo hi; }\nhelper\n' > "$F/scripts/feature.sh"
printf '#!/usr/bin/env bash\nset -uo pipefail\necho danger\n' > "$F/scripts/danger.sh"
gcommit "$F" base
# (a) clean — no working changes
for fn in review_r1 review_r2 review_r3 review_r4; do
  out=$(run_check "$fn" "$F")
  n=$(printf '%s\n' "$out" | grep -cE "^(BLOCKING|CONCERN|NOTE)$TAB" 2>/dev/null || true)
  assert_eq "T1 $fn silent on clean diff (0 findings)" 0 "$n"
done
# (b) in-spec change: edit feature.sh (in scope, not risk-mapped), keep preamble, keep the function.
printf '#!/usr/bin/env bash\nset -uo pipefail\nDIR=x\n. "$DIR/../lib/common.sh"\nhelper() { echo hello; }\nhelper\n' > "$F/scripts/feature.sh"
for fn in review_r1 review_r2 review_r3 review_r4; do
  out=$(run_check "$fn" "$F")
  n=$(printf '%s\n' "$out" | grep -cE "^(BLOCKING|CONCERN|NOTE)$TAB" 2>/dev/null || true)
  assert_eq "T1 $fn silent on in-spec change (0 findings)" 0 "$n"
done
echo ""

# ===========================================================================
# TIER 2 — FIRE: per-check positive controls + silent twins.
# ===========================================================================
echo "-- tier 2: FIRE (per-check) --"

# R1 (BLOCKING) — a removed function with a surviving caller.
F="$WORK/r1"; gitfix "$F"; mkdir -p "$F/scripts"
printf '#!/usr/bin/env bash\nlegacy_helper() { echo hi; }\nlegacy_helper\n' > "$F/scripts/a.sh"
printf '#!/usr/bin/env bash\nlegacy_helper\n'                                > "$F/scripts/b.sh"
gcommit "$F" base
printf '#!/usr/bin/env bash\necho hi\n' > "$F/scripts/a.sh"   # remove legacy_helper(); b.sh still calls it
out=$(run_check review_r1 "$F"); has "$out" BLOCKING r1-caller-integrity && ok "T2 R1 fires BLOCKING on removed fn + surviving caller" || bad "T2 R1" "no BLOCKING; got: $out"
# silent twin — remove the caller too (no survivor).
printf '#!/usr/bin/env bash\necho start\n' > "$F/scripts/b.sh"
out=$(run_check review_r1 "$F"); n=$(cnt "$out" BLOCKING r1-caller-integrity); assert_eq "T2 R1 silent when no caller survives" 0 "$n"

# R2 (BLOCKING) — three regressions, each in isolation, + a silent twin.
F="$WORK/r2"; gitfix "$F"; mkdir -p "$F/scripts"
printf '#!/usr/bin/env bash\nset -uo pipefail\nDIR=x\n. "$DIR/../lib/common.sh"\necho hi\n' > "$F/scripts/g.sh"
gcommit "$F" base
# (a) drop set -uo pipefail
printf '#!/usr/bin/env bash\nDIR=x\n. "$DIR/../lib/common.sh"\necho hi\n' > "$F/scripts/g.sh"
out=$(run_check review_r2 "$F"); has "$out" BLOCKING r2-convention-regression && ok "T2 R2(a) fires BLOCKING on dropped 'set -uo pipefail'" || bad "T2 R2(a)" "no BLOCKING; got: $out"
# (b) stop sourcing ../lib/common.sh
printf '#!/usr/bin/env bash\nset -uo pipefail\necho hi\n' > "$F/scripts/g.sh"
out=$(run_check review_r2 "$F"); has "$out" BLOCKING r2-convention-regression && ok "T2 R2(b) fires BLOCKING on stopped-sourcing the lib" || bad "T2 R2(b)" "no BLOCKING; got: $out"
# (c) (re)introduce set -e
printf '#!/usr/bin/env bash\nset -uo pipefail\nset -e\nDIR=x\n. "$DIR/../lib/common.sh"\necho hi\n' > "$F/scripts/g.sh"
out=$(run_check review_r2 "$F"); has "$out" BLOCKING r2-convention-regression && ok "T2 R2(c) fires BLOCKING on (re)introduced 'set -e'" || bad "T2 R2(c)" "no BLOCKING; got: $out"
# silent twin — change content, keep every convention.
printf '#!/usr/bin/env bash\nset -uo pipefail\nDIR=x\n. "$DIR/../lib/common.sh"\necho changed\n' > "$F/scripts/g.sh"
out=$(run_check review_r2 "$F"); n=$(cnt "$out" BLOCKING r2-convention-regression); assert_eq "T2 R2 silent when conventions preserved" 0 "$n"

# R3 (CONCERN) — a changed file named in the MEMORY.md Risk map.
F="$WORK/r3"; gitfix "$F"; mkdir -p "$F/scripts" "$F/.claude/explorer"
printf '# Memory\n\n## Risk map\n- scripts/risky.sh — eats data — high — scripts/risky.sh:3\n\n## End\n- x\n' > "$F/.claude/explorer/MEMORY.md"
printf 'echo a\n' > "$F/scripts/risky.sh"; printf 'echo b\n' > "$F/scripts/safe.sh"
gcommit "$F" base
printf 'echo a2\n' > "$F/scripts/risky.sh"
out=$(run_check review_r3 "$F"); has "$out" CONCERN r3-risk-touch && ok "T2 R3 fires CONCERN on a risk-mapped file" || bad "T2 R3" "no CONCERN; got: $out"
# silent twin — change a file NOT in the risk map.
git -C "$F" checkout -- scripts/risky.sh >/dev/null 2>&1; printf 'echo b2\n' > "$F/scripts/safe.sh"
out=$(run_check review_r3 "$F"); n=$(cnt "$out" CONCERN r3-risk-touch); assert_eq "T2 R3 silent on a non-risk file" 0 "$n"

# R4 (CONCERN) — a changed file outside the PLAN Scope.
F="$WORK/r4"; gitfix "$F"; mkdir -p "$F/src" "$F/.claude/builder"
printf '# Plan\n\n## Scope\n- src/in.sh\n- `src/also.sh`\n\n## Risks\n- none\n' > "$F/.claude/builder/PLAN.md"
printf 'echo in\n' > "$F/src/in.sh"; printf 'echo out\n' > "$F/src/out.sh"
gcommit "$F" base
printf 'echo in2\n' > "$F/src/in.sh"; printf 'echo out2\n' > "$F/src/out.sh"
out=$(run_check review_r4 "$F"); has "$out" CONCERN r4-scope-discipline && ok "T2 R4 fires CONCERN on an out-of-scope file" || bad "T2 R4" "no CONCERN; got: $out"
# the in-scope file must NOT be flagged.
ofs=$(printf '%s\n' "$out" | grep 'src/out.sh' | wc -l | tr -d ' '); ins=$(printf '%s\n' "$out" | grep 'src/in.sh' | grep -c . || true)
assert_eq "T2 R4 flags only the out-of-scope file (in-scope src/in.sh clean)" 0 "$ins"
# silent twin — revert the out-of-scope file; only in-scope changed.
git -C "$F" checkout -- src/out.sh >/dev/null 2>&1
out=$(run_check review_r4 "$F"); n=$(cnt "$out" CONCERN r4-scope-discipline); assert_eq "T2 R4 silent when only in-scope changes" 0 "$n"
echo ""

# ===========================================================================
# TIER 3 — AGGREGATE: verify-review tally + STATUS extras + agent findings + NOTE-exclusion.
# ===========================================================================
echo "-- tier 3: AGGREGATE (verify-review) --"
AP="$WORK/agg"; gitfix "$AP"; mkdir -p "$AP/scripts" "$AP/.claude/reviewer/findings"
printf '#!/usr/bin/env bash\nlegacy() { echo hi; }\nlegacy\n' > "$AP/scripts/a.sh"
printf '#!/usr/bin/env bash\nlegacy\n'                         > "$AP/scripts/b.sh"
gcommit "$AP" base
printf '#!/usr/bin/env bash\necho hi\n' > "$AP/scripts/a.sh"   # R1 BLOCKING (b.sh calls legacy)
# agent file: 1 BLOCKING + 1 CONCERN + 1 NOTE + a malformed line (must be dropped).
printf 'BLOCKING\tcrit-invariant\tx.sh:1\tinvariant broken\nCONCERN\tscout-x\ty.sh:2\tlook here\nNOTE\tscout-n\tz\tjust a note\nthis is not a finding line\n' > "$AP/.claude/reviewer/findings/agent.tsv"
CLAUDE_PROJECT_DIR="$AP" bash "$VERIFY_REVIEW" >/dev/null 2>&1 || true
gb=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read reviewer blocking' 2>/dev/null || true)
gc=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read reviewer concern'  2>/dev/null || true)
gs=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read reviewer state'    2>/dev/null || true)
assert_eq "T3 blocking = R1 + agent BLOCKING folded into STATUS" 2 "$gb"
assert_eq "T3 concern = agent CONCERN folded into STATUS"        1 "$gc"
assert_eq "T3 state=failed when blocking>0"                 failed "$gs"
[ -f "$AP/.claude/reviewer/REVIEW.md" ] && ok "T3 REVIEW.md written" || bad "T3 REVIEW.md" "missing"
grep -q "broken caller" "$AP/.claude/reviewer/REVIEW.md" 2>/dev/null && ok "T3 REVIEW.md lists the deterministic BLOCKING" || bad "T3 REVIEW.md blocking" "missing"
grep -q "invariant broken" "$AP/.claude/reviewer/REVIEW.md" 2>/dev/null && ok "T3 REVIEW.md lists the agent BLOCKING" || bad "T3 REVIEW.md agent blocking" "missing"
# NOTE present in the report but EXCLUDED from the blocking tally (still 2, not 3).
grep -q "just a note" "$AP/.claude/reviewer/REVIEW.md" 2>/dev/null && ok "T3 NOTE present in REVIEW.md" || bad "T3 NOTE in report" "missing"
# clean: revert the diff + drop only a NOTE -> state done, blocking 0.
git -C "$AP" checkout -- scripts/a.sh >/dev/null 2>&1
printf 'NOTE\tscout-n\tz\tjust a note\n' > "$AP/.claude/reviewer/findings/agent.tsv"
CLAUDE_PROJECT_DIR="$AP" bash "$VERIFY_REVIEW" >/dev/null 2>&1 || true
gs=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read reviewer state'    2>/dev/null || true)
gb=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read reviewer blocking' 2>/dev/null || true)
assert_eq "T3 state=done when 0 blocking" done "$gs"
assert_eq "T3 blocking=0 when only a NOTE" 0  "$gb"
echo ""

# ===========================================================================
# TIER 4 — CROSS-MODULE: the release gate enforces reviewer 0-blocking (and auditor still works).
# ===========================================================================
echo "-- tier 4: CROSS-MODULE (verify-release reads reviewer blocking) --"
gitfix "$WORK/g4"; G4="$WORK/g4"
git -C "$G4" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init >/dev/null 2>&1 || true
G4HEAD=$(git -C "$G4" rev-parse HEAD 2>/dev/null || printf 'x')
relready() {  # <dir> : a release-ready fixture (fresh mem, builder done, changelog) — only the
              # module STATUS we set below should ever fail the gate.
  mkdir -p "$1/.claude/explorer" "$1/.claude/builder"
  { printf 'explored_commit: %s\n' "$G4HEAD"; printf 'coverage: 80%%\n'; } > "$1/.claude/explorer/MEMORY.md"
  printf '# c\n' > "$1/.claude/builder/CHANGELOG.md"
  # Stamp builder tree= (F-A2): the release gate's tree_stale is now FAIL-CLOSED, so a builder STATUS
  # with no recorded tree reads STALE and would wrongly block the PASS fixtures below.
  CLAUDE_PROJECT_DIR="$1" bash -c '. "$LIB"; bd_status_write builder qa done "" tree="$(bd_tree_digest)"' >/dev/null 2>&1 || true
}
# (a) reviewer blocking=1 -> gate BLOCKS (exit 2), reason mentions reviewer.
PA="$G4/relblock"; relready "$PA"
CLAUDE_PROJECT_DIR="$PA" bash -c '. "$LIB"; bd_status_write reviewer review failed "" blocking=1 concern=0' >/dev/null 2>&1 || true
rc=0; CLAUDE_PROJECT_DIR="$PA" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" >/dev/null 2>&1 || rc=$?
assert_eq "T4 release BLOCKS (exit 2) with reviewer blocking=1 under enforce" 2 "$rc"
grep -qi "reviewer:.*BLOCKING" "$PA/.claude/pipeline/RELEASE.md" 2>/dev/null && ok "T4 RELEASE.md reason mentions reviewer BLOCKING" || bad "T4 reviewer reason" "missing"
# (b) reviewer blocking=0 -> that check PASSES (gate exit 0).
PB="$G4/relpass"; relready "$PB"
CLAUDE_PROJECT_DIR="$PB" bash -c '. "$LIB"; bd_status_write reviewer review done "" blocking=0 concern=2 tree="$(bd_tree_digest)"' >/dev/null 2>&1 || true   # tree-stamped (F-A2): reviewer must be a fresh PASS
rc=0; CLAUDE_PROJECT_DIR="$PB" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" >/dev/null 2>&1 || rc=$?
assert_eq "T4 release PASSES (exit 0) with reviewer blocking=0 under enforce" 0 "$rc"
grep -qi "reviewer .*0 blocking" "$PB/.claude/pipeline/RELEASE.md" 2>/dev/null && ok "T4 RELEASE.md shows reviewer 0-blocking PASS" || bad "T4 reviewer pass row" "missing"
# (c) reviewer state=failed (blocking=0) -> gate BLOCKS.
PCF="$G4/relstate"; relready "$PCF"
CLAUDE_PROJECT_DIR="$PCF" bash -c '. "$LIB"; bd_status_write reviewer review failed "" blocking=0 concern=0' >/dev/null 2>&1 || true
rc=0; CLAUDE_PROJECT_DIR="$PCF" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" >/dev/null 2>&1 || rc=$?
assert_eq "T4 release BLOCKS (exit 2) with reviewer state=failed" 2 "$rc"
# (d) NO regression: the existing auditor check still blocks on high=2 (reviewer clean).
PD="$G4/relaud"; relready "$PD"
CLAUDE_PROJECT_DIR="$PD" bash -c '. "$LIB"; bd_status_write reviewer review done "" blocking=0 concern=0 tree="$(bd_tree_digest)"' >/dev/null 2>&1 || true   # reviewer clean+fresh (F-A2)
CLAUDE_PROJECT_DIR="$PD" bash -c '. "$LIB"; bd_status_write auditor audit failed "" high=2 med=0 low=0' >/dev/null 2>&1 || true
rc=0; CLAUDE_PROJECT_DIR="$PD" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" >/dev/null 2>&1 || rc=$?
assert_eq "T4 auditor high=2 STILL blocks alongside the reviewer check (no Phase-2 regression)" 2 "$rc"
grep -q "2 HIGH" "$PD/.claude/pipeline/RELEASE.md" 2>/dev/null && ok "T4 RELEASE.md still cites auditor 2 HIGH" || bad "T4 auditor reason" "missing"
echo ""

# ===========================================================================
# TIER 5 — PORTABILITY: python {real|stub|none}. The checks use ZERO python, so they are stable;
# verify-review's only python touch is bd_status_write, which falls back to the pure-shell writer.
# ===========================================================================
echo "-- tier 5: PORTABILITY (python real/stub/none) --"
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
for n in python3 python py; do printf '#!/bin/sh\nexit 49\n' > "$FAKEBIN/$n"; chmod +x "$FAKEBIN/$n"; done
# R1 fires identically with real python on PATH AND with the stub shadowing it.
FP="$WORK/port"; gitfix "$FP"; mkdir -p "$FP/scripts"
printf '#!/usr/bin/env bash\nlegacy() { echo hi; }\nlegacy\n' > "$FP/scripts/a.sh"
printf '#!/usr/bin/env bash\nlegacy\n'                         > "$FP/scripts/b.sh"
gcommit "$FP" base
printf '#!/usr/bin/env bash\necho hi\n' > "$FP/scripts/a.sh"
o_real=$(run_check review_r1 "$FP")
o_stub=$(REVIEW_ROOT="$FP" PATH="$FAKEBIN:$PATH" bash -c '. "$LIB"; . "$CHECKS"; review_r1' 2>/dev/null || true)
if has "$o_real" BLOCKING r1-caller-integrity && has "$o_stub" BLOCKING r1-caller-integrity; then ok "T5 R1 fires under real AND stub python (no python dependency)"; else bad "T5 R1 portability" "real=[$o_real] stub=[$o_stub]"; fi
# verify-review never crashes and never fails open under the stub: exits 0 (advisory) + records blocking.
rc=0; CLAUDE_PROJECT_DIR="$FP" PATH="$FAKEBIN:$PATH" bash "$VERIFY_REVIEW" >/dev/null 2>&1 || rc=$?
assert_eq "T5 verify-review exits 0 (advisory) under stub python" 0 "$rc"
gb=$(CLAUDE_PROJECT_DIR="$FP" PATH="$FAKEBIN:$PATH" bash -c '. "$LIB"; bd_status_read reviewer blocking' 2>/dev/null || true)
assert_eq "T5 STATUS blocking recorded by the pure-shell writer under stub python" 1 "$gb"
# enforce + stub + blocking>0 -> exits 2 (does NOT fail open to 0 just because python is broken).
rc=0; CLAUDE_PROJECT_DIR="$FP" PATH="$FAKEBIN:$PATH" REVIEWER_ENFORCE=1 bash "$VERIFY_REVIEW" >/dev/null 2>&1 || rc=$?
assert_eq "T5 verify-review enforce exits 2 under stub python (never fail-open)" 2 "$rc"
echo ""

# ===========================================================================
# TIER 6 — NOTE/advisory: a NOTE emits + lands in REVIEW.md but never gates.
# ===========================================================================
echo "-- tier 6: NOTE (emit, never gate) --"
NF="$WORK/note"; gitfix "$NF"; mkdir -p "$NF/scripts" "$NF/.claude/reviewer/findings"
printf '#!/usr/bin/env bash\nset -uo pipefail\necho hi\n' > "$NF/scripts/a.sh"
gcommit "$NF" base
printf '#!/usr/bin/env bash\nset -uo pipefail\necho changed\n' > "$NF/scripts/a.sh"   # in-spec change: no deterministic finding
printf 'NOTE\tscout-n\ta.sh:1\tconsider documenting this\n' > "$NF/.claude/reviewer/findings/agent.tsv"
rc=0; CLAUDE_PROJECT_DIR="$NF" REVIEWER_ENFORCE=1 bash "$VERIFY_REVIEW" >/dev/null 2>&1 || rc=$?
assert_eq "T6 NOTE-only review exits 0 even under enforce" 0 "$rc"
gb=$(CLAUDE_PROJECT_DIR="$NF" bash -c '. "$LIB"; bd_status_read reviewer blocking' 2>/dev/null || true)
gs=$(CLAUDE_PROJECT_DIR="$NF" bash -c '. "$LIB"; bd_status_read reviewer state'    2>/dev/null || true)
assert_eq "T6 NOTE excluded from blocking tally" 0 "$gb"
assert_eq "T6 state=done with only a NOTE"    done "$gs"
grep -q "consider documenting" "$NF/.claude/reviewer/REVIEW.md" 2>/dev/null && ok "T6 NOTE still emitted to REVIEW.md" || bad "T6 NOTE emit" "missing"
echo ""

# ===========================================================================
# TIER 7 — MUTATION SENTINELS: prove the load-bearing lines are load-bearing.
# ===========================================================================
echo "-- tier 7: MUTATION SENTINELS --"
# (a) Neuter R1's caller-grep emit line -> the emit becomes a no-op (`:`), so a broken-caller
#     fixture PASSES the mutant. (If R1 still fired with the emit gone, the emit wasn't load-bearing.)
MUT="$WORK/mut-checks.sh"
sed 's#_review_emit BLOCKING r1-caller-integrity#:#' "$CHECKS" > "$MUT"
MF="$WORK/mut1"; gitfix "$MF"; mkdir -p "$MF/scripts"
printf '#!/usr/bin/env bash\nlegacy() { echo hi; }\nlegacy\n' > "$MF/scripts/a.sh"
printf '#!/usr/bin/env bash\nlegacy\n'                         > "$MF/scripts/b.sh"
gcommit "$MF" base
printf '#!/usr/bin/env bash\necho hi\n' > "$MF/scripts/a.sh"
realR1=$(run_check review_r1 "$MF")
mutR1=$(REVIEW_ROOT="$MF" MUT="$MUT" bash -c '. "$LIB"; . "$MUT"; review_r1' 2>/dev/null || true)
if has "$realR1" BLOCKING r1-caller-integrity && ! has "$mutR1" BLOCKING r1-caller-integrity; then ok "T7 R1 sentinel: real fires, mutant silent -> caller-grep emit load-bearing"; else bad "T7 R1 sentinel" "real=[$realR1] mut=[$mutR1]"; fi

# (b) Neuter verify-release's NEW reviewer fail path (record FAIL 1 -> PASS 0) -> a reviewer
#     blocking>0 fixture (the ONLY failing check) PASSES the mutant.
MUTREL_DIR="$WORK/mutrel"; mkdir -p "$MUTREL_DIR/scripts" "$MUTREL_DIR/lib"
cp "$LIB" "$MUTREL_DIR/lib/common.sh"
sed 's#record "reviewer" FAIL 1#record "reviewer" PASS 0#g' "$VERIFY_RELEASE" > "$MUTREL_DIR/scripts/verify-release.sh"
MR="$G4/relmut"; relready "$MR"
CLAUDE_PROJECT_DIR="$MR" bash -c '. "$LIB"; bd_status_write reviewer review failed "" blocking=1 concern=0' >/dev/null 2>&1 || true
real_rc=0; CLAUDE_PROJECT_DIR="$MR" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE"                       >/dev/null 2>&1 || real_rc=$?
mut_rc=0;  CLAUDE_PROJECT_DIR="$MR" PIPELINE_ENFORCE=1 bash "$MUTREL_DIR/scripts/verify-release.sh" >/dev/null 2>&1 || mut_rc=$?
if [ "$real_rc" = 2 ] && [ "$mut_rc" = 0 ]; then ok "T7 verify-release sentinel: real BLOCKS(2), mutant PASSES(0) -> reviewer fail-path load-bearing"; else bad "T7 verify-release sentinel" "real=$real_rc(want 2) mut=$mut_rc(want 0)"; fi
echo ""

echo "== reviewer ladder summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
