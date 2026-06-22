#!/usr/bin/env bash
# verify-release.sh — the deterministic RELEASE GATE for the pipeline conductor.
#
# Runs as the pipeline plugin's Stop hook and is also invoked directly by /pipeline:run.
# It reads ONLY existing artifacts + the per-module STATUS contract and renders a verdict:
# is this change safe to release? ADVISORY by default (always exit 0, just report); it
# hard-blocks (exit 2) on any REQUIRED failure only when enforce mode is on
# (PIPELINE_ENFORCE=1 or settings.enforce_release=true — see bd_release_enforce).
#
# DECISIONS ARE PURE SHELL/AWK — no python dependency — so the gate is identical on a
# python-less / Windows-stub host (bd_status_read / bd_setting_at carry their own grep
# fallback; nothing here branches on whether python exists). It NEVER crashes on a missing
# file: every absent artifact becomes a FAIL with a clear reason, never an error. NOT
# `set -e` (a single failing probe must shape the verdict, not abort the gate).
#
# Checks (REQUIRED unless noted):
#   1. explorer memory present AND fresh (explored_commit == git HEAD)
#   2. builder finished (STATUS state == done); if PLAN.md exists, every "## Tasks" item
#      has a STRUCTURED CHANGELOG coverage-map header ("### Task <id> … coverage") — a bare
#      in-prose "Task <id>" mention does NOT count as coverage
#   3. if .claude/builder/BUG.md exists: repro green + characterization/linked green
#      (read from .claude/builder/bugfix/results.txt)
#   4. auditor (ADVISORY when absent / extensible): if auditor STATUS exists, require 0 high;
#      if absent, report "not run" and do NOT fail
#   5. CHANGELOG.md present and non-empty
#   6. reviewer (ADVISORY when absent / extensible): if reviewer STATUS exists, require 0 blocking
#      AND state != failed; if absent, report "not run" and do NOT fail (mirrors the auditor check)
#   7. ops (ADVISORY when absent / extensible): if ops STATUS exists, require 0 blocking AND
#      state != failed; if absent, report "not run" and do NOT fail (mirrors the reviewer check)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"

PROJECT="$(bd_project_dir)"
PIPE_DIR="$(bd_pipeline_dir)"
RELEASE_MD="$(bd_release_md)"
mkdir -p "$PIPE_DIR" 2>/dev/null || true

# Full HEAD for the freshness comparison (explored_commit is a full SHA; we also accept a
# short prefix). Empty when git is unavailable / not a work tree.
HEAD_FULL=""
if bd_have git && git -C "$PROJECT" rev-parse HEAD >/dev/null 2>&1; then
  HEAD_FULL="$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null || printf '')"
fi

# Working-tree freshness (external review F-B): a prior green run must NOT certify stale/uncommitted
# code. TREE_NOW digests the current SOURCE tree (HEAD + uncommitted source changes, EXCLUDING the
# gate's own .claude/ bookkeeping); each module's STATUS records the tree it examined. TREE_DIRTY is
# non-empty when there are uncommitted SOURCE changes right now.
TREE_NOW="$(bd_tree_digest)"
TREE_DIRTY=""
if bd_have git && git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  TREE_DIRTY="$(git -C "$PROJECT" status --porcelain -- . ':(exclude).claude' 2>/dev/null || true)"
fi
# tree_stale <module> : succeeds (module IS stale) when its recorded `tree=` DIFFERS from the current
# tree — OR when it recorded NO tree at all (F-A2, FAIL-CLOSED). The old "no record -> not stale" was a
# no-op: the ONLY writer of tree= was verify-build (builder); verify-audit/review/ops wrote STATUS
# WITHOUT tree=, so tree_stale ALWAYS passed for them and a post-gate COMMIT (clean tree -> the dirty
# check at #F_B_DIRTY misses it) shipped on a STALE-but-green aux STATUS that never inspected the new
# code. Now those gates stamp tree= AND a missing record reads STALE ("re-run"), so a module's green
# verdict only counts for the exact tree it examined. (Reached only AFTER a module's STATUS exists and
# its count/state checks passed, so this never fabricates a verdict for a module that did not run.)
tree_stale() {
  local rec; rec="$(bd_status_read "$1" tree 2>/dev/null || true)"
  [ -n "$rec" ] || return 0          #F_B_NOREC no recorded tree -> FAIL-CLOSED (stale): the module must re-run
  [ "$rec" = "$TREE_NOW" ] && return 1
  return 0
}

