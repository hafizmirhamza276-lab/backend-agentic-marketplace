#!/usr/bin/env bash
# lib-audit-checks.sh — deterministic static AUDIT DETECTORS for the `auditor` plugin.
#
# This library productizes THIS project's own audit methodology (the F1–F13 class of
# findings) as REGRESSION detectors: each one fires only when a specific failure class is
# re-introduced, and is SILENT on the clean, post-fix tree. It is sourced by verify-audit.sh
# (the Stop gate) and by the test ladder; every detector is also INDIVIDUALLY CALLABLE
# (`audit_d1`, `audit_d2`, …) so a unit test can point it at a fixture and assert it fires /
# stays silent.
#
# OUTPUT — every detector prints zero or more findings, one per line, TAB-separated:
#     <SEVERITY>\t<detector>\t<file:line-or-path>\t<message>
# SEVERITY ∈ HIGH | MEDIUM | LOW | ADVISORY.
#   HIGH      a gate/module is SILENTLY broken or bypassable — feeds the release gate's
#             0-high enforcement (verify-release.sh reads `auditor high`).
#   MEDIUM    a real defect that does not silently break a gate (portability / coverage gap).
#   LOW       hygiene (line endings, exec bit, shellcheck errors).
#   ADVISORY  informational only — NEVER gates, and is EXCLUDED from the high/med/low tally.
#
# PURITY — pure shell + awk/grep/sed/diff/find/git. No python DEPENDENCY (a JSON validator is
# used opportunistically when present, but its absence never fails a detector). Identical
# behavior on a python-less / Windows-stub host, matching the rest of this marketplace.
#
# CALIBRATION — detectors scan by ROLE, never a blanket `*.sh` glob:
#   * "hook scripts"  = the command scripts resolved from each plugin's hooks/hooks.json
#   * "the lib"       = shared/lib/common.sh (the sourced fail-open / normalize logic)
#   * "manifests"     = .claude-plugin/marketplace.json + plugins/*/.claude-plugin/plugin.json
#   * "agents"        = plugins/*/agents/*.md
# This both matches the audit's wording ("a hook script that…", "a PreToolUse guard…") and
# keeps THIS file — which necessarily contains the very patterns it searches for — out of its
# own scan, so the auditor never false-flags itself.

# Scan root. Lazily resolved so a unit test can target a fixture:  AUDIT_ROOT=/fixture audit_d1
_audit_root() { printf '%s' "${AUDIT_ROOT:-$(bd_project_dir)}"; }

# Emit one finding line. Messages are single-line (callers keep them tab/newline-free).
_audit_emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

# Path relative to the scan root, for readable findings.
_audit_rel() { printf '%s' "${2#"$1"/}"; }

# --- hooks.json parsing ------------------------------------------------------
# Walk every plugins/*/hooks/hooks.json and emit ONE record per command entry:
#     <event>\t<matcher>\t<abs-script-path>\t<has_timeout:0|1>
# `${CLAUDE_PLUGIN_ROOT}` in each command is resolved to that plugin's root (the directory
# two levels above hooks/hooks.json). Pure awk over the predictable pretty-printed JSON: it
# tracks the current event block + matcher, and for each {…} hook object records the command
# script and whether a "timeout" key appeared before the object closed.
_audit_hook_records() {
  local root f proot
  root="$(_audit_root)"
  for f in "$root"/plugins/*/hooks/hooks.json; do
    [ -f "$f" ] || continue
    proot="$(dirname "$(dirname "$f")")"
    awk -v root="$proot" '
      /"(SessionStart|PreToolUse|PostToolUse|SubagentStop|Stop|UserPromptSubmit|PreCompact|Notification|SessionEnd)"[[:space:]]*:[[:space:]]*\[/ {
        if (match($0, /"(SessionStart|PreToolUse|PostToolUse|SubagentStop|Stop|UserPromptSubmit|PreCompact|Notification|SessionEnd)"/)) {
          event=substr($0, RSTART+1, RLENGTH-2); matcher=""
        }
        next
      }
      /"matcher"[[:space:]]*:/ { v=$0; sub(/.*"matcher"[[:space:]]*:[[:space:]]*"/,"",v); sub(/".*/,"",v); matcher=v; next }
      /"command"[[:space:]]*:/ {
        v=$0; sub(/.*"command"[[:space:]]*:[[:space:]]*"/,"",v); sub(/"[[:space:]]*,?[[:space:]]*$/,"",v)
        gsub(/\\"/,"",v); gsub(/"/,"",v)                 # drop the escaped + plain quotes
        if (v ~ /CLAUDE_PLUGIN_ROOT/) { sub(/^[^}]*}/,"",v); cur=root v } else { cur=v }
        pending=1; has_to=0; next
      }
      /"timeout"[[:space:]]*:/ { if (pending) has_to=1; next }
      /^[[:space:]]*}[[:space:]]*,?[[:space:]]*$/ { if (pending) { print event "\t" matcher "\t" cur "\t" has_to; pending=0 } next }
    ' "$f"
  done
}

