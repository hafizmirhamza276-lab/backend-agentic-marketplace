#!/usr/bin/env bash
# lib-ops-checks.sh — deterministic DEPLOY/RELEASE-READINESS checks for the `ops` plugin.
#
# The ops plugin assesses whether the user's codebase is ready to DEPLOY / RELEASE. Its
# deterministic surface is deliberately LEAN and ROBUST: only the two signals that can be read
# without GUESSING — a recorded build/test result, and version consistency across the manifest.
# Everything fuzzy about deploy/observability (CI presence, Dockerfile, health checks, structured
# logging, rollback) is the AGENTS' job (advisory CONCERN/NOTE findings), NOT a brittle static
# detector that would false-fire. This keeps a deterministic BLOCKING trustworthy.
#
# Sourced by verify-ops.sh (the Stop gate) and by the test ladder; every check is INDIVIDUALLY
# CALLABLE (`ops_o1`, `ops_o2`) so a unit test can point it at a fixture and assert it fires /
# stays silent.
#
# OUTPUT — every check prints zero or more findings, one per line, TAB-separated:
#     <SEVERITY>\t<check>\t<file:line-or-path>\t<message>
# SEVERITY ∈ BLOCKING | CONCERN | NOTE.
#   BLOCKING  a recorded build/test FAILURE — the codebase is provably not releasable. Feeds the
#             release gate's 0-blocking enforcement (verify-release.sh reads `ops blocking`).
#   CONCERN   readiness is unverified or inconsistent (no recorded results; mismatched versions) —
#             a human should resolve it, but it does NOT hard-block.
#   NOTE      informational only — NEVER gates, EXCLUDED from the blocking/concern tally.
#
# PURITY — pure shell + awk/grep/sed. No python DEPENDENCY whatsoever, so behavior is identical on
# a python-less / Windows-stub host (matching the rest of this marketplace). NEVER crashes on a
# missing file: an absent ledger/manifest is a calibrated CONCERN or silence, never an error.

# Readiness root. Lazily resolved so a unit test can target a fixture:  OPS_ROOT=/fixture ops_o1
_ops_root() { printf '%s' "${OPS_ROOT:-$(bd_project_dir)}"; }

# Emit one finding line. Messages are single-line (callers keep them tab/newline-free).
_ops_emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

# ===========================================================================
# O1 — test-ledger (BLOCKING / CONCERN): read the build/test results ledger the orchestrator
# records at .claude/ops/results.txt. Each line is "<kind>\t<status>\t<cmd>" — the SAME shape as
# the bug-fix ledger (.claude/builder/bugfix/results.txt); <status> is normalized green/red.
# Running tests is side-effectful, so verify-ops only READS this ledger — the orchestrator
# proposes + confirms the commands and writes it.
#   * any recorded RED (a failed build or test)  -> BLOCKING (the codebase is not releasable)
#   * no ledger at all                            -> CONCERN  (tests/build not verified; do NOT
#                                                    hard-block merely because nothing ran yet)
#   * every recorded result green                 -> silent
# ===========================================================================
ops_o1() {
  local root ledger reds kind cmd
  root="$(_ops_root)"
  ledger="$root/.claude/ops/results.txt"
  if [ ! -f "$ledger" ]; then
    _ops_emit CONCERN o1-test-ledger ".claude/ops/results.txt" "no build/test ledger recorded (.claude/ops/results.txt) — tests/build not verified; run them and record results before release"
    return 0
  fi
  # Every line whose normalized status is RED, as "<kind>\t<cmd>". Normalization mirrors the bug-fix
  # gate so the two ledgers read identically (green|pass|ok|0|true / red|fail|error|1|false).
  reds="$(awk -F'\t' '
    function norm(s){ s=tolower(s); gsub(/^[[:space:]]+|[[:space:]]+$/,"",s);
      if (s ~ /^(green|pass|passed|passing|ok|0|true)$/)  return "green";
      if (s ~ /^(red|fail|failed|failing|error|1|false)$/) return "red";
      return "unknown" }
    NF>=2 && norm($2)=="red" { k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k); print k "\t" $3 }
  ' "$ledger" 2>/dev/null)"
  [ -n "$reds" ] || return 0
  printf '%s\n' "$reds" | while IFS="$(printf '\t')" read -r kind cmd; do
    [ -n "$kind" ] || continue
    _ops_emit BLOCKING o1-test-ledger ".claude/ops/results.txt" "recorded '$kind' result is RED${cmd:+ ($cmd)} — a failed build/test means the codebase is not releasable; make it green before release"
  done
}