# --- result accumulation -----------------------------------------------------
declare -a ROWS=()
REQ_FAIL=0
declare -a FAIL_REASONS=()
# record <name> <PASS|FAIL|SKIP> <required:0|1> <detail>
record() {
  local name="$1" verdict="$2" req="$3" detail="$4"
  ROWS+=("$(printf '%-18s %-4s %s' "$name" "$verdict" "$detail")")
  if [ "$verdict" = "FAIL" ] && [ "$req" = "1" ]; then
    REQ_FAIL=$((REQ_FAIL + 1))
    FAIL_REASONS+=("$detail")
  fi
}

# coverage_gaps <plan> <log> : print each PLAN "### Task <id>" whose id has NO matching
# STRUCTURED coverage marker in the CHANGELOG. The marker is the per-task header the builder's
# apply-change skill emits — an H3 header that names "Task <id>" AND says "coverage":
#   ### Task <id> — edge-case coverage
# A bare in-prose mention ("Task 1 was tricky") or a plain bullet ("- Task 1: did A") is NOT a
# marker and does NOT count — the old loose check let a stray sentence satisfy the gate with no
# real coverage map. Pure awk; ids are compared as whole tokens with trailing punctuation
# stripped, so `1` never matches `10` and `Task 1:` == `Task 1`. Empty output => every task is
# covered (or there are no tasks / no log).
coverage_gaps() {
  local plan="$1" log="$2"
  [ -f "$log" ] || log=/dev/null
  awk -v logf="$log" '
    BEGIN{
      while ((getline line < logf) > 0) {
        # A task is covered ONLY by a STRUCTURED H3 coverage header (### Task <id> … coverage),
        # never by a bare in-prose "Task <id>" mention. (TC4 reverts THIS line to the loose
        # /[Tt]ask …/ match to prove the structured-marker requirement is load-bearing.)
        if (line ~ /^###[[:space:]]+[Tt]ask[[:space:]]+[^[:space:]].*[Cc]overage/) {   #COVERAGE_MARKER_RE
          tok=line; sub(/^[#[:space:]]*[Tt]ask[[:space:]]+/,"",tok)
          sub(/[[:space:]].*$/,"",tok); gsub(/[:.,;]+$/,"",tok)
          if (tok!="") covered[tok]=1
        }
      }
    }
    /^##[[:space:]]/ && $0 !~ /^###/ { intasks = ($0 ~ /[Tt]asks/) ? 1 : 0; next }
    intasks && /^###[[:space:]]/ {
      l=$0; sub(/^###[[:space:]]+/,"",l); sub(/^[Tt]ask[[:space:]]+/,"",l)
      sub(/[[:space:]].*$/,"",l); gsub(/[:.,;]+$/,"",l)
      if (l!="" && !(l in covered)) print l
    }
  ' "$plan"
}

# ---------------------------------------------------------------------------
# 1) explorer memory present AND fresh
# ---------------------------------------------------------------------------
MEM="$(bd_explorer_dir)/MEMORY.md"
if [ ! -f "$MEM" ]; then
  record "explorer-memory" FAIL 1 "explorer memory: MISSING (.claude/explorer/MEMORY.md) — run /explorer:start"
else
  EXPLORED="$(grep -oE '^explored_commit:[[:space:]]*[A-Za-z0-9]+' "$MEM" 2>/dev/null | head -n1 | sed -E 's/^explored_commit:[[:space:]]*//' || true)"
  if [ -z "$EXPLORED" ]; then
    record "explorer-memory" FAIL 1 "explorer memory: present but has no explored_commit line"
  elif [ -z "$HEAD_FULL" ]; then
    record "explorer-memory" FAIL 1 "explorer memory: cannot verify freshness (git HEAD unavailable)"
  else
    case "$HEAD_FULL" in
      "$EXPLORED"*)
        if [ -n "$TREE_DIRTY" ]; then   #F_B_DIRTY working tree must be clean to release
          record "explorer-memory" FAIL 1 "working tree DIRTY — uncommitted source changes are NOT covered by the modules' green runs; commit or revert before release (a prior green run must not certify new/uncommitted code)"
        else
          record "explorer-memory" PASS 1 "fresh: explored_commit matches HEAD; working tree clean"
        fi ;;
      *)            record "explorer-memory" FAIL 1 "explorer memory: STALE (explored=$EXPLORED, HEAD=$HEAD_FULL) — re-run /explorer:start" ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# 2) builder finished + (if PLAN.md) every task covered in the CHANGELOG