# Unique absolute paths of every hook command script in the tree.
_audit_hook_scripts() { _audit_hook_records | awk -F'\t' 'NF>=3 && $3!=""{print $3}' | sort -u; }

# ===========================================================================
# D1 — fail-open (HIGH, F1): a hook script (or the sourced lib) that trusts `command -v
# python3` as a presence test, OR captures a value from a RAW python command-substitution
# under `set -e` with no `|| fallback`. Either re-opens the F1 fail-open: the Windows Store
# `python3` stub is on PATH but exits non-zero with empty stdout, so the guard aborts (under
# set -e) or treats the stub as a working interpreter — and the gate silently does nothing.
# ===========================================================================
audit_d1() {
  local root rel file; root="$(_audit_root)"
  { _audit_hook_scripts; [ -f "$root/shared/lib/common.sh" ] && printf '%s\n' "$root/shared/lib/common.sh"; } \
    | sort -u | while IFS= read -r file; do
    [ -f "$file" ] || continue
    rel="$(_audit_rel "$root" "$file")"
    # (a) `command -v python<N>` (optionally quoted) as a presence test — BROADENED beyond the
    # literal `python3` (F-E: `command -v python`, `command -v python2`, `command -v "python3"` all
    # evaded the old literal match). Skips comment lines + the resolver's own note. `command -v "$1"`
    # (bd_have) never matches — the token after `-v ` must be a literal python interpreter name.
    awk '!/^[[:space:]]*#/ && /command -v[[:space:]]+"?python[0-9]*"?/ {print FNR} #D1_CMDV_RE' "$file" 2>/dev/null | while IFS= read -r n; do
      _audit_emit HIGH d1-fail-open "$rel:$n" "uses 'command -v python…' as a presence test — the Windows Store python stub passes it and the gate fails open (F1); resolve a WORKING interpreter (bd_resolve_python/bd_have_python)"
    done
    # (b) a value captured from a RAW interpreter command-substitution under `set -e` with no
    # '|| fallback' — BROADENED to BOTH `$(…)` AND backtick `` `…` `` forms (F-E: the backtick form
    # `var=`python …`` evaded the old $(-only match). A failed/stub interpreter aborts the hook
    # before its check runs (F1).
    if grep -Eq '^[[:space:]]*set[[:space:]]+-[a-z]*e' "$file" 2>/dev/null; then
      awk '!/^[[:space:]]*#/ && /=[[:space:]]*"?(\$\(|`)/ && (/python/ || /\$BD_PYTHON/) && !/\|\|/ {print FNR}' "$file" 2>/dev/null | while IFS= read -r n; do
        _audit_emit HIGH d1-fail-open "$rel:$n" "captures a value from a raw python/\$BD_PYTHON command-substitution (\$(…) or backticks) under 'set -e' with no '|| fallback' — a failed/stub interpreter aborts the hook before its check runs (F1)"
      done
    fi
  done
}

