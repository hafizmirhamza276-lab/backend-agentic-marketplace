#!/usr/bin/env sh
# minimalist-ladder.sh — production test ladder for the `minimalist` plugin. POSIX sh, `set -eu`,
# isolated mktemp fixtures. Each check carries a FIRE control (a crafted bad fixture -> a finding)
# AND a SILENT twin (the clean/real artifact -> nothing), so a broken check FAILS the suite (it is
# never vacuous). Mutation sentinels prove the load-bearing lines are load-bearing.
#
# The minimalist plugin is an always-on "write the least code that works" capability: a SessionStart
# hook injects the full ladder (skills/minimal-code/SKILL.md) and a UserPromptSubmit hook re-injects a
# compact reminder every turn. Both hooks are node-guarded + fail-quiet, so the suite SKIPS the
# node-behavior tiers when node is absent (mirroring the repo's host-capability skip pattern) and the
# rest still runs. The mode toggle (scripts/set-mode.sh) is pure shell and runs unconditionally.
#
# Tiers:
#   1. STRUCTURE — the real SKILL.md carries all 6 ladder rungs, all 4 never-cut guardrails, the
#      PLAN/gate-reconciliation clause, and the `bd:min:` marker convention (skill_lint silent on it).
#   2. SENTINEL (skill) — a fixture skill with one required element removed -> skill_lint FIRES for it
#      (every assertion is load-bearing; the linter is not vacuous).
#   3. HOOK CONTRACT — hooks.json declares BOTH SessionStart + UserPromptSubmit; every command entry is
#      node-guarded, references ${CLAUDE_PLUGIN_ROOT}, and carries a timeout (so auditor D6/D6b stay
#      silent); plugin.json has NO hooks key.
#   4. INJECTOR (node) — activate.js emits the full ladder; turn.js emits ONLY the compact reminder;
#      mode=off silences BOTH and exits 0. SKIPPED when node is absent.
#   5. SENTINEL (off-guard) — neuter activate.js's off-guard -> mode=off WRONGLY emits -> the off-guard
#      is load-bearing. SKIPPED when node is absent.
#   6. MODE TOGGLE — set-mode.sh round-trips each valid mode into the mode file AND STATUS.json; an
#      invalid mode is rejected (default preserved; exit 2 only under MINIMALIST_ENFORCE=1); STATUS
#      schema correct. SENTINEL: break the validation -> an invalid mode is accepted.
#   7. END-TO-END — set a mode, then prove it is visible via the STATUS contract (bd_status_read).
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
export ROOT
LIB="$ROOT/shared/lib/common.sh";                 export LIB
PLUGIN="$ROOT/plugins/minimalist"
REAL_SKILL="$PLUGIN/skills/minimal-code/SKILL.md"
HOOKS_JSON="$PLUGIN/hooks/hooks.json"
ACTIVATE="$PLUGIN/hooks/minimalist-activate.js"
TURN="$PLUGIN/hooks/minimalist-turn.js"
SET_MODE="$PLUGIN/scripts/set-mode.sh"
TAB=$(printf '\t')

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s  --  %s\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
skipnote()  { printf 'SKIP  %s\n' "$1"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT INT TERM

# skill_lint <skillfile> : print one "MISSING <slug>" line per ABSENT required element; silent when the
# skill carries every required element. The single source of truth for "is this a complete ladder skill".
skill_lint() {
  f="$1"
  [ -f "$f" ] || { printf 'MISSING file\n'; return 0; }
  # 6 ladder rungs
  grep -q  'need to exist'            "$f" || printf 'MISSING rung1-exist\n'
  grep -q  'standard library'         "$f" || printf 'MISSING rung2-stdlib\n'
  grep -qE 'native platform|runtime feature' "$f" || printf 'MISSING rung3-native\n'
  grep -q  'installed dependency'     "$f" || printf 'MISSING rung4-dependency\n'
  grep -q  'one line'                 "$f" || printf 'MISSING rung5-oneline\n'
  grep -q  'minimum code that works'  "$f" || printf 'MISSING rung6-minimum\n'
  # 4 never-cut guardrails
  grep -qi 'input validation'         "$f" || printf 'MISSING guard-validation\n'
  grep -qi 'error handling'           "$f" || printf 'MISSING guard-errorhandling\n'
  grep -qi 'security'                 "$f" || printf 'MISSING guard-security\n'
  grep -qi 'accessibility'            "$f" || printf 'MISSING guard-accessibility\n'
  # PLAN / gate reconciliation (the repo's addition)
  grep -q  'UNREQUESTED scope'        "$f" || printf 'MISSING plan-unrequested\n'
  grep -q  'edge-case coverage'       "$f" || printf 'MISSING plan-edgecase\n'
  # the bd:min: marker convention
  grep -q  'bd:min:'                  "$f" || printf 'MISSING marker\n'
}

echo "== minimalist test ladder =="
echo "ROOT=$ROOT"
HAVE_NODE=no; command -v node >/dev/null 2>&1 && HAVE_NODE=yes
HOSTPY=no; for c in python3 python "py -3"; do if $c -c "pass" >/dev/null 2>&1; then HOSTPY=yes; break; fi; done
echo "node: $HAVE_NODE | host working python: $HOSTPY"
echo ""

# ===========================================================================
# TIER 1 — STRUCTURE: the real SKILL.md is a complete ladder (skill_lint silent on it).
# ===========================================================================
echo "-- tier 1: STRUCTURE (real SKILL.md is complete) --"
out=$(skill_lint "$REAL_SKILL")
n=$(printf '%s\n' "$out" | grep -c '^MISSING' 2>/dev/null || true)
assert_eq "T1 skill_lint SILENT on the real SKILL.md (0 missing)" 0 "$n"
# Spell out each required element as its own assertion (informative on failure).
for tok in \
  'rung1-exist:need to exist' \
  'rung2-stdlib:standard library' \
  'rung4-dependency:installed dependency' \
  'rung5-oneline:one line' \
  'rung6-minimum:minimum code that works' \
  'guard-validation:input validation' \
  'guard-errorhandling:error handling' \
  'guard-security:security' \
  'guard-accessibility:accessibility' \
  'plan-unrequested:UNREQUESTED scope' \
  'plan-edgecase:edge-case coverage' \
  'marker:bd:min:'
do
  slug=${tok%%:*}; needle=${tok#*:}
  if grep -qi "$needle" "$REAL_SKILL"; then ok "T1 SKILL.md carries $slug"; else bad "T1 SKILL.md $slug" "missing [$needle]"; fi
done
# rung 3 is an either/or (native platform OR runtime feature).
if grep -qE 'native platform|runtime feature' "$REAL_SKILL"; then ok "T1 SKILL.md carries rung3-native"; else bad "T1 SKILL.md rung3-native" "missing"; fi
# Attribution to Ponytail (MIT) must be present.
if grep -qi 'Ponytail' "$REAL_SKILL" && grep -qi 'MIT' "$REAL_SKILL"; then ok "T1 SKILL.md attributes Ponytail (MIT)"; else bad "T1 attribution" "missing Ponytail/MIT"; fi
# Intensity levels documented (off/lite/full/ultra), default full.
imiss=0
for lvl in off lite full ultra; do grep -q "\\b$lvl\\b" "$REAL_SKILL" || imiss=$((imiss+1)); done
assert_eq "T1 SKILL.md documents all 4 intensity levels (off/lite/full/ultra)" 0 "$imiss"
echo ""

# ===========================================================================
# TIER 2 — SENTINEL (skill): removing ANY required element makes skill_lint FIRE for exactly it.
# Proves every assertion in skill_lint is load-bearing (the linter is not vacuous).
# ===========================================================================
echo "-- tier 2: SENTINEL (skill — drop one element -> linter fires) --"
# Map each required element to the literal text whose removal must trip its slug.
# (slug=needle) — needle is grep'd out of a copy of the real skill to build the mutant.
# The needle MUST be the SAME token skill_lint greps for, removed case-insensitively, so EVERY
# occurrence (frontmatter + body) is stripped — otherwise a copy left in the frontmatter would keep
# the linter silent and the sentinel would be vacuous (e.g. "security"/"accessibility" also appear in
# the description). Removing the needle must therefore make skill_lint's own grep find nothing -> fire.
sentinel_one() {  # <slug> <needle> <expect-slug>
  slug="$1"; needle="$2"; expect="$3"
  mut="$WORK/skill-$slug.md"
  grep -vi "$needle" "$REAL_SKILL" > "$mut" 2>/dev/null || true
  real_out=$(skill_lint "$REAL_SKILL"); mut_out=$(skill_lint "$mut")
  real_hit=no;  printf '%s\n' "$real_out" | grep -q "MISSING $expect" && real_hit=yes
  mut_hit=no;   printf '%s\n' "$mut_out"  | grep -q "MISSING $expect" && mut_hit=yes
  if [ "$real_hit" = no ] && [ "$mut_hit" = yes ]; then
    ok "T2 sentinel: dropping '$needle' -> skill_lint fires $expect (real silent)"
  else
    bad "T2 sentinel $slug" "real_hit=$real_hit mut_hit=$mut_hit (want no/yes)"
  fi
}
sentinel_one rung1   'need to exist'           rung1-exist
sentinel_one rung2   'standard library'        rung2-stdlib
sentinel_one rung3   'native platform'         rung3-native
sentinel_one rung4   'installed dependency'    rung4-dependency
sentinel_one rung5   'one line'                rung5-oneline
sentinel_one rung6   'minimum code that works' rung6-minimum
sentinel_one valid   'input validation'        guard-validation
sentinel_one errh    'error handling'          guard-errorhandling
sentinel_one sec     'security'                guard-security
sentinel_one a11y    'accessibility'           guard-accessibility
sentinel_one plan    'UNREQUESTED scope'       plan-unrequested
sentinel_one edge    'edge-case coverage'      plan-edgecase
sentinel_one marker  'bd:min:'                 marker
echo ""

# ===========================================================================
# TIER 3 — HOOK CONTRACT: hooks.json declares BOTH events; every command is node-guarded, references
# ${CLAUDE_PLUGIN_ROOT}, and carries a timeout; plugin.json has NO hooks key. Plus the design tie-in:
# the auditor's D6/D6b/D7 stay SILENT on minimalist (incl. the guard-BEFORE placement that keeps D6's
# parsed path clean). Pure static + the real auditor lib; needs NO node.
# ===========================================================================
echo "-- tier 3: HOOK CONTRACT (events, node-guard, plugin-root, timeout, no-hooks-key) --"
CHECKS="$ROOT/plugins/auditor/scripts/lib-audit-checks.sh"
PLUGIN_JSON="$PLUGIN/.claude-plugin/plugin.json"
grep -q '"SessionStart"'     "$HOOKS_JSON" && ok "T3 hooks.json declares SessionStart"     || bad "T3 SessionStart" "missing"
grep -q '"UserPromptSubmit"' "$HOOKS_JSON" && ok "T3 hooks.json declares UserPromptSubmit" || bad "T3 UserPromptSubmit" "missing"
ncmd=$(grep -c '"command":' "$HOOKS_JSON" 2>/dev/null || true)
nguard=$(grep '"command":' "$HOOKS_JSON" 2>/dev/null | grep -cF 'command -v node' || true)
nroot=$(grep '"command":' "$HOOKS_JSON" 2>/dev/null | grep -cF '${CLAUDE_PLUGIN_ROOT}' || true)
nto=$(grep -c '"timeout":' "$HOOKS_JSON" 2>/dev/null || true)
assert_eq "T3 hooks.json has exactly 2 command entries"            2 "$ncmd"
assert_eq "T3 EVERY command is node-guarded ('command -v node')"   "$ncmd" "$nguard"
assert_eq "T3 EVERY command references \${CLAUDE_PLUGIN_ROOT}"      "$ncmd" "$nroot"
assert_eq "T3 EVERY hook entry carries a timeout"                  "$ncmd" "$nto"
if grep -q '"hooks"' "$PLUGIN_JSON"; then bad "T3 plugin.json hooks key" "present (must be auto-discovered)"; else ok "T3 plugin.json carries NO hooks key (auto-discovered)"; fi
# A commandWindows variant accompanies each POSIX command (cross-platform; auditor ignores it).
nwin=$(grep -c '"commandWindows":' "$HOOKS_JSON" 2>/dev/null || true)
assert_eq "T3 each hook ships a commandWindows variant" "$ncmd" "$nwin"
# Auditor tie-in: D6/D6b/D7 must be SILENT on minimalist (the whole point of guard-before + 100755 + valid manifest).
for d in audit_d6 audit_d6b audit_d7; do
  hits=$(AUDIT_ROOT="$ROOT" bash -c '. "$LIB"; . "'"$CHECKS"'"; '"$d" 2>/dev/null | grep -ic minimalist || true)
  assert_eq "T3 $d SILENT on minimalist (auditor stays green)" 0 "$hits"
done
# SENTINEL (design): the trailing-`|| exit 0` (Ponytail) form corrupts D6's parsed path -> D6 FIRES;
# the real guard-before form is silent. Proves the placement decision is load-bearing for auditor-silence.
FX="$WORK/d6fix"; mkdir -p "$FX/plugins/min2/hooks"
cat > "$FX/plugins/min2/hooks/hooks.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "command -v node >/dev/null 2>&1 && node \"${CLAUDE_PLUGIN_ROOT}/hooks/x.js\" || exit 0", "timeout": 5 } ] }
    ]
  }
}
JSON
printf '//x\n' > "$FX/plugins/min2/hooks/x.js"; chmod +x "$FX/plugins/min2/hooks/x.js" 2>/dev/null || true
mut_d6=$(AUDIT_ROOT="$FX"   bash -c '. "$LIB"; . "'"$CHECKS"'"; audit_d6' 2>/dev/null | grep -c 'd6-hook-contract' || true)
real_d6=$(AUDIT_ROOT="$ROOT" bash -c '. "$LIB"; . "'"$CHECKS"'"; audit_d6' 2>/dev/null | grep -ic minimalist || true)
if [ "${mut_d6:-0}" -ge 1 ] && [ "${real_d6:-0}" = 0 ]; then
  ok "T3 sentinel: trailing '|| exit 0' trips D6 ($mut_d6), guard-before silent -> placement load-bearing"
