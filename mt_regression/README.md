# Marten MT (`-Dpreview_mt`) concurrency regression harness

These reproduce and guard against data races found under Crystal multithreading. They are **not**
part of `crystal spec` (that suite is compiled single-threaded); they are standalone programs
compiled with `-Dpreview_mt` and run with `CRYSTAL_WORKERS>=4`.

## Prerequisite
`shard.override.yml` must point `db` at the fixed crystal-db fork (the connection-pool
double-checkout fix), otherwise the transaction harness is confounded by that upstream bug:

```yaml
dependencies:
  db:
    path: /Users/stephen/work/apps/crystal/crystal-db
```

## Run everything (patched PASS + negative controls FAIL)
```
CRYSTAL_WORKERS=8 mt_regression/run.sh
```
`run.sh` builds each harness, runs it against the patched tree (must PASS), then reverts the
relevant source file and reruns (negative control — must FAIL/crash, killed after 45s), then
restores. This proves each lock is *load-bearing*, not merely window-narrowing.

## The harnesses
| File | Guards | Patched | Negative control (lock removed) |
|------|--------|---------|---------------------------------|
| `cache_lost_update.cr` | `Cache::Store::Memory#increment` atomicity | 50/50 rounds exact (32000/32000) | ~4000/32000, fails 50/50 |
| `cache_structural.cr` | `@data` Hash structural safety | 20 rounds, no crash | SIGSEGV / livelock (killed) |
| `tx_hash.cr` | `Connection::Base#@transactions` hash safety + observer-raises leak (gap #3) | clean + post-raise healthy | livelock / corruption (killed) |

Each harness with a clean positive control (`cache_lost_update`) also confirms the *test itself*
has the statistical power to detect the race at the chosen scale (the unsynchronized control loses
updates in ~50/50 rounds).

## Related: crystal-db pool regression
The upstream pool fix has its own MT regression test in the fork at
`spec/pool_mt_spec.cr` — run `CRYSTAL_WORKERS=8 crystal spec -Dpreview_mt spec/pool_mt_spec.cr`.
Fixed pool → 0 violations (pass); stock pool → double-checkout detected (fail).

## Notes / known limitations
- `Cache::Store::Base#fetch` (used by the `{% cache %}` tag) is **not** made atomic by these
  patches: the underlying Hash ops are now safe (no corruption), but a cache *stampede* (N fibers
  recomputing on concurrent miss) is unchanged — that's what `race_condition_ttl` is for. Heap
  safety ✓, logical single-flight ✗.
- The cache patch gives **structural** Hash safety, not atomicity of compound operations
  (`read`+`delete` on expiry, `process_entry_expiry`). Only `increment`/`decrement` are atomic.
- DB access under `-Dpreview_mt` requires BOTH the Marten `@transactions` mutex AND the crystal-db
  pool fix; neither alone is sufficient.
