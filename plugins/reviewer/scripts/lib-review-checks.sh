#!/usr/bin/env bash
# lib-review-checks.sh — deterministic CHANGE-REVIEW checks for the `reviewer` plugin.
#
# The reviewer is ORTHOGONAL to the auditor. The auditor runs F-class REGRESSION detectors over
# the WHOLE tree (fail-open, traversal, manifest/lib drift, …). The reviewer instead reviews a
# CHANGE (the working-tree diff vs HEAD) against the project's recorded invariants, its risk map,
# and its surviving callers — the things you only learn by looking at what THIS edit did. The two
# never cross-source each other's lib at runtime (vendoring rule); the release gate aggregates both.
#
# This library is sourced by verify-review.sh (the Stop gate) and by the test ladder; every check
# is INDIVIDUALLY CALLABLE (`review_r1`, `review_r2`, …) so a unit test can point it at a throwaway
# git fixture and assert it fires / stays silent.
#
# DIFF SOURCE — `git diff HEAD` within the review root (working tree vs HEAD). All checks are
# SILENT when git is unavailable, the tree is not a work tree, or the diff is empty/in-spec —
# never a crash, never a false fire.
#
# OUTPUT — every check prints zero or more findings, one per line, TAB-separated:
#     <SEVERITY>\t<check>\t<file:line-or-path>\t<message>
# SEVERITY ∈ BLOCKING | CONCERN | NOTE.
#   BLOCKING  the change breaks something concrete — a caller left dangling, or a house-style
#             contract dropped that re-opens a known failure class. Feeds the release gate's
#             0-blocking enforcement (verify-release.sh reads `reviewer blocking`).
#   CONCERN   the change touches recorded-risk surface or steps outside the approved scope —
#             a human should look, but it does not hard-block.
#   NOTE      informational only — NEVER gates, EXCLUDED from the blocking/concern tally.
#
# PURITY — pure shell + awk/grep/sed/find/git. No python DEPENDENCY whatsoever, so behavior is
# identical on a python-less / Windows-stub host (matching the rest of this marketplace).

# Review root. Lazily resolved so a unit test can target a fixture:  REVIEW_ROOT=/fixture review_r1
_review_root() { printf '%s' "${REVIEW_ROOT:-$(bd_project_dir)}"; }

# Emit one finding line. Messages are single-line (callers keep them tab/newline-free).
_review_emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

# True only when the review root is a usable git work tree with a HEAD to diff against.
_review_git_ready() {
  local root; root="$(_review_root)"
  bd_have git || return 1
  git -C "$root" rev-parse HEAD >/dev/null 2>&1 || return 1
  return 0
}

# Repo-relative paths changed between HEAD and the working tree (staged + unstaged). Empty when
# git is unavailable / no HEAD / no change — every consumer then loops zero times (silent).
_review_changed_files() {
  local root; root="$(_review_root)"
  _review_git_ready || return 0
  git -C "$root" diff --name-only HEAD 2>/dev/null || true
}

# Is <name> still DEFINED as a shell function anywhere in the working tree? Used so a function
# that was merely MOVED or edited-in-place (still defined somewhere) is not mistaken for removed.
# Matches the `name()` definition form this codebase uses exclusively (optionally spaced parens).
_review_fn_defined_in_tree() {
  local root="$1" name="$2" f
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    grep -Eq "(^|[^A-Za-z0-9_])${name}[[:space:]]*\(\)" "$f" 2>/dev/null && return 0
  done <<EOF
$(find "$root" -name '*.sh' ! -path '*/.git/*' 2>/dev/null)
EOF
  return 1
}

# Print `relpath:line` for every surviving CALL-site of <name> in the working tree: a word-boundary
# occurrence that is neither a comment line nor the function's own `name()` definition. Removed
# lines are by definition absent from the working tree, so this only ever counts code that REMAINS.
_review_fn_callers() {
  local root="$1" name="$2" f rel
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    rel="${f#"$root"/}"
    grep -nE "\b${name}\b" "$f" 2>/dev/null \
      | grep -vE "^[0-9]+:[[:space:]]*#" \
      | grep -vE "\b${name}[[:space:]]*\(\)" \
      | while IFS= read -r m; do printf '%s:%s\n' "$rel" "${m%%:*}"; done
  done <<EOF
$(find "$root" -name '*.sh' ! -path '*/.git/*' 2>/dev/null)
EOF
}

