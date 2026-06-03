# Changelog — builder

## 0.1.0
- Initial release of the spec-driven `builder` plugin.
- Command: `/builder:start` (orchestrator) + `/builder:status` (cheap state read).
- Agents: context-finder, planner (+ Opus deep escalation), implementer, QA (+ Opus deep escalation), memory-sync.
- Skills: recall-memory, plan-change, apply-change, qa-verify, sync-memory.
- Hooks: SessionStart (state/freshness + settings bootstrap), PreToolUse scope guard, SubagentStop progress log, Stop completeness gate.
- Deterministic gates: `validate-plan.sh` (plan structure) and `verify-build.sh` (carries over the explorer `index.json` path-resolution fix).
- Config via `.claude/builder/settings.json`: Opus escalation (default on, last-resort), loop limits, rating/clarity thresholds, `auto_run_tests` (default "ask"), `enforce_gates`.
