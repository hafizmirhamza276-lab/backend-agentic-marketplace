#!/usr/bin/env bash
# verify-build.sh — Stop gate. Advisory by default; hard-blocks (exit 2) only in
# enforce mode. Checks the change actually produced durable artifacts AND that the
# memory it relies on is path-accurate.
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
[ -f "$PLAN" ] || exit 0

[ -f "$PLAN" ] || note "no .claude/builder/PLAN.md — record the plan you implemented"
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
    MISSING="$(PROJECT="$PROJECT" python3 - "$INDEX" <<'PY' 2>/dev/null || true
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
    bd_warn "python3 absent — skipping index.json path-resolution check."
  fi
fi

if [ "$problems" -eq 0 ]; then
  bd_say "build verification passed."
  exit 0
fi

if bd_enforce; then
  printf '[builder] build verification FAILED with %s issue(s) above. Fix before finishing.\n' "$problems" >&2
  exit 2
fi
bd_warn "build verification found $problems issue(s) above (advisory; set enforce_gates=true or BUILDER_ENFORCE=1 to block)."
exit 0
