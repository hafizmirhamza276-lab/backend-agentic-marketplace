# AUDIT — backend-agentic-marketplace (explorer + builder)

**Date:** 2026-06-15 · **Scope:** `.claude-plugin/marketplace.json`, `plugins/explorer/*`, `plugins/builder/*`, docs.
**Method:** read every component; ran the scripts in isolated temp dirs; cross-checked every hook/plugin/marketplace contract against the official Claude Code docs (fetched live, cited below); installed and ran ShellCheck 0.11.0. Read-only — the only file created is this one.

**Docs consulted (fetched 2026-06-15):**
- Hooks reference (events, stdin fields, exit codes): `https://code.claude.com/docs/en/hooks` (redirected from `docs.claude.com/en/docs/claude-code/hooks`).
- Plugins reference (manifest schema, directory layout, agent frontmatter, `${CLAUDE_PLUGIN_ROOT}`): `https://code.claude.com/docs/en/plugins-reference`.

---

## 1. Executive summary & production-readiness verdict

The **packaging is sound and the design is coherent**: both plugins follow the required layout, all manifests are valid, every agent/skill/command referenced is wired up, the planner↔gate contract lines up, and the recent fixes (exec bits, LF, LICENSE, manifest `hooks` key, README) all held. On **Linux/macOS with a real `python3`**, the system largely behaves as designed.

**It is not yet production-ready, because the deterministic gates — the plugins' headline feature — are fragile in ways that matter most on Windows, the platform the project explicitly targets.** The single most important problem: the builder **scope guard fails open** (crashes, edits proceed) on the *default* Windows configuration, where `python3` resolves to the Microsoft Store "App Execution Alias" stub rather than a real interpreter. The same stub makes the explorer completeness gate **false-fail** ("index.json is not valid JSON" on valid JSON; blocks under enforce) and makes the builder's flagship "index.json path-resolution" check **silently no-op**. Separately, both PreToolUse guards can be **bypassed with `..` path traversal**, and the scope guard's **basename fallback** lets a same-named file in another directory slip through when a plan lists bare filenames.

**Verdict: BETA / installable, but do not rely on the gates as written — fix F1 before trusting "scope is law", especially on Windows.** Roughly: Linux/macOS + real python3 → mostly fine modulo F2/F3/F5/F6; Windows default → core safety guard non-functional. Audit coverage is high but not 100%: scripts were exercised directly and contracts verified against docs, but the plugins were **not** run inside a live Claude Code session.

---

## 1a. Resolution status — updated 2026-06-17

The verdict above is the ORIGINAL 2026-06-15 reading. **The F1–F13 class is now fixed and, crucially, regression-guarded by the `auditor` plugin's deterministic detectors** (`plugins/auditor/scripts/lib-audit-checks.sh`), which are SILENT on the clean tree and fire only if a failure class is re-introduced — so a fix cannot silently regress. The detectors map onto the findings: **D1**↔fail-open (F1), **D2**↔traversal (F2), **D3**↔notebook-gap (F9), **D4** stdin-block + **D6b** hook-no-timeout (F11), **D5**↔sessionstart-stderr (F6), **D8** lib-drift (keeps every vendored copy from running stale shared logic), **D9**↔line-endings/exec (F10), plus the ADVISORY doc-drift / agent-tools / stale-index detectors (F5 / F12 / F13). The original blocker **F1** is fixed — `bd_resolve_python`/`bd_have_python` resolve a *working* interpreter and `bd_hook_field` has a grep fallback so it can never propagate a non-zero exit — and is proven by `tests/run.sh` (stub-python "no fail-open") and `tests/ladder.sh` Tier 6 (python real/stub/none portability matrix).

### External review (hardening pass)

A later external review surfaced five additional **precision** findings — narrower than F1–F13: the gates functioned, but were looser or broader than intended. All five are now fixed AND locked by a regression test. Listed with only what is actually fixed + tested:

