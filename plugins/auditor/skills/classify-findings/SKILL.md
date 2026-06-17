---
name: classify-findings
description: The severity taxonomy for audit findings — how to assign HIGH / MEDIUM / LOW / ADVISORY so the release gate enforces the right things and never false-blocks. Use when an auditor sub-agent or /auditor:run records a finding.
---

# Classify a finding's severity

Severity decides what GATES. The pipeline release gate enforces **0 HIGH**; MEDIUM/LOW are
recorded but do not block; ADVISORY is informational and excluded from the tally. Assign
deliberately — an inflated HIGH blocks a clean release; a buried HIGH ships a broken gate.

## HIGH — a gate or module is SILENTLY broken or bypassable
Use for: **security**, **fail-open**, **data-loss**, **path traversal**, and anything that makes
a safety gate not run / not block while appearing healthy.
- A guard that fails open (crashes/returns allow under `set -e`, or trusts a stub interpreter). [D1]
- An allow-zone/scope check on a raw, un-normalized path → `..`/backslash escape. [D2]
- A hook whose command is missing or not executable → it silently never runs. [D6]
- A manifest that won't parse, or a marketplace `source` that doesn't resolve → plugin won't load. [D7]
- A vendored lib drifted from canonical → a plugin runs stale (e.g. un-fixed) shared logic. [D8]
- (Sub-agents) auth bypass, missing input validation on a trust boundary, a destructive op
  without a guard, a broken **invariant** the explorer memory says must hold.

## MEDIUM — a real defect that does NOT silently break a gate
Use for: **portability**, **false-block** (a gate that wrongly blocks), and **contract drift**.
- A matcher/guard that misses a tool variant (e.g. `NotebookEdit`) → a coverage gap. [D3]
- A hook that can block forever on missing stdin (`cat` with no `[ -t 0 ]`). [D4]
- SessionStart guidance sent only to stderr → never reaches the model. [D5]
- A hook entry with no `timeout` → a hang can stall the turn. [D6b]
- A false-fail on a python-less/stub host; a deterministic check that silently no-ops.

## LOW — hygiene / style
Use for: line endings, exec bit, lint.
- A `.sh` that ships CRLF, or a non-hook `.sh` not tracked 100755. [D9]
- ShellCheck **error**-level findings (warnings/info are not surfaced).

## ADVISORY — informational only (NEVER gates; EXCLUDED from the tally)
Use for the "fuzzy" findings whose static signal is too weak to gate on without false-blocking,
and for purely stylistic notes:
- README/doc drift vs actual behavior (F5).
- An agent declaring BOTH `tools:` and `disallowedTools:` (redundant, F12).
- Stale `.claude/explorer/index.json` paths that no longer resolve (F13).
- "ShellCheck skipped" when ShellCheck isn't installed.

## Tie-breakers
- "Could this let an unsafe edit/exec through, or make a gate silently not run?" → **HIGH**.
- "Is it a real defect but the gate still fundamentally works / only degrades?" → **MEDIUM**.
- "Is it cosmetic or hygiene?" → **LOW**.
- "Is the signal fuzzy / would gating on it risk false-blocking a clean tree?" → **ADVISORY**.
- When uncertain between HIGH and MEDIUM, prefer **MEDIUM** unless you can name the concrete
  bypass/fail-open — the gate must stay trustworthy, not trigger-happy.