# ===========================================================================
# D2 — traversal (HIGH, F2): a PreToolUse path guard that decides the allow-zone on a RAW,
# un-normalized path (no bd_normalize_path). A `..`/backslash segment then keeps the allowed
# prefix as a substring while resolving elsewhere, escaping the zone.
# ===========================================================================
audit_d2() {
  local root rel script; root="$(_audit_root)"
  _audit_hook_records | awk -F'\t' '$1=="PreToolUse" && $3!=""{print $3}' | sort -u | while IFS= read -r script; do
    [ -f "$script" ] || continue
    rel="$(_audit_rel "$root" "$script")"
    # A path guard reads a path field; its allow-zone test must run on a NORMALIZED path. BROADENED
    # (F-E): the old check accepted mere TOKEN PRESENCE of `bd_normalize_path` (`grep -q`), so a guard
    # that only MENTIONS it in a comment — while still matching its allow-zone against a RAW path —
    # evaded the detector. We now require a real, NON-COMMENT ASSIGNMENT from bd_normalize_path
    # (`var=…bd_normalize_path…`): a comment-only mention, or no normalization at all, fires. (The
    # marker line below is the load-bearing one the test ladder's sentinel reverts.)
    if grep -Eq 'file_path|notebook_path|tool_input' "$script" 2>/dev/null \
       && ! grep -Eq '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*bd_normalize_path' "$script" 2>/dev/null; then   #D2_NORM_RE
      _audit_emit HIGH d2-traversal "$rel" "PreToolUse guard matches its allow-zone on a raw, un-normalized path (bd_normalize_path is never assigned to the checked variable — only mentioned, or absent) — a '..' or backslash segment escapes the zone (F2)"
    fi
  done
}

# ===========================================================================
# D3 — notebook-gap (MEDIUM, F9): a Write|Edit PreToolUse matcher that omits NotebookEdit, or
# a guard that reads file_path but never notebook_path — a notebook write slips past unguarded.
# ===========================================================================
audit_d3() {
  local root rel; root="$(_audit_root)"
  _audit_hook_records | awk -F'\t' '$1=="PreToolUse" && $2 ~ /(Write|Edit|MultiEdit)/ && $2 !~ /NotebookEdit/ && $3!=""{print $2 "\t" $3}' \
    | sort -u | while IFS="$(printf '\t')" read -r matcher script; do
    rel="$(_audit_rel "$root" "$script")"
    _audit_emit MEDIUM d3-notebook-gap "$rel" "PreToolUse matcher '$matcher' omits NotebookEdit — a NotebookEdit write is not matched by this guard (F9)"
  done
  _audit_hook_records | awk -F'\t' '$1=="PreToolUse" && $3!=""{print $3}' | sort -u | while IFS= read -r script; do
    [ -f "$script" ] || continue
    rel="$(_audit_rel "$root" "$script")"
    if grep -q 'file_path' "$script" 2>/dev/null && ! grep -q 'notebook_path' "$script" 2>/dev/null; then
      _audit_emit MEDIUM d3-notebook-gap "$rel" "guard reads file_path but never notebook_path — a NotebookEdit target is unguarded (F9)"
    fi
  done
}

# ===========================================================================
# D4 — stdin-block (MEDIUM, F11): a hook script (or the lib) that reads stdin via `cat`
# without an `[ -t 0 ]` terminal guard — it blocks forever if ever invoked with no payload.
# ===========================================================================
audit_d4() {
  local root rel file; root="$(_audit_root)"
  { _audit_hook_scripts; [ -f "$root/shared/lib/common.sh" ] && printf '%s\n' "$root/shared/lib/common.sh"; } \
    | sort -u | while IFS= read -r file; do
    [ -f "$file" ] || continue
    rel="$(_audit_rel "$root" "$file")"
    if grep -Eq '\$\(cat([[:space:]]|\))|cat[[:space:]]+2>/dev/null' "$file" 2>/dev/null \
       && ! grep -q '\-t 0' "$file" 2>/dev/null; then
      _audit_emit MEDIUM d4-stdin-block "$rel" "reads stdin via 'cat' with no '[ -t 0 ]' guard — blocks forever if the hook is invoked without a payload (F11)"
    fi
  done
}