| # | Finding | Resolution | Regression lock |
|---|---------|-----------|-----------------|
| 1 | guard-scope **fail-open on unparseable scope** | a PLAN.md whose `## Scope` has no parseable file list now **fails closed** (`bd_block`, exit 2) instead of warn + exit 0 — a broken Scope is no longer more permissive than a valid one; PLAN.md itself stays editable so the user can add a Scope and recover | `tests/ladder.sh` **Tier 8** — Defect A: `A1` unparseable-Scope edit → BLOCK, plus a mutation sentinel proving the fail-closed line is load-bearing (real BLOCKS 2, neutered mutant PASSES 0) |
| 2 | guard-scope **`.claude/*` over-permission** | the blanket `.claude/*` always-allow zone is narrowed to `.claude/builder/*` + `.claude/specs/*` (with a narrow memory-sync carve-out for the four explorer risk-map artifacts), so the builder can no longer write another module's STATUS outside the plan | `tests/ladder.sh` **Tier 8** — Defect B fire/silent twins + a mutation sentinel proving the narrowed allow-zone is load-bearing |
| 3 | guard-readonly **unanchored allow-zone** | the explorer read-only zone is anchored to THIS project (`bd_project_dir` + `bd_normalize_path`, `case "$abs" in "$ZONE"/*)`) instead of a bare `/.claude/explorer/` substring, so another project's memory path no longer slips through | `tests/ladder.sh` **Tier 9** — `TR2` outside-project path → BLOCK (passed before the fix) + `TR6` sentinel proving the `$ZONE` prefix anchor is load-bearing |
| 4 | verify-release **loose coverage match** | `coverage_gaps` counts a PLAN task as covered ONLY via the structured per-task header the builder emits (`### Task <id> … coverage`), never a casual prose `Task <id>` mention; whole-token id match preserved (`1` ≠ `10`) | `tests/ladder.sh` **Tier 10** — `TC1` fix, `TC2` control, `TC3` whole-token, `TC4` mutation sentinel (loose-match mutant passes the prose-only fixture) + `tests/e2e-ladder.sh` **Tier 2(c)** |
| 5 | pipeline-status **incomplete dashboard** | the conductor dashboard now natively rows auditor/reviewer/ops with each module's state + headline count (auditor `high=`, reviewer/ops `blocking=`), so a stale or FAILED auxiliary gate is visible BEFORE the release gate aggregates it; an absent STATUS prints `not run`; still exits 0 and stays pure-shell (no python dependency) | `tests/e2e-ladder.sh` **Tier 3** — all six native module rows on the green fixture (auditor `done`+`high=0`, reviewer/ops `done`+`blocking=0`) and `not run` rows + exit 0 on an empty project |

This update re-scopes nothing else in §2/§3 — those remain the original findings, now resolved and detector-guarded as described above.

---

## 2. Findings table

