#!/usr/bin/env node
/*
 * minimalist-turn.js — UserPromptSubmit per-turn reminder for the `minimalist` plugin.
 *
 * Emits ONLY a COMPACT reminder (the 6 ladder rungs + the never-cut line) to STDOUT every turn, so the
 * least-code discipline stays salient without re-injecting the whole skill. Per-turn re-injection has a
 * real token cost (documented in Ponytail; on terse reasoning models it can cost more than it saves) —
 * so the SessionStart hook carries the FULL ladder, and this per-turn hook stays a few lines only.
 * mode=off -> emit NOTHING and exit 0. Reads the same mode file as the SessionStart injector.
 *
 * INJECTS CONTEXT ONLY (no gate decision). node-guarded + fail-quiet at the hooks.json layer; this
 * script also swallows every internal error so it can never block or slow a turn.
 */
'use strict';
const fs = require('fs');
const path = require('path');

const VALID = ['off', 'lite', 'full', 'ultra'];

function readMode() {
  try {
    const proj = process.env.CLAUDE_PROJECT_DIR || process.cwd();
    const v = fs.readFileSync(path.join(proj, '.claude', 'minimalist', 'mode'), 'utf8').trim().toLowerCase();
    return VALID.indexOf(v) >= 0 ? v : 'full';
  } catch (e) {
    return 'full';
  }
}

const REMINDER =
  '[minimalist] least-code reminder — stop at the FIRST rung that holds:\n' +
  '  1 need to exist at all? (YAGNI)   2 standard library?   3 native platform/runtime feature?\n' +
  '  4 already an installed dependency?   5 can it be one line?   6 the minimum code that works.\n' +
  'NEVER cut for brevity: input validation · error handling (data loss) · security · accessibility · ' +
  'anything the user asked to keep.\n';

try {
  if (readMode() === 'off') process.exit(0);                // fully silenced (load-bearing off-guard)
  process.stdout.write(REMINDER);
} catch (e) {
  // fail-quiet
}
process.exit(0);
