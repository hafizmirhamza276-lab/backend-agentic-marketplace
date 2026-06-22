#!/usr/bin/env sh
# ops-ladder.sh — production test ladder for the `ops` plugin. POSIX sh, `set -eu`, isolated
# mktemp fixtures. Each check carries a FIRE control (a crafted bad fixture -> the right
# SEVERITY/slug) AND a SILENT twin (a clean variant -> nothing), so a broken check FAILS the suite
# (it is never vacuous). Mutation sentinels prove the load-bearing lines are load-bearing.
#
# O1/O2 read files (a ledger, the manifests) and need NO git, so tiers 1-3, 5, 6 and sentinel (a)
# run unconditionally; only the cross-module gate fixtures (tier 4) and sentinel (b) need a git
# work tree and are guarded.
#
# Tiers:
#   1. SILENT — O1, O2 silent on a clean fixture (green ledger, matching versions).
#   2. FIRE — O1 BLOCKING on a RED ledger + CONCERN on an absent ledger + silent on all-green;
#      O2 CONCERN on a version mismatch + silent when versions match.
#   3. AGGREGATE — verify-ops folds agent BLOCKING/CONCERN into STATUS, EXCLUDES NOTE from the
#      blocking tally, writes OPS.md (listing the blocking), state=failed when blocking>0 else done.
#   4. CROSS-MODULE — release-ready fixture: ops blocking=1 -> verify-release enforce FAILS (exit 2,
#      reason mentions ops); blocking=0 -> PASSES; AND auditor high=2 + reviewer blocking=1 STILL
#      block alongside (all three gates coexist; no Phase-2/3 regression).
#   5. PORTABILITY — verify-ops under python {real|stub|none}: checks + tally stable; never crash,
#      never fail-open (enforce + red ledger -> exit 2 under stub). (stub ≡ none: both yield
#      BD_PYTHON="" -> the python-free path.)
#   6. NOTE/advisory — a NOTE-only finding emits + lands in OPS.md but never gates (exit 0 even
#      under enforce; excluded from the blocking tally).
#   7. MUTATION SENTINEL — neuter O1's RED-detection emit -> a red-ledger fixture PASSES the mutant
#      (O1 emit load-bearing); neuter verify-release's NEW ops fail/exit-2 path -> an ops-blocking>0
#      fixture PASSES the mutant (the ops gate wiring is load-bearing).
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
export ROOT
LIB="$ROOT/shared/lib/common.sh";                         export LIB
CHECKS="$ROOT/plugins/ops/scripts/lib-ops-checks.sh";     export CHECKS
VERIFY_OPS="$ROOT/plugins/ops/scripts/verify-ops.sh"
VERIFY_RELEASE="$ROOT/plugins/pipeline/scripts/verify-release.sh"
TAB=$(printf '\t')

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s  --  %s\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
skipnote()  { printf 'SKIP  %s\n' "$1"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT INT TERM

# Run ONE check function against a fixture root; print its findings (stdout only).
run_check() { OPS_ROOT="$2" bash -c '. "$LIB"; . "$CHECKS"; '"$1" 2>/dev/null || true; }
# Match / count finding lines "<SEV>\t<slug-prefix>".
has() { printf '%s\n' "$1" | grep -q "^$2$TAB$3" 2>/dev/null; }
cnt() { printf '%s\n' "$1" | grep -c "^$2$TAB$3" 2>/dev/null || true; }

# --- fixture helpers ---------------------------------------------------------
# Write .claude/ops/results.txt from a content string (already containing real tabs + newlines).
put_ledger() { mkdir -p "$1/.claude/ops"; printf '%s\n' "$2" > "$1/.claude/ops/results.txt"; }
# A marketplace.json (one plugin entry) + that plugin's plugin.json, with given versions. The
# top-level marketplace "version" is deliberately a DIFFERENT value (9.9.9) to prove the parser
# never mistakes it for an entry's version.  <root> <entry-version> <plugin.json-version>
mk_manifest() {
  mkdir -p "$1/.claude-plugin" "$1/plugins/foo/.claude-plugin"
  {
    printf '{\n  "name": "fix",\n  "version": "9.9.9",\n  "plugins": [\n'
    printf '    {\n      "name": "foo",\n      "source": "./plugins/foo",\n      "version": "%s",\n      "author": { "name": "t" }\n    }\n' "$2"
    printf '  ]\n}\n'
  } > "$1/.claude-plugin/marketplace.json"
  printf '{\n  "name": "foo",\n  "version": "%s"\n}\n' "$3" > "$1/plugins/foo/.claude-plugin/plugin.json"
}
# Deterministic git fixture (autocrlf/fileMode off — throwaway repos).
gitfix() {
  mkdir -p "$1"
  git -C "$1" init -q >/dev/null 2>&1
  git -C "$1" config core.autocrlf false
  git -C "$1" config core.fileMode false
  git -C "$1" config user.email t@e
  git -C "$1" config user.name t
}

echo "== ops test ladder =="
echo "ROOT=$ROOT"
HAVE_GIT=no; command -v git >/dev/null 2>&1 && HAVE_GIT=yes
HOSTPY=no; for c in python3 python "py -3"; do if $c -c "pass" >/dev/null 2>&1; then HOSTPY=yes; break; fi; done
echo "git: $HAVE_GIT | host working python: $HOSTPY"
echo ""

# ===========================================================================
# TIER 1 — SILENT on a clean fixture: a green ledger + matching versions -> no findings.
# ===========================================================================
echo "-- tier 1: SILENT (clean fixture) --"
F="$WORK/t1"
put_ledger "$F" "$(printf 'build\tgreen\tmake build\ntest\tgreen\tmake test')"
mk_manifest "$F" 0.1.0 0.1.0
for fn in ops_o1 ops_o2; do
  out=$(run_check "$fn" "$F")
  n=$(printf '%s\n' "$out" | grep -cE "^(BLOCKING|CONCERN|NOTE)$TAB" 2>/dev/null || true)
  assert_eq "T1 $fn silent on clean fixture (0 findings)" 0 "$n"
done
echo ""

# ===========================================================================
# TIER 2 — FIRE: per-check positive controls + silent twins.
# ===========================================================================
echo "-- tier 2: FIRE (per-check) --"

# O1 (BLOCKING) — a RED ledger (one red row among greens).
F="$WORK/o1red"; put_ledger "$F" "$(printf 'build\tgreen\tmake\ntest\tred\tmake test')"
out=$(run_check ops_o1 "$F"); has "$out" BLOCKING o1-test-ledger && ok "T2 O1 fires BLOCKING on a RED ledger" || bad "T2 O1 red" "no BLOCKING; got: $out"
# O1 (CONCERN) — an absent ledger (do NOT hard-block on absence).
F="$WORK/o1absent"; mkdir -p "$F"
out=$(run_check ops_o1 "$F"); has "$out" CONCERN o1-test-ledger && ok "T2 O1 fires CONCERN on an absent ledger" || bad "T2 O1 absent" "no CONCERN; got: $out"
# O1 silent — every recorded result green ('passed' normalizes to green).
F="$WORK/o1green"; put_ledger "$F" "$(printf 'build\tgreen\tmake\ntest\tpassed\tmake test')"
out=$(run_check ops_o1 "$F")
nb=$(cnt "$out" BLOCKING o1-test-ledger); nc=$(cnt "$out" CONCERN o1-test-ledger)
assert_eq "T2 O1 silent (no BLOCKING) on an all-green ledger" 0 "$nb"
assert_eq "T2 O1 silent (no CONCERN) on an all-green ledger"  0 "$nc"

# O2 (CONCERN) — marketplace entry version != plugin.json version.
F="$WORK/o2bad"; mk_manifest "$F" 0.1.0 0.2.0
out=$(run_check ops_o2 "$F"); has "$out" CONCERN o2-version-consistency && ok "T2 O2 fires CONCERN on a version mismatch" || bad "T2 O2 mismatch" "no CONCERN; got: $out"
# O2 silent — versions match.
F="$WORK/o2ok"; mk_manifest "$F" 0.1.0 0.1.0
out=$(run_check ops_o2 "$F"); n=$(cnt "$out" CONCERN o2-version-consistency); assert_eq "T2 O2 silent when versions match" 0 "$n"
echo ""

# ===========================================================================
# TIER 3 — AGGREGATE: verify-ops tally + STATUS extras + agent findings + NOTE-exclusion.
# ===========================================================================
echo "-- tier 3: AGGREGATE (verify-ops) --"
AP="$WORK/agg"; mkdir -p "$AP/.claude/ops/findings"
put_ledger "$AP" "$(printf 'build\tgreen\tmake\ntest\tred\tmake test')"   # O1 BLOCKING=1 (no manifest -> O2 silent)
# agent file: 1 BLOCKING + 1 CONCERN + 1 NOTE + a malformed line (must be dropped).
printf 'BLOCKING\tcrit-x\tx:1\tagent blocker\nCONCERN\tscout-ci\ty\tno ci pipeline\nNOTE\tscout-n\tz\tjust a note\nthis is not a finding line\n' > "$AP/.claude/ops/findings/agent.tsv"
CLAUDE_PROJECT_DIR="$AP" bash "$VERIFY_OPS" >/dev/null 2>&1 || true
gb=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read ops blocking' 2>/dev/null || true)
gc=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read ops concern'  2>/dev/null || true)
gs=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read ops state'    2>/dev/null || true)
assert_eq "T3 blocking = O1 + agent BLOCKING folded into STATUS" 2 "$gb"
assert_eq "T3 concern = agent CONCERN folded into STATUS"        1 "$gc"
assert_eq "T3 state=failed when blocking>0"                 failed "$gs"
[ -f "$AP/.claude/ops/OPS.md" ] && ok "T3 OPS.md written" || bad "T3 OPS.md" "missing"
grep -q "is RED" "$AP/.claude/ops/OPS.md" 2>/dev/null && ok "T3 OPS.md lists the deterministic BLOCKING" || bad "T3 OPS.md blocking" "missing"
grep -q "agent blocker" "$AP/.claude/ops/OPS.md" 2>/dev/null && ok "T3 OPS.md lists the agent BLOCKING" || bad "T3 OPS.md agent blocking" "missing"
grep -q "just a note" "$AP/.claude/ops/OPS.md" 2>/dev/null && ok "T3 NOTE present in OPS.md" || bad "T3 NOTE in report" "missing"
# clean: green ledger + only a NOTE agent file -> state done, blocking 0.
put_ledger "$AP" "$(printf 'build\tgreen\tmake\ntest\tgreen\tmake test')"
printf 'NOTE\tscout-n\tz\tjust a note\n' > "$AP/.claude/ops/findings/agent.tsv"
CLAUDE_PROJECT_DIR="$AP" bash "$VERIFY_OPS" >/dev/null 2>&1 || true
gs=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read ops state'    2>/dev/null || true)
gb=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read ops blocking' 2>/dev/null || true)
assert_eq "T3 state=done when 0 blocking" done "$gs"
assert_eq "T3 blocking=0 when only a NOTE" 0  "$gb"
echo ""

# ===========================================================================
# TIER 4 — CROSS-MODULE: the release gate enforces ops 0-blocking, and all three module gates
# (ops + reviewer + auditor) coexist. Needs a git work tree for the freshness check.
# ===========================================================================
echo "-- tier 4: CROSS-MODULE (verify-release reads ops blocking) --"
if [ "$HAVE_GIT" = yes ]; then
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
  # (a) ops blocking=1 -> gate BLOCKS (exit 2), reason mentions ops.
  PA="$G4/relblock"; relready "$PA"
  CLAUDE_PROJECT_DIR="$PA" bash -c '. "$LIB"; bd_status_write ops readiness failed "" blocking=1 concern=0' >/dev/null 2>&1 || true
  rc=0; CLAUDE_PROJECT_DIR="$PA" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" >/dev/null 2>&1 || rc=$?
  assert_eq "T4 release BLOCKS (exit 2) with ops blocking=1 under enforce" 2 "$rc"
  grep -qi "ops:.*BLOCKING" "$PA/.claude/pipeline/RELEASE.md" 2>/dev/null && ok "T4 RELEASE.md reason mentions ops BLOCKING" || bad "T4 ops reason" "missing"
  # (b) ops blocking=0 -> that check PASSES (gate exit 0; reviewer/auditor absent -> SKIP).
  PB="$G4/relpass"; relready "$PB"
  CLAUDE_PROJECT_DIR="$PB" bash -c '. "$LIB"; bd_status_write ops readiness done "" blocking=0 concern=2 tree="$(bd_tree_digest)"' >/dev/null 2>&1 || true   # tree-stamped (F-A2): ops must be a fresh PASS
  rc=0; CLAUDE_PROJECT_DIR="$PB" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" >/dev/null 2>&1 || rc=$?
  assert_eq "T4 release PASSES (exit 0) with ops blocking=0 under enforce" 0 "$rc"
  grep -qi "ops .*0 blocking" "$PB/.claude/pipeline/RELEASE.md" 2>/dev/null && ok "T4 RELEASE.md shows ops 0-blocking PASS" || bad "T4 ops pass row" "missing"
  # (c) ops state=failed (blocking=0) -> gate BLOCKS.
  PCF="$G4/relstate"; relready "$PCF"
  CLAUDE_PROJECT_DIR="$PCF" bash -c '. "$LIB"; bd_status_write ops readiness failed "" blocking=0 concern=0' >/dev/null 2>&1 || true
  rc=0; CLAUDE_PROJECT_DIR="$PCF" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" >/dev/null 2>&1 || rc=$?
  assert_eq "T4 release BLOCKS (exit 2) with ops state=failed" 2 "$rc"
  # (d) ALL THREE coexist: ops clean + auditor high=2 + reviewer blocking=1 -> BLOCKS; cite each.
  PD="$G4/reltrio"; relready "$PD"
  CLAUDE_PROJECT_DIR="$PD" bash -c '. "$LIB"; bd_status_write ops readiness done "" blocking=0 concern=0 tree="$(bd_tree_digest)"' >/dev/null 2>&1 || true   # ops clean+fresh (F-A2)
  CLAUDE_PROJECT_DIR="$PD" bash -c '. "$LIB"; bd_status_write reviewer review failed "" blocking=1 concern=0'    >/dev/null 2>&1 || true
  CLAUDE_PROJECT_DIR="$PD" bash -c '. "$LIB"; bd_status_write auditor audit failed "" high=2 med=0 low=0'        >/dev/null 2>&1 || true
  rc=0; CLAUDE_PROJECT_DIR="$PD" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" >/dev/null 2>&1 || rc=$?
  assert_eq "T4 auditor high=2 AND reviewer blocking=1 STILL block alongside ops (all three coexist)" 2 "$rc"
  grep -q "2 HIGH" "$PD/.claude/pipeline/RELEASE.md" 2>/dev/null && ok "T4 RELEASE.md still cites auditor 2 HIGH" || bad "T4 auditor reason" "missing"
  grep -qi "reviewer:.*BLOCKING" "$PD/.claude/pipeline/RELEASE.md" 2>/dev/null && ok "T4 RELEASE.md still cites reviewer BLOCKING" || bad "T4 reviewer reason" "missing"
  grep -qi "ops .*0 blocking" "$PD/.claude/pipeline/RELEASE.md" 2>/dev/null && ok "T4 RELEASE.md shows ops 0-blocking PASS alongside" || bad "T4 ops pass alongside" "missing"
else
  skipnote "T4 CROSS-MODULE (git unavailable)"
fi
echo ""

# ===========================================================================
# TIER 5 — PORTABILITY: python {real|stub|none}. O1/O2 use ZERO python, so they are stable;
# verify-ops's only python touch is bd_status_write, which falls back to the pure-shell writer.
# ===========================================================================
echo "-- tier 5: PORTABILITY (python real/stub/none) --"
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
for n in python3 python py; do printf '#!/bin/sh\nexit 49\n' > "$FAKEBIN/$n"; chmod +x "$FAKEBIN/$n"; done
# O1 fires identically with real python on PATH AND with the stub shadowing it (no python dependency).
FP="$WORK/port"; put_ledger "$FP" "$(printf 'test\tred\tmake test')"
o_real=$(run_check ops_o1 "$FP")
o_stub=$(OPS_ROOT="$FP" PATH="$FAKEBIN:$PATH" bash -c '. "$LIB"; . "$CHECKS"; ops_o1' 2>/dev/null || true)
if has "$o_real" BLOCKING o1-test-ledger && has "$o_stub" BLOCKING o1-test-ledger; then ok "T5 O1 fires under real AND stub python (no python dependency)"; else bad "T5 O1 portability" "real=[$o_real] stub=[$o_stub]"; fi
# verify-ops never crashes and never fails open under the stub: exits 0 (advisory) + records blocking.
rc=0; CLAUDE_PROJECT_DIR="$FP" PATH="$FAKEBIN:$PATH" bash "$VERIFY_OPS" >/dev/null 2>&1 || rc=$?
assert_eq "T5 verify-ops exits 0 (advisory) under stub python" 0 "$rc"
gb=$(CLAUDE_PROJECT_DIR="$FP" PATH="$FAKEBIN:$PATH" bash -c '. "$LIB"; bd_status_read ops blocking' 2>/dev/null || true)
assert_eq "T5 STATUS blocking recorded by the pure-shell writer under stub python" 1 "$gb"
# enforce + stub + blocking>0 -> exits 2 (does NOT fail open to 0 just because python is broken).
rc=0; CLAUDE_PROJECT_DIR="$FP" PATH="$FAKEBIN:$PATH" OPS_ENFORCE=1 bash "$VERIFY_OPS" >/dev/null 2>&1 || rc=$?
assert_eq "T5 verify-ops enforce exits 2 under stub python (never fail-open)" 2 "$rc"
echo ""

# ===========================================================================
# TIER 6 — NOTE/advisory: a NOTE emits + lands in OPS.md but never gates.
# ===========================================================================
echo "-- tier 6: NOTE (emit, never gate) --"
NF="$WORK/note"; mkdir -p "$NF/.claude/ops/findings"
put_ledger "$NF" "$(printf 'build\tgreen\tmake\ntest\tgreen\tmake test')"   # green -> O1 silent
printf 'NOTE\tscout-n\tconfig.yml:1\tconsider adding a readiness probe\n' > "$NF/.claude/ops/findings/agent.tsv"
rc=0; CLAUDE_PROJECT_DIR="$NF" OPS_ENFORCE=1 bash "$VERIFY_OPS" >/dev/null 2>&1 || rc=$?
assert_eq "T6 NOTE-only readiness exits 0 even under enforce" 0 "$rc"
gb=$(CLAUDE_PROJECT_DIR="$NF" bash -c '. "$LIB"; bd_status_read ops blocking' 2>/dev/null || true)
gs=$(CLAUDE_PROJECT_DIR="$NF" bash -c '. "$LIB"; bd_status_read ops state'    2>/dev/null || true)
assert_eq "T6 NOTE excluded from blocking tally" 0 "$gb"
assert_eq "T6 state=done with only a NOTE"    done "$gs"
grep -q "readiness probe" "$NF/.claude/ops/OPS.md" 2>/dev/null && ok "T6 NOTE still emitted to OPS.md" || bad "T6 NOTE emit" "missing"
echo ""

# ===========================================================================
# TIER 7 — MUTATION SENTINELS: prove the load-bearing lines are load-bearing.
# ===========================================================================
echo "-- tier 7: MUTATION SENTINELS --"
# (a) Neuter O1's RED-detection emit line -> the emit becomes a no-op (`:`), so a red-ledger fixture
#     PASSES the mutant. (If O1 still fired with the emit gone, the emit wasn't load-bearing.)
MUT="$WORK/mut-checks.sh"
sed 's#_ops_emit BLOCKING o1-test-ledger#:#' "$CHECKS" > "$MUT"
MF="$WORK/mut1"; put_ledger "$MF" "$(printf 'test\tred\tmake test')"
realO1=$(run_check ops_o1 "$MF")
mutO1=$(OPS_ROOT="$MF" MUT="$MUT" bash -c '. "$LIB"; . "$MUT"; ops_o1' 2>/dev/null || true)
if has "$realO1" BLOCKING o1-test-ledger && ! has "$mutO1" BLOCKING o1-test-ledger; then ok "T7 O1 sentinel: real fires, mutant silent -> RED-emit load-bearing"; else bad "T7 O1 sentinel" "real=[$realO1] mut=[$mutO1]"; fi

# (b) Neuter verify-release's NEW ops fail path (record FAIL 1 -> PASS 0) -> an ops blocking>0
#     fixture (the ONLY failing check) PASSES the mutant. Needs git (release-ready fixture).
if [ "$HAVE_GIT" = yes ]; then
  MUTREL_DIR="$WORK/mutrel"; mkdir -p "$MUTREL_DIR/scripts" "$MUTREL_DIR/lib"
  cp "$LIB" "$MUTREL_DIR/lib/common.sh"
  sed 's#record "ops" FAIL 1#record "ops" PASS 0#g' "$VERIFY_RELEASE" > "$MUTREL_DIR/scripts/verify-release.sh"
  MR="$G4/relmut"; relready "$MR"
  CLAUDE_PROJECT_DIR="$MR" bash -c '. "$LIB"; bd_status_write ops readiness failed "" blocking=1 concern=0' >/dev/null 2>&1 || true
  real_rc=0; CLAUDE_PROJECT_DIR="$MR" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE"                       >/dev/null 2>&1 || real_rc=$?
  mut_rc=0;  CLAUDE_PROJECT_DIR="$MR" PIPELINE_ENFORCE=1 bash "$MUTREL_DIR/scripts/verify-release.sh" >/dev/null 2>&1 || mut_rc=$?
  if [ "$real_rc" = 2 ] && [ "$mut_rc" = 0 ]; then ok "T7 verify-release sentinel: real BLOCKS(2), mutant PASSES(0) -> ops fail-path load-bearing"; else bad "T7 verify-release sentinel" "real=$real_rc(want 2) mut=$mut_rc(want 0)"; fi
else
  skipnote "T7 verify-release sentinel (git unavailable)"
fi
echo ""

# ===========================================================================
# TIER 8 — REGRESSION: ops_o2 must be robust to JSON RE-FORMATTING (external review). Key order /
# whitespace is insignificant, so a reformatter (prettier / jq / `python -m json.tool`) can split a
# plugin's nested `"author": { "name": … }` onto its own indented line; a naive line-start "name"
# anchor then reads the AUTHOR name as a plugin and — when the author block precedes "version" — LOSES
# the real version (flushed empty, mis-attributed to the author). The fix tracks object-nesting depth
# and captures plugin fields only at nest==0. All cases use ZERO python (pure awk).
#   TF1 (the fix) pretty fixture, author BLOCK before version, real version MISMATCH -> O2 still
#       detects the REAL plugin's mismatch (names 'foo', keeps 0.1.0 vs 0.2.0), never the author name.
#       (Before the fix foo's version was lost -> NO concern.)
#   TF2 (control) the current single-line-author layout, versions match -> O2 silent (no regression).
#   TF3 a real mismatch is detected under BOTH the single-line AND the pretty author-before-version layout.
#   TF4 (sentinel) neuter the nested-object skip (drop the #NEST_SKIP nest++) -> the pretty fixture
#       mis-parses, foo's version is lost, and the CONCERN vanishes -> the nesting skip is load-bearing.
# ===========================================================================
echo "-- tier 8: REGRESSION ops_o2 reformat-robust (nested author skip) --"
# mk_manifest_pretty <root> <entry-version> <plugin.json-version> : like mk_manifest but PRETTY-PRINTED
# with the nested author object SPLIT across indented lines and placed BEFORE "version" (the layout a
# reformatter can produce). A literal {brace} in the description proves brace-in-string safety. The
# top-level marketplace "version" (9.9.9) again differs, proving it is never mistaken for an entry.
mk_manifest_pretty() {
  mkdir -p "$1/.claude-plugin" "$1/plugins/foo/.claude-plugin"
  {
    printf '{\n  "name": "fix",\n  "version": "9.9.9",\n  "plugins": [\n'
    printf '    {\n'
    printf '      "name": "foo",\n'
    printf '      "source": "./plugins/foo",\n'
    printf '      "description": "desc with a literal {brace} in prose",\n'
    printf '      "author": {\n'
    printf '        "name": "ACME-Author",\n'
    printf '        "url": "https://example.test"\n'
    printf '      },\n'
    printf '      "version": "%s",\n' "$2"
    printf '      "category": "x"\n'
    printf '    }\n'
    printf '  ]\n}\n'
  } > "$1/.claude-plugin/marketplace.json"
  printf '{\n  "name": "foo",\n  "version": "%s"\n}\n' "$3" > "$1/plugins/foo/.claude-plugin/plugin.json"
}

# TF1 — pretty author-before-version + real mismatch -> O2 detects the REAL plugin, never the author.
F="$WORK/tf1"; mk_manifest_pretty "$F" 0.1.0 0.2.0
out=$(run_check ops_o2 "$F")
has "$out" CONCERN o2-version-consistency && ok "TF1 pretty author-before-version: O2 still DETECTS the real mismatch" || bad "TF1 detect" "no CONCERN; got: [$out]"
printf '%s\n' "$out" | grep -q "for plugin 'foo'" && ok "TF1 CONCERN names the REAL plugin 'foo' (not the author)" || bad "TF1 names foo" "got: [$out]"
printf '%s\n' "$out" | grep -q "version '0.1.0' != plugin.json version '0.2.0'" && ok "TF1 real version pair (0.1.0 vs 0.2.0) preserved, not lost" || bad "TF1 version pair" "got: [$out]"
if printf '%s\n' "$out" | grep -q "ACME-Author"; then bad "TF1 author leak" "author name surfaced as a plugin: [$out]"; else ok "TF1 author name 'ACME-Author' is NEVER treated as a plugin"; fi

# TF2 — control: current single-line-author layout, versions match -> O2 silent (exactly as before).
F="$WORK/tf2"; mk_manifest "$F" 0.1.0 0.1.0
out=$(run_check ops_o2 "$F"); n=$(cnt "$out" CONCERN o2-version-consistency)
assert_eq "TF2 control single-line author + matching versions -> O2 silent (no regression)" 0 "$n"

# TF3 — a real mismatch is detected under BOTH layouts.
F="$WORK/tf3a"; mk_manifest "$F" 1.0.0 2.0.0
outA=$(run_check ops_o2 "$F")
has "$outA" CONCERN o2-version-consistency && ok "TF3 mismatch detected under single-line author layout" || bad "TF3 single-line" "got: [$outA]"
F="$WORK/tf3b"; mk_manifest_pretty "$F" 1.0.0 2.0.0
outB=$(run_check ops_o2 "$F")
has "$outB" CONCERN o2-version-consistency && ok "TF3 mismatch detected under pretty author-before-version layout" || bad "TF3 pretty" "got: [$outB]"

# TF4 MUTATION SENTINEL — neuter the nested-object skip (drop `nest++` on the #NEST_SKIP line) so the
# author block no longer raises depth. The pretty fixture then mis-parses: the author "name" is read
# as a plugin, foo is flushed with an EMPTY version, and foo's source collapses into the version slot
# (tab is IFS-whitespace) -> the gate reports a GARBAGE version, NOT the real 0.1.0-vs-0.2.0 pair. The
# REAL parser still reads the correct pair, so the nesting skip is load-bearing (not vacuous).
MUTN="$WORK/mut-nest-checks.sh"
sed '/#NEST_SKIP/ s/nest++; //' "$CHECKS" > "$MUTN"
if ! cmp -s "$CHECKS" "$MUTN"; then ok "TF4 mutant differs from real checks (nest++ removed by sed)"; else bad "TF4 mutant" "sed no-op — sentinel would be vacuous"; fi
F="$WORK/tf4"; mk_manifest_pretty "$F" 0.1.0 0.2.0
real_o2=$(run_check ops_o2 "$F")
mut_o2=$(OPS_ROOT="$F" MUT="$MUTN" bash -c '. "$LIB"; . "$MUT"; ops_o2' 2>/dev/null || true)
CORRECT="version '0.1.0' != plugin.json version '0.2.0'"
real_ok=no; printf '%s\n' "$real_o2" | grep -qF "$CORRECT" && real_ok=yes
mut_ok=no;  printf '%s\n' "$mut_o2"  | grep -qF "$CORRECT" && mut_ok=yes
if [ "$real_ok" = yes ] && [ "$mut_ok" = no ]; then ok "TF4 sentinel: real reads the correct version pair, nest-neutered mutant mis-parses it -> nested-skip load-bearing"; else bad "TF4 sentinel" "real_ok=$real_ok mut_ok=$mut_ok | real=[$real_o2] mut=[$mut_o2]"; fi
echo ""

echo "== ops ladder summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