| ID | Severity | Area | Summary |
|----|----------|------|---------|
| F1 | **High** (Critical on Windows) | Hooks / Security / Portability | `bd_hook_field` python branch has no fallback; on the Windows `python3` Store-stub `guard-scope.sh` crashes (exit 49) under `set -e` before checking scope → **scope guard fails open** |
| F2 | **High** | Security | Both PreToolUse guards match an **un-normalized** path → `..` traversal escapes the allow-zone (`.claude/explorer/../../evil.py` is allowed) |
| F3 | Medium | Security | `guard-scope.sh` basename fallback (`grep -qxF "$BASE"`) lets a same-named file in another dir pass when the plan's Scope lists a **bare filename** |
| F4 | Medium | Hooks / Portability | Store-stub `python3` is treated as "present": `verify-output.sh` false-reports "index.json is not valid JSON" (exits 2 under enforce); `verify-build.sh` index-path gate silently checks nothing |
| F5 | Medium | Docs | README "Configuration" says the scope guard is "advisory (warn only)" by default — but `guard-scope.sh` **hard-blocks** out-of-scope edits whenever a PLAN exists, regardless of `enforce_gates` |
| F6 | Medium | Hooks | Builder SessionStart guidance is printed to **stderr** (`bd_say`/`bd_warn`); SessionStart only feeds Claude via **stdout**, so the "recall, don't re-scan" nudge never reaches the model |
| F7 | Low | Hooks correctness | SubagentStop scripts read `subagent_type`; the documented field is **`agent_type`**. `record-coverage.sh` has no `agent_type` fallback → always logs "subagent" |
| F8 | Low | Shell | `check-builder-state.sh` aborts early under `set -e` when `MEMORY.md` lacks an `explored_commit:` line → recall nudge skipped |
| F9 | Low | Hooks coverage | Explorer read-only guard matcher omits `NotebookEdit` and doesn't read `notebook_path` → a notebook write outside `.claude/explorer/` is unguarded |
| F10 | Low / Nit | Portability / Tooling | Working-tree scripts are CRLF on Windows (autocrlf) → ShellCheck SC1017 locally. **Not shipped** (index is LF; `.gitattributes` forces LF) — informational |
| F11 | Nit | Robustness | No explicit per-hook `timeout`; scripts read stdin via `cat`, which blocks if ever invoked without a payload |
| F12 | Nit | Agents | Explorer agents declare both `tools:` (allowlist) and `disallowedTools:` (redundant); tool-restriction style is inconsistent with builder agents |
| F13 | Nit / Hygiene | Repo | Committed `.claude/explorer/` memory describes a codebase (`KPS-MobileSupport/…`) that no longer exists in the tree — stale demo data |

---

## 3. Findings in detail

### F1 — Scope guard fails open on the Windows `python3` stub (High; Critical on Windows)
**Where:** `plugins/builder/lib/common.sh:67-88` (`bd_hook_field`), `:18` (`bd_have_python`); `plugins/builder/scripts/guard-scope.sh:6` (`set -euo pipefail`), `:15` (`TARGET="$(bd_hook_field tool_input.file_path)"`). Same root cause hits `plugins/builder/scripts/record-progress.sh:5,15`.

**What's wrong:** `bd_have_python()` is `command -v python3`. On a default Windows install, `python3` resolves to the Microsoft Store **App Execution Alias stub** (`…\WindowsApps\python3`), which is on PATH even when no real Python named `python3` exists. The stub exits non-zero with **empty stdout** (stderr only). `bd_hook_field`'s python branch (lines 71-80) has **no `|| fallback`** — unlike every other python call site — so it propagates the stub's exit code. Under `set -euo pipefail`, `TARGET="$(bd_hook_field …)"` then **aborts the whole hook** before any scope check runs.

**Evidence (this host):**
```
command -v python3 -> /c/Users/.../WindowsApps/python3      # stub IS found
python3 --version  -> stdout=[]  exit=49                     # empty stdout, stderr-only error
# guard-scope.sh, DEFAULT PATH, an OUT-OF-SCOPE target that should be BLOCKED:
exit=49      # NOT 2 → not the block code
```
For PreToolUse only **exit 2** blocks; any other non-zero is a non-blocking error, so **the edit proceeds** — the guard does nothing. (If some harness build instead treated *any* non-zero as blocking, it would break *all* edits — fail-closed — which is equally wrong.) The whole builder "Scope is law" contract (`commands/start.md:46`, README) rests on this guard.

**Why it matters:** the advertised hard guarantee that out-of-scope edits are blocked is **absent on the default Windows setup** — the very platform the prior fix round (exec bits) targeted.

**Fix:** make `bd_have_python` detect a *working* interpreter (`python3 -c '' 2>/dev/null` exit-check, and/or prefer `python`/`py -3`), and give `bd_hook_field`'s python branch the same `|| <grep fallback>` the other call sites have so it can never return non-zero. Don't let parsing failures propagate through `set -e`. **Effort: S.**

