---
description: "Show the current builder state cheaply — reads .claude/builder/ artifacts (PLAN.md, CHANGELOG.md, QA.md, settings.json) and explorer freshness, without spawning any sub-agents. Use to resume or inspect."
---

# /builder:status

Report the current builder state **without dispatching any sub-agent** (keep it cheap). Read and summarize:

1. **Explorer memory freshness** — does `.claude/explorer/MEMORY.md` exist; is `explored_commit` == `git HEAD`? Flag stale.
2. **Specs** — list `.claude/specs/spec*.md` present.
3. **Active plan** — if `.claude/builder/PLAN.md` exists: its Goal, Clarity score, and Scope file list.
4. **Bug-fix mode** — if `.claude/builder/BUG.md` exists: BUG-FIX MODE is engaged. Report the symptom, the `Repro status:` (RED/GREEN), whether the declared repro test resolves on disk (reproduce-first satisfied) or source edits are still gated, and any `.claude/builder/bugfix/results.txt` repro/char/linked statuses.
5. **Progress** — last few lines of `.claude/builder/CHANGELOG.md`.
6. **QA** — if `.claude/builder/QA.md` exists: mode + score.
7. **Settings** — the effective values from `.claude/builder/settings.json` (escalation on/off, thresholds, auto_run_tests; bug-fix: bugfix_mode, require_reproduction, require_characterization, bugfix_enforce, bugfix_diagnosis_tier).

Then state the single recommended next step (e.g. "answer the open clarity questions", "confirm the plan to implement", "capture the failing repro", "run the regression gate", "run QA", "ready to report"). Do not change any files.
