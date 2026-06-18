---
name: minimal-code
description: "Always-on discipline to write the SMALLEST code that fully satisfies the requirement — never thousands of debug-hostile lines — WITHOUT cutting validation, error handling, security, or accessibility. Walk THE LADDER before writing any code and stop at the first rung that holds. Use when writing, adding, or refactoring ANY code in this marketplace (the minimalist plugin injects this at session start and re-nudges every turn unless mode=off); consult it the moment you are about to add an abstraction, a dependency, a file, or boilerplate, and to reconcile laziness with the active builder PLAN."
---

# minimal-code — write the least code that fully works

**Lazy = efficient, not careless. The best code is the code never written;** the
second best is the code a maintainer can hold in their head. Minimal is the
*default*, never an excuse to drop validation, error handling, security, or
accessibility.

## THE LADDER — stop at the first rung that holds
Before writing any code, walk down and **stop at the first rung that applies**:

1. **Does this need to exist at all?** → if no, **don't build it** (YAGNI).
2. **Does the standard library do it?** → use it.
3. **Does a native platform / runtime feature cover it?** → use it.
4. **Is it already in an installed dependency?** → use it.
5. **Can it be one line?** → make it one line.
6. **Only then:** write the **minimum code that works**.

You only descend a rung when the one above genuinely does not hold — and you say
so in one phrase if it is not obvious.

## RULES
- **No unrequested abstractions** — no layer, interface, or framework nobody asked for.
- **No avoidable dependencies** — a new dependency must earn its place; prefer rungs 2–4.
- **No boilerplate nobody asked for** — generated scaffolding, dead config, "just in case" hooks.
- **Deletion over addition** — removing code that already solves it beats writing more.
- **Boring over clever** — the obvious solution a maintainer reads once and trusts.
- **Fewest files** — do not spread three lines across three files.
- **Edge-correct tie-break** — between two same-size options, pick the one **correct on the edge cases**.
- **Never stall** — ship the lazy version **and** question an over-complex request in the **same**
  response. Do not down-tools to ask "should this be simpler?" — propose the simpler shape inline and proceed.

## WHEN NOT TO BE LAZY (never simplify these away)
Minimal stops the moment it would cut a load-bearing safeguard. **Never** drop, in the name of brevity:

- **Trust-boundary input validation** — anything crossing a trust boundary is validated, fail-closed.
- **Error handling that prevents data loss** — partial writes, dropped transactions, swallowed failures.
- **Security measures** — authn/authz, secret handling, injection/escaping, safe defaults.
- **Accessibility basics** — labels, roles, keyboard paths, contrast where a UI is in scope.
- **Anything the user explicitly asked to keep** — an explicit request is in-scope by definition.

A guardrail is not boilerplate. Cutting one is not "lazy", it is a defect.

## PLAN / GATE RECONCILIATION (this repo's addition)
YAGNI applies **ONLY to UNREQUESTED scope**. It is **not** licence to skip mandated work.

- Anything the active **builder PLAN** (`.claude/builder/PLAN.md`), its **coverage map**, or the
  **user** mandates is **in-scope** and **must NOT be skipped**. Minimal ≠ incomplete.
- Every PLAN task still needs its **edge-case coverage**: the builder appends a per-task
  `### Task <id> — edge-case coverage` map to `.claude/builder/CHANGELOG.md` (each enumerated case →
  `handled at file:line` | `covered by <test>` | `DEFERRED: <reason>`), and the release gate
  (`verify-release.sh`) BLOCKS a task whose id has no such structured marker. Writing less code
  never excuses a missing coverage marker.
- **Non-trivial logic still leaves ONE runnable check** — an assert-based self-check or one small
  test file (no new test framework, no new dependency). This dovetails with the builder's
  **reproduce-first** bug-fix mode: the smallest proof that the logic works, runnable on demand.

## THE `bd:min:` MARKER
When you take an **intentional** shortcut with a known ceiling, leave a one-line comment in the code:

```
# bd:min: <the ceiling this version accepts> — upgrade: <the concrete path past it>
```

It names **both** the ceiling (what this minimal version does NOT yet handle) **and** the upgrade
path (what to do when the ceiling is reached). A `bd:min:` marker is a deliberate, signposted
trade-off — never a silent gap, and never a substitute for a never-cut guardrail above.

## OUTPUT DISCIPLINE
- **Code first.** Then **at most three short lines**: what was skipped, and when to add it.
- If the explanation is **longer than the code**, delete the explanation.
- Explanation the **user explicitly asked for** is not debt — give it in full.

## INTENSITY
Set via `/minimize` (writes `.claude/minimalist/mode`); both injector hooks and the skill read it.
Default **full**.

- **off** — disabled. SessionStart injects nothing; the per-turn reminder is silent. The skill is
  still available on demand.
- **lite** — a gentle nudge: prefer the smaller option, but apply light judgment; markers optional.
- **full** *(default)* — apply the whole ladder, the rules, and output discipline every time; leave
  a `bd:min:` marker on every intentional shortcut.
- **ultra** — strictest. Justify every new file and dependency out loud; lead with deletion; question
  an over-complex request before writing a line of it; a `bd:min:` marker is **mandatory** for any
  non-obvious amount of code.

<!-- min:only ultra -->
### ULTRA extra-strictness
Before adding ANY file or dependency, write one line naming the rung (2–4) you first ruled out and
why. If you cannot, you are not yet at rung 6 — go back up the ladder.
<!-- /min:only -->

## ATTRIBUTION
Ladder adapted from **Ponytail** by Dietrich Gebert (MIT). Packaging, the `bd:min:` marker, the
mode/STATUS state, the PLAN/gate reconciliation, and the tests are this repository's house style.
