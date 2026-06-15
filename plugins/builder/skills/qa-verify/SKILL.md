---
name: qa-verify
description: "Verify a freshly built feature with a hybrid strategy: auto-detect a real test/build harness and (with confirmation) run it for feature-level edge cases AND app-level regression; if no harness exists, fall back to rigorous static analysis and edge-case enumeration. Use after apply-change, before reporting to the user. Produces a QA report and a score the orchestrator rates. Used by both the Sonnet QA agent and the Opus QA escalation."
---

# qa-verify

Goal: maximize confidence the feature works and did not break anything else,
honestly reporting what was actually executed vs. only reasoned about.

## Step 0 — recall + locate
Load the relevant context (recall-memory) and read the change report in
`.claude/builder/CHANGELOG.md` to know exactly what was built and where.

## Step 0.5 — verify the edge-case coverage map (when `require_edge_case_coverage` is on — default)
Cross-check the plan's `## Tasks` edge cases against the implementer's **edge-case coverage
map** in `.claude/builder/CHANGELOG.md`. For EACH enumerated edge case, confirm it is one of:
handled at a real `file:line` (open it — does the code actually cover it?), covered by a named
test, or `DEFERRED:` with a reason that is genuinely safe. **Flag any case that is neither
handled nor justifiably deferred** — and any case present in the plan but absent from the map
(a silent skip) — as a defect. Give extra scrutiny to the highest-risk classes: boundaries,
**fail-closed** guard paths, and the named MEMORY.md risks/invariants. Where execution is
allowed (per `auto_run_tests`), propose targeted tests for those highest-risk cases.

## Step 1 — detect the harness (auto-detect)
Look for an executable test/build setup, e.g.:
- Node: `package.json` scripts (`test`, `build`), jest/vitest/mocha configs.
- .NET: `*.sln` / `*.csproj`, `dotnet test`, xUnit/NUnit.
- Python: `pytest`, `tox.ini`, `pyproject.toml`.
- Go: `go test ./...`. Java: `mvn test` / `gradle test`. Rust: `cargo test`.
- Generic: a `Makefile` target, CI config (`.github/workflows`) naming test/build commands.

## Step 2 — run vs. reason (gated)
Read `auto_run_tests` from `.claude/builder/settings.json`:
- `"ask"` (default): propose the exact command(s) to the orchestrator and let it confirm with the user before running. Running tests/builds is a side-effectful action — never run unprompted.
- `"never"`: do not execute; go straight to static mode.
- `"auto"`: you may run detected, read-only test/build commands directly.

**If a harness exists and running is allowed/confirmed** → run it:
- **Feature-level:** exercise the new behavior across normal, boundary, and failure inputs; null/empty, large values, concurrency if relevant, auth/permission paths, error handling. Capture pass/fail.
- **App-level (regression):** run the broader suite / start the app's smoke path to check the change didn't break neighboring features. Note anything red.

**If no harness exists, or running is declined** → static mode:
- Trace the new code paths by hand against the spec; enumerate edge cases and argue each is handled (cite path:line).
- Identify the most likely regression surface from MEMORY.md's module map and reason about impact.
- Be explicit that this is analysis, not execution — cap the confidence accordingly.

## Step 3 — report
Write `.claude/builder/QA.md`:
- **Mode** — executed (with commands + results) or static-only.
- **Feature checks** — case → expected → result/argument.
- **Edge-case coverage** — per task: enumerated cases that are handled / tested / deferred vs.
  any that are unaddressed (silent skips or hand-waved defers). This is a first-class section,
  not a footnote.
- **Regression** — what was checked app-level; findings.
- **Defects** — anything that would "burst in prod," with severity.
- **Confidence** — a score /10 with justification. The score must reflect **edge-case
  coverage, not just that it builds**: an unaddressed enumerated edge case (especially a
  boundary or a fail-closed path) caps the score. Executed-and-green earns a high score
  honestly; static-only is capped lower because it wasn't run.

## Return to orchestrator (≤10 lines)
Mode, score/10, any blocking defect, and a one-line confidence statement. The
orchestrator rates QA; if < threshold it returns precise gaps for another pass.
