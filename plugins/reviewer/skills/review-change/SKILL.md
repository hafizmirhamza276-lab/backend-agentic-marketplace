---
name: review-change
description: Methodology for reviewing a CHANGE (the working-tree diff vs HEAD) against the codebase's recorded invariants, risk map, surviving callers, and approved scope — the deterministic checks, the finding line format, and how the review sub-agents add invariant/risk judgment on top. Use when running /reviewer:run or as a reviewer sub-agent.
---

# Review a change systematically

The reviewer judges a **change**, not the whole tree. The auditor productizes this project's
F1–F13 *whole-tree* regression detectors; the reviewer is **orthogonal** — it reads *this diff vs
HEAD* against the things you only learn by looking at what the edit did: the invariants and risk
map the explorer recorded, the callers that must still resolve, and the scope the plan approved.
Never re-source the auditor's lib at runtime (vendoring rule); the release gate aggregates both.

Two layers:

1. **Deterministic checks** (`scripts/lib-review-checks.sh`, pure shell/awk, no python) — the
   floor. Diff source is `git diff HEAD`. Each check is individually callable and SILENT on a
   clean / in-spec change, so a finding is trustworthy.
2. **Review sub-agents** (`reviewer-scout` breadth / `reviewer-critical` depth) — judgment on top:
   does the change violate a recorded invariant, mishandle a risk-mapped area, or drift a
   producer/consumer contract? Things static analysis cannot see.

## Finding line format (BOTH layers emit this)
One finding per line, TAB-separated:

```
<SEVERITY>\t<check>\t<file:line-or-path>\t<message>
```

`SEVERITY ∈ BLOCKING | CONCERN | NOTE` (see the `check-invariants` skill). `verify-review.sh`
tallies BLOCKING/CONCERN (NOTE excluded), writes `.claude/reviewer/REVIEW.md`, and records
`bd_status_write reviewer review <state> "" blocking=$B concern=$C`. The pipeline release gate
(`verify-release.sh`) reads `reviewer blocking` and requires it to be **0** to release.

## The deterministic check map (what each reviews, and why)
BLOCKING — the change breaks something concrete (these feed the 0-blocking gate):
- **R1 caller-integrity** — a shell function REMOVED or RENAMED in the diff that still has
  surviving call-sites in the tree. A rename surfaces as the old name removed; if the name is no
  longer defined anywhere but is still called, that caller is broken. (A function merely moved /
  edited in place — still defined somewhere — is not flagged.)
- **R2 convention-regression** — a changed `.sh` that, versus its HEAD blob, drops
  `set -uo pipefail`, stops sourcing `../lib/common.sh`, or (re)introduces an errexit `set -e`.
  Each regresses the house safety preamble that keeps the gates from failing open.

CONCERN — the change warrants a human look but does not hard-block:
- **R3 risk-touch** — a changed file whose path is named in the explorer `MEMORY.md` **Risk map**
  (`- <area> — <risk> — <severity> — <evidence>`). Touching recorded-risk surface → re-read the risk.
- **R4 scope-discipline** — a changed file NOT listed in the approved `.claude/builder/PLAN.md`
  Scope (same parser/membership test as the builder scope guard). Possible scope creep.

NOTE — informational only, NEVER gates, EXCLUDED from the tally (a stylistic observation, or an
agent's context note that should travel with the review without affecting the verdict).

## Sub-agent method (scout + critical)
- **Recall, don't re-scan.** Read `.claude/explorer/MEMORY.md` (architecture, invariants, risk map)
  for ground truth, then read the diff under review (`git diff HEAD`, or the base ref the
  orchestrator passed).
- Reason about: broken **invariants** the explorer recorded, risk-mapped areas the change touches,
  producer/consumer **contract drift** (STATUS keys, gate inputs), dangling callers the static
  check could not resolve, and scope creep.
- Cite `path:line`. Separate **evidence** from **inference** (a hypothesis is labelled, never a
  BLOCKING).
- Append each finding to `.claude/reviewer/findings/<agent>.tsv` in the line format above.
- Do not duplicate a deterministic check's finding; add what it cannot see.

Keep findings dense and evidence-first. A BLOCKING must be a real, defensible breakage — the gate
trusts it.
