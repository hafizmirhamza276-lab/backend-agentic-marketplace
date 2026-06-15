#!/usr/bin/env bash
# guard-scope.sh — PreToolUse gate for Write|Edit|MultiEdit|NotebookEdit.
# Enforces the consistency contract: builder may ONLY touch files listed in the
# approved .claude/builder/PLAN.md scope. Writes to the plugin's own memory
# (.claude/) are always allowed. Blocks (exit 2) on out-of-scope edits.
#
# Advisory by default for the "no plan yet" case (warns); becomes a hard block
# when enforce mode is on (BUILDER_ENFORCE=1 or settings.enforce_gates=true).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"

bd_load_hook_input
TARGET="$(bd_hook_field tool_input.file_path)"
[ -n "$TARGET" ] || TARGET="$(bd_hook_field tool_input.notebook_path)"
[ -n "$TARGET" ] || exit 0   # nothing to check

PROJECT="$(bd_project_dir)"
# repo-relative form
REL="${TARGET#"$PROJECT"/}"

# Always allow the plugin's own durable memory + specs.
case "$REL" in
  .claude/*) exit 0 ;;
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
  bd_warn "PLAN.md has no parseable '## Scope' file list — cannot verify $REL is in scope (advisory)."
  exit 0
fi

# membership check (exact match on repo-relative path or basename match)
BASE="$(basename "$REL")"
if printf '%s\n' "$SCOPE" | grep -qxF "$REL" \
   || printf '%s\n' "$SCOPE" | grep -qxF "./$REL" \
   || printf '%s\n' "$SCOPE" | grep -qxF "$BASE"; then
  exit 0
fi

bd_block "BLOCKED: $REL is NOT in the approved PLAN.md scope. The spec contract forbids touching files the plan did not name. If this edit is genuinely required, add it to the Scope section of .claude/builder/PLAN.md and re-confirm with the user first."
