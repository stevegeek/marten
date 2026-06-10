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

run_case () {        # name  src_file_to_revert  harness.cr
  local name="$1" src="$2" cr="$3" bin="/tmp/mtreg_$1"
  echo "==================== $name ===================="
  crystal build -Dpreview_mt -o "$bin" "mt_regression/$cr" 2>/dev/null || { echo "BUILD FAIL"; return 1; }
  echo "-- patched (expect PASS) --"
  if "$bin"; then echo "  => PASS"; else echo "  => UNEXPECTED FAIL (exit $?)"; fi

  echo "-- negative control: revert $src, rebuild, rerun (expect FAIL/crash) --"
  git stash push -q -- "$src"
  crystal build -Dpreview_mt -o "${bin}_neg" "mt_regression/$cr" 2>/dev/null || { echo "  (neg build failed)"; git stash pop -q; return 1; }
  if run_with_timeout 45 "${bin}_neg"; then echo "  => UNEXPECTED PASS (lock may not be load-bearing!)"; else echo "  => FAILED as expected (exit $? ; crash/livelock killed)"; fi
  git stash pop -q
  echo ""
}

run_case cache_lost_update src/marten/cache/store/memory.cr     cache_lost_update.cr
run_case cache_structural  src/marten/cache/store/memory.cr     cache_structural.cr
run_case tx_hash           src/marten/db/connection/base.cr     tx_hash.cr
echo "done."