# ===========================================================================
# R1 — caller-integrity (BLOCKING): for each shell function REMOVED or RENAMED in the diff, the
# tree is searched for surviving call-sites. A rename shows the OLD name removed (and a new name
# added under a different identifier), so removed-definition detection covers both. A name that is
# still defined somewhere (moved / edited in place) is NOT removed and is skipped. Any survivor ->
# a broken caller, the most concrete way a change silently breaks the codebase.
# ===========================================================================
review_r1() {
  local root diff names name firstcaller callercount
  root="$(_review_root)"
  _review_git_ready || return 0
  diff="$(git -C "$root" diff HEAD 2>/dev/null)"; [ -n "$diff" ] || return 0

  # Function-definition names on REMOVED lines ('-' but not the '---' file header). Two forms:
  # the `function name` keyword form, and the bare `name()` form (this repo uses the latter).
  names="$(printf '%s\n' "$diff" | awk '
    /^-/ && !/^---/ {
      l = substr($0, 2)
      if (match(l, /^[[:space:]]*function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
        s = substr(l, RSTART, RLENGTH); sub(/^[[:space:]]*function[[:space:]]+/, "", s); print s
      } else if (match(l, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/)) {
        s = substr(l, RSTART, RLENGTH); sub(/^[[:space:]]*/, "", s); sub(/[[:space:]]*\(\).*/, "", s); print s
      }
    }' | sort -u)"
  [ -n "$names" ] || return 0

  printf '%s\n' "$names" | while IFS= read -r name; do
    [ -n "$name" ] || continue
    # Still defined somewhere? Then it moved / changed in place — callers are fine. Skip.
    _review_fn_defined_in_tree "$root" "$name" && continue
    # Surviving call-sites (scanned once). No survivors -> nothing broke; stay silent.
    callers="$(_review_fn_callers "$root" "$name")"
    [ -n "$callers" ] || continue
    callercount="$(printf '%s\n' "$callers" | grep -c .)"
    firstcaller="$(printf '%s\n' "$callers" | head -n1)"
    _review_emit BLOCKING r1-caller-integrity "$firstcaller" "function '$name()' removed/renamed in the diff but $callercount surviving call-site(s) remain (broken caller) — first at $firstcaller"
  done
}

# ===========================================================================
# R2 — convention-regression (BLOCKING): a CHANGED .sh that REGRESSES house style relative to its
# HEAD version — drops `set -uo pipefail`, stops sourcing ../lib/common.sh, or (re)introduces an
# errexit `set -e`. Each is judged by comparing the HEAD blob to the working tree, so it fires only
# on a genuine before->after regression (a brand-new file, or a file that never had the convention,
# is not flagged here — that is the auditor's whole-tree concern, not a change regression).
# ===========================================================================
review_r2() {
  local root rel f headv workv
  root="$(_review_root)"
  _review_git_ready || return 0
  git -C "$root" diff --name-only HEAD 2>/dev/null | while IFS= read -r rel; do
    case "$rel" in *.sh) ;; *) continue ;; esac
    f="$root/$rel"
    [ -f "$f" ] || continue                                   # deleted file -> no regression to flag
    headv="$(git -C "$root" show "HEAD:$rel" 2>/dev/null)" || continue
    [ -n "$headv" ] || continue                               # new file (absent in HEAD) -> not a regression
    workv="$(cat "$f" 2>/dev/null || printf '')"
    # (a) dropped `set -uo pipefail`
    if printf '%s' "$headv" | grep -q 'set -uo pipefail' \
       && ! printf '%s' "$workv" | grep -q 'set -uo pipefail'; then
      _review_emit BLOCKING r2-convention-regression "$rel" "changed .sh dropped 'set -uo pipefail' — the house safety preamble; its absence re-opens the F1 fail-open class"
    fi
    # (b) stopped sourcing ../lib/common.sh
    if printf '%s' "$headv" | grep -Eq '(^|[^[:alnum:]])(\.|source)[[:space:]].*lib/common\.sh' \
       && ! printf '%s' "$workv" | grep -Eq '(^|[^[:alnum:]])(\.|source)[[:space:]].*lib/common\.sh'; then
      _review_emit BLOCKING r2-convention-regression "$rel" "changed .sh no longer sources ../lib/common.sh — loses the shared bd_ helpers and the STATUS contract"
    fi
    # (c) (re)introduced errexit `set -e` (any flag cluster containing 'e': set -e / -eu / -euo …)
    if ! printf '%s' "$headv" | grep -Eq '^[[:space:]]*set[[:space:]]+-[a-z]*e' \
       && printf '%s' "$workv" | grep -Eq '^[[:space:]]*set[[:space:]]+-[a-z]*e'; then
      _review_emit BLOCKING r2-convention-regression "$rel" "changed .sh (re)introduces 'set -e' (errexit) — forbidden house style; a single failing probe aborts the gate (fail-open risk)"
    fi
  done
}

