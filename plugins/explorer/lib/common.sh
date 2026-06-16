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
# Bug-fix mode artifacts. BUG.md is the persistent "Bug Brief" (like PLAN.md, it
# survives across sessions until the bug is done); the bugfix/ dir holds per-bug
# gate state (the run-results ledger, the reproduce-first override marker).
bd_bug()          { printf '%s/BUG.md'   "$(bd_builder_dir)"; }
bd_bugfix_dir()   { printf '%s/bugfix'   "$(bd_builder_dir)"; }

# --- environment probes ------------------------------------------------------
bd_have() { command -v "$1" >/dev/null 2>&1; }

# Resolve a WORKING python interpreter ONCE, at source time. On Windows, `python3`
# is frequently the Microsoft Store "App Execution Alias" stub: it is on PATH (so
# `command -v python3` succeeds) but exits non-zero with EMPTY stdout instead of
# running. We therefore never trust `command -v` — each candidate must actually
# execute `-c "pass"` (exit 0; the stub fails this). Candidates are tried in order;
# the first that runs wins. BD_PYTHON is the resolved command ("" if none works);
# it may carry args (e.g. "py -3"), so call sites use it UNQUOTED on purpose.
bd_resolve_python() {
  local cand
  for cand in python3 python "py -3"; do
    if $cand -c "pass" >/dev/null 2>&1; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 0
}
BD_PYTHON="$(bd_resolve_python)"

# True only when a WORKING python interpreter was resolved.
bd_have_python() { [ -n "${BD_PYTHON:-}" ]; }

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
    $BD_PYTHON - "$file" "$key" "$def" <<'PY' 2>/dev/null || printf '%s' "$def"
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

# Per-edit lint/type feedback loop enforce (independent of enforce_gates):
# BUILDER_ENFORCE=1 or settings.feedback_enforce=true makes the Stop gate refuse to
# pass while edited files still carry unaddressed lint/type findings.
bd_feedback_enforce() {
  [ "${BUILDER_ENFORCE:-}" = "1" ] && return 0
  [ "$(bd_setting feedback_enforce false)" = "true" ] && return 0
  return 1
}

# Bug-fix regression gate enforce (independent of enforce_gates; mirrors
# bd_feedback_enforce): BUILDER_ENFORCE=1 or settings.bugfix_enforce=true makes the
# Stop-time regression gate hard-block (exit 2) when the repro isn't green or a
# characterization test regressed. Advisory (warn only) otherwise.
bd_bugfix_enforce() {
  [ "${BUILDER_ENFORCE:-}" = "1" ] && return 0
  [ "$(bd_setting bugfix_enforce false)" = "true" ] && return 0
  return 1
}

# --- hook stdin parsing ------------------------------------------------------
# Reads the hook JSON payload (passed on stdin) once into BD_HOOK_JSON. Skips the
# read when stdin is a terminal (manual run / misconfig) so it can never block on a
# missing payload (F11).
bd_load_hook_input() {
  if [ -t 0 ]; then BD_HOOK_JSON=""; else BD_HOOK_JSON="$(cat 2>/dev/null || true)"; fi
  export BD_HOOK_JSON
}

# Flat grep fallback for bd_hook_field: grab the leaf key as a "key": "value".
# Trails with `|| true` so it can NEVER return non-zero — a non-zero return from a
# `TARGET="$(bd_hook_field …)"` caller under `set -e` is exactly the F1 fail-open bug.
bd_hook_field_grep() {
  local leaf="${1##*.}"
  printf '%s' "${BD_HOOK_JSON:-}" \
    | grep -oE "\"$leaf\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -n1 | sed -E 's/.*:[[:space:]]*"//; s/"$//' || true
}

# bd_hook_field <dotted.path>  e.g. tool_name  |  tool_input.file_path
# JSON is passed to python via an env var so the heredoc owns stdin (passing the
# JSON on stdin would collide with the `<py> -` program read from the heredoc).
bd_hook_field() {
  local path="$1"
  [ -n "${BD_HOOK_JSON:-}" ] || return 0
  if bd_have_python; then
    # If the interpreter fails for ANY reason, fall back to grep (same as the
    # no-python branch) so this function never propagates a non-zero exit (F1).
    BD_PATH="$path" BD_JSON="$BD_HOOK_JSON" $BD_PYTHON - <<'PY' 2>/dev/null || bd_hook_field_grep "$path"
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
    bd_hook_field_grep "$path"
  fi
}

# --- output helpers ----------------------------------------------------------
bd_say()  { printf '[builder] %s\n' "$*" >&2; }       # advisory -> shown to user (stderr)
bd_warn() { printf '[builder] ⚠ %s\n' "$*" >&2; }
# SessionStart context MUST go to STDOUT to be injected into Claude's context
# (stderr is surfaced only with --verbose). Use these for SessionStart guidance (F6).
bd_tell()     { printf '[builder] %s\n' "$*"; }
bd_tellwarn() { printf '[builder] ⚠ %s\n' "$*"; }
# bd_block <reason> : emit reason for Claude and exit 2 (PreToolUse block contract)
bd_block() { printf '%s\n' "$*" >&2; exit 2; }