---

### F2 — Path-traversal bypass in both PreToolUse guards (High)
**Where:** `plugins/explorer/scripts/guard-readonly.sh:44` (`[[ "$abs" == *"/.claude/explorer/"* ]]`); `plugins/builder/scripts/guard-scope.sh:24-26` (`case "$REL" in .claude/*)`).

**What's wrong:** both decide "in the allow-zone" by substring/glob on the **raw, un-normalized** path. A `..` segment keeps the allowed prefix as a substring while resolving elsewhere.

**Evidence (grep-fallback forced, so this is pure guard logic):**
```
guard-readonly  target='.claude/explorer/../../evil.py'  -> exit=0   # allowed (should block)
guard-scope     target='.claude/../src/b/evil.cs'        -> exit=0   # allowed (should block)
```
**Why it matters:** defense-in-depth guards bypassable with `..`. Explorer sub-agents lack edit tools (mitigation), but the main session is not similarly constrained.

**Fix:** canonicalize before comparing — `realpath -m`/`readlink -f`, or a pure-bash `..` collapse — then check the resolved path is inside the allow-zone. **Effort: S–M.**

---

### F3 — Basename fallback admits cross-directory files (Medium)
**Where:** `plugins/builder/scripts/guard-scope.sh:56-59` — membership test's third branch `printf '%s\n' "$SCOPE" | grep -qxF "$BASE"`.

**What's wrong:** the target's *basename* is matched against whole Scope lines. The PLAN format (`skills/plan-change/SKILL.md:38-41`) asks for "path first" but does not forbid bare filenames; when a Scope entry is a bare filename, any directory's same-named file passes.

**Evidence:**
```
Scope='config.json'        target='src/secret/config.json' -> exit=0  (WRONGLY allowed)
Scope='src/a/config.json'  target='src/b/config.json'      -> exit=2  (correctly blocked)
Scope='src/a/config.json'  target='src/a/config.json'      -> exit=0  (correct)
```
So the bypass requires a bare-filename Scope entry; full paths are safe.

**Fix:** drop the bare-basename branch (require repo-relative path equality), or only honor a basename match when the Scope entry itself is a bare filename **and** it resolves to exactly one file. **Effort: S.**

---

### F4 — Store-stub `python3` causes false failures / silent no-ops (Medium)
**Where:** `common.sh:18`; `plugins/explorer/scripts/verify-output.sh:30-32`; `plugins/builder/scripts/verify-build.sh:42-71`; `plugins/explorer/scripts/record-coverage.sh:13-19`.

**What's wrong:** because `command -v python3` is true for the stub, the "python present" branches run the stub and misbehave:
- `verify-output.sh:31` runs `python3 -c 'json.load…'`; the stub fails → `|| problems+=("index.json is not valid JSON")` → **false positive on valid JSON**. Under `EXPLORER_ENFORCE=1` it then **exits 2 and blocks Claude from stopping**.
- `verify-build.sh`'s index path-resolution gate (the advertised "explorer fix") gets empty stub output guarded by `|| true`, so it **silently checks nothing**; with no `python3` at all it prints "python3 absent — skipping". Either way the flagship deterministic check does not run on python-less or stub-python hosts.

**Evidence:**
```
verify-output (valid index.json, default PATH) -> "[explorer] … index.json is not valid JSON"
verify-output (… , EXPLORER_ENFORCE=1)          -> exit=2   (blocks over a bogus complaint)
verify-output (… , PATH=/usr/bin no python)     -> exit=0   (correctly silent)
verify-build  (bogus index path, default PATH)  -> exit=0, path NOT flagged
verify-build  (… , PATH=/usr/bin)               -> "python3 absent — skipping …"
```
**Fix:** detect a *working* python (as in F1); on real absence, skip without false-flagging; consider a `jq`/`node` fallback for JSON validation. **Effort: S–M.**

---

