---
name: assess-readiness
description: Methodology for assessing whether a codebase is ready to DEPLOY/RELEASE — the deterministic readiness checks (O1 build/test ledger, O2 version consistency), the finding line format, and how the ops sub-agents add deploy/observability judgment on top. Use when running /ops:run or as an ops sub-agent.
---

# Assess deploy/release readiness systematically

The ops plugin answers one question: **is this codebase safe to deploy/release right now?** It is
deliberately split into a LEAN deterministic floor and a fuzzy, agent-driven ceiling, so a BLOCKING
stays trustworthy and the gate never false-blocks on a heuristic. It is **orthogonal** to the
auditor (whole-tree F-class regressions) and the reviewer (this-change-vs-invariants); the release
gate aggregates all three independently.

Two layers:

1. **Deterministic checks** (`scripts/lib-ops-checks.sh`, pure shell/awk, no python) — the floor.
   Only what can be read without guessing:
   - **O1 test-ledger** — read `.claude/ops/results.txt` (`<kind>\t<status>\t<cmd>`, status
     normalized green/red; the SAME shape as the bug-fix ledger). Any recorded **RED** → **BLOCKING**
     (the codebase is provably not releasable). **No ledger** → **CONCERN** (not verified; does not
     hard-block). All green → silent. Running tests is side-effectful, so the orchestrator
     proposes + confirms the commands and WRITES the ledger; verify-ops only READS it.
   - **O2 version-consistency** — for each `.claude-plugin/marketplace.json` plugin entry, compare
     its version to that plugin's `plugin.json` version. Mismatch → **CONCERN** (a release would
     ship inconsistent versions). Silent when they match or a file is absent.
2. **Ops sub-agents** (`ops-scout` breadth / `ops-critical` depth) — judgment on top: the
   deploy/observability surface static analysis should NOT gate on. CI/CD presence, Dockerfile and
   manifests, health checks, config/secret handling, structured logging, migrations, rollback. They
   emit **advisory** CONCERN/NOTE findings only.

## Finding line format (BOTH layers emit this)
One finding per line, TAB-separated:

```
<SEVERITY>\t<check>\t<file:line-or-path>\t<message>
```

`SEVERITY ∈ BLOCKING | CONCERN | NOTE` (see the `deploy-checklist` skill). `verify-ops.sh` tallies
BLOCKING/CONCERN (NOTE excluded), writes `.claude/ops/OPS.md`, and records
`bd_status_write ops readiness <state> "" blocking=$B concern=$C`. The pipeline release gate
(`verify-release.sh`) reads `ops blocking` and requires it to be **0** to release.

## Why the deterministic surface is intentionally small
A static "is there a health check?" detector is wrong often enough that gating on it would block
clean releases and train people to ignore the gate. So the deterministic checks assert only ground
truth (a recorded failure, a literal version mismatch); the judgment about whether a deploy is wise
is the agents' advisory job. Keep it that way — do not add brittle deploy detectors that false-fire.

## Sub-agent method (scout + critical)
- **Recall, don't re-scan.** Read `.claude/explorer/MEMORY.md` (architecture, risk map) for ground
  truth, then inventory the deploy/observability surface.
- Reason about: deployability (build artifact, container, CI, pinned deps), operability (health
  checks, structured logs, metrics/traces), safety (migrations, rollback, secrets/config hygiene).
- Cite `path:line`. Separate **evidence** from **inference** (a hypothesis is labelled, never a
  BLOCKING). Append each finding to `.claude/ops/findings/<agent>.tsv` in the line format above.
- Deploy judgment is ADVISORY — emit CONCERN/NOTE, not BLOCKING. The only deterministic BLOCKING is
  O1's recorded red build/test.

Keep findings dense and evidence-first. The gate trusts a BLOCKING — and the only deterministic
BLOCKING is a real, recorded red build/test.
