#!/usr/bin/env sh
# check-shared-sync.sh — verify every vendored plugin lib is byte-identical to the
# canonical shared/lib/common.sh. Prints a unified diff for any copy that drifted
# and exits non-zero; exits 0 when all copies are in sync.
#
# Pairs with sync-shared.sh: that script writes the copies, this one proves they
# never silently diverge (drift would mean one plugin runs stale shared logic).
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")

SRC="$ROOT/shared/lib/common.sh"
[ -f "$SRC" ] || { echo "check-shared-sync: canonical lib missing: $SRC" >&2; exit 1; }

DESTS="$ROOT/plugins/builder/lib/common.sh $ROOT/plugins/explorer/lib/common.sh $ROOT/plugins/pipeline/lib/common.sh"

rc=0
for dest in $DESTS; do
  rel="${dest#"$ROOT"/}"
  if [ ! -f "$dest" ]; then
    echo "DRIFT: vendored copy missing: $rel  (run scripts/sync-shared.sh)"
    rc=1
    continue
  fi
  if diff -u "$SRC" "$dest" >/dev/null 2>&1; then
    echo "ok: $rel in sync"
  else
    echo "DRIFT: $rel differs from shared/lib/common.sh:"
    diff -u "$SRC" "$dest" || true
    rc=1
  fi
done

if [ "$rc" -ne 0 ]; then
  echo "check-shared-sync: vendored libs are OUT OF SYNC. Run: scripts/sync-shared.sh" >&2
fi
exit "$rc"