# ---------------------------------------------------------------------------
BSTATE="$(bd_status_read builder state 2>/dev/null || true)"
if [ "$BSTATE" != "done" ]; then
  record "builder-finished" FAIL 1 "builder: NOT done (STATUS state='${BSTATE:-<none>}')"
elif tree_stale builder; then   #F_B_TREE builder STATUS recorded against a different tree
  record "builder-finished" FAIL 1 "builder: STATUS recorded against a DIFFERENT working tree than now (stale green) — re-run the build before release"
else
  PLAN="$(bd_plan)"
  if [ -f "$PLAN" ]; then
    GAPS="$(coverage_gaps "$PLAN" "$(bd_changelog)")"
    if [ -n "$GAPS" ]; then
      record "builder-finished" FAIL 1 "builder: task(s) missing CHANGELOG coverage map: $(printf '%s' "$GAPS" | tr '\n' ' ')"
    else
      record "builder-finished" PASS 1 "builder done; all PLAN tasks have a structured coverage-map header"
    fi
  else
    record "builder-finished" PASS 1 "builder done (no PLAN.md; coverage-map check N/A)"
  fi
fi

# ---------------------------------------------------------------------------
# 3) bug-fix verification net (only when a BUG.md is present)
# ---------------------------------------------------------------------------
BUG="$(bd_bug)"
if [ ! -f "$BUG" ]; then
  record "bugfix-net" SKIP 0 "bugfix: no BUG.md — not a bug-fix release (N/A)"
else
  LEDGER="$(bd_bugfix_dir)/results.txt"
  if [ ! -f "$LEDGER" ]; then
    record "bugfix-net" FAIL 1 "bugfix: results ledger MISSING (.claude/builder/bugfix/results.txt)"
  else
    # Transition-aware bug-fix net (external review F-C): terminal GREEN alone is NOT enough — a
    # no-op / always-green "repro" would otherwise sail through, having NEVER proven it can catch
    # the bug. Require a real RED→GREEN TRANSITION per repro id (the command — the BUG.md schema
    # declares one 'Repro command', so each id is one repro): the repro must have been observed RED
    # at some point (historical, kept in the ledger by regression-gate.sh) AND be GREEN now (its
    # LATEST recorded status). char/linked must not be red. Pure awk over the whitespace-separated
    # ledger ($1=kind, $2=status, $3..=command id). Counts: repro-ids, repro-not-green-now,
    # repro-green-now-but-never-red, char/linked-red.
    COUNTS="$(awk '
      function norm(s){ s=tolower(s);
        if (s ~ /^(green|pass|passed|passing|ok|0|true)$/)  return "green";
        if (s ~ /^(red|fail|failed|failing|error|1|false)$/) return "red";
        return "unknown" }
      { k=$1; st=norm($2);
        id=""; for(i=3;i<=NF;i++) id=id (i>3?" ":"") $i
        if (k=="repro")                  { rseen[id]=1; rlatest[id]=st; if (st=="red") rred[id]=1 }
        else if (k=="char"||k=="linked") { if (st=="red") cr++ } }
      END{ for (x in rseen) { rt++;
             if (rlatest[x]!="green")  rng++;          # still red now
             else if (!(x in rred))   rnr++ }          # green now but never observed red (no transition)
           printf "%d %d %d %d", rt+0, rng+0, rnr+0, cr+0 }
    ' "$LEDGER" 2>/dev/null)"
    # shellcheck disable=SC2086
    set -- $COUNTS
    RT="${1:-0}"; RNG="${2:-0}"; RNR="${3:-0}"; CR="${4:-0}"
    if [ "$RT" -eq 0 ]; then
      record "bugfix-net" FAIL 1 "bugfix: no reproduction result recorded — repro is the cornerstone of the fix"
    elif [ "$RNG" -gt 0 ]; then
      record "bugfix-net" FAIL 1 "bugfix: reproduction not green (red->green not proven)"
    elif [ "$RNR" -gt 0 ]; then   #BUGFIX_TRANSITION_RE require an observed RED before the GREEN
      record "bugfix-net" FAIL 1 "bugfix: no red->green transition observed — the repro was already green before the fix (an always-green repro does not prove the bug was fixed)"
    elif [ "$CR" -gt 0 ]; then
      record "bugfix-net" FAIL 1 "bugfix: characterization/linked test regressed ($CR red)"
    else
      record "bugfix-net" PASS 1 "bugfix: repro red->green transition observed; characterization/linked green"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4) auditor (extensible) — advisory when absent, required (0 high) when present
