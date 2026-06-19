#!/usr/bin/env bash
# guard-bugfix.sh — PreToolUse gate for Write|Edit|MultiEdit|NotebookEdit.
# Encodes the BUG-FIX MODE cornerstone: REPRODUCE-FIRST. When a bug-fix session is
# engaged (a .claude/builder/BUG.md Bug Brief exists) and `require_reproduction` is
# true, NO source file may be edited until the symptom is captured as a failing
# reproduction (a repro TEST file on disk) — or the reporter has explicitly confirmed
# a constructed repro (override marker). Test files and the plugin's own memory are
# always allowed, so the diagnostician can build the verification net.
#
# This is a SEPARATE hook from guard-scope.sh on purpose: it does not touch the scope
# contract or its F2/F3 fixes. Outside a bug-fix session it is a pure no-op, so it can
# never interfere with the ordinary feature flow.
#
# Fail direction: this guard only ever ACTS inside an engaged bug-fix session; when it
# can't be sure (no BUG.md), it exits 0 and stays out of the way. Within a bug-fix
# session the safe failure is to BLOCK (force a repro), which is what it does.
# NOT errexit (F-A4): under `set -e` a PreToolUse guard that hits an unexpected non-zero aborts with
# THAT code — and PreToolUse blocks only on exit 2, so the edit would proceed unguarded (fail-open).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"

bd_load_hook_input
TARGET="$(bd_hook_field tool_input.file_path)"
[ -n "$TARGET" ] || TARGET="$(bd_hook_field tool_input.notebook_path)"
[ -n "$TARGET" ] || exit 0   # nothing to check

PROJECT="$(bd_project_dir)"
# repo-relative form with '.'/'..' collapsed FIRST (same hardening as guard-scope, F2).
REL="${TARGET#"$PROJECT"/}"
REL="$(bd_normalize_path "$REL")"

# Always allow the plugin's own durable memory + specs + bug-fix state.
case "$REL" in
  .claude/*) exit 0 ;;
esac

# Bug-fix engaged only when a Bug Brief exists; otherwise this guard does nothing.
BUGMD="$(bd_bug)"
[ -f "$BUGMD" ] || exit 0

# Reproduce-first is opt-out: honor require_reproduction (default true).
[ "$(bd_setting require_reproduction true)" = "true" ] || exit 0

# Recognize test files across ecosystems (so the failing repro + characterization tests can be
# written before any source edit). Precise patterns — avoid matching e.g. `latest.py` as a test.
# Defined BEFORE the capture checks because (external review F-C) a declared repro now counts as
# "captured" ONLY when it is a recognized TEST path — not merely any existing file on disk.
is_test_path() {
  local p="$1" bn lb lp
  bn="$(basename "$p")"
  lp="$(printf '%s' "$p"  | tr '[:upper:]' '[:lower:]')"
  lb="$(printf '%s' "$bn" | tr '[:upper:]' '[:lower:]')"
  # a path SEGMENT that is a conventional test dir (slashes anchor it to a full segment)
  case "/$lp/" in
    */tests/*|*/test/*|*/__tests__/*|*/spec/*|*/specs/*|*/e2e/*|*/testing/*) return 0 ;;
  esac
  # conventional test basenames, per ecosystem
  case "$lb" in
    test_*.py|*_test.py|conftest.py) return 0 ;;
    *.test.js|*.test.jsx|*.test.ts|*.test.tsx|*.test.mjs|*.test.cjs) return 0 ;;
    *.spec.js|*.spec.jsx|*.spec.ts|*.spec.tsx|*.spec.mjs|*.spec.cjs) return 0 ;;
    *_test.go|*_spec.rb|*_test.rb|*_test.exs|*.test.php|*test.php) return 0 ;;
  esac
  case "$bn" in   # Java/Kotlin/C# use a case-sensitive Test/Tests/IT suffix
    *Test.java|*Tests.java|*IT.java|*Test.kt|*Tests.kt|*Test.cs|*Tests.cs) return 0 ;;
  esac
  return 1
}

# --- already captured? then reproduce-first is satisfied; let edits through -------
# (a) explicit reporter confirmation of a constructed repro (orchestrator writes this
#     only after the user confirmed proceeding), or
# (b) the declared repro is a recognized TEST path that exists on disk (you wrote the failing
#     test). (external review F-C) The old check accepted ANY existing file as the repro, so
#     declaring a non-test file (README.md, a source file) "captured" reproduce-first with no
#     real repro — and a no-op/always-green repro then sailed through the whole bug-fix net.
if [ -f "$(bd_bugfix_dir)/repro.confirmed" ]; then exit 0; fi

REPRO_DECL="$(grep -iE '^[[:space:]]*-?[[:space:]]*Repro test[[:space:]]*:' "$BUGMD" 2>/dev/null \
  | head -n1 \
  | sed -E 's/.*[Rr]epro test[[:space:]]*:[[:space:]]*//; s/`//g; s/::.*$//; s/[[:space:]].*$//' || true)"
if [ -n "$REPRO_DECL" ]; then
  case "$REPRO_DECL" in /*) repro_abs="$REPRO_DECL" ;; *) repro_abs="$PROJECT/$REPRO_DECL" ;; esac
  if is_test_path "$REPRO_DECL" && [ -e "$repro_abs" ]; then exit 0; fi   #BUGFIX_REPRO_TESTPATH the repro must be a recognized TEST path, not any file
fi

# --- not captured: allow building the net (tests), block touching source ---------
# Always allow the file the Brief names as the repro test (it may live anywhere).
[ -n "$REPRO_DECL" ] && [ "$REL" = "$REPRO_DECL" ] && exit 0

is_test_path "$REL" && exit 0

bd_block "BLOCKED (reproduce-first): bug-fix mode is engaged (.claude/builder/BUG.md) and no failing reproduction has been captured yet, so source edits are not allowed ($REL). Write a DETERMINISTIC failing repro test that asserts the expected behavior FIRST (it must fail on the current code), then fix. If the symptom genuinely can't be reproduced, surface the missing info to the reporter or get explicit confirmation of a constructed repro (then the orchestrator writes .claude/builder/bugfix/repro.confirmed). Not fixing a bug? Remove .claude/builder/BUG.md. (Set require_reproduction=false to disable this guard.)"