### F5 — README overstates the scope guard as advisory-by-default (Medium, docs)
**Where:** `README.md` "Configuration" note vs `guard-scope.sh:57-63`.

**What's wrong:** the README says *"By default `enforce_gates` is false, meaning the scope guard and build-verify hooks are advisory (warn only)."* But `guard-scope.sh` calls `bd_block` (exit 2) for an out-of-scope edit **unconditionally whenever a PLAN exists** — `enforce_gates` only gates the *no-plan* case (`:29-35`) and `verify-build.sh` (`:79`).

**Evidence:** with the default `enforce_gates:false` settings, the full-path cross-dir case above returns **exit 2 (block)**. So the doc is wrong for `guard-scope`; it is correct for `verify-build`.

**Fix:** reword: once an approved PLAN exists, out-of-scope edits are always hard-blocked; `enforce_gates` controls (a) editing with **no** plan and (b) the `verify-build` Stop gate. **Effort: S.**

---

### F6 — Builder SessionStart guidance goes to stderr, so Claude never sees it (Medium)
**Where:** `common.sh:91-92` (`bd_say`/`bd_warn` both `>&2`), used by `check-builder-state.sh:30,35,42,46-48`.

**What's wrong:** Docs (SessionStart): *"Exit 0 … plain stdout reaches Claude automatically"*; *"stderr shown only with `--verbose`."* The builder's "recall, don't re-scan" nudge and staleness warning are emitted on **stderr**, so they are **not injected into Claude's context** — unlike the explorer's `check-memory.sh`, which correctly uses `echo` to stdout (`:10,17,20,22`). Practical impact is limited (the `/builder:start` command re-reads state itself), but the SessionStart hook's purpose is undermined.

**Fix:** print SessionStart informational/context lines to **stdout** (keep stderr for the PreToolUse/Stop *blocking* reasons, where stderr is the correct channel for exit-2 feedback). **Effort: S.**

---

### F7 — SubagentStop scripts read the wrong stdin key (Low)
**Where:** `record-coverage.sh:14-19` (`subagent_type` / `agent` / `name`, **no** `agent_type`); `record-progress.sh:15` (`subagent_type` then falls back to `agent_type`).

**Docs (SubagentStop input, verbatim):** `session_id`, `transcript_path`, `cwd`, `hook_event_name`, **`agent_type`**, `agent_id`. There is no `subagent_type`.

**What's wrong:** `record-coverage.sh` never matches the real key → the explorer breadcrumb always says "sub-agent finished: subagent". `record-progress.sh` works via its `agent_type` fallback (though it also crashes on the stub host per F1). Cosmetic, but a latent correctness defect.

**Fix:** read `agent_type` (and optionally `agent_id`) as the primary key in both. **Effort: S.**

---

### F8 — `check-builder-state.sh` aborts when `explored_commit` is absent (Low)
**Where:** `check-builder-state.sh:6` (`set -euo pipefail`) + `:39` (`EXPLORED_COMMIT="$(grep -oE 'explored_commit:…' "$EXPLORER_MEM" | head -n1 | sed …)"`).

**What's wrong:** if `MEMORY.md` exists but has no `explored_commit:` line (hand-written/older memory), the grep pipeline returns non-zero, `pipefail` propagates, and `set -e` aborts the hook at line 39 — skipping the recall nudge (`:46-49`).

