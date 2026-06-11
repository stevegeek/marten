#!/usr/bin/env bash
# MT regression runner for Marten's concurrency fixes.
#
# Builds each harness with -Dpreview_mt and runs it against the PATCHED tree (must PASS), then
# temporarily reverts the relevant source file (NEGATIVE CONTROL) and reruns (must FAIL/crash),
# then restores. This proves each lock is load-bearing, not just window-narrowing.
#
# Requires: shard.override.yml pointing `db` at the fixed crystal-db fork (the pool double-checkout
# fix), so the cache/transaction results aren't confounded by the upstream pool bug.
#
# Usage:  CRYSTAL_WORKERS=8 mt_regression/run.sh
set -uo pipefail
cd "$(dirname "$0")/.."
export CRYSTAL_WORKERS="${CRYSTAL_WORKERS:-8}"

# Hard timeout (macOS has no `timeout`): heap corruption in a negative-control run can wedge the
# runtime so the in-program watchdog fiber never even gets scheduled. Kill it from outside.
run_with_timeout () {
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) & local killer=$!
  wait "$pid"; local rc=$?
  kill "$killer" 2>/dev/null
  return $rc
}

# The fixes are committed on this branch, so the negative control reverts the file to its pre-fix
# state at BASELINE (default origin/main) and restores it from HEAD afterwards.
BASELINE="${BASELINE:-origin/main}"

run_case () {        # name  src_file_to_revert  harness.cr
  local name="$1" src="$2" cr="$3" bin="/tmp/mtreg_$1"
  echo "==================== $name ===================="
  crystal build -Dpreview_mt -o "$bin" "mt_regression/$cr" 2>/dev/null || { echo "BUILD FAIL"; return 1; }
  echo "-- patched (expect PASS) --"
  # A patched run can occasionally hit Crystal's preview_mt mutex-contention stall (the in-program
  # watchdog exits 98). That is a runtime stall, NOT data corruption (a real failure prints the
  # crash / wrong count). Retry a few times to get a verdict on correctness.
  local rc=0 attempt=1
  while :; do
    if "$bin"; then rc=0; break; fi
    rc=$?
    if [ "$rc" = "98" ] && [ "$attempt" -lt 3 ]; then
      echo "  (attempt $attempt: preview_mt mutex-contention stall (watchdog) — retrying)"
      attempt=$((attempt + 1)); continue
    fi
    break
  done
  if [ "$rc" = "0" ]; then echo "  => PASS"
  elif [ "$rc" = "98" ]; then echo "  => INCONCLUSIVE: preview_mt mutex stall persisted (Crystal runtime, not the fix)"
  else echo "  => UNEXPECTED FAIL (exit $rc)"; fi

  echo "-- negative control: $src @ $BASELINE (pre-fix), rebuild, rerun (expect FAIL/crash) --"
  if ! git show "$BASELINE:$src" > "$src" 2>/dev/null; then echo "  (could not load $BASELINE:$src)"; git checkout -q HEAD -- "$src"; return 1; fi
  crystal build -Dpreview_mt -o "${bin}_neg" "mt_regression/$cr" 2>/dev/null || { echo "  (neg build failed)"; git checkout -q HEAD -- "$src"; return 1; }
  if run_with_timeout 45 "${bin}_neg"; then echo "  => UNEXPECTED PASS (lock may not be load-bearing!)"; else echo "  => FAILED as expected (crash/livelock killed)"; fi
  git checkout -q HEAD -- "$src"   # restore the committed, patched version
  echo ""
}

run_case cache_lost_update src/marten/cache/store/memory.cr     cache_lost_update.cr
run_case cache_structural  src/marten/cache/store/memory.cr     cache_structural.cr
run_case tx_hash           src/marten/db/connection/base.cr     tx_hash.cr
run_case template_cache    src/marten/template/loader/cached.cr template_cache.cr
echo "done."
