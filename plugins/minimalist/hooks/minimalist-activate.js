#!/usr/bin/env node
/*
 * minimalist-activate.js — SessionStart injector for the `minimalist` plugin.
 *
 * Reads the intensity mode from ${CLAUDE_PROJECT_DIR}/.claude/minimalist/mode (default "full"); for
 * mode=off it emits NOTHING and exits 0. Otherwise it reads the ladder skill
 * (skills/minimal-code/SKILL.md), strips the YAML frontmatter, filters to the active intensity, and
 * writes it to STDOUT — SessionStart injects STDOUT into Claude's context, so the FULL ladder lands
 * once per session.
 *
 * This hook INJECTS CONTEXT ONLY — it makes NO gate decision (every gate in this marketplace stays
 * pure shell/awk). node is OPTIONAL: the hooks.json command is node-guarded and fail-quiet, and this
 * script additionally swallows every internal error, so a missing skill / unreadable mode / any throw
 * can never block or slow a session.
 *
 * NOTE on the hooks.json wiring: the POSIX command places the node guard BEFORE the invocation
 * (`command -v node ... || exit 0; node "${CLAUDE_PLUGIN_ROOT}"/hooks/minimalist-activate.js`) rather
 * than the trailing-`|| exit 0` Ponytail form, on purpose — the auditor's D6 hook-contract parser
 * keeps everything AFTER `${CLAUDE_PLUGIN_ROOT}` as the script path, so a trailing `|| exit 0` would
 * corrupt the resolved path and trip a false HIGH. Guard-before keeps the path the final token.
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
    return 'full'; // no mode file yet -> default full
  }
}

/*
 * render: strip the leading YAML frontmatter (first `--- ... ---` block) and apply intensity filtering.
 * A block fenced by `<!-- min:only <modes> -->` ... `<!-- /min:only -->` is kept ONLY when the active
 * mode is listed in <modes> (comma/space separated); everything outside a fence is always kept. So
 * `full` ships the whole ladder minus the ultra-only extras, and `ultra` ships those too.
 */
function render(body, mode) {
  const text = String(body).replace(/^﻿?---\r?\n[\s\S]*?\r?\n---\r?\n/, '');
  const out = [];
  let skip = false;
  text.split(/\r?\n/).forEach(function (line) {
    const open = line.match(/<!--\s*min:only\s+([^>]*?)\s*-->/);
    if (open) { skip = open[1].toLowerCase().split(/[\s,]+/).indexOf(mode) < 0; return; }
    if (/<!--\s*\/min:only\s*-->/.test(line)) { skip = false; return; }
    if (!skip) out.push(line);
  });
  return out.join('\n').replace(/\n{3,}/g, '\n\n').trim();
}

try {
  const mode = readMode();
  if (mode === 'off') process.exit(0);                      // fully silenced (load-bearing off-guard)
  const root = process.env.CLAUDE_PLUGIN_ROOT || path.join(__dirname, '..');
  const ladder = render(fs.readFileSync(path.join(root, 'skills', 'minimal-code', 'SKILL.md'), 'utf8'), mode);
  if (ladder) {
    process.stdout.write(
      '[minimalist] mode=' + mode + ' — write the LEAST code that fully works (skill: minimal-code). ' +
      'Always-on; toggle with /minimize off|lite|full|ultra.\n\n' + ladder + '\n'
    );
  }
} catch (e) {
  // fail-quiet: never block or slow the session
}
process.exit(0);
