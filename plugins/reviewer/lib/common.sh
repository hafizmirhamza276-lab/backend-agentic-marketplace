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
# Conductor (pipeline) plugin artifacts. The release gate writes RELEASE.md + STATUS here
# and reads its own settings (e.g. enforce_release) from .claude/pipeline/settings.json.
bd_pipeline_dir()      { printf '%s/pipeline'      "$(bd_claude_dir)"; }
bd_pipeline_settings() { printf '%s/settings.json' "$(bd_pipeline_dir)"; }
bd_release_md()        { printf '%s/RELEASE.md'    "$(bd_pipeline_dir)"; }

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

# bd_tree_digest : a stable digest of the CURRENT working tree's SOURCE state — the HEAD commit plus a
# hash of every uncommitted change (the tracked diff vs HEAD + the porcelain status for untracked
# files), EXCLUDING the gate's own .claude/ bookkeeping (module STATUS/memory, which is expected to be
# untracked in real projects and in the test fixtures alike, and must NOT count as a source change).
# A module STATUS records this so the release gate can FAIL a later STALE-but-green release — a prior
# green run must not certify new/uncommitted code (external review F-B). Prints "unknown" when git is
# unavailable / not a work tree; the release gate treats that conservatively (its dirty check still runs).
bd_tree_digest() {
  bd_have git || { printf 'unknown'; return; }
  local dir head body
  dir="$(bd_project_dir)"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf 'unknown'; return; }
  head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || printf 'nohead')"
  # `diff HEAD` = the CONTENT of every tracked change; `status --porcelain` = the rest (incl. untracked
  # file names). Both scoped with a `.claude` exclusion so the gate's own state never reads as a source
  # change. The combined stream is hashed by git's own object hasher (always present when git is).
  body="$( { git -C "$dir" diff HEAD -- . ':(exclude).claude' 2>/dev/null
             git -C "$dir" status --porcelain -- . ':(exclude).claude' 2>/dev/null
           } | git -C "$dir" hash-object --stdin 2>/dev/null || printf 'nohash' )"
  printf '%s' "$head:$body"
}

