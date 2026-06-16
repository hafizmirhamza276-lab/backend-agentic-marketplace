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
set -eu

# Resolve the repo root from THIS script's own location (robust to the caller's
# working directory): scripts/ lives directly under the repo root.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")

SRC="$ROOT/shared/lib/common.sh"
[ -f "$SRC" ] || { echo "sync-shared: canonical lib not found: $SRC" >&2; exit 1; }

# One vendored destination per plugin, each under the plugin's OWN root so the
# plugin never reaches outside itself at runtime.
DESTS="$ROOT/plugins/builder/lib/common.sh $ROOT/plugins/explorer/lib/common.sh $ROOT/plugins/pipeline/lib/common.sh"

for dest in $DESTS; do
  mkdir -p "$(dirname "$dest")"
  cp "$SRC" "$dest"
  echo "synced: shared/lib/common.sh -> ${dest#"$ROOT"/}"
done
