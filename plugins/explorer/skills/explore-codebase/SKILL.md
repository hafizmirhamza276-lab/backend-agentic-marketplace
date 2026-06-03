---
name: explore-codebase
description: Methodology and report schemas for systematically exploring a backend codebase. Use when mapping or analyzing an unfamiliar codebase, or when running as an explorer sub-agent during /explorer:start.
---

# Explore a codebase systematically

This skill defines HOW to explore and the EXACT report format. Consistent format is what
makes the memory durable and re-readable by a future agent.

## Traversal order (cheap signal first)
1. **Manifests & config** — dependency files, build/CI config, env templates, Dockerfiles,
   IaC. These reveal the stack, runtime, and boundaries fastest. Language-agnostic.
2. **Entry points** — `main`/server bootstrap, route registration, workers, schedulers,
   message consumers, CLI commands.
3. **Public surface** — routes/handlers, exported APIs, published events, schemas/contracts.
4. **Core domain** — the business logic the surface delegates to. Spend the most effort here.
5. **Data layer** — models, migrations, queries, caches, queues.
6. **Cross-cutting** — auth, config, logging, error handling, observability, feature flags.
7. **Tests** — they document intended behavior and edge cases; mine them.

## Coverage discipline (so claims stay honest)
- Mark each area `read` (fully read), `sampled` (representative files only), or
  `unverified` (not reached). Never label something `read` you only skimmed.
- Always cite `path:line` for concrete claims. Use `git log`/`git blame` to recover intent.
- Separate **evidence** from **inference**. Inference must be labeled as a hypothesis.
- A coverage estimate is a percentage of *meaningful* code paths reviewed, not files touched.

## Scout Report schema (breadth — explorer-scout returns this)
```markdown
# Scout Report
## Stack & runtime
- language(s), framework(s), runtime, package manager   (evidence: path:line)
## Repo shape
- module/service tree with one-line purpose each
## Entry points
- how it starts / what triggers each path
## External interfaces
- routes / RPC / events / integrations (method, path, handler@path:line)
## Data layer
- datastores, models/migrations, caches, queues
## Module dependency map (coarse)
- A -> B (why)
## Conventions actually used
- errors / logging / config / testing
## coverage: <NN>%
## unverified:
- <area> — <why not reached>
```

## Sage Report schema (depth — explorer-sage returns this)
```markdown
# Sage Report
## Architecture in one paragraph
## Why this shape (constraints that explain it)
## Key decisions
- Decision: <what> | Alternative: <what> | Trade-off: <why> | Evidence: <path:line | commit | inferred>
## Invariants & contracts
- <assumption that must hold> — breaks if: <...>
## Hidden coupling / sequencing
## Risk map
- <area> — <risk> — <severity> — <evidence>
## If you change X, watch Y
## coverage: <NN>%
## open-questions:
- <question the orchestrator or a human should resolve>
```

Keep both reports dense, evidence-first, and free of filler. The orchestrator merges them
into `.claude/explorer/MEMORY.md` via the `write-memory` skill.