# ===========================================================================
# D5 — sessionstart-stderr (MEDIUM, F6): a SessionStart-wired script that emits its guidance
# ONLY to stderr (bd_say/bd_warn/>&2) with nothing to stdout. SessionStart injects only STDOUT
# into Claude's context, so the nudge never reaches the model.
# ===========================================================================
audit_d5() {
  local root rel script; root="$(_audit_root)"
  _audit_hook_records | awk -F'\t' '$1=="SessionStart" && $3!=""{print $3}' | sort -u | while IFS= read -r script; do
    [ -f "$script" ] || continue
    rel="$(_audit_rel "$root" "$script")"
    if grep -Eq 'bd_say|bd_warn|>&2' "$script" 2>/dev/null \
       && ! grep -Eq 'bd_tell|bd_tellwarn' "$script" 2>/dev/null \
       && ! grep -Eq '^[[:space:]]*(echo|printf)' "$script" 2>/dev/null; then
      _audit_emit MEDIUM d5-sessionstart-stderr "$rel" "SessionStart guidance goes only to stderr (bd_say/bd_warn/>&2); SessionStart injects STDOUT into Claude's context — use bd_tell (F6)"
    fi
  done
}

# ===========================================================================
# D6 — hook-contract-broken (HIGH): a hooks.json command whose script does not exist, or is
# not tracked as executable (mode 100755). Either way Claude Code can't run it and the hook
# SILENTLY never fires — the worst failure for a safety gate.
# ===========================================================================
audit_d6() {
  local root rel script mode; root="$(_audit_root)"
  _audit_hook_records | awk -F'\t' 'NF>=3 && $3!=""{print $3}' | sort -u | while IFS= read -r script; do
    rel="$(_audit_rel "$root" "$script")"
    if [ ! -f "$script" ]; then
      _audit_emit HIGH d6-hook-contract "$rel" "hooks.json references a command script that does not exist — the hook silently never runs"
      continue
    fi
    mode=""
    bd_have git && mode="$(git -C "$root" ls-files -s -- "$rel" 2>/dev/null | awk '{print $1; exit}')"
    if [ -n "$mode" ]; then
      [ "$mode" = "100755" ] || _audit_emit HIGH d6-hook-contract "$rel" "hook script is tracked mode $mode (not 100755/+x) — Claude Code cannot execute it; the hook silently never runs"
    elif [ ! -x "$script" ]; then
      _audit_emit HIGH d6-hook-contract "$rel" "hook script is not executable (+x) — the hook silently never runs"
    fi
  done
}

# ===========================================================================
# D6b — hook-no-timeout (MEDIUM): a hooks.json command entry with no `timeout`. A hung hook
# can stall the whole turn; an explicit per-hook timeout bounds the blast radius (F11).
# ===========================================================================
audit_d6b() {
  local root rel; root="$(_audit_root)"
  _audit_hook_records | while IFS="$(printf '\t')" read -r event matcher script has_to; do
    [ "${has_to:-1}" = "0" ] || continue
    rel="$(_audit_rel "$root" "$script")"
    _audit_emit MEDIUM d6b-hook-no-timeout "$rel" "hooks.json command entry ($event) has no 'timeout' — a hung hook can stall the turn (F11)"
  done
}

