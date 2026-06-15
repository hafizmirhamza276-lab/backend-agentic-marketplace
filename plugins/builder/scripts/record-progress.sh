#!/usr/bin/env bash
# record-progress.sh — SubagentStop gate (advisory, never blocks).
# Appends a timestamped breadcrumb to .claude/builder/CHANGELOG.md so a fresh
# session can reconstruct what happened without re-reading sub-agent transcripts.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"

BUILDER_DIR="$(bd_builder_dir)"
mkdir -p "$BUILDER_DIR" 2>/dev/null || true
LOG="$(bd_changelog)"

bd_load_hook_input
# SubagentStop's documented key is agent_type; fall back to subagent_type for older
# Claude Code builds (F7).
AGENT="$(bd_hook_field agent_type)"; [ -n "$AGENT" ] || AGENT="$(bd_hook_field subagent_type)"
[ -n "$AGENT" ] || AGENT="sub-agent"
TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"

[ -f "$LOG" ] || printf '# builder — change log\n\n' > "$LOG"
printf -- '- %s  %s finished (HEAD %s)\n' "$TS" "$AGENT" "$(bd_git_head)" >> "$LOG"
exit 0
