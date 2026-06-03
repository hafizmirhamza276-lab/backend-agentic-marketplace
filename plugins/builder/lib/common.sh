#!/usr/bin/env bash
# common.sh — shared helpers for the `builder` plugin scripts.
# Sourced by every script in scripts/. Pure bash with optional python3 for
# robust JSON parsing; everything degrades gracefully when python3 is absent.

# --- paths -------------------------------------------------------------------
bd_project_dir() { printf '%s' "${CLAUDE_PROJECT_DIR:-$PWD}"; }
bd_claude_dir()   { printf '%s/.claude' "$(bd_project_dir)"; }
bd_builder_dir()  { printf '%s/builder'  "$(bd_claude_dir)"; }
bd_explorer_dir() { printf '%s/explorer' "$(bd_claude_dir)"; }
bd_specs_dir()    { printf '%s/specs'    "$(bd_claude_dir)"; }
bd_settings()     { printf '%s/settings.json' "$(bd_builder_dir)"; }
bd_plan()         { printf '%s/PLAN.md'    "$(bd_builder_dir)"; }
bd_changelog()    { printf '%s/CHANGELOG.md' "$(bd_builder_dir)"; }

# --- environment probes ------------------------------------------------------
bd_have() { command -v "$1" >/dev/null 2>&1; }
bd_have_python() { bd_have python3; }

bd_git_head() {
  if bd_have git && git -C "$(bd_project_dir)" rev-parse --short HEAD >/dev/null 2>&1; then
    git -C "$(bd_project_dir)" rev-parse --short HEAD
  else
    printf 'unknown'
  fi
}

# --- settings ----------------------------------------------------------------
# bd_setting <key> <default>  -> reads .claude/builder/settings.json
bd_setting() {
  local key="$1" def="$2" file; file="$(bd_settings)"
  [ -f "$file" ] || { printf '%s' "$def"; return; }
  if bd_have_python; then
    python3 - "$file" "$key" "$def" <<'PY' 2>/dev/null || printf '%s' "$def"
import json, sys
f, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(f) as fh:
        v = json.load(fh).get(key, default)
    print(("true" if v else "false") if isinstance(v, bool) else v)
except Exception:
    print(default)
PY
  else
    # crude grep fallback: "key": value
    local v
    v=$(grep -oE "\"$key\"[[:space:]]*:[[:space:]]*[^,}]+" "$file" 2>/dev/null \
        | head -n1 | sed -E "s/.*:[[:space:]]*//; s/\"//g; s/[[:space:]]+$//")
    printf '%s' "${v:-$def}"
  fi
}

# Gates enforce (hard-block) only when asked. Default = advisory.
bd_enforce() {
  [ "${BUILDER_ENFORCE:-}" = "1" ] && return 0
  [ "$(bd_setting enforce_gates false)" = "true" ] && return 0
  return 1
}

# --- hook stdin parsing ------------------------------------------------------
# Reads the hook JSON payload (passed on stdin) once into BD_HOOK_JSON.
bd_load_hook_input() { BD_HOOK_JSON="$(cat 2>/dev/null || true)"; export BD_HOOK_JSON; }

# bd_hook_field <dotted.path>  e.g. tool_name  |  tool_input.file_path
# JSON is passed to python via an env var so the heredoc owns stdin (passing the
# JSON on stdin would collide with the `python3 -` program read from the heredoc).
bd_hook_field() {
  local path="$1"
  [ -n "${BD_HOOK_JSON:-}" ] || return 0
  if bd_have_python; then
    BD_PATH="$path" BD_JSON="$BD_HOOK_JSON" python3 - <<'PY' 2>/dev/null
import json, os
try:
    obj = json.loads(os.environ["BD_JSON"])
    for part in os.environ["BD_PATH"].split("."):
        obj = obj.get(part, "") if isinstance(obj, dict) else ""
    print(obj if isinstance(obj, str) else json.dumps(obj))
except Exception:
    print("")
PY
  else
    # fallback: grab the leaf key as a flat "key": "value"
    local leaf="${path##*.}"
    printf '%s' "$BD_HOOK_JSON" \
      | grep -oE "\"$leaf\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
      | head -n1 | sed -E 's/.*:[[:space:]]*"//; s/"$//'
  fi
}

# --- output helpers ----------------------------------------------------------
bd_say()  { printf '[builder] %s\n' "$*" >&2; }       # advisory -> shown to user
bd_warn() { printf '[builder] ⚠ %s\n' "$*" >&2; }
# bd_block <reason> : emit reason for Claude and exit 2 (PreToolUse block contract)
bd_block() { printf '%s\n' "$*" >&2; exit 2; }
