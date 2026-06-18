#!/usr/bin/env bash
# guard-bash-write.sh — PreToolUse(Bash) gate (external review F-A).
#
# The sibling write guards (guard-readonly / guard-scope / guard-bugfix) only match
# Write|Edit|MultiEdit|NotebookEdit, so a `Bash` command — `sed -i …`, `… > file`, `tee`, `cp`,
# `mv`, `dd`, `truncate`, `install`, `ln` — can MUTATE files straight past every one of them. This
# guard closes that hole: it inspects the Bash COMMAND STRING for those mutating constructs and
# BLOCKS (exit 2, fail-CLOSED) when a mutation's target cannot be PROVEN inside THIS plugin's
# allow-zone / PLAN scope. It reuses bd_normalize_path and the SAME zone/scope logic as the sibling
# guards (explorer → only under .claude/explorer/; builder → the PLAN.md Scope + the builder's own
# always-allow zone).
#
# IMPORTANT — command-string inspection is necessarily BEST-EFFORT and CONSERVATIVE. A shell line
# cannot be parsed perfectly without a shell, so this guard tokenizes heuristically and ERRS TOWARD
# BLOCKING: a mutation whose target it cannot prove in-zone is REFUSED, never waved through. Pure
# read commands (no mutating construct) pass untouched. NOT `set -e` (sourcing the lib must not add it).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"
PLUGIN="$(basename "$(dirname "$DIR")")"   # explorer | builder | …
PROJECT="$(bd_project_dir)"

bd_load_hook_input
CMD="$(bd_hook_field tool_input.command)"
[ -n "$CMD" ] || exit 0   # not a Bash call we can read -> nothing to check

# --- extract candidate WRITE TARGETS from the command (best-effort) -----------
# Split each logical line on `;`, `&&`, `||`; within a segment pull the target of every mutating
# construct. Redirections (`>`,`>>`, incl. `N>`/`&>`; `>&N` fd-dups are skipped). `cp`/`mv`/`install`/
# `ln` → the destination (last non-option token, stopping at a `>` redirect). `tee` → its file args.
# `sed -i`/`--in-place` → the file (last non-option token). `dd` → `of=`. `truncate` → its file.
# `|` is deliberately NOT a segment break, so a `sed 's|a|b|' file` stays intact (its file is found).
TARGETS="$(printf '%s' "$CMD" | awk '
  function clean(p){ gsub(/^[\047\042]+/,"",p); gsub(/[\047\042]+$/,"",p); return p }
  {
    line=$0
    gsub(/&&|\|\|/, ";", line)
    n=split(line, seg, /;/)
    for(s=1;s<=n;s++){
      k=split(seg[s], t, /[[:space:]]+/)
      for(i=1;i<=k;i++){
        w=t[i]; if(w=="") continue
        if(w ~ /^[0-9]*&?>>?$/){ if(i<k){ nx=t[i+1]; if(nx!="" && nx !~ /^[&-]/) print clean(nx) } continue }
        if(w ~ />/ && w !~ />&/){ x=w; sub(/^[0-9]*&?>>?/,"",x); if(x!="") print clean(x); continue }
        if(w=="cp"||w=="mv"||w=="install"||w=="ln"){ last=""; for(j=i+1;j<=k;j++){ if(t[j] ~ />/) break; if(t[j]=="" || t[j] ~ /^-/) continue; last=t[j] } if(last!="") print clean(last) }
        else if(w=="tee"){ for(j=i+1;j<=k;j++){ if(t[j] ~ />/) break; if(t[j]=="" || t[j] ~ /^-/) continue; print clean(t[j]) } }
        else if(w=="truncate"){ last=""; for(j=i+1;j<=k;j++){ if(t[j] ~ />/) break; if(t[j]=="" || t[j] ~ /^-/ || t[j] ~ /^[0-9]+$/) continue; last=t[j] } if(last!="") print clean(last) }
        else if(w=="dd"){ for(j=i+1;j<=k;j++){ if(t[j] ~ /^of=/){ x=t[j]; sub(/^of=/,"",x); if(x!="") print clean(x) } } }
        else if(w=="sed"){ ip=0; for(j=i+1;j<=k;j++){ if(t[j] ~ /^-i/ || t[j] ~ /^--in-place/) ip=1 } if(ip){ last=""; for(j=i+1;j<=k;j++){ if(t[j] ~ />/) break; if(t[j]=="" || t[j] ~ /^-/) continue; last=t[j] } if(last!="") print clean(last) } }
      }
    }
  }