# bd_normalize_path <path> : collapse '.' and '..' segments LEXICALLY (no filesystem
# access; works for non-existent paths). Keeps a leading '/' for absolute inputs.
# Used by the scope guard so a `..` segment can't escape the allow-zone (F2).
bd_normalize_path() {
  local input="$1" lead="" seg n=0
  local -a parts=()
  case "$input" in /*) lead="/" ;; esac
  set -f
  local IFS='/'
  for seg in $input; do
    case "$seg" in
      ''|.) ;;
      ..)
        if [ "$n" -gt 0 ] && [ "${parts[n-1]}" != ".." ]; then
          n=$((n-1))                      # pop one segment
        elif [ -z "$lead" ]; then
          parts[n]=".."; n=$((n+1))       # relative path may keep leading '..'
        fi ;;                             # absolute: '..' above root is dropped
      *) parts[n]="$seg"; n=$((n+1)) ;;
    esac
  done
  set +f
  local out="" i=0
  while [ "$i" -lt "$n" ]; do
    if [ -z "$out" ]; then out="${parts[i]}"; else out="$out/${parts[i]}"; fi
    i=$((i+1))
  done
  printf '%s' "$lead$out"
}

# --- STATUS contract (additive; consumed by the future pipeline conductor) ---
# A tiny, machine-readable status file per module at
#   ${CLAUDE_PROJECT_DIR}/.claude/<module>/STATUS.json
# with a fixed minimal schema:
#   { "module":<m>, "phase":<p>, "state":<s>, "commit":<short HEAD|"unknown">,
#     "coverage":<int|null>, "updated_at":<ISO-8601 UTC> }
# state ∈ {pending,running,blocked,done,failed}. Uses the working python when
# available, else a pure grep/sed fallback — and NEVER crashes on a python-less
# or stub-python host (same philosophy as bd_hook_field / bd_setting). The two
# writers emit byte-identical JSON so either path round-trips with either reader.
bd_status_file() { printf '%s/%s/STATUS.json' "$(bd_claude_dir)" "$1"; }

# bd_status_write <module> <phase> <state> [coverage]
bd_status_write() {
  local module="$1" phase="$2" state="$3" coverage="${4:-}"
  local dir file commit updated cov
  dir="$(bd_claude_dir)/$module"
  file="$dir/STATUS.json"
  mkdir -p "$dir" 2>/dev/null || true
  commit="$(bd_git_head)"; [ -n "$commit" ] || commit="unknown"
  # ISO-8601 UTC. `date -u` is present on every host we target (coreutils/Git Bash).
  updated="$(date -u +%FT%TZ 2>/dev/null || printf 'unknown')"
  if bd_have_python; then
    # The interpreter writes the file directly; if it fails for ANY reason we fall
    # through to the pure-shell writer below (so a stub python can never half-write).
    BD_F="$file" BD_M="$module" BD_P="$phase" BD_S="$state" \
    BD_C="$coverage" BD_CM="$commit" BD_T="$updated" \
    $BD_PYTHON - <<'PY' 2>/dev/null && return 0
import json, os
c = os.environ.get("BD_C", "")
doc = {
    "module":     os.environ.get("BD_M", ""),
    "phase":      os.environ.get("BD_P", ""),
    "state":      os.environ.get("BD_S", ""),
    "commit":     os.environ.get("BD_CM", "") or "unknown",
    "coverage":   int(c) if c.isdigit() else None,
    "updated_at": os.environ.get("BD_T", ""),
}
with open(os.environ["BD_F"], "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
PY
  fi
  # Pure-shell fallback: hand-emit the SAME JSON shape python would (indent=2).
  case "$coverage" in
    ''|*[!0-9]*) cov="null" ;;
    *)           cov="$coverage" ;;
  esac
  {
    printf '{\n'
    printf '  "module": "%s",\n'    "$module"
    printf '  "phase": "%s",\n'     "$phase"
    printf '  "state": "%s",\n'     "$state"
    printf '  "commit": "%s",\n'    "$commit"
    printf '  "coverage": %s,\n'    "$cov"
    printf '  "updated_at": "%s"\n' "$updated"
    printf '}\n'
  } > "$file" 2>/dev/null || true
  return 0
}

# bd_status_read <module> <key>  -> prints one field value ("" if absent or null)
bd_status_read() {
  local module="$1" key="$2" file line val
  file="$(bd_claude_dir)/$module/STATUS.json"
  [ -f "$file" ] || { printf ''; return 0; }
  if bd_have_python; then
    BD_F="$file" BD_K="$key" $BD_PYTHON - <<'PY' 2>/dev/null && return 0
import json, os
try:
    with open(os.environ["BD_F"]) as fh:
        v = json.load(fh).get(os.environ["BD_K"], "")
    print("" if v is None else (v if isinstance(v, str) else json.dumps(v)))
except Exception:
    print("")
PY
  fi
  # Pure-shell fallback: pull `"key": value` (string, number, or null) from the JSON.
  line="$(grep -oE "\"$key\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[^,}[:space:]]+)" "$file" 2>/dev/null | head -n1)"
  [ -n "$line" ] || { printf ''; return 0; }
  val="$(printf '%s' "$line" | sed -E 's/^[^:]*:[[:space:]]*//')"
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    null)  val="" ;;
  esac
  printf '%s' "$val"
  return 0
}