# ---------------------------------------------------------------------------
AUD="$(bd_claude_dir)/auditor/STATUS.json"
if [ ! -f "$AUD" ]; then
  record "auditor" SKIP 0 "auditor: not run (advisory — does not block release)"
else
  ASTATE="$(bd_status_read auditor state 2>/dev/null || true)"
  AHIGH="$(bd_status_read auditor high 2>/dev/null || true)"   # future auditor may record a 'high' count
  if [ -n "$AHIGH" ] && [ "$AHIGH" != "0" ]; then
    record "auditor" FAIL 1 "auditor: $AHIGH HIGH finding(s) — must be 0 to release"
  elif [ "$ASTATE" = "failed" ] || [ "$ASTATE" = "blocked" ]; then
    record "auditor" FAIL 1 "auditor: STATUS state='$ASTATE'"
  elif tree_stale auditor; then
    record "auditor" FAIL 1 "auditor: STATUS recorded against a DIFFERENT working tree than now (stale green) — re-run the audit before release"
  else
    record "auditor" PASS 1 "auditor: state='${ASTATE:-?}', 0 high"
  fi
fi

# ---------------------------------------------------------------------------
# 5) CHANGELOG present and non-empty
# ---------------------------------------------------------------------------
LOG="$(bd_changelog)"
if [ -s "$LOG" ]; then
  record "changelog" PASS 1 "CHANGELOG present and non-empty"
else
  record "changelog" FAIL 1 "CHANGELOG: missing or empty (.claude/builder/CHANGELOG.md)"
fi

# ---------------------------------------------------------------------------
# 6) reviewer (extensible) — advisory when absent, required (0 blocking) when present.
# Mirrors the auditor check (4): a change-vs-invariants/callers/scope review records a BLOCKING
# count; require 0 blocking and a non-failed state to release. Absent -> SKIP (does not block), so
# this addition is purely additive and leaves every prior fixture's verdict unchanged.
# ---------------------------------------------------------------------------
REV="$(bd_claude_dir)/reviewer/STATUS.json"
if [ ! -f "$REV" ]; then
  record "reviewer" SKIP 0 "reviewer: not run (advisory — does not block release)"
else
  RSTATE="$(bd_status_read reviewer state 2>/dev/null || true)"
  RBLOCK="$(bd_status_read reviewer blocking 2>/dev/null || true)"   # reviewer records a 'blocking' count
  if [ -n "$RBLOCK" ] && [ "$RBLOCK" != "0" ]; then
    record "reviewer" FAIL 1 "reviewer: $RBLOCK BLOCKING finding(s) — must be 0 to release"
  elif [ "$RSTATE" = "failed" ] || [ "$RSTATE" = "blocked" ]; then
    record "reviewer" FAIL 1 "reviewer: STATUS state='$RSTATE'"
  elif tree_stale reviewer; then
    record "reviewer" FAIL 1 "reviewer: STATUS recorded against a DIFFERENT working tree than now (stale green) — re-run the review before release"
  else
    record "reviewer" PASS 1 "reviewer: state='${RSTATE:-?}', 0 blocking"
  fi
fi