')"

# No mutating target found -> a read-only command -> allow.
[ -n "$TARGETS" ] || exit 0

# --- in_zone <abs-normalized> : 0 if THIS plugin may write there, else 1 (reuses the sibling guards' logic) ---
in_zone() {
  local abs="$1" rel zone plan scope
  rel="${abs#"$PROJECT"/}"
  case "$PLUGIN" in
    explorer)
      # mirrors guard-readonly: only strictly UNDER this project's .claude/explorer/ zone.
      zone="$(bd_normalize_path "$PROJECT/.claude/explorer")"
      case "$abs" in "$zone"/*) return 0 ;; esac
      return 1 ;;
    builder)
      # mirrors guard-scope: the builder's own always-allow zone + the narrow memory-sync artifacts…
      case "$rel" in
        .claude/builder/*|.claude/specs/*) return 0 ;;
        .claude/explorer/MEMORY.md|.claude/explorer/index.json|.claude/explorer/TRACK.md|.claude/explorer/map/*) return 0 ;;
      esac
      # …then the approved PLAN.md Scope (full repo-relative path equality; no PLAN -> not provable -> block).
      plan="$(bd_plan)"; [ -f "$plan" ] || return 1
      scope="$(awk '
        /^#{1,6}[[:space:]].*[Ss]cope/ {grab=1; next}
        /^#{1,6}[[:space:]]/ {grab=0}
        grab && /^[[:space:]]*[-*][[:space:]]/ { line=$0; sub(/^[[:space:]]*[-*][[:space:]]+/,"",line); gsub(/`/,"",line); sub(/[[:space:]].*$/,"",line); print line }
      ' "$plan" 2>/dev/null)"
      printf '%s\n' "$scope" | grep -qxF "$rel"   && return 0
      printf '%s\n' "$scope" | grep -qxF "./$rel" && return 0
      return 1 ;;
    *) return 1 ;;   # unknown plugin -> fail-closed
  esac
}

# --- check every extracted target; block fail-closed on the first one we cannot prove in-zone ----
BLOCKED=""
while IFS= read -r tgt; do
  [ -n "$tgt" ] || continue
  case "$tgt" in
    /dev/null|/dev/stdout|/dev/stderr|/dev/tty|/dev/fd/*) continue ;;   # harmless redirect sinks
    -*|\&*) continue ;;                                                 # an option / fd-dup, not a path
  esac
  case "$tgt" in
    /*) abs="$tgt" ;;
    *)  abs="$PROJECT/$tgt" ;;
  esac
  abs="$(bd_normalize_path "$abs")"
  in_zone "$abs" || BLOCKED="$BLOCKED $tgt"   #BASHWRITE_BLOCK flag any target not provably in-zone
done <<EOF
$TARGETS
EOF

if [ -n "$BLOCKED" ]; then
  case "$PLUGIN" in
    explorer) _z="only under .claude/explorer/" ;;
    builder)  _z="the approved PLAN.md Scope (or the builder's own .claude/builder/, .claude/specs/, and the memory-sync risk-map artifacts)" ;;
    *)        _z="this plugin's allow-zone" ;;
  esac
  bd_block "BLOCKED (bash write guard, F-A): this Bash command would MUTATE file(s) outside $_z:${BLOCKED}. A Bash mutation (sed -i / redirect / tee / cp / mv / dd / truncate / install / ln) is not allowed to write where the Write/Edit guards forbid. Command-string inspection is conservative (best-effort): if a target's location can't be proven safe it is refused. Write only within zone, or perform the change via an Edit the scope guard can vet."
fi
exit 0