# ===========================================================================
# D7 — manifest (HIGH): a plugin.json / marketplace.json that does not parse, or a marketplace
# `source` that is not a directory — either makes a plugin (or the whole marketplace) fail to
# load. JSON validity uses jq/node/python when available; its absence never fires (the
# source-dir check below is pure shell and always runs).
# ===========================================================================
_audit_json_valid() {  # 0 valid · 1 invalid · 2 no validator available
  local f="$1"
  if bd_have jq;        then jq -e . "$f" >/dev/null 2>&1; return $(( $? == 0 ? 0 : 1 )); fi
  if bd_have node;      then node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$f" >/dev/null 2>&1; return $(( $? == 0 ? 0 : 1 )); fi
  if bd_have_python;    then $BD_PYTHON -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" >/dev/null 2>&1; return $(( $? == 0 ? 0 : 1 )); fi
  return 2
}
audit_d7() {
  local root rel f mk src d rc; root="$(_audit_root)"
  for f in "$root"/.claude-plugin/marketplace.json "$root"/plugins/*/.claude-plugin/plugin.json; do
    [ -f "$f" ] || continue
    rel="$(_audit_rel "$root" "$f")"
    _audit_json_valid "$f"; rc=$?
    [ "$rc" = "1" ] && _audit_emit HIGH d7-manifest "$rel" "manifest JSON does not parse — the plugin/marketplace will not load"
  done
  mk="$root/.claude-plugin/marketplace.json"
  if [ -f "$mk" ]; then
    grep -oE '"source"[[:space:]]*:[[:space:]]*"[^"]*"' "$mk" 2>/dev/null \
      | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | while IFS= read -r src; do
      [ -n "$src" ] || continue
      case "$src" in /*) d="$src" ;; *) d="$root/$src" ;; esac
      [ -d "$d" ] || _audit_emit HIGH d7-manifest ".claude-plugin/marketplace.json" "marketplace entry source '$src' is not a directory — that plugin is unresolvable"
    done
  fi
}

# ===========================================================================
# D8 — lib-drift (HIGH): a vendored plugins/*/lib/common.sh that differs from the canonical
# shared/lib/common.sh. A plugin can only source its OWN vendored copy at runtime, so drift
# means it silently runs STALE shared logic (e.g. an un-fixed F1/F2). Pure `diff`.
# ===========================================================================
audit_d8() {
  local root rel canon f; root="$(_audit_root)"
  canon="$root/shared/lib/common.sh"
  if [ ! -f "$canon" ]; then
    _audit_emit HIGH d8-lib-drift "shared/lib/common.sh" "canonical shared lib is missing — vendored copies cannot be verified"
    return
  fi
  for f in "$root"/plugins/*/lib/common.sh; do
    [ -f "$f" ] || continue
    rel="$(_audit_rel "$root" "$f")"
    diff -q "$canon" "$f" >/dev/null 2>&1 || _audit_emit HIGH d8-lib-drift "$rel" "vendored lib differs from shared/lib/common.sh — this plugin runs stale shared logic; run scripts/sync-shared.sh"
  done
}

# ===========================================================================
# D9 — line-endings/exec (LOW, F10 / F-B4): a .sh OR .js/.mjs/.cjs with CRLF line endings (breaks the
# '#!' shebang — #!/usr/bin/env bash AND #!/usr/bin/env node — on Linux/macOS), or a NON-hook script
# tracked at a mode other than 100755 (hook scripts' +x is D6's concern — D9 covers the rest of the
# convention without double-flagging). F-B4 added .js/.mjs/.cjs: the minimalist node hooks are the first
# .js shebang files, so a CRLF re-save would silently break #!/usr/bin/env node on POSIX.
# ===========================================================================
audit_d9() {
  local root rel f hooks mode eol; root="$(_audit_root)"
  hooks="$(_audit_hook_scripts)"
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    rel="$(_audit_rel "$root" "$f")"
    # Judge the SHIPPED form, not the checkout: git's index eol is authoritative + cross-
    # platform. A Windows autocrlf *working tree* is CRLF yet ships LF (F10, benign), and on
    # Windows `awk`/`grep` read in text mode and never even see the CR — so only `git ls-files
    # --eol` (i/crlf|i/mixed) reliably catches a .sh that would actually SHIP with CRLF.
    eol=""
    bd_have git && eol="$(git -C "$root" ls-files --eol -- "$rel" 2>/dev/null | awk '{print $1; exit}')"
    case "$eol" in
      i/crlf|i/mixed) _audit_emit LOW d9-line-endings "$rel" "script ships with CRLF/mixed line endings ($eol) — breaks the '#!' shebang on Linux/macOS (F10/F-B4); pin 'eol=lf' for this extension in .gitattributes" ;;
    esac
    case "$(printf '\n%s\n' "$hooks")" in *"$(printf '\n%s\n' "$f")"*) : ;; *)
      mode=""
      bd_have git && mode="$(git -C "$root" ls-files -s -- "$rel" 2>/dev/null | awk '{print $1; exit}')"
      if [ -n "$mode" ] && [ "$mode" != "100755" ]; then
        _audit_emit LOW d9-exec-mode "$rel" "non-hook script is tracked mode $mode (not 100755) — inconsistent with the repo's executable-script convention"
      fi ;;
    esac
  done < <(find "$root/plugins" "$root/scripts" "$root/shared" "$root/tests" \( -name '*.sh' -o -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \) 2>/dev/null)   #D9_FIND_RE
}

# ===========================================================================
# D10 — bash-bypass (HIGH, F-A): a PreToolUse WRITE-DISCIPLINE plugin (one whose PreToolUse wires
# guard-scope / guard-readonly / guard-bugfix) that has NO PreToolUse `Bash` matcher. Those write
# guards only match Write|Edit|MultiEdit|NotebookEdit, so a Bash command (sed -i, >, tee, cp, mv,
# dd, truncate, install, ln) mutates files straight PAST them. Closing the hole needs a PreToolUse
# `Bash` matcher wiring a guard-bash-write.sh. Plugins with no write-discipline guard are not judged.
# ===========================================================================
audit_d10() {
  local root rel plug bscript brel armed; root="$(_audit_root)"
  # Pass 1 (F-A): a write-discipline plugin with NO PreToolUse `Bash` matcher.
  _audit_hook_records | awk -F'\t' '
    $1=="PreToolUse" && $3!="" {
      p=$3; sub(/.*\/plugins\//,"",p); sub(/\/.*/,"",p)        # plugin = the path component after /plugins/
      if (p=="") next
      seen[p]=1
      if ($3 ~ /guard-(scope|readonly|bugfix)\.sh$/) wd[p]=1   # this plugin enforces write discipline
      if ($2 ~ /Bash/) bash[p]=1                               # …and has a PreToolUse Bash matcher
    }
    END{ for (p in seen) if (wd[p] && !(p in bash)) print p }  #D10_BYPASS_RE
  ' | sort -u | while IFS= read -r plug; do
    [ -n "$plug" ] || continue
    rel="plugins/$plug/hooks/hooks.json"
    _audit_emit HIGH d10-bash-bypass "$rel" "PreToolUse write-discipline plugin '$plug' wires guard-scope/guard-readonly/guard-bugfix but has NO PreToolUse 'Bash' matcher — a Bash command (sed -i, >, tee, cp, mv, dd, truncate, install, ln) mutates files straight past the write guard (F-A); add a PreToolUse Bash matcher wiring guard-bash-write.sh"
  done
  # Pass 2 (F-A3): a wired guard-bash-write.sh that EXISTS but is HOLLOWED OUT — lacking the interpreter
  # inline-eval DENY and/or the expanded mutating-verb set, so a BEGIN{}-only stub would satisfy the
  # mere-matcher check above while doing NOTHING. Token presence is a static proxy for "the threat-model
  # logic is wired" (the behavioral proof lives in the guard test suite). A MISSING script is D6's
  # concern, not double-flagged here.
  _audit_hook_records | awk -F'\t' '$1=="PreToolUse" && $2 ~ /Bash/ && $3 ~ /guard-bash-write\.sh$/{print $3}' \
    | sort -u | while IFS= read -r bscript; do
    [ -f "$bscript" ] || continue
    brel="$(_audit_rel "$root" "$bscript")"
    armed=1
    grep -Eq 'python|perl|ruby|node|deno|php|bun' "$bscript" 2>/dev/null || armed=0   # interpreter set
    grep -Eq '\-\-eval|--execute'                 "$bscript" 2>/dev/null || armed=0   # inline-eval flags
    grep -Eq 'rmdir|mkdir|chmod|chown'            "$bscript" 2>/dev/null || armed=0   # expanded mutating verbs
    grep -Eq '\-delete|sponge'                    "$bscript" 2>/dev/null || armed=0   # destructive verbs
    [ "$armed" = 1 ] || _audit_emit HIGH d10-bash-bypass "$brel" "wired guard-bash-write.sh is HOLLOWED OUT — missing the interpreter inline-eval DENY and/or the expanded mutating-verb set (rm/mkdir/chmod/chown/sponge/find -delete), so a Bash mutation slips past it (F-A3); restore the threat-model logic"   #D10_HOLLOW_RE
  done
}