# ---------------------------------------------------------------------------
# 7) ops (extensible) — advisory when absent, required (0 blocking) when present.
# Mirrors the reviewer check (6): a deploy/release-readiness assessment records a BLOCKING count;
# require 0 blocking and a non-failed state to release. Absent -> SKIP (does not block), so this
# addition is purely additive and leaves every prior fixture's verdict unchanged.
# ---------------------------------------------------------------------------
OPS="$(bd_claude_dir)/ops/STATUS.json"
if [ ! -f "$OPS" ]; then
  record "ops" SKIP 0 "ops: not run (advisory — does not block release)"
else
  OSTATE="$(bd_status_read ops state 2>/dev/null || true)"
  OBLOCK="$(bd_status_read ops blocking 2>/dev/null || true)"   # ops records a 'blocking' count
  if [ -n "$OBLOCK" ] && [ "$OBLOCK" != "0" ]; then
    record "ops" FAIL 1 "ops: $OBLOCK BLOCKING finding(s) — must be 0 to release"
  elif [ "$OSTATE" = "failed" ] || [ "$OSTATE" = "blocked" ]; then
    record "ops" FAIL 1 "ops: STATUS state='$OSTATE'"
  elif tree_stale ops; then
    record "ops" FAIL 1 "ops: STATUS recorded against a DIFFERENT working tree than now (stale green) — re-run the readiness check before release"
  else
    record "ops" PASS 1 "ops: state='${OSTATE:-?}', 0 blocking"
  fi
fi

# --- verdict -----------------------------------------------------------------
if [ "$REQ_FAIL" -eq 0 ]; then RELEASE_STATE="done"; VERDICT="RELEASE READY"; else RELEASE_STATE="failed"; VERDICT="BLOCKED"; fi
if bd_release_enforce; then MODE="enforce"; else MODE="advisory"; fi
NOW="$(date -u +%FT%TZ 2>/dev/null || printf 'unknown')"

# Persist the module STATUS so the dashboard + conductor can read the verdict.
bd_status_write pipeline release "$RELEASE_STATE" >/dev/null 2>&1 || true

# Write RELEASE.md (deterministic report).
{
  printf '# Release gate — %s\n\n' "$VERDICT"
  # NB: a printf FORMAT beginning with '-' is parsed as an option flag, so the leading
  # bullet '-' lives in the ARGUMENT (format is '%s\n'), not the format string.
  printf '%s\n' "- Generated: $NOW"
  printf '%s\n' "- HEAD: ${HEAD_FULL:-unknown}"
  printf '%s\n' "- Mode: $MODE"
  printf '%s\n\n' "- Required failures: $REQ_FAIL"
  printf '## Checks\n\n'
  printf '| Check | Result | Detail |\n'
  printf '|---|---|---|\n'
  for r in "${ROWS[@]}"; do
    nm="${r%% *}"; rest="${r#"$nm"}"; rest="${rest#"${rest%%[![:space:]]*}"}"
    vd="${rest%% *}"; dt="${rest#"$vd"}"; dt="${dt#"${dt%%[![:space:]]*}"}"
    printf '| %s | %s | %s |\n' "$nm" "$vd" "$dt"
  done
  printf '\n## Required failures\n\n'
  if [ "$REQ_FAIL" -eq 0 ]; then
    printf 'none\n'
  else
    for f in "${FAIL_REASONS[@]}"; do printf -- '- %s\n' "$f"; done
  fi
} > "$RELEASE_MD" 2>/dev/null || true

# --- emit to STDOUT (visible dashboard) + decide exit ------------------------
printf '[pipeline] release gate (%s) — %s\n' "$MODE" "$VERDICT"
printf '  %-18s %-4s %s\n' "CHECK" "RES" "DETAIL"
for r in "${ROWS[@]}"; do printf '  %s\n' "$r"; done
printf '  report: %s\n' "${RELEASE_MD#"$PROJECT"/}"

if bd_release_enforce && [ "$REQ_FAIL" -ne 0 ]; then
  {
    printf '[pipeline] RELEASE BLOCKED: %s required check(s) failed:\n' "$REQ_FAIL"
    for f in "${FAIL_REASONS[@]}"; do printf '  - %s\n' "$f"; done
    printf 'Resolve the above (or unset enforce) before releasing. See %s.\n' "${RELEASE_MD#"$PROJECT"/}"
  } >&2
  exit 2
fi
exit 0