**Evidence:**
```
# MEMORY.md present, no explored_commit:
exit=1; only "[builder] initialized … settings.json" printed; "builder ready. RECALL" never reached
# isolated control: set -euo pipefail; x="$(grep nomatch /dev/null | head | sed …)"  → aborts (outer-exit=1)
```
**Fix:** append `|| true` to the assignment (the explorer's `check-memory.sh:14` already avoids this by using `set -uo`, not `-e`). **Effort: S.**

---

### F9 — Explorer read-only guard ignores `NotebookEdit` (Low)
**Where:** `plugins/explorer/hooks/hooks.json` PreToolUse matcher `"Write|Edit|MultiEdit"`; `guard-readonly.sh:13-27` (reads `file_path`/`path`, never `notebook_path`).

**What's wrong:** a `NotebookEdit` to a path outside `.claude/explorer/` is not guarded. Mitigated because explorer sub-agents declare `tools: Read, Grep, Glob, Bash` (no edit tools), so only the main session could do it. Builder's guard correctly includes `NotebookEdit` and reads `notebook_path` (`guard-scope.sh:16`).

**Fix:** add `NotebookEdit` to the matcher and read `notebook_path`. **Effort: S.**

---

### F10 — Working-tree CRLF triggers ShellCheck SC1017 locally (Low / informational)
**What:** ShellCheck on the **Windows working tree** flags SC1017 ("literal carriage return") on every line, plus a cascading false `SC1046 couldn't find 'fi'` on `verify-output.sh`. This is the **autocrlf checkout**, not the shipped form: `git ls-files --eol` shows `i/lf  w/crlf` and `.gitattributes` forces `*.sh eol=lf`, so a clone on any OS (and the marketplace cache copy) gets LF. Re-running ShellCheck on **LF-normalized** content yields **only `SC1091`** (an informational "couldn't follow sourced `../lib/common.sh`", itself an artifact of the test harness layout). Git Bash tolerates the CR locally, and the scripts ran correctly in every test. **No action needed beyond awareness.**

---

### F11 — No per-hook timeouts; `cat` blocks without stdin (Nit)
**Where:** all `hooks.json` entries (no `timeout` field); `guard-readonly.sh:11`, `record-coverage.sh:11`, `common.sh:62` (`event="$(cat …)"`).
**What:** a hung command hook can stall a turn. Risk is low (these scripts only read the payload then run quick `git`/`grep`), but invoking one **without** stdin (e.g., a manual test or misconfig) blocks on `cat`. Consider adding explicit `timeout` values and/or `read -t`. **Effort: S.**

---

### F12 — Redundant/inconsistent agent tool restrictions (Nit)
**Where:** `explorer-scout.md:7-8` and `explorer-sage.md:7-8` declare **both** `tools: Read, Grep, Glob, Bash` and `disallowedTools: Write, Edit, MultiEdit` (the allowlist already excludes those); `builder-context-finder.md:7` uses only `disallowedTools`. Harmless, but pick one convention. **Effort: S.**

---

### F13 — Committed explorer memory points at a deleted codebase (Nit / hygiene)
**Where:** `.claude/explorer/index.json` (`files[].path = KPS-MobileSupport/SNMP.APP/…`), `.claude/explorer/MEMORY.md` (`explored_commit: d33a0c7…`). The `KPS-MobileSupport/` tree is no longer in the repo, so none of these paths resolve — i.e., running `verify-build.sh` against this repo's own memory (with real python3) would flag them all. This is stale sample/demo data, not a plugin defect, but it's shipped in the repo. Consider removing or regenerating it. **Effort: S.**

---

## 4. Confirmed healthy (checked, genuinely fine — don't re-litigate)

- **Manifests valid & minimal-correct.** `marketplace.json` and both `plugin.json` parse (validated with `node`); only `name` is required (docs) and all are present. Both `source` paths (`./plugins/explorer`, `./plugins/builder`) resolve and contain `.claude-plugin/plugin.json`. Builder `plugin.json` now carries `"hooks": "./hooks/hooks.json"` (consistent with explorer).
- **Directory layout correct.** `commands/ agents/ skills/ hooks/` live at each plugin root; only `plugin.json` is under `.claude-plugin/` — exactly as the docs' "directory structure mistakes" warning requires.
- **Recent fixes held.** All 10 `*.sh` are mode **100755** in git (`git ls-files -s`) and **LF in the index** (`i/lf`, `.gitattributes` enforces `eol=lf`). `LICENSE` (MIT) present. README documents **both** plugins with a clean end-user install section.
- **Hook wiring valid.** Event names used (`SessionStart`, `PreToolUse`, `SubagentStop`, `Stop`) are all real; matchers (`Write|Edit|MultiEdit[|NotebookEdit]`) are valid; `${CLAUDE_PLUGIN_ROOT}` is correctly double-quoted in shell-form (`"\"${CLAUDE_PLUGIN_ROOT}\"/scripts/…"`). PreToolUse **exit 2 = block** is the correct contract the guards use; the Stop/SubagentStop advisory exits are correct.
- **Agents well-formed.** Every agent has valid frontmatter (`name`, `description`, `model`, `effort`, `maxTurns`); model values are all `sonnet`/`opus` (valid); deep-escalation agents use `opus`, base agents `sonnet` — matching their descriptions.
- **No dangling or orphan references.** All 7 builder agents and 2 explorer agents referenced by the orchestrator commands exist; all 5 builder + 3 explorer skills referenced by agents/commands exist; nothing is referenced-but-missing or present-but-unwired.
- **Gate ↔ planner contract lines up.** `validate-plan.sh` parses exactly the `PLAN.md` shape that `skills/plan-change/SKILL.md:30-59` tells the planner to write: `Clarity: N/10` (`:24-25`), `## Scope` with path-first bullets (`:33`), at least one `path:line` citation (`:38`), and a Risks/Invariants section referencing `MEMORY.md` (`:43-48`). On a missing plan it degrades cleanly (warns, exit 1), not a crash.
- **Memory completeness contract holds.** `verify-output.sh:23` requires headings `## TL;DR`, `## How it works`, `## Why it's built this way`, `## Module map`, `## Risk map`, `## Blind spots` plus `explored_commit:`/`coverage:` — all present in both the `write-memory` skill schema and the actual `MEMORY.md`.
- **Memory persistence is correct by design.** All scripts write under `${CLAUDE_PROJECT_DIR}/.claude/…` (git-trackable), never inside the ephemeral plugin cache — matching the docs' guidance on `${CLAUDE_PLUGIN_ROOT}` being ephemeral.
- **Shell quality is clean.** `bash -n` passes on all 10 scripts; ShellCheck 0.11.0 on **LF** content reports only `SC1091` (source-follow note). Quoting, `set` flags, and the `python3`-absent fallbacks are otherwise sound — the real issues are the *stub-python* and *traversal* logic above, not general shell hygiene.
- **Advisory/enforce model (where the docs match the code).** `verify-build.sh` is advisory by default and hard-blocks only under `enforce_gates`/`BUILDER_ENFORCE=1`; `guard-scope.sh` correctly hard-blocks out-of-scope edits once a plan exists.

---

## 5. Tooling gaps & audit caveats

- **ShellCheck:** not preinstalled. Installed `shellcheck-py==0.11.0` via the host's real pip (Python 3.11) and **did run it**. On LF content: clean (only `SC1091`). On the Windows CRLF working tree it floods `SC1017` — a checkout artifact (see F10), not a script defect.
- **`python3`:** the `python3` on PATH here is the **Microsoft Store App-Execution-Alias stub** (empty stdout, exit 49), *not* a real interpreter — this is precisely the root of F1/F4. A real Python exists as `python`/Python311 (that's the pip used above). `jq` is **absent**; `node` is present (used to validate JSON).
- **Not run in a live session.** Findings are based on direct script execution (isolated temp dirs, crafted hook JSON on stdin, both default PATH and a python-less `PATH=/usr/bin`) plus doc cross-reference — not on observing the plugins inside an actual Claude Code run. Hook *delivery* semantics (how Claude Code on Windows shells out to `*.sh`) are inferred from the docs, not observed.
- **Severity of F1** is rated High generically and **Critical for Windows** specifically; on Linux/macOS with a working `python3` it does not trigger.

*End of audit. No source files were modified.*
