#!/usr/bin/env bash
# SubagentStop: record that a sub-agent finished, so TRACK.md reflects progress even if a
# run is interrupted. Best-effort; never blocks.
#
# Shared helpers (hook payload load + field parse, with the working-python resolver and
# grep fallback) come from the vendored lib/common.sh. We keep `set -uo pipefail` (NOT -e).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SELF_DIR/../lib/common.sh"

PROJECT_DIR="$(bd_project_dir)"
DIR="$PROJECT_DIR/.claude/explorer"
TRACK="$DIR/TRACK.md"
mkdir -p "$DIR" 2>/dev/null || true

# Read the payload once (skipped when stdin is a terminal, F11) and resolve the agent
# name. SubagentStop's documented key is `agent_type` (F7) — read it FIRST, then fall
# back to legacy/related keys. bd_hook_field uses the working python and degrades to
# grep, so the name is read even on a python-less or stub-python host.
bd_load_hook_input
name="$(bd_hook_field agent_type)"
[ -n "$name" ] || name="$(bd_hook_field subagent_type)"
[ -n "$name" ] || name="$(bd_hook_field agent)"
[ -n "$name" ] || name="$(bd_hook_field name)"
[ -n "$name" ] || name="subagent"

[[ -f "$TRACK" ]] || printf '# Exploration Track\n## Changelog\n' > "$TRACK"
printf -- '- %s — sub-agent finished: %s\n' "$(date -u +%FT%TZ)" "$name" >> "$TRACK"
exit 0
