---
name: sync-memory
description: "After a change is implemented and QA'd, update the durable memory so the next session is accurate: refresh the affected explorer artifacts (.claude/explorer/MEMORY.md, index.json, TRACK.md, map/*.md) and the builder log. Use as the final builder step. CRITICAL: resolve every index.json path on disk via find/glob — never infer paths (this fixes the known explorer defect where ~half the paths pointed at the wrong sub-folder)."
---

# sync-memory

Keep the "brain" current so future work recalls correct facts. Touch only what
the change affected — do not rewrite the whole memory.

## What to update
1. **`.claude/explorer/index.json`** — for each file the change added/modified/removed, update or add its entry (`path`, `summary`, `symbols`, `depends_on`, `area`, `status`). Set `status` to `Done` only for files you actually changed and understand; keep others as the explorer left them.
2. **`.claude/explorer/MEMORY.md`** — if the change altered how something works, why, an interface, a convention, or a risk, edit the relevant section. Bump nothing you didn't verify. If the working tree advanced, update `explored_commit` in the frontmatter to the new `git HEAD` **only for the areas you re-touched**; otherwise leave it and note partial freshness in TRACK.md.
3. **`.claude/explorer/map/<area>.md`** — update the deep-dive for any area whose behavior changed.
4. **`.claude/explorer/TRACK.md`** — move changed files to Done; add a changelog line (what changed, by which spec).
5. **`.claude/builder/`** — ensure `PLAN.md`, `CHANGELOG.md`, and `QA.md` reflect the final state.

## CRITICAL — path resolution (the explorer fix)
Before writing any `path` into index.json, **resolve it on disk**:
- Use `find`/glob to locate the real file (e.g. `find . -name OrderService.cs`), do not infer the directory from the project + filename.
- If a path can't be resolved to exactly one file, flag it rather than guessing.
- The Stop gate `verify-build.sh` fails the run if any index.json path does not exist — so a guessed path is caught deterministically. Get it right here.

## Honesty
Record real coverage and `Unverified` status truthfully. Do not upgrade a file
to `Done` you only skimmed. Off-repo logic stays a blind spot.

## Return to orchestrator (≤8 lines)
Which memory files you updated, any path corrections made, and whether
`explored_commit` was advanced or left partial. Detail lives in the files.
