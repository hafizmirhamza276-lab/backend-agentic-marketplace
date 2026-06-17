---
name: deploy-checklist
description: The deploy/release readiness checklist and severity taxonomy for ops findings — the dimensions to inventory (deployability, operability, safety) and how to assign BLOCKING / CONCERN / NOTE so the release gate enforces the right thing and never false-blocks. Use when an ops sub-agent or /ops:run records a readiness finding.
---

# Classify a deploy/release-readiness finding

Severity decides what GATES. The pipeline release gate enforces **0 BLOCKING** from ops; CONCERN is
recorded but does not block; NOTE is informational and excluded from the tally. The deterministic
checks own the only BLOCKING signal (a recorded RED build/test); the agents' deploy/observability
judgment is **advisory** (CONCERN/NOTE) by design — an inflated BLOCKING on a heuristic blocks a
clean release and erodes trust in the gate.

## The readiness checklist (what the agents inventory)
Ground every judgment in the explorer memory (`.claude/explorer/MEMORY.md` — architecture, risk
map). Walk three dimensions:

- **Deployability** — is there a reproducible build/artifact? A container image or deploy manifest?
  A CI pipeline that builds and tests? Pinned dependencies / a lockfile?
- **Operability** — health/readiness checks for long-running services? Structured logging? Metrics
  / traces / error reporting? A documented run/restart path?
- **Safety** — are schema migrations gated and reversible? Is there a rollback path? Are secrets
  kept OUT of source and read from config/env? Is configuration environment-aware?

## BLOCKING — provably not releasable (deterministic only)
- A recorded **RED** build or test in `.claude/ops/results.txt`. [O1] This is the only deterministic
  BLOCKING — a failed build/test means the codebase cannot ship.
- (Agents) reserve BLOCKING for a concrete, evidenced, CERTAIN breakage; when in doubt, use CONCERN.

## CONCERN — a human should resolve before deploy, does NOT hard-block
- **No build/test ledger** — readiness was not verified. [O1]
- **Version inconsistency** — a marketplace entry's version ≠ the plugin's `plugin.json` version. [O2]
- (Agents) a missing health check on a long-running service; an unguarded/irreversible migration;
  secrets that appear to live in source; no rollback path; no structured logging on a service that
  needs operability. Real, but a judgment call → CONCERN.

## NOTE — informational only (NEVER gates; EXCLUDED from the tally)
A heads-up for the deployer: "consider adding a readiness probe", "document the rollback step", a
metric worth emitting. Travels with the report without affecting the verdict.

## Tie-breakers
- "Is there a recorded build/test failure?" → **BLOCKING** (O1).
- "Is readiness unverified, are versions inconsistent, or is there a real deploy/operability gap a
  human should close?" → **CONCERN**.
- "Is it a suggestion or heads-up?" → **NOTE**.
- When uncertain between BLOCKING and CONCERN for an agent finding, prefer **CONCERN** — the only
  trustworthy deterministic BLOCKING is the recorded red build/test. Match the service to the risk:
  a CLI tool needs no health check; a long-running service does.
