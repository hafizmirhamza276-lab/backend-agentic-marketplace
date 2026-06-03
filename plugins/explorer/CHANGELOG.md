# Changelog — explorer

## 0.1.0
- Initial scaffold.
- `/explorer:start` orchestration command (freshness gate → parallel sub-agents → synthesize → persist).
- Sub-agents: `explorer-scout` (Sonnet, breadth) and `explorer-sage` (Opus, depth), both read-only.
- Skills: `explore-codebase` (method + report schemas), `recall-codebase` (read-don't-rescan), `write-memory` (durable output schema).
- Hooks: SessionStart (recall nudge + staleness), PreToolUse (read-only guard), SubagentStop (progress), Stop (completeness check).