# ===========================================================================
# R3 — risk-touch (CONCERN): a changed file whose path is NAMED in the explorer MEMORY.md "Risk
# map" section. The explorer records risk surface as `- <area> — <risk> — <severity> — <evidence>`;
# touching one of those areas in a change is exactly when a human should re-read the recorded risk.
# Silent when there is no MEMORY.md or no Risk map. The plugin's own .claude/ memory is exempt.
# ===========================================================================
review_r3() {
  local root mem section rel
  root="$(_review_root)"
  mem="$root/.claude/explorer/MEMORY.md"
  [ -f "$mem" ] || return 0
  # The Risk map section: from a heading containing 'Risk map' until the next heading of any level.
  section="$(awk '
    /^#{1,6}[[:space:]].*[Rr]isk[[:space:]]*[Mm]ap/ { grab=1; next }
    /^#{1,6}[[:space:]]/ { grab=0 }
    grab { print }
  ' "$mem" 2>/dev/null)"
  [ -n "$section" ] || return 0
  _review_changed_files | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in .claude/*) continue ;; esac
    if printf '%s\n' "$section" | grep -qF "$rel"; then
      _review_emit CONCERN r3-risk-touch "$rel" "changed file is named in the explorer MEMORY.md Risk map — re-read the recorded risk and confirm the change respects it before release"
    fi
  done
}

# ===========================================================================
# R4 — scope-discipline (CONCERN): a changed file NOT listed in the approved .claude/builder/PLAN.md
# Scope. Reuses the builder scope-guard's exact Scope parser (bullet paths under a 'Scope' heading,
# first token, backticks stripped) and its repo-relative membership test. Silent when there is no
# PLAN.md or no parseable Scope. The plugin's own .claude/ memory is exempt (never part of a Scope,
# always writable — mirrors guard-scope.sh's allow-zone).
# ===========================================================================
review_r4() {
  local root plan scope rel
  root="$(_review_root)"
  plan="$root/.claude/builder/PLAN.md"
  [ -f "$plan" ] || return 0
  scope="$(awk '
    /^#{1,6}[[:space:]].*[Ss]cope/ { grab=1; next }
    /^#{1,6}[[:space:]]/ { grab=0 }
    grab && /^[[:space:]]*[-*][[:space:]]/ {
      line=$0; sub(/^[[:space:]]*[-*][[:space:]]+/, "", line); gsub(/`/, "", line); sub(/[[:space:]].*$/, "", line); print line
    }
  ' "$plan" 2>/dev/null)"
  [ -n "$scope" ] || return 0                                 # no parseable scope -> nothing to enforce
  _review_changed_files | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in .claude/*) continue ;; esac
    if printf '%s\n' "$scope" | grep -qxF "$rel" || printf '%s\n' "$scope" | grep -qxF "./$rel"; then
      continue
    fi
    _review_emit CONCERN r4-scope-discipline "$rel" "changed file is NOT listed in the approved PLAN.md Scope — confirm it belongs to this change (possible scope creep) or add it to the plan"
  done
}

# Run every deterministic check. BLOCKING-class first for readable streaming output; verify-review.sh
# re-tallies by severity regardless of order.
review_run_all() {
  review_r1; review_r2          # BLOCKING class
  review_r3; review_r4          # CONCERN class
}