# --- settings ----------------------------------------------------------------
# bd_setting_at <file> <key> <default> : read a top-level key from ANY settings JSON, using
# the working python when present and a crude grep fallback otherwise (so it never DEPENDS
# on python). This is the generic primitive; bd_setting is the builder-settings
# specialization, and the pipeline release gate reads its own settings via this same form.
bd_setting_at() {
  local file="$1" key="$2" def="$3"
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
    # Pure-shell fallback — NESTING-AWARE (F-D) + COMPACT-AWARE (F-B2) + LAST-WINS (F-C1) + ESCAPE-AWARE
    # (F-C2). settings.json is USER-controlled (keys may be indented/reordered), so we CANNOT line-start-
    # anchor like bd_status_read; instead track STRUCTURAL object/array depth (mirroring ops_o2) and
    # accept a key ONLY at depth==1 (the root object's `{` opens depth 1; a key nested at depth>1 is
    # IGNORED). The key is compared as a STRING (not a regex), so the match is injection-proof.
    #
    # F-B2 (compact fail-open): the depth parser opens a level only on a line that ENDS in `{`/`[`, so a
    # COMPACT single-line object `{"enforce_release": true}` never reached depth==1 and silently returned
    # the (advisory) DEFAULT — a FAIL-OPEN for enforce_*/require_reproduction on a python-less host (python
    # read true, shell read false). FIX (normalize-then-reuse): NORMALIZE the document first — a string/
    # brace/bracket-aware char walk that inserts a newline after each STRUCTURAL `{`/`[`/`,` and before
    # each `}`/`]` — so a compact object is split one-key-per-line and the EXISTING proven depth parser
    # reaches it. The split respects string + escape state, so a brace/comma INSIDE a quoted value (or an
    # escaped `\"`) is never treated as a structural separator and cannot skew it (do NOT naively split).
    # F-C1 (precedence): on DUPLICATE top-level keys python's json.load keeps the LAST; the old shell
    # fallback short-circuited on the FIRST (`!found`). Aligned to LAST-WINS (no `!found` guard; `val` is
    # overwritten on each top-level match, emitted at END).
    # F-C2 (escaped quotes): the SURROUNDING quotes are stripped but escaped inner quotes are preserved,
    # then unescaped in the shell (\\ -> \, THEN \" -> ") so a value round-trips what bd_json_escape wrote.
    local v normalized
    normalized="$(awk '
      BEGIN { NL = "\n" }                                              #SETTING_NORMALIZE  (sentinel sets NL="" -> no split -> a compact object yields the default)
      { doc = doc $0 " " }                                            # join all lines (a JSON string never spans lines, so a space-join is lossless)
      END {
        n = length(doc); instr = 0; esc = 0; out = ""
        for (i = 1; i <= n; i++) {
          c = substr(doc, i, 1)
          if (instr) {                                                # inside a string: only an UNescaped " ends it
            out = out c
            if (esc)            esc = 0
            else if (c == "\\") esc = 1
            else if (c == "\"") instr = 0
          } else if (c == "\"")          { instr = 1; out = out c }
          else if (c == "{" || c == "[") out = out c NL               # opener -> newline AFTER (so the line ends in {/[)
          else if (c == ",")             out = out c NL               # top-of-value comma -> newline AFTER (one key per line)
          else if (c == "}" || c == "]") out = out NL c               # closer -> newline BEFORE (so a lone }/] closes depth)
          else                           out = out c
        }
        printf "%s\n", out
      }
    ' "$file" 2>/dev/null)"
    v=$(printf '%s\n' "$normalized" | awk -v want="$key" '
      BEGIN { depth=0; found=0 }
      {
        line=$0
        if (depth==1 && match(line, /^[[:space:]]*"[^"]*"[[:space:]]*:/)) {   #SETTING_DEPTH_RE  last-wins: no !found guard
          k=line; sub(/^[[:space:]]*"/,"",k); sub(/".*/,"",k)            # the quoted key name on this line
          if (k==want) {
            v=line
            sub(/^[[:space:]]*"[^"]*"[[:space:]]*:[[:space:]]*/,"",v)    # strip indent + key + colon
            sub(/[[:space:]]*,[[:space:]]*$/,"",v)                       # drop a trailing JSON comma
            sub(/[[:space:]]+$/,"",v)                                    # drop trailing whitespace
            if (v ~ /^".*"$/) v=substr(v,2,length(v)-2)                  # strip ONLY the surrounding quotes (keep escaped inner ones)   #SETTING_QSTRIP
            val=v; found=1                                               # LAST top-level match wins (F-C1)
          }
        }
        # Structural depth AFTER the key check (an opener on THIS line raises depth for SUBSEQUENT lines).
        if (line ~ /[{[][[:space:]]*$/)                                 depth++
        else if (line ~ /^[[:space:]]*[]}][[:space:]]*,?[[:space:]]*$/) depth--
      }
      END { if (found) printf "%s", val }
    ' 2>/dev/null)
    # F-C2: reverse bd_json_escape (\\ -> \, THEN \" -> ") so an escaped value round-trips.
    v="${v//\\\\/\\}"      #SETTING_UNESCAPE
    v="${v//\\\"/\"}"
    # F-B2 safety net: a key the (normalized) parser still can't resolve falls back to the default — but
    # WARN so a silent enforcement DOWNGRADE on a python-less host can never pass unnoticed. (The file is
    # known to exist here; a missing file already early-returned the default above WITHOUT warning.)
    if [ -z "$v" ]; then
      printf "[bd] WARN: settings key '%s' unresolved in %s; check format\n" "$key" "$file" >&2
    fi
    printf '%s' "${v:-$def}"
  fi
}

# bd_setting <key> <default>  -> reads .claude/builder/settings.json
bd_setting() { bd_setting_at "$(bd_settings)" "$1" "$2"; }

# Gates enforce (hard-block) only when asked. Default = advisory.
bd_enforce() {
  [ "${BUILDER_ENFORCE:-}" = "1" ] && return 0
  [ "$(bd_setting enforce_gates false)" = "true" ] && return 0
  return 1
}

# Release gate enforce (pipeline conductor). Advisory by default; hard-blocks (exit 2)
# only when PIPELINE_ENFORCE=1 or settings.enforce_release=true in
# .claude/pipeline/settings.json. Mirrors bd_enforce so the gate stays opt-in.
bd_release_enforce() {
  [ "${PIPELINE_ENFORCE:-}" = "1" ] && return 0
  [ "$(bd_setting_at "$(bd_pipeline_settings)" enforce_release false)" = "true" ] && return 0
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
#
# Windows backslash robustness (B): Claude Code may hand us '\'-separated paths on
# Windows, so we fold EVERY '\' to '/' BEFORE collapsing '.'/'..'. Without this pre-step
# a backslashed traversal such as `a\..\b` or `.claude\explorer\..\..\evil` would be seen
# as ONE opaque segment and slip straight past the '..' logic (the allow-zone escape that
# F2 guards against). Trade-off: a LITERAL backslash in a POSIX filename is consequently
# treated as a path separator — acceptable for a Windows-first tool, and pure forward-slash
# paths are completely unaffected (their behavior is byte-for-byte unchanged). Both
# guard-readonly.sh and guard-scope.sh route through this one function, so the conversion
# applies consistently in BOTH.
bd_normalize_path() {
  local input="$1" lead="" seg n=0
  local -a parts=()
  input=${input//\\//}                 # (B) '\' -> '/' before ANY segment analysis
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

# bd_json_escape <string> : minimal JSON string-BODY escaper for the PURE-SHELL writer (A).
# Doubles backslashes and escapes double-quotes, and neutralizes the control characters
# that would otherwise break a one-line JSON string (CR dropped; LF/TAB -> space) so even
# an ADVERSARIAL field value still emits SYNTACTICALLY VALID JSON. Order matters:
# backslashes are doubled FIRST, then quotes — otherwise the backslash we add in front of a
# quote would itself be re-doubled. For safe/enum inputs (no '\', '"', CR, LF, or TAB) every
# substitution is a no-op, so the shell writer stays BYTE-IDENTICAL to the python writer and
# the existing round-trip tests keep passing. (Unlike python json with ensure_ascii, this
# leaves non-ASCII as raw UTF-8 — still valid JSON, merely not \uXXXX-escaped; that
# divergence only ever occurs for non-safe inputs, which the contract allows.)
bd_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}      # \  -> \\   (MUST run first)
  s=${s//\"/\\\"}      # "  -> \"
  s=${s//$'\r'/}       # CR -> drop
  s=${s//$'\n'/ }      # LF -> space
  s=${s//$'\t'/ }      # TAB -> space
  printf '%s' "$s"
}

# bd_status_write <module> <phase> <state> [coverage] [k1=v1 k2=v2 ...]
# (A, extended) Optional trailing `key=value` pairs are merged into STATUS.json AFTER the six
# fixed fields, in the order given. A value that is ALL digits becomes a JSON NUMBER; any other
# value (including the empty string) becomes a JSON STRING — escaped via bd_json_escape in the
# shell writer and by json.dump in the python writer, so even an adversarial value stays valid
# JSON. This is the bridge the release gate needs: the auditor records `high=/med=/low=` counts
# (read back generically by bd_status_read, enforced as 0-high by verify-release.sh).
#
# INVARIANTS this extension preserves (so the existing 16 + 66 tests stay green):
#   - With NO extras the output is BYTE-IDENTICAL to the prior writer (still exactly 8 lines:
#     `{`, six fields, `}`), so the python-free 8-line control and the python<->shell
#     byte-agreement / round-trip tests are unaffected.
#   - The python and pure-shell writers emit BYTE-IDENTICAL JSON for the same SAFE inputs
#     (ASCII keys/values, no leading-zero digit strings) — exactly the inputs this project
#     emits — so either writer round-trips with either reader, extras included. (The same
#     pre-existing divergence the fixed fields already carry applies: a non-ASCII value is
#     \uXXXX-escaped by python but left as raw UTF-8 by the shell, and a zero-padded digit
#     string is normalized by python's int() but kept verbatim by the shell — both remain
#     valid JSON; neither shape occurs for the enum states / unpadded counts in use.)
#   - A 3-arg call (coverage omitted), e.g. `bd_status_write pipeline release done`, still works:
#     the `shift 4` that collects extras only runs when there ARE extras ($# > 4).
bd_status_write() {
  local module="$1" phase="$2" state="$3" coverage="${4:-}"
  local dir file commit updated cov
  # Everything after the 4th positional is an extra k=v pair. Guard the shift so a 3-arg call
  # (no coverage) never errors with "shift count out of range".
  local -a extras=()
  if [ "$#" -gt 4 ]; then shift 4; extras=("$@"); fi
  dir="$(bd_claude_dir)/$module"
  file="$dir/STATUS.json"
  mkdir -p "$dir" 2>/dev/null || true
  commit="$(bd_git_head)"; [ -n "$commit" ] || commit="unknown"
  # ISO-8601 UTC. `date -u` is present on every host we target (coreutils/Git Bash).
  updated="$(date -u +%FT%TZ 2>/dev/null || printf 'unknown')"
  if bd_have_python; then
    # The interpreter writes the file directly; if it fails for ANY reason we fall
    # through to the pure-shell writer below (so a stub python can never half-write).
    # Extras ride in on argv (ordered) — `python -` reads the program from the heredoc on
    # stdin, so sys.argv[1:] carries the k=v pairs. The `${extras[@]+...}` guard keeps the
    # empty-array expansion safe under callers' `set -u`.
    BD_F="$file" BD_M="$module" BD_P="$phase" BD_S="$state" \
    BD_C="$coverage" BD_CM="$commit" BD_T="$updated" \
    $BD_PYTHON - ${extras[@]+"${extras[@]}"} <<'PY' 2>/dev/null && return 0
import json, os, sys
c = os.environ.get("BD_C", "")
doc = {
    "module":     os.environ.get("BD_M", ""),
    "phase":      os.environ.get("BD_P", ""),
    "state":      os.environ.get("BD_S", ""),
    "commit":     os.environ.get("BD_CM", "") or "unknown",
    "coverage":   int(c) if c.isdigit() else None,
    "updated_at": os.environ.get("BD_T", ""),
}
for pair in sys.argv[1:]:
    k, sep, v = pair.partition("=")
    if not sep:
        continue                       # no '=' -> not a pair; skip (mirrors the shell writer)
    doc[k] = int(v) if v.isdigit() else v
with open(os.environ["BD_F"], "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
PY
  fi
  # Pure-shell fallback: hand-emit the SAME JSON shape python would (indent=2). Every
  # STRING field is JSON-escaped FIRST (A) so an adversarial value (a stray '"', '\', or a
  # newline) can never break the JSON; for the safe/enum inputs this project actually emits,
  # the escape is a no-op, so this stays byte-identical to the python writer.
  local e_module e_phase e_state e_commit e_updated
  e_module="$(bd_json_escape "$module")"
  e_phase="$(bd_json_escape "$phase")"
  e_state="$(bd_json_escape "$state")"
  e_commit="$(bd_json_escape "$commit")"
  e_updated="$(bd_json_escape "$updated")"
  case "$coverage" in
    ''|*[!0-9]*) cov="null" ;;
    *)           cov="$coverage" ;;
  esac
  # Build the field bodies (`  "key": value`, NO trailing comma) in order: the six fixed fields
  # then any extras. Joining with ",\n" at emit time puts a comma after every field EXCEPT the
  # last — for any number of extras — which is exactly what json.dump(indent=2) produces, so
  # the no-extras case stays the prior 8-line file and the with-extras case matches python.
  local -a fields=()
  local line
  printf -v line '  "module": "%s"'     "$e_module";  fields+=("$line")
  printf -v line '  "phase": "%s"'      "$e_phase";   fields+=("$line")
  printf -v line '  "state": "%s"'      "$e_state";   fields+=("$line")
  printf -v line '  "commit": "%s"'     "$e_commit";  fields+=("$line")
  printf -v line '  "coverage": %s'     "$cov";       fields+=("$line")
  printf -v line '  "updated_at": "%s"' "$e_updated"; fields+=("$line")
  local pair k v jv ek
  for pair in ${extras[@]+"${extras[@]}"}; do
    k="${pair%%=*}"; v="${pair#*=}"
    [ "$pair" = "$k" ] && continue     # no '=' -> not a pair; skip (mirrors the python writer)
    case "$v" in
      ''|*[!0-9]*) jv="\"$(bd_json_escape "$v")\"" ;;   # string  -> quoted, escaped body
      *)           jv="$v" ;;                            # all digits -> bare JSON number
    esac
    ek="$(bd_json_escape "$k")"
    printf -v line '  "%s": %s' "$ek" "$jv"; fields+=("$line")
  done
  {
    printf '{\n'
    local i=0 n=${#fields[@]}
    while [ "$i" -lt "$n" ]; do
      if [ "$i" -lt "$((n - 1))" ]; then printf '%s,\n' "${fields[i]}"; else printf '%s\n' "${fields[i]}"; fi
      i=$((i + 1))
    done
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
  # Pure-shell fallback: pull `"key": value` (string, number, or null) from the JSON. The grep is
  # ANCHORED to line-start (^[[:space:]]*"key") so it matches ONLY a TOP-LEVEL key: both writers
  # (python json.dump indent=2 AND the shell writer above) emit one key per line with a 2-space
  # indent, so every real top-level key begins its own line. WITHOUT the anchor a `"key": v`
  # substring INSIDE a string value (or a nested object) could be returned by head -n1 BEFORE the
  # real key — making the release gate MISREAD auditor high= / reviewer|ops blocking= (a false block
  # when the real count is 0, or — the dangerous direction — a FAIL-OPEN when an earlier `"high": 0`
  # substring masks a real non-zero count). The python reader is unaffected (json.load already keys
  # on the real top-level field). The extraction sed below is unchanged: its `[^:]*` spans the
  # leading indent + the quoted key (neither holds a ':'), so the first ':' it stops at is still the
  # key/value separator. (Line-start anchoring is valid ONLY because the writer is pretty/one-key-
  # per-line; it would be WRONG for a compact single-line writer — but this project never emits one.)
  # The quoted-value alternative is "(\\.|[^"\\])*" — it spans escaped chars (\" / \\) instead of the old
  # "[^"]*" which TERMINATED at the first escaped \" (F-C2), truncating any value bd_json_escape wrote
  # with an embedded quote/backslash. (Line-start still anchors to the real top-level key, F-#8.)
  line="$(grep -oE "^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*(\"(\\\\.|[^\"\\\\])*\"|[^,}[:space:]]+)" "$file" 2>/dev/null | head -n1)"  #STATUS_KEY_RE
  [ -n "$line" ] || { printf ''; return 0; }
  val="$(printf '%s' "$line" | sed -E 's/^[^:]*:[[:space:]]*//')"
  case "$val" in
    \"*\")
      val="${val#\"}"; val="${val%\"}"     # strip the surrounding quotes
      val="${val//\\\\/\\}"                 # F-C2: unescape \\ -> \  (reverse bd_json_escape step 1)
      val="${val//\\\"/\"}"                 # then       \" -> "      (reverse bd_json_escape step 2)   #STATUS_UNESCAPE
      ;;
    null)  val="" ;;
  esac
  printf '%s' "$val"
  return 0
}
