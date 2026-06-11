# MT regression: Template::Loader::Cached#@templates_cache structural safety.
#
# Build & run:  crystal build -Dpreview_mt -o /tmp/tmpl_cache mt_regression/template_cache.cr
#               CRYSTAL_WORKERS=8 /tmp/tmpl_cache
#
# When `config.templates.cached = true` (the recommended production setting) a single Cached loader
# lives in the shared Marten.templates.loaders and every concurrent request fiber renders through it.
# get_template does a bare `@templates_cache[name] = template`, so concurrent first-renders mutate a
# shared Hash with no lock -> heap corruption under -Dpreview_mt.
#
# Negative control: remove the @mutex from src/marten/template/loader/cached.cr and rerun -> crash.
# (run.sh automates that toggle.)
require "../src/marten"

spawn do
  sleep 60.seconds
  STDERR.puts "WATCHDOG: timed out -> livelock (corruption symptom)"
  Process.exit(98)
end

# In-memory inner loader so the test needs no template files on disk; compiling the source widens
# the race window (real first-render work).
class MemLoader < Marten::Template::Loader::Base
  def get_template_source(template_name) : String
    "Hello {{ name }} from #{template_name}"
  end
end

FIBERS = 8
OPS    = 5_000
ROUNDS = 15

ROUNDS.times do |round|
  cached = Marten::Template::Loader::Cached.new([MemLoader.new] of Marten::Template::Loader::Base)
  done = Channel(String?).new
  FIBERS.times do
    spawn do
      err = nil.as(String?)
      begin
        OPS.times { |i| cached.get_template("t#{i}") } # overlapping keys -> concurrent read+write+grow
      rescue ex
        err = "#{ex.class}: #{ex.message}"
      end
      done.send(err)
    end
  end
  crashes = [] of String
  FIBERS.times { if e = done.receive; crashes << e end }
  unless crashes.empty?
    puts "TEMPLATE-CACHE: FAIL round #{round} -> #{crashes.first}"
    exit 1
  end
end

puts "workers=#{ENV["CRYSTAL_WORKERS"]? || "1"} fibers=#{FIBERS} ops=#{OPS} rounds=#{ROUNDS}"
puts "TEMPLATE-CACHE: PASS (#{ROUNDS} rounds, no crash)"
exit 0
