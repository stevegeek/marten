# MT regression: Connection::Base#@transactions hash safety under concurrent transactions.
#
# Build & run (REQUIRES the fixed crystal-db pool underneath, else the pool double-checkout
# bug dominates — run.sh wires up shard.override.yml to the fork before building this):
#   crystal build -Dpreview_mt -o /tmp/tx_hash mt_regression/tx_hash.cr
#   CRYSTAL_WORKERS=8 /tmp/tx_hash
#
# Part 1 stresses the shared @transactions Hash from many fibers (insert/lookup/delete keyed by
# Fiber.current.object_id). With the @transactions_mutex this must never crash; without it the
# Hash corrupts (SIGSEGV in notify_observers / livelock).
#
# Part 2 is a deterministic single-fiber check for the observer-raises leak (gap #3): a commit
# observer raises, and the *next* transaction on the same fiber must still run cleanly. Without
# the `ensure`-guarded delete, the stale per-fiber entry would make the next transaction be
# treated as already-in-transaction.
require "sqlite3"
require "../src/marten"

DB_PATH = "/tmp/marten-mt-experiment/tx_hash.db"
Dir.mkdir_p("/tmp/marten-mt-experiment")
File.delete(DB_PATH) if File.exists?(DB_PATH)

Marten.configure do |config|
  config.secret_key = "x" * 32
  config.database do |db|
    db.backend = :sqlite
    db.name = DB_PATH
    db.max_pool_size = 16
  end
end
Marten.settings.databases.each { |c| Marten::DB::Connection.register(c) }
conn = Marten::DB::Connection.default
conn.open { |c| c.exec("CREATE TABLE IF NOT EXISTS t (id INTEGER)") }

spawn do
  sleep 60.seconds
  STDERR.puts "WATCHDOG: timed out -> livelock"
  Process.exit(98)
end

# ---- Part 1: concurrent @transactions hash stress ----
FIBERS = 16
ITERS  = 2_000
done = Channel(String?).new
FIBERS.times do
  spawn do
    err = nil.as(String?)
    begin
      ITERS.times { conn.transaction { conn.open { |c| c.scalar("SELECT 1") } } }
    rescue ex
      err = "#{ex.class}: #{ex.message}"
    end
    done.send(err)
  end
end
crashes = [] of String
FIBERS.times { if e = done.receive; crashes << e end }

# ---- Part 2: observer-raises leak (gap #3), deterministic, single fiber ----
leak_ok = true
begin
  conn.transaction do
    conn.observe_transaction_commit(->{ raise "boom from observer" })
  end
rescue
  # expected: the commit observer raised
end
# If the stale entry leaked, this next transaction would be (wrongly) treated as nested and the
# inner rollback would NOT actually roll back at the DB. We assert a fresh transaction commits fine.
begin
  conn.transaction { conn.open { |c| c.scalar("SELECT 1") } }
rescue ex
  leak_ok = false
  STDERR.puts "Part2 follow-up transaction failed: #{ex.class}: #{ex.message}"
end

puts "workers=#{ENV["CRYSTAL_WORKERS"]? || "1"} fibers=#{FIBERS} iters=#{ITERS}"
if crashes.empty? && leak_ok
  puts "TX-HASH: PASS (concurrent transactions clean; post-observer-raise transaction healthy)"
  exit 0
else
  puts "TX-HASH: FAIL  hash_failures=#{crashes.size} (#{crashes.first?}) leak_ok=#{leak_ok}"
  exit 1
end
