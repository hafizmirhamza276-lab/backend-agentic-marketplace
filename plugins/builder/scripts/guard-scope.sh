#!/usr/bin/env bash
# guard-scope.sh — PreToolUse gate for Write|Edit|MultiEdit|NotebookEdit.
# Enforces the consistency contract: builder may ONLY touch files listed in the
# approved .claude/builder/PLAN.md scope. The builder's own state (.claude/builder/*,
# .claude/specs/*) plus the narrow memory-sync risk-map artifacts are always allowed;
# all OTHER .claude/ paths are scope-checked. Blocks (exit 2) on out-of-scope edits.
#
# Advisory by default for the "no plan yet" case (warns); becomes a hard block
# when enforce mode is on (BUILDER_ENFORCE=1 or settings.enforce_gates=true).
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
# repo-relative form, with '.'/'..' collapsed FIRST so a `..` segment can neither
# escape the allow-zone below nor sneak past the scope check (F2).
REL="${TARGET#"$PROJECT"/}"
REL="$(bd_normalize_path "$REL")"

# Always-allow zone: the builder's OWN durable state + the specs it implements.
# (B) NARROWED from a blanket `.claude/*`, which was over-permissive: it let the builder
# write to ANY other module's state (.claude/pipeline/, .claude/auditor/, .claude/reviewer/,
# .claude/ops/, …) outside the approved plan. Only the builder's own dir and the specs are
# unconditionally writable now; every OTHER .claude/ path falls through to the scope check
# (so e.g. .claude/pipeline/STATUS.json is blocked unless the PLAN.md Scope names it).
#
# Memory-sync carve-out (NARROW, intentional): the builder's FINAL phase
# (builder-memory-sync — start.md Phase 7; agents/builder-memory-sync.md) legitimately writes
# the explorer "risk map" back after a build/bug-fix — exactly MEMORY.md, index.json, TRACK.md,
# and the map/<area>.md deep-dives (skills/sync-memory/SKILL.md "What to update"; diagnose-bug
# SKILL.md:123 "records the bug + fix into the durable risk map (MEMORY.md / index.json /
# TRACK.md)"). That phase runs while PLAN.md still exists, and those paths are NOT in the plan's
# Scope (which lists source + test files), so the narrowed guard would otherwise block the
# legitimate sync. We therefore allow ONLY those four exact artifacts — deliberately NOT a
# blanket `.claude/explorer/*`, so the builder still cannot write arbitrary explorer state
# (a stray `.claude/explorer/anything-else` stays subject to the scope check). `..` can't widen
# this: REL was lexically normalized above before any of these patterns are matched.
case "$REL" in
  .claude/builder/*|.claude/specs/*) exit 0 ;;
  .claude/explorer/MEMORY.md|.claude/explorer/index.json|.claude/explorer/TRACK.md|.claude/explorer/map/*) exit 0 ;;
esac

PLAN="$(bd_plan)"
if [ ! -f "$PLAN" ]; then
  if bd_enforce; then
    bd_block "BLOCKED: no approved plan. Build flow requires .claude/builder/PLAN.md before editing code ($REL). Run /builder:start first."
  fi
  bd_warn "editing $REL without an approved PLAN.md — builder expects a plan first (advisory)."
  exit 0
fi

# Extract the Scope list: bullet paths under a heading that contains 'Scope'.
SCOPE="$(awk '
  /^#{1,6}[[:space:]].*[Ss]cope/ {grab=1; next}
  /^#{1,6}[[:space:]]/ {grab=0}
  grab && /^[[:space:]]*[-*][[:space:]]/ {
    line=$0
    sub(/^[[:space:]]*[-*][[:space:]]+/, "", line)
    gsub(/`/, "", line)
    sub(/[[:space:]].*$/, "", line)   # path is first token
    print line
  }
' "$PLAN" 2>/dev/null)"

if [ -z "$SCOPE" ]; then
  # (A) FAIL CLOSED. Previously this WARNED and `exit 0` (allowed the edit) — a fail-open: a
  # broken/empty Scope was MORE permissive than a valid one (a valid Scope blocks out-of-scope
  # edits UNCONDITIONALLY via the bd_block below). A PLAN.md whose Scope can't be parsed must be
  # NO MORE permissive than one that can, so we block here too. Unconditional (NOT gated on
  # bd_enforce) to match that out-of-scope block — the "PLAN.md exists" regime enforces scope
  # regardless of enforce mode; only the separate "no PLAN.md at all" case is advisory.
  # PLAN.md itself (and the rest of .claude/builder/*) stays editable via the always-allow zone
  # above, so the user can ADD a Scope section to recover.
  bd_block "BLOCKED: .claude/builder/PLAN.md exists but has no parseable '## Scope' file list, so $REL cannot be verified as in scope (a broken Scope must not be more permissive than a valid one). Add a '## Scope' section listing the repo-relative files this change may touch — PLAN.md itself stays editable so you can fix it — then retry."
fi

# membership check: repo-relative path equality (with a './' prefix tolerance).
# No basename fallback — a bare-filename match would admit a same-named file in
# another directory (F3); scope membership requires the full repo-relative path.
if printf '%s\n' "$SCOPE" | grep -qxF "$REL" \
   || printf '%s\n' "$SCOPE" | grep -qxF "./$REL"; then
  exit 0
fi

bd_block "BLOCKED: $REL is NOT in the approved PLAN.md scope. The spec contract forbids touching files the plan did not name. If this edit is genuinely required, add it to the Scope section of .claude/builder/PLAN.md and re-confirm with the user first."
