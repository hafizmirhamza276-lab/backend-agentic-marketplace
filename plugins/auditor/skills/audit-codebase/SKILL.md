---
name: audit-codebase
description: Methodology for auditing this marketplace against its own F1–F13 failure classes — the deterministic static detectors, the finding line format, and how the review sub-agents add logic/security/invariant findings on top. Use when running /auditor:run or as an auditor sub-agent.
---

# Audit this codebase systematically

The auditor productizes THIS project's own audit (the F1–F13 findings) as **regression
detectors**: each fires only when a specific, previously-fixed failure class is re-introduced,
and stays silent on a clean tree. Two layers:

1. **Deterministic detectors** (`scripts/lib-audit-checks.sh`, pure shell/awk, no python) —
   the floor. They scan by ROLE (hook scripts resolved from each plugin's `hooks.json`, the
   sourced `shared/lib/common.sh`, the manifests, the agent files), never a blanket grep, so
   they neither miss a hook nor false-flag the detector library itself.
2. **Review sub-agents** (`auditor-scout` breadth / `auditor-critical` depth) — judgment on top:
   logic, security, and invariant breaks that static analysis cannot see.

## Finding line format (BOTH layers emit this)
One finding per line, TAB-separated:

```
<SEVERITY>\t<detector>\t<file:line-or-path>\t<message>
```

`SEVERITY ∈ HIGH | MEDIUM | LOW | ADVISORY` (see the `classify-findings` skill). `verify-audit.sh`
tallies HIGH/MEDIUM/LOW (ADVISORY excluded), writes `.claude/auditor/FINDINGS.md`, and records
`bd_status_write auditor audit <state> "" high=$H med=$M low=$L`. The pipeline release gate
(`verify-release.sh`) reads `auditor high` and requires it to be **0** to release.

## The detector map (what each guards against, grounded in the audit)
HIGH — a gate/module is SILENTLY broken or bypassable (these feed the 0-high gate):
- **D1 fail-open (F1)** — a hook/lib trusting `command -v python3` as a presence test, or a raw
  python `$(…)` capture under `set -e` with no `|| fallback`. The Windows Store stub re-opens fail-open.
- **D2 traversal (F2)** — a PreToolUse path guard matching its allow-zone on a raw path (no
  `bd_normalize_path`); a `..`/backslash segment escapes the zone.
- **D6 hook-contract-broken** — a `hooks.json` command whose script is missing or not +x (100755);
  the hook silently never runs.
- **D7 manifest** — a `plugin.json`/`marketplace.json` that doesn't parse, or a marketplace
  `source` dir that doesn't exist.
- **D8 lib-drift** — a vendored `plugins/*/lib/common.sh` that differs from the canonical
  `shared/lib/common.sh` (runs stale shared logic).

MEDIUM — a real defect that doesn't silently break a gate:
- **D3 notebook-gap (F9)** — a `Write|Edit` matcher omitting `NotebookEdit`, or a guard not reading `notebook_path`.
- **D4 stdin-block (F11)** — a hook reading stdin via `cat` without an `[ -t 0 ]` guard.
- **D5 sessionstart-stderr (F6)** — SessionStart guidance emitted only to stderr (SessionStart injects STDOUT).
- **D6b hook-no-timeout (F11)** — a `hooks.json` command entry with no `timeout`.

LOW — hygiene:
- **D9 line-endings/exec (F10)** — a `.sh` shipping CRLF (`git ls-files --eol` = i/crlf), or a
  non-hook `.sh` not tracked 100755. Plus per-file ShellCheck **errors** when ShellCheck is installed.

ADVISORY — informational only, NEVER gates, EXCLUDED from the tally (the "fuzzy" findings whose
static signal is too weak to gate on without false-blocking): README/doc drift (F5), redundant
agent `tools:`+`disallowedTools:` (F12), stale explorer `index.json` paths (F13).

## Sub-agent method (scout + critical)
- **Recall, don't re-scan.** Read `.claude/explorer/MEMORY.md` for ground truth, then read the
  diff under review (`git diff` or the base ref the orchestrator passed).
- Reason about: fail-open/error-swallowing, path/zone bypasses, auth & input validation,
  data-loss/destructive ops, and broken **invariants** the explorer recorded.
- Cite `path:line`. Separate **evidence** from **inference** (a hypothesis is labelled, never a HIGH).
- Append each finding to `.claude/auditor/findings/<agent>.tsv` in the line format above.
- Do not duplicate a deterministic detector's finding; add what it cannot see.

Keep findings dense and evidence-first. A HIGH must be a real, defensible regression — the gate
trusts it.
