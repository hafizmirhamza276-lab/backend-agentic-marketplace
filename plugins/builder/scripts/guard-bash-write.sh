#!/usr/bin/env bash
# guard-bash-write.sh — PreToolUse(Bash) gate (external review F-A, hardened F-A3).
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
# F-A3 — the original extractor only saw redirects + cp/mv/install/ln/tee/truncate/dd/sed-i, then
# `[ -n "$TARGETS" ] || exit 0`: ANY command without one of those tokens produced NO target and was
# WAVED THROUGH. Two new defenses close that threat-model gap:
#   (1) OPAQUE write-surface DENY (fail-closed): an interpreter running an INLINE program
#       (python/python3/perl/ruby/node/deno/php/bun with -c/-e/-E/-r/--eval/--execute, or `deno eval`),
#       a `patch` / `git apply` (writes the files named inside a diff), and `awk` in-place all mutate
#       through a surface static analysis cannot read — there is no target to prove, so they are
#       REFUSED outright. Plain script/module runs (python file.py, python -m pytest, node script.js,
#       deno run x.ts) carry no such flag and are NOT denied.
#   (2) the always-mutating verbs rm/rmdir/mkdir/chmod/chown/sponge and `find … -delete` are added to
#       target extraction and held to the SAME in-zone proof as the redirect/copy constructs.
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

# --- (F-A3) OPAQUE write-surface DENY (fail-closed) -------------------------------------------------
# Detect a construct whose file writes static analysis cannot enumerate, and REFUSE it outright (there
# is no target to prove in-zone). Each logical segment (split on ; && ||) is examined for its command
# word (skipping VAR=val env prefixes); a basename match keeps /usr/bin/python3 etc. honest. `head -n1`
# keeps the first hit for the message. Plain script/module execution carries no inline-eval flag and is
# deliberately NOT matched here — it falls through to ordinary target extraction below.
OPAQUE="$(printf '%s' "$CMD" | awk '
  function base(p){ sub(/.*\//,"",p); return p }
  {
    line=$0; gsub(/&&|\|\|/, ";", line); n=split(line, seg, /;/)
    for(s=1;s<=n;s++){
      k=split(seg[s], t, /[[:space:]]+/); ci=0
      for(i=1;i<=k;i++){ if(t[i]=="") continue; if(t[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue; ci=i; break }
      if(ci==0) continue
      c=base(t[ci])
      if(c ~ /^(python[0-9.]*|perl|ruby|node|deno|php|bun)$/){                       #BASHWRITE_EVAL_DENY interpreter inline-eval
        for(j=ci+1;j<=k;j++){
          if(t[j]=="") continue
          if(t[j] ~ /^(-c|-e|-E|-r|--eval|--execute)$/ || (c=="deno" && t[j]=="eval")){ print "inline-eval: " seg[s]; break }
          if(t[j] !~ /^-/) break                          # first positional (a script/path/subcommand) -> NOT inline-eval
        }
      } else if(c=="patch"){ print "patch: " seg[s] }                                # writes the files named INSIDE a diff
      else if(c=="git"){                                                             # `git apply` -> same opaque diff write
        for(j=ci+1;j<=k;j++){ if(t[j]=="") continue; if(t[j]=="-C"||t[j]=="-c"){ j++; continue } if(t[j] ~ /^-/) continue; if(t[j]=="apply") print "git-apply: " seg[s]; break }
      } else if(c=="awk"||c=="gawk"||c=="mawk"){                                      # awk in-place edit -> ambiguous target
        ip=0; for(j=ci+1;j<=k;j++){ if(t[j] ~ /^--in-place/) ip=1; if(t[j]=="-i" && (j+1)<=k && t[j+1]=="inplace") ip=1 }
        if(ip) print "awk-inplace: " seg[s]
      }
    }
  }
' | head -n1)"
if [ -n "$OPAQUE" ]; then
  bd_block "BLOCKED (bash write guard, F-A3): this Bash command mutates files through a surface static analysis cannot vet (${OPAQUE%%:*}) — an inline interpreter program (python -c / node -e / perl -e / deno eval), a patch / git apply, or awk in-place. Its write targets cannot be proven inside this plugin's zone, so it is refused fail-closed (command-string inspection is conservative). Run the change as an Edit the scope guard can vet, or from a script file the guards can see."
fi

# --- extract candidate WRITE TARGETS from the command (best-effort) -----------
# Split each logical line on `;`, `&&`, `||`; within a segment pull the target of every mutating
# construct. Redirections (`>`,`>>`, incl. `N>`/`&>`; `>&N` fd-dups are skipped). `cp`/`mv`/`install`/
# `ln` → the destination (last non-option token, stopping at a `>` redirect). `tee` → its file args.
# `sed -i`/`--in-place` → the file (last non-option token). `dd` → `of=`. `truncate` → its file.
# rm/rmdir/mkdir → every non-option arg; chmod/chown → every non-option arg AFTER the mode/owner;
# sponge → its file arg; `find … -delete` → the search-root path(s). (F-A3 added the last row.)
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
        else if(w=="rm"||w=="rmdir"||w=="mkdir"){ for(j=i+1;j<=k;j++){ if(t[j] ~ />/) break; if(t[j]=="" || t[j] ~ /^-/) continue; print clean(t[j]) } }   #BASHWRITE_MUT_VERBS
        else if(w=="chmod"||w=="chown"){ sk=0; for(j=i+1;j<=k;j++){ if(t[j] ~ />/) break; if(t[j]=="" || t[j] ~ /^-/) continue; if(!sk){ sk=1; continue } print clean(t[j]) } }
        else if(w=="sponge"){ for(j=i+1;j<=k;j++){ if(t[j] ~ />/) break; if(t[j]=="" || t[j] ~ /^-/) continue; print clean(t[j]) } }
        else if(w=="find"){ del=0; for(j=i+1;j<=k;j++){ if(t[j]=="-delete"||t[j]=="-fprint"||t[j]=="-fprintf") del=1 } if(del){ for(j=i+1;j<=k;j++){ if(t[j]=="") continue; if(t[j] ~ />/) break; if(t[j] ~ /^-/) break; print clean(t[j]) } } }
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
  bd_block "BLOCKED (bash write guard, F-A): this Bash command would MUTATE file(s) outside $_z:${BLOCKED}. A Bash mutation (sed -i / redirect / tee / cp / mv / dd / truncate / install / ln / rm / rmdir / mkdir / chmod / chown / sponge / find -delete) is not allowed to write where the Write/Edit guards forbid. Command-string inspection is conservative (best-effort): if a target's location can't be proven safe it is refused. Write only within zone, or perform the change via an Edit the scope guard can vet."
fi
exit 0
