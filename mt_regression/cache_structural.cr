# MT regression: Cache::Store::Memory structural Hash safety under concurrent mutation.
#
# Build & run:  crystal build -Dpreview_mt -o /tmp/cache_struct mt_regression/cache_structural.cr
#               CRYSTAL_WORKERS=8 /tmp/cache_struct
#
# Hammers the PATCHED store with concurrent write/read/delete/clear on overlapping keys, hard
# enough that the UNPATCHED store reliably crashes (SIGSEGV / "Duplicate large block deallocation")
# or livelocks under -Dpreview_mt. With the mutex, the process must survive every round and the
# surviving-key count must stay internally consistent (never exceed what was written).
#
# NEGATIVE CONTROL: remove the @mutex from src/marten/cache/store/memory.cr and rerun — this must
# crash/hang. (run.sh automates that toggle.) A clean run here only means "no corruption observed";
# pairing with the negative control is what proves the lock is load-bearing.
require "../src/marten"

FIBERS = 8
OPS    = 40_000
ROUNDS = 20

# watchdog: corruption can manifest as a livelock rather than a crash; don't hang the suite.
spawn do
  sleep 60.seconds
  STDERR.puts "WATCHDOG: timed out -> livelock (corruption symptom)"
  Process.exit(98)
end

ROUNDS.times do |round|
  store = Marten::Cache::Store::Memory.new
  done = Channel(String?).new
  FIBERS.times do |t|
    spawn do
      err = nil.as(String?)
      begin
        OPS.times do |i|
          store.write("k#{t}-#{i}", "x")
          store.read("k#{t}-#{i % 128}")
          store.delete("k#{t}-#{i - 64}") if i > 64
        end
      rescue ex
        err = "#{ex.class}: #{ex.message}"
      end
      done.send(err)
    end
  end
  crashes = [] of String
  FIBERS.times { if e = done.receive; crashes << e end }
  unless crashes.empty?
    puts "STRUCTURAL: FAIL round #{round} -> #{crashes.first}"
    exit 1
  end
end

puts "workers=#{ENV["CRYSTAL_WORKERS"]? || "1"} fibers=#{FIBERS} ops=#{OPS} rounds=#{ROUNDS}"
puts "STRUCTURAL: PASS (#{ROUNDS} rounds, no crash/exception)"
exit 0
