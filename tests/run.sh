#!/usr/bin/env sh
# run.sh — self-test harness for the marketplace gate scripts. POSIX sh, `set -eu`.
#
# Each case runs a REAL in-place script (so it sources its own vendored ../lib/common.sh)
# inside an ISOLATED temp project dir, feeds crafted hook JSON on stdin, and asserts the
# exit code / output. Together they PROVE the preserved audit fixes:
#   F1  stub python (on PATH, exits non-zero, empty stdout) must NOT fail open — the
#       guards block via the grep fallback (never exit 0).
#   F2  `..` path traversal is collapsed before the allow-zone check, in BOTH guards.
#   F3  a bare-basename Scope entry does not admit a same-named file in another dir.
#   F4  a valid index.json is not false-flagged; with no working python the JSON check
#       is skipped (not failed).
#   F9  a NotebookEdit whose notebook_path is outside the allow-zone is blocked.
#   F7  (bonus) SubagentStop records agent_type — even without python (grep fallback).
#   STATUS  bd_status_write -> bd_status_read round-trips, with and without python.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")

GUARD_READONLY="$ROOT/plugins/explorer/scripts/guard-readonly.sh"
GUARD_SCOPE="$ROOT/plugins/builder/scripts/guard-scope.sh"
VERIFY_OUTPUT="$ROOT/plugins/explorer/scripts/verify-output.sh"
RECORD_COVERAGE="$ROOT/plugins/explorer/scripts/record-coverage.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s  --  %s\n' "$1" "$2"; }

# assert_eq <name> <expected> <actual> — on mismatch, also surface the last run's stderr.
assert_eq() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    bad "$1" "expected [$2], got [$3]; stderr: $(cat "$WORK/err" 2>/dev/null)"
  fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# A fake-bin dir whose python3/python/py all FAIL (exit 49, empty stdout) — exactly the
# Windows Store-stub shape. PREPENDED to the full PATH it shadows any real interpreter, so
# the lib's resolver yields BD_PYTHON="" (no WORKING python). This is how we force the
# grep fallback / skip-JSON paths regardless of what the host actually has installed.
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
for n in python3 python py; do
  printf '#!/bin/sh\nexit 49\n' > "$FAKEBIN/$n"
  chmod +x "$FAKEBIN/$n"
done

# Does the HOST have any working python? (mirrors the lib resolver; guards a control case
# that only makes sense with a real interpreter.)
host_has_python() {
  for c in python3 python "py -3"; do
    # shellcheck disable=SC2086  # $c may carry an arg ("py -3") on purpose
    if $c -c "pass" >/dev/null 2>&1; then return 0; fi
  done
  return 1
}

newproj() { d="$WORK/proj.$1"; mkdir -p "$d"; printf '%s' "$d"; }

# run_guard <script> <project> <json> [pathprefix] -> prints exit code (set -e safe).
run_guard() {
  _s="$1"; _p="$2"; _j="$3"; _pp="${4:-}"; _rc=0
  if [ -n "$_pp" ]; then
    printf '%s' "$_j" | PATH="$_pp:$PATH" CLAUDE_PROJECT_DIR="$_p" bash "$_s" >"$WORK/out" 2>"$WORK/err" || _rc=$?
  else
    printf '%s' "$_j" | CLAUDE_PROJECT_DIR="$_p" bash "$_s" >"$WORK/out" 2>"$WORK/err" || _rc=$?
  fi
  printf '%s' "$_rc"
}

# run_verify <project> [pathprefix] -> prints exit code (EXPLORER_ENFORCE=1, no stdin).
run_verify() {
  _p="$1"; _pp="${2:-}"; _rc=0
  if [ -n "$_pp" ]; then
    PATH="$_pp:$PATH" CLAUDE_PROJECT_DIR="$_p" EXPLORER_ENFORCE=1 bash "$VERIFY_OUTPUT" </dev/null >"$WORK/out" 2>"$WORK/err" || _rc=$?
  else
    CLAUDE_PROJECT_DIR="$_p" EXPLORER_ENFORCE=1 bash "$VERIFY_OUTPUT" </dev/null >"$WORK/out" 2>"$WORK/err" || _rc=$?
  fi
  printf '%s' "$_rc"
}

# A complete explorer memory so verify-output's ONLY possible complaint is index.json.
# $1 = project dir, $2 = index.json body.
make_complete_memory() {
  md="$1/.claude/explorer"
  mkdir -p "$md"
  {
    printf '# Codebase Memory\n'
    printf 'explored_commit: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'
    printf 'coverage: 80%%\n'
    printf '## TL;DR\nx\n'
    printf '## How it works\nx\n'
    printf "## Why it's built this way\nx\n"
    printf '## Module map\nx\n'
    printf '## Risk map\nx\n'
    printf '## Blind spots\nx\n'
  } > "$md/MEMORY.md"
  printf '# Exploration Track\n' > "$md/TRACK.md"
  printf '%s' "$2" > "$md/index.json"
}

