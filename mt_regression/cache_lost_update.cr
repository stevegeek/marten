# MT regression: Cache::Store::Memory increment atomicity (lost-update race).
#
# Build & run:  crystal build -Dpreview_mt -o /tmp/cache_lu mt_regression/cache_lost_update.cr
#               CRYSTAL_WORKERS=8 /tmp/cache_lu
#
# Asserts the PATCHED Memory store loses zero increments across many high-contention rounds.
# Includes a POSITIVE CONTROL (an unsynchronized counter) so we can see the test actually has
# the statistical power to detect lost updates at this fiber/iteration scale — if the control
# does NOT lose updates, the test parameters are too weak and a green store result is meaningless.
require "../src/marten"

# Without the fix, the unsynchronized store can livelock (Hash corruption) instead of crashing;
# guard so the negative-control run can't hang the suite.
spawn do
  sleep 60.seconds
  STDERR.puts "WATCHDOG: timed out -> livelock (corruption symptom)"
  Process.exit(98)
end

FIBERS = 16
PER    = 2_000
ROUNDS = 50
EXPECTED = FIBERS * PER

# ---- positive control: deliberately unsynchronized read-modify-write on a shared Int ----
class Counter
  property v = 0
end

def run_control : Int32
  box = Counter.new
  done = Channel(Nil).new
  FIBERS.times { spawn { PER.times { box.v = box.v + 1 }; done.send(nil) } }
  FIBERS.times { done.receive }
  box.v
end

# ---- the actual subject: Marten's patched Memory store ----
def run_store : Int32
  store = Marten::Cache::Store::Memory.new
  done = Channel(Nil).new
  FIBERS.times { spawn { PER.times { store.increment("counter") }; done.send(nil) } }
  FIBERS.times { done.receive }
  store.read("counter").try(&.to_i) || 0
end

control_lost_rounds = 0
ROUNDS.times { control_lost_rounds += 1 if run_control != EXPECTED }

store_failures = [] of Int32
ROUNDS.times do
  v = run_store
  store_failures << v if v != EXPECTED
end

puts "workers=#{ENV["CRYSTAL_WORKERS"]? || "1"} fibers=#{FIBERS} per=#{PER} rounds=#{ROUNDS} expected=#{EXPECTED}"
puts "CONTROL (no lock): lost updates in #{control_lost_rounds}/#{ROUNDS} rounds  -> #{control_lost_rounds > 0 ? "OK (test has power)" : "WEAK (raise FIBERS/PER!)"}"
if store_failures.empty?
  puts "STORE   (patched): PASS  (#{ROUNDS}/#{ROUNDS} rounds exact)"
  exit 0
else
  puts "STORE   (patched): FAIL  (#{store_failures.size}/#{ROUNDS} rounds wrong; e.g. #{store_failures.first}/#{EXPECTED})"
  exit 1
end
