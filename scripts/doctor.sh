#!/usr/bin/env bash
# doctor.sh — /doctor preflight: a readiness table for the toolchain the plugins'
# deterministic gates depend on. ADVISORY ONLY — it diagnoses, never fails: it always
# exits 0.
#
# It sources the canonical shared/lib/common.sh so the python row uses the SAME
# working-python resolver the gates use — which is what lets it tell a real interpreter
# apart from the Windows Store "App Execution Alias" stub (on PATH, but exits non-zero
# with empty stdout). We keep `set -uo pipefail` (NOT -e) so a single probe can't abort
# the table.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SELF_DIR")"

if [ -f "$ROOT/shared/lib/common.sh" ]; then
  # shellcheck source=../shared/lib/common.sh
  . "$ROOT/shared/lib/common.sh"
else
  # Degrade gracefully if the canonical lib is missing — doctor must still run.
  bd_have() { command -v "$1" >/dev/null 2>&1; }
  bd_have_python() { return 1; }
  BD_PYTHON=""
  bd_git_head() { git rev-parse --short HEAD 2>/dev/null || printf 'unknown'; }
fi

row() { printf '  %-11s %-8s %s\n' "$1" "$2" "$3"; }
rule() { printf '  %s\n' "----------------------------------------------------------------------"; }

echo "[doctor] backend-agentic-marketplace preflight"
rule
row "TOOL" "STATUS" "NOTE"
rule

# bash — the interpreter every gate runs under.
if bd_have bash; then
  row "bash" "present" "$(bash --version 2>/dev/null | head -n1)"
else
  row "bash" "absent" "no bash on PATH — gates cannot run"
fi

# git — used for commit stamps and staleness checks.
if bd_have git; then
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    row "git" "present" "work tree OK (HEAD $(bd_git_head))"
  else
    row "git" "degraded" "git found, but $ROOT is not a git work tree"
  fi
else
  row "git" "absent" "git not on PATH — commit/staleness info degrades to 'unknown'"
fi

# python — a WORKING interpreter, distinguished from the Store stub.
if bd_have_python; then
  pv="$($BD_PYTHON -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null || printf '?')"
  row "python" "present" "working interpreter: '$BD_PYTHON' (v$pv)"
elif command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1 || command -v py >/dev/null 2>&1; then
  row "python" "degraded" "a python is on PATH but NONE executes (Store stub?) — JSON via grep"
else
  row "python" "absent" "no python — JSON checks skip; gates still block via grep fallback"
fi

# jq — optional accelerator for the read-only guard's path extraction.
if bd_have jq; then
  row "jq" "present" "$(jq --version 2>/dev/null || printf 'jq')"
else
  row "jq" "absent" "optional — guard-readonly falls back to grep without it"
fi

# ShellCheck — optional dev-time lint; not needed at runtime.
if bd_have shellcheck; then
  scv="$(shellcheck --version 2>/dev/null | awk '/^version:/{print $2}' | head -n1)"
  row "shellcheck" "present" "v${scv:-?}"
else
  row "shellcheck" "absent" "optional lint — not required at runtime"
fi

rule
echo "[doctor] advisory only — exit 0 regardless of the rows above."
exit 0