# STATUS round-trip helper (one bash script, invoked under different PATH/project).
# args: <expected_state> <expected_coverage>
STATUS_HELPER="$WORK/status_check.sh"
cat > "$STATUS_HELPER" <<'BASH'
#!/usr/bin/env bash
. "$REPO/shared/lib/common.sh"
es="$1"; ec="$2"
bd_status_write builder plan "$es" "$ec"
[ "$(bd_status_read builder module)"   = builder ] || { echo "module mismatch";   exit 11; }
[ "$(bd_status_read builder phase)"    = plan ]    || { echo "phase mismatch";    exit 12; }
[ "$(bd_status_read builder state)"    = "$es" ]   || { echo "state mismatch";    exit 13; }
[ "$(bd_status_read builder coverage)" = "$ec" ]   || { echo "coverage mismatch [$(bd_status_read builder coverage)] != [$ec]"; exit 14; }
[ -n "$(bd_status_read builder commit)" ]          || { echo "commit empty";      exit 15; }
[ -n "$(bd_status_read builder updated_at)" ]      || { echo "updated_at empty";  exit 16; }
[ -z "$(bd_status_read builder no_such_key)" ]     || { echo "absent not empty";  exit 17; }
exit 0
BASH

# run_status <project> <pathprefix-or-empty> <state> <coverage> -> prints exit code.
run_status() {
  _p="$1"; _pp="${2:-}"; _st="$3"; _cv="$4"; _rc=0
  if [ -n "$_pp" ]; then
    REPO="$ROOT" PATH="$_pp:$PATH" CLAUDE_PROJECT_DIR="$_p" bash "$STATUS_HELPER" "$_st" "$_cv" >"$WORK/out" 2>"$WORK/err" || _rc=$?
  else
    REPO="$ROOT" CLAUDE_PROJECT_DIR="$_p" bash "$STATUS_HELPER" "$_st" "$_cv" >"$WORK/out" 2>"$WORK/err" || _rc=$?
  fi
  printf '%s' "$_rc"
}

echo "== marketplace gate self-tests =="
echo "ROOT=$ROOT"
echo "host jq: $(command -v jq >/dev/null 2>&1 && echo present || echo absent) | host working python: $(host_has_python && echo yes || echo no)"
echo ""

# ---------------------------------------------------------------------------
# F1 — stub python must NOT fail open; both guards block via the grep fallback.
# ---------------------------------------------------------------------------
p=$(newproj f1a); mkdir -p "$p/.claude/builder"
printf '# Plan\n## Scope\n- src/allowed.py\n' > "$p/.claude/builder/PLAN.md"
json=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/src/evil.py"}}' "$p")
rc=$(run_guard "$GUARD_SCOPE" "$p" "$json" "$FAKEBIN")
assert_eq "F1 guard-scope blocks out-of-scope under stub python (grep fallback) exit 2" 2 "$rc"

p=$(newproj f1b)
json=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/src/evil.py"}}' "$p")
rc=$(run_guard "$GUARD_READONLY" "$p" "$json" "$FAKEBIN")
assert_eq "F1 guard-readonly blocks out-of-zone under stub python (grep fallback) exit 2" 2 "$rc"

# ---------------------------------------------------------------------------
# F2 — `..` traversal cannot escape the allow-zone in EITHER guard.
# ---------------------------------------------------------------------------
p=$(newproj f2a)
json='{"tool_name":"Write","tool_input":{"file_path":".claude/explorer/../../evil.py"}}'
rc=$(run_guard "$GUARD_READONLY" "$p" "$json")
assert_eq "F2 guard-readonly blocks .claude/explorer/../../evil.py exit 2" 2 "$rc"

p=$(newproj f2a_ctl)
json=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/.claude/explorer/notes.md"}}' "$p")
rc=$(run_guard "$GUARD_READONLY" "$p" "$json")
assert_eq "F2 (control) legit .claude/explorer/notes.md allowed exit 0" 0 "$rc"

p=$(newproj f2b); mkdir -p "$p/.claude/builder"
printf '# Plan\n## Scope\n- src/allowed.cs\n' > "$p/.claude/builder/PLAN.md"
json=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/.claude/../src/b/evil.cs"}}' "$p")
rc=$(run_guard "$GUARD_SCOPE" "$p" "$json")
assert_eq "F2 guard-scope blocks .claude/../src/b/evil.cs (normalized out of zone) exit 2" 2 "$rc"

