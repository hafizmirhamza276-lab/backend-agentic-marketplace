#!/usr/bin/env sh
# sync-shared.sh — vendor the canonical shared lib into EACH plugin.
#
# A Claude Code plugin is installed/sourced ONLY from its own `source` dir, so it
# cannot `source` a sibling folder at runtime. The shared shell lib must therefore
# be VENDORED (copied) into every plugin's own lib/. This script is the single
# place that copy happens; re-run it whenever shared/lib/common.sh changes.
#
# POSIX sh. Byte-exact copy: the canonical is LF (enforced by .gitattributes:
# `*.sh text eol=lf`) and `cp` preserves the bytes, so each vendored copy is LF
# too. Idempotent — running it twice is a no-op on disk. Prints what it copied.
# NOT errexit (F-A4): `-e` is dropped so a stray non-zero can't abort mid-sync; the critical copy is
# guarded explicitly below, so removing `-e` never lets a FAILED copy pass silently (the gate would
# then read drift as in-sync). `-u`/`pipefail` are kept.
set -uo pipefail

# Resolve the repo root from THIS script's own location (robust to the caller's
# working directory): scripts/ lives directly under the repo root.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")

SRC="$ROOT/shared/lib/common.sh"
[ -f "$SRC" ] || { echo "sync-shared: canonical lib not found: $SRC" >&2; exit 1; }

# One vendored destination per plugin, each under the plugin's OWN root so the plugin never reaches
# outside itself at runtime. Destinations are DERIVED from the SAME glob the auditor's D8 detector
# scans (plugins/*/lib/common.sh) and the check-shared-sync gate verifies — NOT a hardcoded list
# (which omitted minimalist, so a synced canonical left minimalist's copy stale and D8 fired forever,
# F-A1). Deriving all three from the one glob makes the fixer-writes / gate-checks / D8-scans sets
# TAUTOLOGICALLY identical. A glob matches only EXISTING copies, so the unmatched-glob literal (a tree
# with no plugin libs yet) is skipped rather than written as a bogus path.
for dest in "$ROOT"/plugins/*/lib/common.sh; do
  [ -e "$dest" ] || continue
  mkdir -p "$(dirname "$dest")" || { echo "sync-shared: cannot create dir for $dest" >&2; exit 1; }
  cp "$SRC" "$dest"             || { echo "sync-shared: copy FAILED: $SRC -> $dest" >&2; exit 1; }
  echo "synced: shared/lib/common.sh -> ${dest#"$ROOT"/}"
done
