#!/usr/bin/env sh
# check-shared-sync.sh — verify every vendored plugin lib is byte-identical to the
# canonical shared/lib/common.sh. Prints a unified diff for any copy that drifted
# and exits non-zero; exits 0 when all copies are in sync.
#
# Pairs with sync-shared.sh: that script writes the copies, this one proves they
# never silently diverge (drift would mean one plugin runs stale shared logic).
# NOT errexit (F-A4): `-e` is dropped so a stray non-zero can't abort the scan; abort-on-real-failure
# is preserved EXPLICITLY — a missing/divergent copy sets rc=1 (the diff step below is already fully
# if/else-guarded) and the final `exit "$rc"` fails the gate, so removing `-e` never lets drift pass.
# `pipefail` is also DROPPED: it is a bash/ksh `set -o` option that POSIX sh/dash REJECT ("set: Illegal
# option -o pipefail") under this `#!/usr/bin/env sh` shebang — it would abort the gate before any work.
# No pipe here relies on it. Keep ONLY `-u` (nounset is POSIX-safe).
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")

SRC="$ROOT/shared/lib/common.sh"
[ -f "$SRC" ] || { echo "check-shared-sync: canonical lib missing: $SRC" >&2; exit 1; }

# Destinations are DERIVED from the SAME glob the auditor's D8 detector scans (plugins/*/lib/common.sh)
# and the sync-shared fixer writes, so the gate-checks / fixer-writes / D8-scans sets are TAUTOLOGICALLY
# identical — a vendored copy (e.g. minimalist) can never drift in one set yet be invisible to another
# (F-A1: the old hardcoded 6-list omitted minimalist, so this gate could read sync=0 while D8 flagged
# minimalist HIGH). A glob matches only EXISTING copies, so the unmatched-glob literal is skipped.
rc=0
for dest in "$ROOT"/plugins/*/lib/common.sh; do
  [ -e "$dest" ] || continue
  rel="${dest#"$ROOT"/}"
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