# ---------------------------------------------------------------------------
# F3 — a bare-basename Scope entry must not admit a same-named file elsewhere.
# ---------------------------------------------------------------------------
p=$(newproj f3a); mkdir -p "$p/.claude/builder"
printf '# Plan\n## Scope\n- config.json\n' > "$p/.claude/builder/PLAN.md"
json=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/src/secret/config.json"}}' "$p")
rc=$(run_guard "$GUARD_SCOPE" "$p" "$json")
assert_eq "F3 bare-basename Scope does NOT admit src/secret/config.json exit 2" 2 "$rc"

p=$(newproj f3b); mkdir -p "$p/.claude/builder"
printf '# Plan\n## Scope\n- src/a/config.json\n' > "$p/.claude/builder/PLAN.md"
json=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/src/a/config.json"}}' "$p")
rc=$(run_guard "$GUARD_SCOPE" "$p" "$json")
assert_eq "F3 full-path equality src/a/config.json allowed exit 0" 0 "$rc"

# ---------------------------------------------------------------------------
# F4 — valid index.json not false-flagged; skip JSON check when no working python.
# ---------------------------------------------------------------------------
p=$(newproj f4a); make_complete_memory "$p" '{"files": []}'
rc=$(run_verify "$p" "")
if [ "$rc" = 0 ] && ! grep -q "not valid JSON" "$WORK/err"; then
  ok "F4 valid index.json NOT flagged (default PATH, ENFORCE=1) exit 0"
else
  bad "F4 valid/default" "exit=$rc err=$(cat "$WORK/err")"
fi

p=$(newproj f4b); make_complete_memory "$p" '{"files": []}'
rc=$(run_verify "$p" "$FAKEBIN")
if [ "$rc" = 0 ] && ! grep -q "not valid JSON" "$WORK/err"; then
  ok "F4 no working python -> JSON check SKIPPED exit 0 (no false complaint)"
else
  bad "F4 valid/no-python" "exit=$rc err=$(cat "$WORK/err")"
fi

if host_has_python; then
  p=$(newproj f4c); make_complete_memory "$p" '{ this is not valid json'
  rc=$(run_verify "$p" "")
  if [ "$rc" = 2 ] && grep -q "not valid JSON" "$WORK/err"; then
    ok "F4 (control) invalid index.json IS flagged under working python exit 2"
  else
    bad "F4 invalid/control" "expected exit 2 + complaint, got exit=$rc err=$(cat "$WORK/err")"
  fi
else
  printf 'SKIP  F4 (control) invalid-json: host has no working python\n'
fi

# ---------------------------------------------------------------------------
# F9 — NotebookEdit notebook_path outside the allow-zone is guarded.
# ---------------------------------------------------------------------------
p=$(newproj f9a)
json=$(printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s/src/analysis.ipynb"}}' "$p")
rc=$(run_guard "$GUARD_READONLY" "$p" "$json")
assert_eq "F9 NotebookEdit outside zone (notebook_path) BLOCKED exit 2" 2 "$rc"

p=$(newproj f9b)
json=$(printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s/.claude/explorer/nb.ipynb"}}' "$p")
rc=$(run_guard "$GUARD_READONLY" "$p" "$json")
assert_eq "F9 (control) NotebookEdit under .claude/explorer/ allowed exit 0" 0 "$rc"

# ---------------------------------------------------------------------------
# F7 (bonus) — SubagentStop records agent_type, even without python (grep fallback).
# ---------------------------------------------------------------------------
p=$(newproj f7a)
json='{"hook_event_name":"SubagentStop","agent_type":"explorer-scout","agent_id":"a1"}'
rc=$(run_guard "$RECORD_COVERAGE" "$p" "$json" "$FAKEBIN")
if [ "$rc" = 0 ] && grep -q "explorer-scout" "$p/.claude/explorer/TRACK.md" 2>/dev/null; then
  ok "F7 record-coverage logs agent_type without python (grep fallback) exit 0"
else
  bad "F7 agent_type" "exit=$rc track=$(cat "$p/.claude/explorer/TRACK.md" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# STATUS — bd_status_write -> bd_status_read round-trips, with and without python.
# ---------------------------------------------------------------------------
p=$(newproj st_py)
rc=$(run_status "$p" "" "running" 73)
assert_eq "STATUS round-trip WITH python (state=running coverage=73)" 0 "$rc"

p=$(newproj st_nopy)
rc=$(run_status "$p" "$FAKEBIN" "blocked" 42)
assert_eq "STATUS round-trip WITHOUT python (state=blocked coverage=42, grep/sed fallback)" 0 "$rc"

p=$(newproj st_null)
rc=$(run_status "$p" "$FAKEBIN" "done" "")
assert_eq "STATUS round-trip null coverage (omitted -> null -> reads empty)" 0 "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