# ===========================================================================
# D11 — errexit (HIGH, F-A4): a plugin script under plugins/*/scripts/ whose ACTUAL `set` directive
# enables errexit (set -e / -eu / -euo …). A PreToolUse guard under `set -e` ABORTS on the first
# unexpected non-zero (a grep no-match, git in a non-repo, a bd_ helper returning 1) with THAT exit
# code — and PreToolUse BLOCKS only on exit 2, so any other code lets the tool call PROCEED: a silent
# fail-open. The convention is `set -uo pipefail` (never -e). This matches a REAL directive line
# (anchored to line-start so it can never confuse a COMMENT that merely mentions "set -e" — the repo
# has many such comments — for a live directive). Distinct from reviewer R2, which only catches a
# NEWLY-introduced errexit (HEAD-vs-working diff); D11 is the static catch for a PRE-EXISTING one.
# ===========================================================================
audit_d11() {
  local root rel f; root="$(_audit_root)"
  for f in "$root"/plugins/*/scripts/*.sh; do
    [ -f "$f" ] || continue
    rel="$(_audit_rel "$root" "$f")"
    # First real `set …-e…` directive line only (one finding per file). The `^[[:space:]]*set`
    # anchor excludes a comment line (which begins with '#'), so "# … set -e …" never matches.
    awk '/^[[:space:]]*set[[:space:]]+-[a-z]*e/ {print FNR; exit} #D11_ERREXIT_RE' "$f" 2>/dev/null | while IFS= read -r n; do
      _audit_emit HIGH d11-errexit "$rel:$n" "plugin script enables errexit (set -e) in its actual 'set' directive — under -e a PreToolUse guard ABORTS on any unexpected non-zero and the tool then PROCEEDS (PreToolUse blocks only on exit 2): a fail-open (F-A4). Use 'set -uo pipefail' and guard real failures explicitly."
    done
  done
}

# ===========================================================================
# D12 — sh-shebang + pipefail (HIGH, CodeRabbit/PR#6): a script whose FIRST line is a NON-bash POSIX
# `sh`/`dash` shebang (#!/usr/bin/env sh, #!/bin/sh, …/dash) that nonetheless enables `pipefail` via a
# real `set` directive. `pipefail` is a bash/ksh `set -o` option; POSIX sh/dash REJECT it ("set: Illegal
# option -o pipefail") and ABORT the script BEFORE any work — silently killing the tool/gate when it runs
# under its OWN shebang (the test harness invokes scripts via `bash …`, which hides the bug, so the seven
# suites can't catch it; this static check is the durable guard). FIRES only when BOTH hold: the shebang
# is sh/dash (NOT bash/ksh/zsh — pipefail is valid there) AND a real `set …pipefail` DIRECTIVE exists
# (line-start `set`, never a comment or the bare word inside a string — the test ladders MENTION
# "pipefail" in DATA and MUST stay silent). Scans the harness-invoked tooling + plugin + test scripts.
# ===========================================================================
audit_d12() {
  local root rel f sb; root="$(_audit_root)"
  for f in "$root"/plugins/*/scripts/*.sh "$root"/scripts/*.sh "$root"/tests/*.sh; do
    [ -f "$f" ] || continue
    sb="$(sed -n '1p' "$f" 2>/dev/null)"
    case "$sb" in '#!'*) : ;; *) continue ;; esac                                   # first line must be a shebang
    printf '%s' "$sb" | grep -Eq '[/ ](sh|dash)[[:space:]]*$' || continue           #D12_SHEBANG_RE interpreter = sh|dash, NOT bash/ksh/zsh
    rel="$(_audit_rel "$root" "$f")"
    # First real `set …pipefail` DIRECTIVE line only (one finding per file). `^[[:space:]]*set[[:space:]]`
    # excludes a comment ('# …') and a quoted mention ('printf "…pipefail"'), so test DATA stays silent.
    awk '/^[[:space:]]*set[[:space:]].*pipefail/ {print FNR; exit} #D12_PIPEFAIL_RE' "$f" 2>/dev/null | while IFS= read -r n; do
      _audit_emit HIGH d12-sh-pipefail "$rel:$n" "POSIX 'sh'/'dash' shebang ($sb) with a 'set …pipefail' directive — pipefail is a bash/ksh option that POSIX sh/dash REJECT (set: Illegal option -o pipefail), aborting the script under its own shebang BEFORE any work (the harness hides this by running via bash). Drop pipefail (use 'set -u') or switch the shebang to bash."
    done
  done
}

# ===========================================================================
# ADVISORY — informational only. NEVER gates and is EXCLUDED from the high/med/low tally by
# verify-audit.sh. These are the "fuzzy" findings whose static signal is weak enough that
# gating on them would risk false-blocking: doc drift (F5), redundant agent tools (F12),
# stale explorer-index paths (F13).
# ===========================================================================
audit_advisory() {
  local root rel f idx p t rm; root="$(_audit_root)"
  for f in "$root"/plugins/*/agents/*.md; do
    [ -f "$f" ] || continue
    rel="$(_audit_rel "$root" "$f")"
    if grep -Eq '^tools:' "$f" 2>/dev/null && grep -Eq '^disallowedTools:' "$f" 2>/dev/null; then
      _audit_emit ADVISORY agent-tools "$rel" "agent frontmatter declares BOTH tools: and disallowedTools: — redundant; pick one convention (F12)"
    fi
  done
  idx="$root/.claude/explorer/index.json"
  if [ -f "$idx" ]; then
    grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]*"' "$idx" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in /*) t="$p" ;; *) t="$root/$p" ;; esac
      [ -e "$t" ] || _audit_emit ADVISORY stale-index ".claude/explorer/index.json" "index path '$p' does not resolve on disk — stale memory (F13); regenerate via /explorer:start"
    done
  fi
  rm="$root/README.md"
  if [ -f "$rm" ] && grep -Eqi 'advisory \(warn only\)' "$rm" 2>/dev/null && grep -Eq 'guard-scope|scope guard' "$rm" 2>/dev/null; then
    _audit_emit ADVISORY doc-drift "README.md" "README may describe the scope guard as advisory/warn-only, but it hard-blocks once a PLAN exists (F5) — verify the Configuration note"
  fi
}

# ===========================================================================
# Per-file ShellCheck lint when it is installed (errors -> LOW). When absent, emit a single
# ADVISORY "skipped" note and do NOT fail. Only ERROR severity is surfaced; SC1091 (can't
# follow the sourced lib) and lower are informational artifacts of the layout. Content is
# CR-stripped first so a Windows autocrlf checkout doesn't flood SC1017 (F10 — judge the
# shipped LF form). (Comment intentionally avoids starting with the ShellCheck directive word.)
# ===========================================================================
audit_shellcheck() {
  local root rel f ln; root="$(_audit_root)"
  if ! bd_have shellcheck; then
    _audit_emit ADVISORY shellcheck "-" "shellcheck: skipped (not installed) — install ShellCheck for per-file static lint"
    return
  fi
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    # ShellCheck is a SHELL linter — it cannot lint JS (a node-shebang .js trips SC1008/SC1071…), so
    # skip .js/.mjs/.cjs here. The find predicate is broadened in step with D9 (F-B4) so the two scans
    # cover the same set, but JS line-endings/mode are D9's concern, NOT shellcheck's.
    case "$f" in *.js|*.mjs|*.cjs) continue ;; esac
    rel="$(_audit_rel "$root" "$f")"
    tr -d '\r' < "$f" | shellcheck -S error -f gcc -e SC1091 - 2>/dev/null | while IFS= read -r ln; do
      [ -n "$ln" ] && _audit_emit LOW shellcheck "$rel" "shellcheck: ${ln#*: }"
    done
  done < <(find "$root/plugins" "$root/scripts" "$root/shared" \( -name '*.sh' -o -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \) 2>/dev/null)
}

# Run every detector. Order is HIGH-class first for readable streaming output; verify-audit.sh
# re-tallies by severity regardless of order.
audit_run_all() {
  audit_d1; audit_d2; audit_d6; audit_d7; audit_d8; audit_d10; audit_d11; audit_d12   # HIGH class
  audit_d3; audit_d4; audit_d5; audit_d6b                 # MEDIUM class
  audit_d9                                                # LOW class
  audit_advisory; audit_shellcheck                        # ADVISORY + lint
}
