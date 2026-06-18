#!/usr/bin/env bash
# verify-build.sh — Stop gate. Advisory by default; hard-blocks (exit 2) only in
# enforce mode. Checks the change actually produced durable artifacts AND that the
# memory it relies on is path-accurate.
#
# No-PLAN handling is STATUS-aware (not a blanket early-exit). If the builder STATUS shows the
# builder actually ran (state set and != pending) but neither PLAN.md NOR a bug-fix BUG.md
# exists, that missing durable artifact is REPORTED — a build that ran should leave a plan. A
# bug-fix build records BUG.md instead of a PLAN, so that case is NOT flagged. Only the genuine
# "build not started" case (no builder STATUS, or state still pending) stays the silent no-op it
# always was. Reading STATUS is pure-shell (bd_status_read's grep fallback); advisory by default.
#
# Carries over the known explorer defect: index.json paths were INFERRED, not
# verified (~half pointed at wrong sub-folders). This gate fails if any
# index.json file path does not resolve on disk — exactly the class of error a
# deterministic check catches.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"

PROJECT="$(bd_project_dir)"
PLAN="$(bd_plan)"
LOG="$(bd_changelog)"
INDEX="$(bd_explorer_dir)/index.json"
problems=0
note() { printf '  - %s\n' "$*" >&2; ((problems++)) || true; }

# Only act when builder has actually been engaged this session.
[ -d "$(bd_builder_dir)" ] || exit 0

# Per-edit feedback loop, ENFORCE mode: refuse to finish while files edited this
# session still carry unaddressed lint/type findings (lint-feedback.sh records them
# under .claude/builder/feedback/; a clean re-edit clears its record). Independent of
# enforce_gates and of whether a PLAN exists, so it can't be skipped. Advisory mode
# (default) writes no records, so this block is a no-op then.
if bd_feedback_enforce; then
  FEEDBACK_DIR="$(bd_builder_dir)/feedback"
  if [ -d "$FEEDBACK_DIR" ]; then
    outstanding=0
    for rec in "$FEEDBACK_DIR"/*.txt; do
      [ -e "$rec" ] || continue
      [ -s "$rec" ] && outstanding=$((outstanding + 1))
    done
    if [ "$outstanding" -gt 0 ]; then
      printf '[builder] build verification BLOCKED: %s file(s) have unaddressed lint/type findings from the per-edit feedback loop (see .claude/builder/feedback/). Fix them, or unset feedback_enforce.\n' "$outstanding" >&2
      exit 2
    fi
  fi
fi

# No PLAN.md: this WAS a blanket `exit 0` that silently passed even when the builder had run and
# left no plan (and made the "no PLAN.md" note below dead code). Now STATUS-aware — distinguish
# "build not started" (legit no-op) from "builder ran but left no durable plan" (a reportable
# missing artifact). A bug-fix build records BUG.md instead of a PLAN, so it is NOT a missing
# artifact and we exit clean then too.
if [ ! -f "$PLAN" ]; then
  BSTATE="$(bd_status_read builder state 2>/dev/null || true)"
  case "$BSTATE" in
    ''|pending) exit 0 ;;                 # no builder activity yet — nothing durable to verify
  esac
  [ -f "$(bd_bug)" ] && exit 0            # bug-fix build: BUG.md is the durable artifact, not a PLAN
  # else: builder engaged (running/blocked/done/failed) yet left no PLAN.md -> fall through, report it.
fi

[ -f "$PLAN" ] || note "no .claude/builder/PLAN.md — builder STATUS shows it ran; record the plan you implemented"
[ -f "$LOG" ]  || note "no .claude/builder/CHANGELOG.md — record what changed"

# Scope paths named in the plan should exist after implementation.
if [ -f "$PLAN" ]; then
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in /*) abs="$p" ;; *) abs="$PROJECT/$p" ;; esac
    [ -e "$abs" ] || note "PLAN scope path does not exist on disk: $p"
  done < <(awk '
    /^#{1,6}[[:space:]].*[Ss]cope/{g=1;next}/^#{1,6}[[:space:]]/{g=0}
    g&&/^[[:space:]]*[-*][[:space:]]/{l=$0;sub(/^[[:space:]]*[-*][[:space:]]+/,"",l);gsub(/`/,"",l);sub(/[[:space:]].*$/,"",l);print l}
  ' "$PLAN")
fi

# index.json path-resolution check (the explorer fix).
if [ -f "$INDEX" ]; then
  if bd_have_python; then
    MISSING="$(PROJECT="$PROJECT" $BD_PYTHON - "$INDEX" <<'PY' 2>/dev/null || true
import json, os, sys
proj = os.environ["PROJECT"]
miss = []
try:
    data = json.load(open(sys.argv[1]))
    for f in data.get("files", []):
        p = f.get("path") if isinstance(f, dict) else None
        if not p: continue
        ap = p if os.path.isabs(p) else os.path.join(proj, p)
        if not os.path.exists(ap):
            miss.append(p)
except Exception as e:
    print("PARSE_ERROR")
    sys.exit(0)
for m in miss[:12]:
    print(m)
PY
)"
    if [ "$MISSING" = "PARSE_ERROR" ]; then
      note "could not parse .claude/explorer/index.json"
    elif [ -n "$MISSING" ]; then
      note "index.json paths that DON'T resolve (fix via find/glob, not inference):"
      printf '%s\n' "$MISSING" | sed 's/^/      • /' >&2
    fi
  else
    bd_warn "no working python interpreter — skipping index.json path-resolution check."
  fi
fi

if [ "$problems" -eq 0 ]; then
  # Stamp the WORKING TREE this build was verified against (external review F-B) so the release gate
  # can FAIL a later stale-but-green release. Re-write STATUS preserving its existing fields and only
  # ADD tree=; do it only when the builder STATUS already exists (the agents set it), so this never
  # fabricates a STATUS for a build that did not run.
  _bstate="$(bd_status_read builder state 2>/dev/null || true)"
  if [ -n "$_bstate" ]; then
    bd_status_write builder \
      "$(bd_status_read builder phase 2>/dev/null || true)" \
      "$_bstate" \
      "$(bd_status_read builder coverage 2>/dev/null || true)" \
      tree="$(bd_tree_digest)" >/dev/null 2>&1 || true
  fi
  bd_say "build verification passed."
  exit 0
fi

if bd_enforce; then
  printf '[builder] build verification FAILED with %s issue(s) above. Fix before finishing.\n' "$problems" >&2
  exit 2
fi
bd_warn "build verification found $problems issue(s) above (advisory; set enforce_gates=true or BUILDER_ENFORCE=1 to block)."
exit 0