# ===========================================================================
# O2 — version-consistency (CONCERN): for each plugin entry in .claude-plugin/marketplace.json,
# compare the entry's "version" to that plugin's own plugins/<name>/.claude-plugin/plugin.json
# "version". A mismatch means a release would ship INCONSISTENT versions (the marketplace says one
# thing, the plugin manifest another). Pure awk/grep; silent when they match, when a plugin.json is
# absent/unreadable, or when there is no marketplace.json.
# ===========================================================================
ops_o2() {
  local root mk entries name ver src relsrc pj pjver
  root="$(_ops_root)"
  mk="$root/.claude-plugin/marketplace.json"
  [ -f "$mk" ] || return 0
  # One record per plugin entry: "<name>\t<marketplace-version>\t<source>". The parser tracks the
  # plugins[] array and anchors each key to LINE START, so the top-level marketplace "version" (it
  # sits before the array) and the inline author "name" (its line starts with "author") are never
  # mistaken for an entry's fields. Pretty-printed one-key-per-line JSON, as this repo emits.
  entries="$(awk '
    function flush(){ if (name!="") printf "%s\t%s\t%s\n", name, ver, src; name=""; ver=""; src="" }
    /"plugins"[[:space:]]*:[[:space:]]*\[/ { inarr=1; next }
    inarr && /^[[:space:]]*\][[:space:]]*}?[[:space:]]*$/ { flush(); inarr=0; next }
    inarr && /^[[:space:]]*"name"[[:space:]]*:/    { flush(); v=$0; sub(/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"/,"",v); sub(/".*/,"",v); name=v; next }
    inarr && /^[[:space:]]*"version"[[:space:]]*:/ { v=$0; sub(/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"/,"",v); sub(/".*/,"",v); ver=v; next }
    inarr && /^[[:space:]]*"source"[[:space:]]*:/  { v=$0; sub(/^[[:space:]]*"source"[[:space:]]*:[[:space:]]*"/,"",v); sub(/".*/,"",v); src=v; next }
    END { flush() }
  ' "$mk" 2>/dev/null)"
  [ -n "$entries" ] || return 0
  printf '%s\n' "$entries" | while IFS="$(printf '\t')" read -r name ver src; do
    [ -n "$name" ] || continue
    [ -n "$ver" ]  || continue                      # entry has no version -> nothing to compare
    relsrc="${src#./}"; [ -n "$relsrc" ] || relsrc="plugins/$name"
    pj="$root/$relsrc/.claude-plugin/plugin.json"
    [ -f "$pj" ] || continue                        # absent manifest -> silent (per spec)
    pjver="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$pj" 2>/dev/null | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
    [ -n "$pjver" ] || continue                     # unreadable version -> silent
    if [ "$ver" != "$pjver" ]; then
      _ops_emit CONCERN o2-version-consistency "$relsrc/.claude-plugin/plugin.json" "marketplace version '$ver' != plugin.json version '$pjver' for plugin '$name' — release would ship inconsistent versions"
    fi
  done
}

# Run every deterministic check. BLOCKING-class first for readable streaming output; verify-ops.sh
# re-tallies by severity regardless of order.
ops_run_all() {
  ops_o1          # BLOCKING / CONCERN
  ops_o2          # CONCERN
}