else
  bad "T3 D6 placement sentinel" "mut=$mut_d6 (want >=1) real=$real_d6 (want 0)"
fi
echo ""

# ===========================================================================
# TIER 4 — INJECTOR (node behavior): activate.js emits the FULL ladder; turn.js emits ONLY the compact
# reminder; mode=off silences BOTH and exits 0. SKIPPED when node is absent (host-capability skip).
# ===========================================================================
echo "-- tier 4: INJECTOR (node behavior) --"
if [ "$HAVE_NODE" = yes ]; then
  PF="$WORK/proj-full"; mkdir -p "$PF/.claude/minimalist"; printf 'full' > "$PF/.claude/minimalist/mode"
  a_out=$(CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PF" node "$ACTIVATE" 2>/dev/null || true)
  if printf '%s' "$a_out" | grep -q 'need to exist' && printf '%s' "$a_out" | grep -q 'minimum code that works'; then
    ok "T4 activate.js emits the ladder rungs (full)"
  else bad "T4 activate rungs" "got first line: $(printf '%s' "$a_out" | head -1)"; fi
  printf '%s' "$a_out" | grep -qi 'ATTRIBUTION' && ok "T4 activate.js emits the FULL skill (ATTRIBUTION section present)" || bad "T4 activate full" "no full-skill marker"
  printf '%s' "$a_out" | grep -q 'mode=full' && ok "T4 activate.js banner names mode=full" || bad "T4 activate banner" "missing"
  # frontmatter must be stripped (no YAML leakage).
  if printf '%s' "$a_out" | grep -qE '^name:[[:space:]]*minimal-code|^---$'; then bad "T4 frontmatter leak" "YAML leaked into context"; else ok "T4 activate.js strips the YAML frontmatter"; fi
  # intensity filter (silent twin): FULL mode EXCLUDES the ultra-only block (T7 proves ULTRA includes it).
  if printf '%s' "$a_out" | grep -q 'ULTRA extra-strictness'; then bad "T4 intensity filter" "full mode leaked the ultra-only block"; else ok "T4 full mode excludes the ultra-only block (intensity filter works)"; fi

  t_out=$(CLAUDE_PROJECT_DIR="$PF" node "$TURN" 2>/dev/null || true)
  if printf '%s' "$t_out" | grep -qi 'never cut' && printf '%s' "$t_out" | grep -q 'need to exist'; then
    ok "T4 turn.js emits the compact reminder (rungs + never-cut line)"
  else bad "T4 turn reminder" "got: $t_out"; fi
  if printf '%s' "$t_out" | grep -qE 'ATTRIBUTION|PLAN / GATE|bd:min:'; then bad "T4 turn compactness" "turn.js leaked full-skill content"; else ok "T4 turn.js is COMPACT (no full-skill content)"; fi
  tln=$(printf '%s\n' "$t_out" | grep -c . || true)
  if [ "${tln:-99}" -le 6 ]; then ok "T4 turn.js reminder is short (<=6 non-empty lines: $tln)"; else bad "T4 turn length" "$tln lines"; fi

  PO="$WORK/proj-off"; mkdir -p "$PO/.claude/minimalist"; printf 'off' > "$PO/.claude/minimalist/mode"
  ab=$(CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PO" node "$ACTIVATE" 2>/dev/null | wc -c | tr -d ' ')
  tb=$(CLAUDE_PROJECT_DIR="$PO" node "$TURN" 2>/dev/null | wc -c | tr -d ' ')
  assert_eq "T4 mode=off: activate.js emits NOTHING (0 bytes)" 0 "$ab"
  assert_eq "T4 mode=off: turn.js emits NOTHING (0 bytes)"     0 "$tb"
  rc=0; CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PO" node "$ACTIVATE" >/dev/null 2>&1 || rc=$?
  assert_eq "T4 activate.js exits 0 on mode=off" 0 "$rc"
else
  skipnote "T4 INJECTOR (node absent — mirror the repo's host-capability skip)"
fi
echo ""

# ===========================================================================
# TIER 5 — SENTINEL (off-guard): neuter each injector's off-guard -> mode=off WRONGLY emits, proving the
# guard is load-bearing. SKIPPED when node is absent.
# ===========================================================================
echo "-- tier 5: SENTINEL (off-guard — neuter -> off wrongly emits) --"
if [ "$HAVE_NODE" = yes ]; then
  PO="$WORK/proj-off"; mkdir -p "$PO/.claude/minimalist"; printf 'off' > "$PO/.claude/minimalist/mode"
  for pair in "activate:$ACTIVATE" "turn:$TURN"; do
    nm=${pair%%:*}; src=${pair#*:}
    mut="$WORK/mut-$nm.js"
    sed '/load-bearing off-guard/ s/process.exit(0)/0/' "$src" > "$mut"
    if cmp -s "$src" "$mut"; then bad "T5 $nm sentinel" "sed no-op — vacuous"; continue; fi
    rb=$(CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PO" node "$src" 2>/dev/null | wc -c | tr -d ' ')
    mb=$(CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PO" node "$mut" 2>/dev/null | wc -c | tr -d ' ')
    if [ "${rb:-1}" = 0 ] && [ "${mb:-0}" -gt 0 ]; then
      ok "T5 $nm off-guard load-bearing (real off=0 bytes, neutered mutant off=$mb bytes)"
    else bad "T5 $nm off-guard" "real=$rb (want 0) mut=$mb (want >0)"; fi
  done
else
  skipnote "T5 off-guard SENTINEL (node absent)"
fi
echo ""

# ===========================================================================
# TIER 6 — MODE TOGGLE: set-mode.sh round-trips each valid mode into the mode file AND STATUS.json; an
# invalid mode is rejected FAIL-CLOSED (current/default preserved, nothing written; advisory exit 0,
# exit 2 only under MINIMALIST_ENFORCE=1); the STATUS schema is correct. Pure shell — runs always.
# SENTINEL: neuter the validation (min_valid always true) -> an invalid mode is ACCEPTED -> load-bearing.
# ===========================================================================
echo "-- tier 6: MODE TOGGLE (round-trip + invalid rejection + STATUS) --"
PM="$WORK/proj-mode"; mkdir -p "$PM"
read_status() { CLAUDE_PROJECT_DIR="$PM" bash -c '. "$LIB"; bd_status_read minimalist '"$1" 2>/dev/null || true; }
for m in off lite full ultra; do
  CLAUDE_PROJECT_DIR="$PM" bash "$SET_MODE" "$m" >/dev/null 2>&1 || true
  fv=$(cat "$PM/.claude/minimalist/mode" 2>/dev/null || true)
  assert_eq "T6 set '$m' -> mode file holds it"   "$m" "$fv"
  assert_eq "T6 set '$m' -> STATUS.mode reflects it" "$m" "$(read_status mode)"
done
# STATUS schema after a valid set: module/state/updated_at present, state=done.
assert_eq "T6 STATUS.module = minimalist" minimalist "$(read_status module)"
assert_eq "T6 STATUS.state = done"        done       "$(read_status state)"
if [ -n "$(read_status updated_at)" ]; then ok "T6 STATUS.updated_at present"; else bad "T6 updated_at" "empty"; fi
# Invalid -> fail-closed: current (ultra) preserved; advisory exit 0.
rc=0; CLAUDE_PROJECT_DIR="$PM" bash "$SET_MODE" BOGUS >/dev/null 2>&1 || rc=$?
assert_eq "T6 invalid mode is advisory (exit 0)" 0 "$rc"
assert_eq "T6 invalid mode preserves current (writes nothing)" ultra "$(cat "$PM/.claude/minimalist/mode" 2>/dev/null || true)"
# Invalid under enforce -> exit 2 (never silently fail open).
rc=0; CLAUDE_PROJECT_DIR="$PM" MINIMALIST_ENFORCE=1 bash "$SET_MODE" BOGUS >/dev/null 2>&1 || rc=$?
assert_eq "T6 invalid mode under MINIMALIST_ENFORCE=1 exits 2" 2 "$rc"
# SENTINEL — make min_valid always true; an invalid mode is then ACCEPTED (written), proving validation
# is load-bearing. The mutant is built in a MIRRORED plugin layout ($WORK/mutplug/{scripts,lib}) so it
# can still source ../lib/common.sh — a bare copy elsewhere would fail to find the vendored lib and
# misbehave for the wrong reason (same setup the ops ladder uses for its release-gate sentinel).
MUTP="$WORK/mutplug"; mkdir -p "$MUTP/scripts" "$MUTP/lib"
cp "$LIB" "$MUTP/lib/common.sh"
MUT="$MUTP/scripts/set-mode.sh"
sed 's/^min_valid().*/min_valid() { return 0; }/' "$SET_MODE" > "$MUT"
if cmp -s "$SET_MODE" "$MUT"; then
  bad "T6 validation sentinel" "sed no-op — vacuous"
else
  PS="$WORK/proj-sent"; PSM="$WORK/proj-sent-mut"; mkdir -p "$PS" "$PSM"
  CLAUDE_PROJECT_DIR="$PS"  bash "$SET_MODE" full  >/dev/null 2>&1 || true   # real: seed a known-good mode
  CLAUDE_PROJECT_DIR="$PS"  bash "$SET_MODE" BOGUS >/dev/null 2>&1 || true   # real: rejected -> keeps full
  realmode=$(cat "$PS/.claude/minimalist/mode" 2>/dev/null || true)
  CLAUDE_PROJECT_DIR="$PSM" bash "$MUT"      full  >/dev/null 2>&1 || true   # mutant: seed full
  CLAUDE_PROJECT_DIR="$PSM" bash "$MUT"      BOGUS >/dev/null 2>&1 || true   # mutant: accepts -> writes bogus
  mutmode=$(cat "$PSM/.claude/minimalist/mode" 2>/dev/null || true)
  if [ "$realmode" = full ] && [ "$mutmode" = bogus ]; then
    ok "T6 sentinel: real REJECTS 'BOGUS' (keeps full), validation-neutered mutant ACCEPTS it -> validation load-bearing"
  else
    bad "T6 validation sentinel" "realmode=$realmode (want full) mutmode=$mutmode (want bogus)"
  fi
fi
echo ""

# ===========================================================================
# TIER 7 — END-TO-END + cross-module: the plugin is registered in the marketplace (version consistent
# with plugin.json, so ops O2 stays silent); a /minimize sets a mode that is VISIBLE via the STATUS
# contract AND read identically by the SessionStart injector. Plus the remaining mutation sentinels:
# registration and the STATUS mirror.
# ===========================================================================
echo "-- tier 7: END-TO-END + cross-module --"
MK="$ROOT/.claude-plugin/marketplace.json"
PLUGIN_JSON="$PLUGIN/.claude-plugin/plugin.json"
# (a) registration present (name + source dir).
if grep -q '"minimalist"' "$MK" && grep -q '"\./plugins/minimalist"' "$MK"; then
  ok "T7 marketplace.json registers minimalist (source ./plugins/minimalist)"
else bad "T7 registration" "missing name/source in marketplace.json"; fi
# version consistency (the ops O2 invariant): marketplace entry version == plugin.json version.
mkver=$(grep -A4 '"minimalist"' "$MK" 2>/dev/null | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
pjver=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PLUGIN_JSON" 2>/dev/null | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
assert_eq "T7 marketplace version == plugin.json version (ops O2 stays silent)" "$pjver" "$mkver"

# (b) e2e: /minimize ultra -> STATUS visible via bd_status_read AND the injector reads the same mode.
PE="$WORK/proj-e2e"; mkdir -p "$PE"
CLAUDE_PROJECT_DIR="$PE" bash "$SET_MODE" ultra >/dev/null 2>&1 || true
assert_eq "T7 e2e: STATUS.mode visible after /minimize ultra"  ultra "$(CLAUDE_PROJECT_DIR="$PE" bash -c '. "$LIB"; bd_status_read minimalist mode'  2>/dev/null || true)"
assert_eq "T7 e2e: STATUS.state visible after /minimize ultra" done  "$(CLAUDE_PROJECT_DIR="$PE" bash -c '. "$LIB"; bd_status_read minimalist state' 2>/dev/null || true)"
if [ "$HAVE_NODE" = yes ]; then
  inj=$(CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PE" node "$ACTIVATE" 2>/dev/null || true)
  printf '%s' "$inj" | grep -q 'mode=ultra'           && ok "T7 e2e: injector reflects the set mode (banner mode=ultra)"  || bad "T7 e2e injector mode" "no mode=ultra banner"
  printf '%s' "$inj" | grep -q 'ULTRA extra-strictness' && ok "T7 e2e: ultra intensity INCLUDES the ultra-only block"     || bad "T7 e2e ultra block" "missing"
  CLAUDE_PROJECT_DIR="$PE" bash "$SET_MODE" off >/dev/null 2>&1 || true
  ob=$(CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PE" node "$ACTIVATE" 2>/dev/null | wc -c | tr -d ' ')
  assert_eq "T7 e2e: /minimize off silences the injector (0 bytes)" 0 "$ob"
else
  skipnote "T7 e2e injector cross-check (node absent)"
fi

# (c) registration SENTINEL: drop the minimalist entry -> the registration check fires (load-bearing).
MKMUT="$WORK/marketplace-nomin.json"
grep -v 'minimalist' "$MK" > "$MKMUT" 2>/dev/null || true
real_reg=no; grep -q '"minimalist"' "$MK"    && real_reg=yes
mut_reg=no;  grep -q '"minimalist"' "$MKMUT" && mut_reg=yes
if [ "$real_reg" = yes ] && [ "$mut_reg" = no ]; then
  ok "T7 sentinel: dropping the entry -> registration check fires (real registered, mutant not) -> load-bearing"
else bad "T7 registration sentinel" "real=$real_reg mut=$mut_reg (want yes/no)"; fi

# (d) STATUS-mirror SENTINEL: neuter min_status -> STATUS.json is NOT written -> bd_status_read empty,
# proving the STATUS mirror is load-bearing for dashboard visibility. Mirrored layout so the lib resolves.
MUTP2="$WORK/mutplug2"; mkdir -p "$MUTP2/scripts" "$MUTP2/lib"; cp "$LIB" "$MUTP2/lib/common.sh"
MUT2="$MUTP2/scripts/set-mode.sh"
sed 's/^min_status() .*/min_status() { :; }/' "$SET_MODE" > "$MUT2"
if cmp -s "$SET_MODE" "$MUT2"; then
  bad "T7 status sentinel" "sed no-op — vacuous"
else
  PR="$WORK/pr-stat"; PMU="$WORK/pmu-stat"; mkdir -p "$PR" "$PMU"
  CLAUDE_PROJECT_DIR="$PR"  bash "$SET_MODE" full >/dev/null 2>&1 || true
  CLAUDE_PROJECT_DIR="$PMU" bash "$MUT2"      full >/dev/null 2>&1 || true
  r_st=$(CLAUDE_PROJECT_DIR="$PR"  bash -c '. "$LIB"; bd_status_read minimalist mode' 2>/dev/null || true)
  m_st=$(CLAUDE_PROJECT_DIR="$PMU" bash -c '. "$LIB"; bd_status_read minimalist mode' 2>/dev/null || true)
  rfile=$(cat "$PMU/.claude/minimalist/mode" 2>/dev/null || true)   # the mode FILE is still written
  if [ "$r_st" = full ] && [ -z "$m_st" ] && [ "$rfile" = full ]; then
    ok "T7 sentinel: real writes STATUS (mode=full); status-neutered mutant writes the mode file but NO STATUS -> mirror load-bearing"
  else bad "T7 status sentinel" "real_status=[$r_st] mut_status=[$m_st] mut_file=[$rfile]"; fi
fi
echo ""

echo "== minimalist ladder summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
