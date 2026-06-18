#!/usr/bin/env sh
# audit-ladder.sh — production test ladder for the `auditor` plugin. POSIX sh, `set -eu`,
# isolated mktemp fixtures. Each detector carries a FIRE control (a fixture that triggers it
# -> the right severity/slug) AND a SILENT control (a clean variant -> nothing), so a broken
# detector FAILS the suite (it is never vacuous). Mutation sentinels prove the load-bearing
# lines are load-bearing.
#
# Tiers:
#   1. SILENT — every deterministic detector is silent on the REAL (clean) repo; the auditor's
#      own 3 scripts are ShellCheck-clean. (No false positives -> gate trusts a HIGH.)
#   2. FIRE — per-detector positive control: D1,D2,D6,D7,D8 (HIGH); D3,D4,D5,D6b (MEDIUM);
#      D9 (LOW, via a git fixture). Each fires its slug at its severity.
#   3. AGGREGATE — verify-audit tallies HIGH/MED/LOW, EXCLUDES advisory, writes FINDINGS.md +
#      the STATUS extras (high=/med=/low=), folds in agent findings, drops malformed lines.
#   4. GATE — the bridge: verify-release.sh PASSES with auditor high=0, BLOCKS (exit 2) with
#      high>0 or state=failed. (Exercises the Section-A extras end-to-end.)
#   5. PORTABILITY — detectors + verify-audit behave identically under python {real|stub|none}
#      and never crash (no python dependency).
#   6. ADVISORY — advisory findings emit but are EXCLUDED from the gate tally.
#   7. MUTATION SENTINEL — neuter D2's normalize-check and D8's diff; prove the matching FIRE
#      fixture then PASSES the mutant (the checks are load-bearing).
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
export ROOT
LIB="$ROOT/shared/lib/common.sh";                         export LIB
CHECKS="$ROOT/plugins/auditor/scripts/lib-audit-checks.sh"; export CHECKS
VERIFY_AUDIT="$ROOT/plugins/auditor/scripts/verify-audit.sh"
VERIFY_RELEASE="$ROOT/plugins/pipeline/scripts/verify-release.sh"
TAB=$(printf '\t')

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s  --  %s\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
skipnote()  { printf 'SKIP  %s\n' "$1"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT INT TERM

# Run ONE detector function against a fixture root; print its findings (stdout only).
run_det() { AUDIT_ROOT="$2" bash -c '. "$LIB"; . "$CHECKS"; '"$1" 2>/dev/null || true; }
# Count finding lines matching "<SEV>\t<slug-prefix>".
cnt() { printf '%s\n' "$1" | grep -c "^$2$TAB$3" 2>/dev/null || true; }
has() { printf '%s\n' "$1" | grep -q "^$2$TAB$3" 2>/dev/null; }

# --- fixture helpers ---------------------------------------------------------
# Pretty-printed hooks.json (the parser assumes the project's one-key-per-line style).
# write_pre <plugindir> <matcher> <script> <timeoutline>  -> a PreToolUse hooks.json
write_pre() {  # <plugindir> <matcher> <script> <withto:1|0>
  mkdir -p "$1/hooks"
  {
    printf '{\n  "hooks": {\n    "PreToolUse": [\n      {\n'
    printf '        "matcher": "%s",\n        "hooks": [\n          {\n' "$2"
    printf '            "type": "command",\n'
    if [ "$4" = 1 ]; then
      printf '            "command": "\\"${CLAUDE_PLUGIN_ROOT}\\"/scripts/%s",\n            "timeout": 10\n' "$3"
    else
      printf '            "command": "\\"${CLAUDE_PLUGIN_ROOT}\\"/scripts/%s"\n' "$3"
    fi
    printf '          }\n        ]\n      }\n    ]\n  }\n}\n'
  } > "$1/hooks/hooks.json"
}
write_session() {  # <plugindir> <script> <withto:1|0>
  mkdir -p "$1/hooks"
  {
    printf '{\n  "hooks": {\n    "SessionStart": [\n      {\n        "hooks": [\n          {\n'
    printf '            "type": "command",\n'
    if [ "$3" = 1 ]; then
      printf '            "command": "\\"${CLAUDE_PLUGIN_ROOT}\\"/scripts/%s",\n            "timeout": 10\n' "$2"
    else
      printf '            "command": "\\"${CLAUDE_PLUGIN_ROOT}\\"/scripts/%s"\n' "$2"
    fi
    printf '          }\n        ]\n      }\n    ]\n  }\n}\n'
  } > "$1/hooks/hooks.json"
}

# write_pre_with_bash <plugindir> <writeguard.sh> : a PreToolUse hooks.json with BOTH a
# Write|Edit|MultiEdit|NotebookEdit matcher (the write guard) AND a Bash matcher (guard-bash-write).
write_pre_with_bash() {
  mkdir -p "$1/hooks"
  {
    printf '{\n  "hooks": {\n    "PreToolUse": [\n      {\n'
    printf '        "matcher": "Write|Edit|MultiEdit|NotebookEdit",\n        "hooks": [\n          {\n'
    printf '            "type": "command",\n            "command": "\\"${CLAUDE_PLUGIN_ROOT}\\"/scripts/%s",\n            "timeout": 10\n' "$2"
    printf '          }\n        ]\n      },\n      {\n'
    printf '        "matcher": "Bash",\n        "hooks": [\n          {\n'
    printf '            "type": "command",\n            "command": "\\"${CLAUDE_PLUGIN_ROOT}\\"/scripts/guard-bash-write.sh",\n            "timeout": 10\n'
    printf '          }\n        ]\n      }\n    ]\n  }\n}\n'
  } > "$1/hooks/hooks.json"
}

echo "== auditor test ladder =="
echo "ROOT=$ROOT"
HOSTPY=no; for c in python3 python "py -3"; do if $c -c "pass" >/dev/null 2>&1; then HOSTPY=yes; break; fi; done
echo "host working python: $HOSTPY | shellcheck: $(command -v shellcheck >/dev/null 2>&1 && echo present || echo absent)"
echo ""

# ===========================================================================
# TIER 1 — SILENT on the real (clean) repo.
# ===========================================================================
echo "-- tier 1: SILENT on clean repo --"
for fn in audit_d1 audit_d2 audit_d3 audit_d4 audit_d5 audit_d6 audit_d6b audit_d7 audit_d8 audit_d9 audit_d10; do
  out=$(run_det "$fn" "$ROOT")
  n=$(printf '%s\n' "$out" | grep -cE "^(HIGH|MEDIUM|LOW)$TAB" 2>/dev/null || true)
  assert_eq "T1 $fn silent on clean repo (0 findings)" 0 "$n"
done
if command -v shellcheck >/dev/null 2>&1; then
  scbad=0
  for s in lib-audit-checks.sh verify-audit.sh auditor-status.sh; do
    o=$(tr -d '\r' < "$ROOT/plugins/auditor/scripts/$s" | shellcheck -S error -f gcc -e SC1091 - 2>/dev/null || true)
    [ -n "$o" ] && { scbad=$((scbad+1)); printf '      %s: %s\n' "$s" "$o"; }
  done
  assert_eq "T1 auditor's own 3 scripts ShellCheck-clean (-S error)" 0 "$scbad"
else
  skipnote "T1 ShellCheck-clean (shellcheck absent)"
fi
echo ""

# ===========================================================================
# TIER 2 — FIRE: per-detector positive controls.
# ===========================================================================
echo "-- tier 2: FIRE (per-detector) --"

# D1 (HIGH) — guard uses `command -v python3` as a presence test.
F="$WORK/d1"; mkdir -p "$F/plugins/p/scripts"
write_pre "$F/plugins/p" "Write|Edit|MultiEdit|NotebookEdit" "guard.sh" 1
printf '#!/usr/bin/env bash\nset -uo pipefail\nif command -v python3 >/dev/null 2>&1; then echo ok; fi\n[ -n "$file_path" ]\n' > "$WORK/d1/plugins/p/scripts/guard.sh"; chmod +x "$WORK/d1/plugins/p/scripts/guard.sh"
out=$(run_det audit_d1 "$F"); has "$out" HIGH d1-fail-open && ok "T2 D1 fires HIGH on 'command -v python3'" || bad "T2 D1" "no HIGH; got: $out"
# D1 silent — same guard without the presence test.
printf '#!/usr/bin/env bash\nset -uo pipefail\necho clean\n' > "$WORK/d1/plugins/p/scripts/guard.sh"
out=$(run_det audit_d1 "$F"); n=$(cnt "$out" HIGH d1-fail-open); assert_eq "T2 D1 silent without it" 0 "$n"
# D1 BROADENED (F-E): `command -v python` (NO version digit) — the old literal `python3` match missed it.
printf '#!/usr/bin/env bash\nset -uo pipefail\nif command -v python >/dev/null 2>&1; then echo ok; fi\n[ -n "$file_path" ]\n' > "$WORK/d1/plugins/p/scripts/guard.sh"
out=$(run_det audit_d1 "$F"); has "$out" HIGH d1-fail-open && ok "T2 D1 fires on 'command -v python' (no version digit) (F-E)" || bad "T2 D1 cmd-v broadened" "no HIGH; got: $out"
# D1 BROADENED (F-E): a BACKTICK interpreter capture under set -e with no '||' — the old $(-only match missed it.
printf '#!/usr/bin/env bash\nset -e\nv=`python -c "print(1)"`\necho "$v"\n' > "$WORK/d1/plugins/p/scripts/guard.sh"
out=$(run_det audit_d1 "$F"); has "$out" HIGH d1-fail-open && ok "T2 D1 fires on a BACKTICK python capture under set -e (F-E)" || bad "T2 D1 backtick broadened" "no HIGH; got: $out"
# D1 silent control — a backtick python capture WITH a '|| fallback' is safe.
printf '#!/usr/bin/env bash\nset -e\nv=`python -c "print(1)"` || v=""\necho "$v"\n' > "$WORK/d1/plugins/p/scripts/guard.sh"
out=$(run_det audit_d1 "$F"); n=$(cnt "$out" HIGH d1-fail-open); assert_eq "T2 D1 silent on a backtick capture WITH '|| fallback'" 0 "$n"

# D2 (HIGH) — PreToolUse guard reads file_path but never bd_normalize_path.
F="$WORK/d2"; mkdir -p "$F/plugins/p/scripts"
write_pre "$F/plugins/p" "Write|Edit|MultiEdit|NotebookEdit" "guard.sh" 1
printf '#!/usr/bin/env bash\nt="$tool_input"; case "$file_path" in .claude/*) exit 0;; esac\nexit 2\n' > "$F/plugins/p/scripts/guard.sh"; chmod +x "$F/plugins/p/scripts/guard.sh"
out=$(run_det audit_d2 "$F"); has "$out" HIGH d2-traversal && ok "T2 D2 fires HIGH on raw-path guard" || bad "T2 D2" "no HIGH; got: $out"
# D2 silent — add bd_normalize_path.
printf '#!/usr/bin/env bash\nr="$(bd_normalize_path "$file_path")"; case "$r" in .claude/*) exit 0;; esac\nexit 2\n' > "$F/plugins/p/scripts/guard.sh"
out=$(run_det audit_d2 "$F"); n=$(cnt "$out" HIGH d2-traversal); assert_eq "T2 D2 silent with bd_normalize_path" 0 "$n"
# D2 BROADENED (F-E): bd_normalize_path only MENTIONED in a comment (never ASSIGNED) while the
# allow-zone is matched on a RAW path — the old token-presence `grep -q` was fooled; now it fires.
printf '#!/usr/bin/env bash\n# this guard uses bd_normalize_path (it does not, really)\nt="$file_path"; case "$t" in .claude/*) exit 0;; esac\nexit 2\n' > "$F/plugins/p/scripts/guard.sh"
out=$(run_det audit_d2 "$F"); has "$out" HIGH d2-traversal && ok "T2 D2 fires on a COMMENT-ONLY bd_normalize_path mention (F-E)" || bad "T2 D2 comment-only broadened" "no HIGH; got: $out"

# D6 (HIGH) — hooks.json points at a missing script.
F="$WORK/d6"; mkdir -p "$F/plugins/p/scripts"
write_pre "$F/plugins/p" "Write|Edit|MultiEdit|NotebookEdit" "nope.sh" 1
out=$(run_det audit_d6 "$F"); has "$out" HIGH d6-hook-contract && ok "T2 D6 fires HIGH on missing hook script" || bad "T2 D6" "no HIGH; got: $out"
# D6 silent — script present + executable.
printf '#!/usr/bin/env bash\nexit 0\n' > "$F/plugins/p/scripts/nope.sh"; chmod +x "$F/plugins/p/scripts/nope.sh"
out=$(run_det audit_d6 "$F"); n=$(cnt "$out" HIGH d6-hook-contract); assert_eq "T2 D6 silent when script present+exec" 0 "$n"

# D7 (HIGH) — marketplace 'source' dir missing.
F="$WORK/d7"; mkdir -p "$F/.claude-plugin"
printf '{\n  "plugins": [\n    { "name": "ghost", "source": "./plugins/ghost" }\n  ]\n}\n' > "$F/.claude-plugin/marketplace.json"
out=$(run_det audit_d7 "$F"); has "$out" HIGH d7-manifest && ok "T2 D7 fires HIGH on missing source dir" || bad "T2 D7" "no HIGH; got: $out"
# D7 silent — source exists.
mkdir -p "$F/plugins/ghost"
out=$(run_det audit_d7 "$F"); n=$(cnt "$out" HIGH d7-manifest); assert_eq "T2 D7 silent when source exists" 0 "$n"

# D8 (HIGH) — vendored lib differs from canonical.
F="$WORK/d8"; mkdir -p "$F/shared/lib" "$F/plugins/p/lib"
cp "$LIB" "$F/shared/lib/common.sh"; printf '# DRIFT\n' > "$F/plugins/p/lib/common.sh"
out=$(run_det audit_d8 "$F"); has "$out" HIGH d8-lib-drift && ok "T2 D8 fires HIGH on vendored drift" || bad "T2 D8" "no HIGH; got: $out"
# D8 silent — identical.
cp "$LIB" "$F/plugins/p/lib/common.sh"
out=$(run_det audit_d8 "$F"); n=$(cnt "$out" HIGH d8-lib-drift); assert_eq "T2 D8 silent when in sync" 0 "$n"

# D10 (HIGH, F-A) — a write-discipline plugin (guard-scope) with NO PreToolUse Bash matcher.
F="$WORK/d10"; mkdir -p "$F/plugins/p/scripts"
write_pre "$F/plugins/p" "Write|Edit|MultiEdit|NotebookEdit" "guard-scope.sh" 1
out=$(run_det audit_d10 "$F"); has "$out" HIGH d10-bash-bypass && ok "T2 D10 fires HIGH on write-guard plugin with no Bash matcher" || bad "T2 D10" "no HIGH; got: $out"
# D10 silent — once a PreToolUse Bash matcher is wired.
write_pre_with_bash "$F/plugins/p" "guard-scope.sh"
out=$(run_det audit_d10 "$F"); n=$(cnt "$out" HIGH d10-bash-bypass); assert_eq "T2 D10 silent once a Bash matcher is wired" 0 "$n"
# D10 silent — a plugin with NO write-discipline guard is not judged (a missing Bash matcher is fine).
F2="$WORK/d10nb"; mkdir -p "$F2/plugins/q/scripts"
write_pre "$F2/plugins/q" "Write|Edit|MultiEdit|NotebookEdit" "lint-feedback.sh" 1
out=$(run_det audit_d10 "$F2"); n=$(cnt "$out" HIGH d10-bash-bypass); assert_eq "T2 D10 silent on a non-write-discipline plugin (not judged)" 0 "$n"

# D3 (MEDIUM) — matcher omits NotebookEdit.
F="$WORK/d3"; mkdir -p "$F/plugins/p/scripts"
write_pre "$F/plugins/p" "Write|Edit|MultiEdit" "guard.sh" 1
printf '#!/usr/bin/env bash\nx="$file_path$notebook_path"\n' > "$F/plugins/p/scripts/guard.sh"; chmod +x "$F/plugins/p/scripts/guard.sh"
out=$(run_det audit_d3 "$F"); has "$out" MEDIUM d3-notebook-gap && ok "T2 D3 fires MEDIUM on matcher missing NotebookEdit" || bad "T2 D3" "no MED; got: $out"
# D3 silent — matcher includes NotebookEdit + guard reads notebook_path.
write_pre "$F/plugins/p" "Write|Edit|MultiEdit|NotebookEdit" "guard.sh" 1
out=$(run_det audit_d3 "$F"); n=$(cnt "$out" MEDIUM d3-notebook-gap); assert_eq "T2 D3 silent with NotebookEdit+notebook_path" 0 "$n"

# D4 (MEDIUM) — cat stdin without [ -t 0 ].
F="$WORK/d4"; mkdir -p "$F/plugins/p/scripts"
write_session "$F/plugins/p" "s.sh" 1
printf '#!/usr/bin/env bash\nx="$(cat 2>/dev/null)"\nprintf "%%s" "$x"\n' > "$F/plugins/p/scripts/s.sh"; chmod +x "$F/plugins/p/scripts/s.sh"
out=$(run_det audit_d4 "$F"); has "$out" MEDIUM d4-stdin-block && ok "T2 D4 fires MEDIUM on unguarded cat" || bad "T2 D4" "no MED; got: $out"
# D4 silent — add [ -t 0 ] guard.
printf '#!/usr/bin/env bash\nif [ -t 0 ]; then x=""; else x="$(cat 2>/dev/null)"; fi\nprintf "%%s" "$x"\n' > "$F/plugins/p/scripts/s.sh"
out=$(run_det audit_d4 "$F"); n=$(cnt "$out" MEDIUM d4-stdin-block); assert_eq "T2 D4 silent with [ -t 0 ] guard" 0 "$n"

# D5 (MEDIUM) — SessionStart guidance only to stderr.
F="$WORK/d5"; mkdir -p "$F/plugins/p/scripts"
write_session "$F/plugins/p" "s.sh" 1
printf '#!/usr/bin/env bash\nbd_say "hello from stderr only"\n' > "$F/plugins/p/scripts/s.sh"; chmod +x "$F/plugins/p/scripts/s.sh"
out=$(run_det audit_d5 "$F"); has "$out" MEDIUM d5-sessionstart-stderr && ok "T2 D5 fires MEDIUM on stderr-only SessionStart" || bad "T2 D5" "no MED; got: $out"
# D5 silent — emit to stdout.
printf '#!/usr/bin/env bash\nprintf "[p] hello\\n"\n' > "$F/plugins/p/scripts/s.sh"
out=$(run_det audit_d5 "$F"); n=$(cnt "$out" MEDIUM d5-sessionstart-stderr); assert_eq "T2 D5 silent when emitting to stdout" 0 "$n"

# D6b (MEDIUM) — hook entry without timeout.
F="$WORK/d6b"; mkdir -p "$F/plugins/p/scripts"
write_pre "$F/plugins/p" "Write|Edit|MultiEdit|NotebookEdit" "guard.sh" 0
printf '#!/usr/bin/env bash\nexit 0\n' > "$F/plugins/p/scripts/guard.sh"; chmod +x "$F/plugins/p/scripts/guard.sh"
out=$(run_det audit_d6b "$F"); has "$out" MEDIUM d6b-hook-no-timeout && ok "T2 D6b fires MEDIUM on missing timeout" || bad "T2 D6b" "no MED; got: $out"
# D6b silent — with timeout.
write_pre "$F/plugins/p" "Write|Edit|MultiEdit|NotebookEdit" "guard.sh" 1
out=$(run_det audit_d6b "$F"); n=$(cnt "$out" MEDIUM d6b-hook-no-timeout); assert_eq "T2 D6b silent with timeout" 0 "$n"

# D9 (LOW) — needs git: a tracked .sh that ships CRLF, and a non-hook .sh tracked 100644.
GF="$WORK/d9git"
if git -C "$WORK" init -q d9git >/dev/null 2>&1; then
  git -C "$GF" config core.autocrlf false; git -C "$GF" config core.fileMode false
  mkdir -p "$GF/plugins/p/scripts"
  printf '#!/usr/bin/env bash\r\necho crlf\r\n' > "$GF/plugins/p/scripts/crlf.sh"
  printf '#!/usr/bin/env bash\necho lf\n'       > "$GF/plugins/p/scripts/plain.sh"
  git -C "$GF" add -A >/dev/null 2>&1
  git -C "$GF" -c user.email=t@e -c user.name=t commit -qm f >/dev/null 2>&1 || true
  out=$(run_det audit_d9 "$GF")
  has "$out" LOW d9-line-endings && ok "T2 D9 fires LOW on CRLF-shipped .sh" || bad "T2 D9 crlf" "no LOW; got: $out"
  has "$out" LOW d9-exec-mode && ok "T2 D9 fires LOW on non-hook .sh not 100755" || bad "T2 D9 mode" "no LOW; got: $out"
else
  skipnote "T2 D9 (could not git-init a fixture)"
fi
echo ""

# ===========================================================================
# TIER 3 — AGGREGATE: verify-audit tally + STATUS extras + agent findings + malformed-drop.
# ===========================================================================
echo "-- tier 3: AGGREGATE (verify-audit) --"
AP="$WORK/agg"; mkdir -p "$AP/.claude/auditor/findings" "$AP/shared/lib"; cp "$LIB" "$AP/shared/lib/common.sh"
# clean minimal project (valid canonical lib, no plugins) -> 0 static findings; the agent file
# supplies 1 HIGH + 1 MED + 1 ADVISORY + a malformed line, isolating the aggregation behavior.
printf 'HIGH\tscout-x\tsrc/a.sh:10\treal high\nMEDIUM\tscout-y\tsrc/b.sh:3\ta medium\nADVISORY\tscout-z\tdoc\tinfo only\nthis is not a finding line\n' > "$AP/.claude/auditor/findings/scout.tsv"
CLAUDE_PROJECT_DIR="$AP" bash "$VERIFY_AUDIT" >/dev/null 2>&1 || true
gh=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read auditor high' 2>/dev/null || true)
gm=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read auditor med'  2>/dev/null || true)
gl=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read auditor low'  2>/dev/null || true)
gs=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read auditor state' 2>/dev/null || true)
assert_eq "T3 agent HIGH folded into STATUS high"   1 "$gh"
assert_eq "T3 agent MEDIUM folded into STATUS med"  1 "$gm"
assert_eq "T3 advisory EXCLUDED from low tally"     0 "$gl"
assert_eq "T3 state=failed when high>0"          failed "$gs"
[ -f "$AP/.claude/auditor/FINDINGS.md" ] && ok "T3 FINDINGS.md written" || bad "T3 FINDINGS.md" "missing"
grep -q "real high" "$AP/.claude/auditor/FINDINGS.md" 2>/dev/null && ok "T3 FINDINGS.md lists the HIGH" || bad "T3 FINDINGS.md HIGH" "missing"
# clean agent file -> state done, high 0
printf 'LOW\tscout-q\tx\tminor\n' > "$AP/.claude/auditor/findings/scout.tsv"
CLAUDE_PROJECT_DIR="$AP" bash "$VERIFY_AUDIT" >/dev/null 2>&1 || true
gs=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read auditor state' 2>/dev/null || true)
gh=$(CLAUDE_PROJECT_DIR="$AP" bash -c '. "$LIB"; bd_status_read auditor high' 2>/dev/null || true)
assert_eq "T3 state=done when 0 high" done "$gs"
assert_eq "T3 high=0 when only LOW"   0    "$gh"
echo ""

# ===========================================================================
# TIER 4 — GATE: the release gate enforces auditor 0-high (Section-A extras end-to-end).
# ===========================================================================
echo "-- tier 4: GATE integration (verify-release reads auditor high) --"
git -C "$WORK" init -q g4 >/dev/null 2>&1 || true
G4="$WORK/g4"
git -C "$G4" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init >/dev/null 2>&1 || true
G4HEAD=$(git -C "$G4" rev-parse HEAD 2>/dev/null || printf 'x')
relready() {  # <dir> : make a release-ready fixture (fresh mem, builder done, changelog)
  mkdir -p "$1/.claude/explorer" "$1/.claude/builder"
  { printf 'explored_commit: %s\n' "$G4HEAD"; printf 'coverage: 80%%\n'; } > "$1/.claude/explorer/MEMORY.md"
  printf '# c\n' > "$1/.claude/builder/CHANGELOG.md"
  CLAUDE_PROJECT_DIR="$1" bash -c '. "$LIB"; bd_status_write builder qa done' >/dev/null 2>&1 || true
}
# (a) auditor high=0 -> gate PASS even under enforce
PA="$G4/relpass"; relready "$PA"
CLAUDE_PROJECT_DIR="$PA" bash -c '. "$LIB"; bd_status_write auditor audit done "" high=0 med=1 low=2' >/dev/null 2>&1 || true
rc=0; CLAUDE_PROJECT_DIR="$PA" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" >/dev/null 2>&1 || rc=$?
assert_eq "T4 release PASS (exit 0) with auditor high=0 under enforce" 0 "$rc"
grep -q "0 high" "$PA/.claude/pipeline/RELEASE.md" 2>/dev/null && ok "T4 RELEASE.md shows auditor 0 high PASS" || bad "T4 auditor pass row" "missing"
# (b) auditor high=2 -> gate BLOCKS (exit 2)
PB="$G4/relhigh"; relready "$PB"
CLAUDE_PROJECT_DIR="$PB" bash -c '. "$LIB"; bd_status_write auditor audit failed "" high=2 med=0 low=0' >/dev/null 2>&1 || true
rc=0; CLAUDE_PROJECT_DIR="$PB" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" >/dev/null 2>&1 || rc=$?
assert_eq "T4 release BLOCKS (exit 2) with auditor high=2 under enforce" 2 "$rc"
grep -q "2 HIGH" "$PB/.claude/pipeline/RELEASE.md" 2>/dev/null && ok "T4 RELEASE.md cites 2 HIGH" || bad "T4 auditor high reason" "missing"
# (c) auditor state=failed (high=0) -> gate BLOCKS
PC="$G4/relfail"; relready "$PC"
CLAUDE_PROJECT_DIR="$PC" bash -c '. "$LIB"; bd_status_write auditor audit failed "" high=0 med=0 low=0' >/dev/null 2>&1 || true
rc=0; CLAUDE_PROJECT_DIR="$PC" PIPELINE_ENFORCE=1 bash "$VERIFY_RELEASE" >/dev/null 2>&1 || rc=$?
assert_eq "T4 release BLOCKS (exit 2) with auditor state=failed" 2 "$rc"
echo ""

# ===========================================================================
# TIER 5 — PORTABILITY: python {real|stub|none} — detectors never depend on python.
# ===========================================================================
echo "-- tier 5: PORTABILITY (python real/stub/none) --"
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
for n in python3 python py; do printf '#!/bin/sh\nexit 49\n' > "$FAKEBIN/$n"; chmod +x "$FAKEBIN/$n"; done
# Reuse the D8-drift fixture (pure diff) + D7 missing-source (pure shell) under stub python.
FP="$WORK/port"; mkdir -p "$FP/shared/lib" "$FP/plugins/p/lib" "$FP/.claude-plugin"
cp "$LIB" "$FP/shared/lib/common.sh"; printf '# DRIFT\n' > "$FP/plugins/p/lib/common.sh"
printf '{\n  "plugins": [\n    { "name": "ghost", "source": "./plugins/ghost" }\n  ]\n}\n' > "$FP/.claude-plugin/marketplace.json"
o_real=$(run_det audit_d8 "$FP")
o_stub=$(AUDIT_ROOT="$FP" PATH="$FAKEBIN:$PATH" bash -c '. "$LIB"; . "$CHECKS"; audit_d8' 2>/dev/null || true)
has "$o_real" HIGH d8-lib-drift && has "$o_stub" HIGH d8-lib-drift && ok "T5 D8 fires under real AND stub python" || bad "T5 D8 portability" "real=[$o_real] stub=[$o_stub]"
o7=$(AUDIT_ROOT="$FP" PATH="$FAKEBIN:$PATH" bash -c '. "$LIB"; . "$CHECKS"; audit_d7' 2>/dev/null || true)
has "$o7" HIGH d7-manifest && ok "T5 D7 source-dir check fires under stub python (pure shell)" || bad "T5 D7 portability" "got: $o7"
# verify-audit never crashes under stub python.
rc=0; CLAUDE_PROJECT_DIR="$AP" PATH="$FAKEBIN:$PATH" bash "$VERIFY_AUDIT" >/dev/null 2>&1 || rc=$?
assert_eq "T5 verify-audit exits 0 (advisory) under stub python" 0 "$rc"
echo ""

# ===========================================================================
# TIER 6 — ADVISORY emits but is excluded from the gate tally.
# ===========================================================================
echo "-- tier 6: ADVISORY (emit, never gate) --"
F="$WORK/adv"; mkdir -p "$F/plugins/p/agents"
printf -- '---\nname: a\ntools: Read\ndisallowedTools: Write\n---\nbody\n' > "$F/plugins/p/agents/a.md"
out=$(run_det audit_advisory "$F")
has "$out" ADVISORY agent-tools && ok "T6 advisory fires on tools:+disallowedTools:" || bad "T6 advisory fire" "got: $out"
nadv_high=$(printf '%s\n' "$out" | grep -cE "^(HIGH|MEDIUM|LOW)$TAB" 2>/dev/null || true)
assert_eq "T6 advisory emits NO HIGH/MED/LOW" 0 "$nadv_high"
echo ""

# ===========================================================================
# TIER 7 — MUTATION SENTINELS: prove the load-bearing lines are load-bearing.
# ===========================================================================
echo "-- tier 7: MUTATION SENTINELS --"
MUT="$WORK/mut-checks.sh"
# Neuter D2 (broadened non-comment-assignment check -> never fires), D8 (force diff -q success),
# D10 (invert the bash-matcher test), and D1 (revert the broadened `command -v python<N>` to the
# literal `python3`). One MUT carries every sentinel mutation.
sed -e '/#D2_NORM_RE/ s#! grep -Eq [^;]*2>/dev/null#false#' \
    -e '/#D1_CMDV_RE/ s/python\[0-9\]\*/python3/' \
    -e 's#diff -q "\$canon" "\$f" >/dev/null 2>&1 || #true || #' \
    -e '/#D10_BYPASS_RE/ s#!(p in bash)#(p in bash)#' \
    "$CHECKS" > "$MUT"
# D2 sentinel — a COMMENT-ONLY bd_normalize_path mention (the F-E evasion): the REAL broadened
# detector catches it; the neutered mutant must miss it.
mkdir -p "$WORK/mut2/plugins/p/scripts"; write_pre "$WORK/mut2/plugins/p" "Write|Edit|MultiEdit|NotebookEdit" "guard.sh" 1
printf '#!/usr/bin/env bash\n# normalized with bd_normalize_path (not really)\ncase "$file_path" in .claude/*) exit 0;; esac\nexit 2\n' > "$WORK/mut2/plugins/p/scripts/guard.sh"
realD2=$(run_det audit_d2 "$WORK/mut2")
mutD2=$(AUDIT_ROOT="$WORK/mut2" CHECKS="$MUT" bash -c '. "$LIB"; . "$MUT"; audit_d2' 2>/dev/null || true)
if has "$realD2" HIGH d2-traversal && ! has "$mutD2" HIGH d2-traversal; then ok "T7 D2 sentinel: real fires on comment-only normalize, mutant silent -> broadened normalize-check load-bearing"; else bad "T7 D2 sentinel" "real=[$realD2] mut=[$mutD2]"; fi
# D1 sentinel — revert the broadened `command -v python<N>` to literal `python3`: a `command -v python`
# (no digit) guard the REAL detector catches must be MISSED by the mutant.
mkdir -p "$WORK/mut1/plugins/p/scripts"; write_pre "$WORK/mut1/plugins/p" "Write|Edit|MultiEdit|NotebookEdit" "guard.sh" 1
printf '#!/usr/bin/env bash\nset -uo pipefail\nif command -v python >/dev/null 2>&1; then echo ok; fi\n[ -n "$file_path" ]\n' > "$WORK/mut1/plugins/p/scripts/guard.sh"
realD1=$(run_det audit_d1 "$WORK/mut1")
mutD1=$(AUDIT_ROOT="$WORK/mut1" CHECKS="$MUT" bash -c '. "$LIB"; . "$MUT"; audit_d1' 2>/dev/null || true)
if has "$realD1" HIGH d1-fail-open && ! has "$mutD1" HIGH d1-fail-open; then ok "T7 D1 sentinel: real fires on 'command -v python', mutant (literal python3) silent -> broadening load-bearing"; else bad "T7 D1 sentinel" "real=[$realD1] mut=[$mutD1]"; fi
# D8 sentinel
mkdir -p "$WORK/mut8/shared/lib" "$WORK/mut8/plugins/p/lib"; cp "$LIB" "$WORK/mut8/shared/lib/common.sh"; printf '# DRIFT\n' > "$WORK/mut8/plugins/p/lib/common.sh"
realD8=$(run_det audit_d8 "$WORK/mut8")
mutD8=$(AUDIT_ROOT="$WORK/mut8" CHECKS="$MUT" bash -c '. "$LIB"; . "$MUT"; audit_d8' 2>/dev/null || true)
if has "$realD8" HIGH d8-lib-drift && ! has "$mutD8" HIGH d8-lib-drift; then ok "T7 D8 sentinel: real fires, mutant silent -> diff load-bearing"; else bad "T7 D8 sentinel" "real=[$realD8] mut=[$mutD8]"; fi
# D10 sentinel — invert the bash-matcher test (!(p in bash) -> (p in bash)) and prove a write-guard
# plugin with no Bash matcher, which the real detector catches, is missed by the mutant.
mkdir -p "$WORK/mut10/plugins/p/scripts"; write_pre "$WORK/mut10/plugins/p" "Write|Edit|MultiEdit|NotebookEdit" "guard-scope.sh" 1
realD10=$(run_det audit_d10 "$WORK/mut10")
mutD10=$(AUDIT_ROOT="$WORK/mut10" CHECKS="$MUT" bash -c '. "$LIB"; . "$MUT"; audit_d10' 2>/dev/null || true)
if has "$realD10" HIGH d10-bash-bypass && ! has "$mutD10" HIGH d10-bash-bypass; then ok "T7 D10 sentinel: real fires, mutant silent -> bash-matcher check load-bearing"; else bad "T7 D10 sentinel" "real=[$realD10] mut=[$mutD10]"; fi
echo ""

echo "== auditor ladder summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
