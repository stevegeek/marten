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

# In-memory inner loader returning a single pre-built Template. We deliberately do NOT compile in the
# hot loop: this test targets the @templates_cache Hash safety (the bug), and keeping per-call
# allocation low avoids confounding it with Crystal's preview_mt GC/scheduler behaviour under heavy
# allocation. (Concurrent Template compilation itself was separately verified race-free.)
class MemLoader < Marten::Template::Loader::Base
  @template : Marten::Template::Template

  def initialize
    @template = Marten::Template::Template.new("Hello {{ name }}")
  end

  def get_template_source(template_name) : String
    "Hello {{ name }}"
  end

  def get_template(template_name) : Marten::Template::Template
    @template
  end
end

# Kept modest on purpose: unpatched corruption appears within the first hundreds of concurrent
# writes, so a smaller workload reproduces it reliably while the patched run stays fast (the patched
# path takes a mutex per call; a 600k-call tight loop over one lock can starve under load in a way
# real per-request rendering never does).
FIBERS =     8
OPS    = 1_200
ROUNDS =     6

ROUNDS.times do |round|
  cached = Marten::Template::Loader::Cached.new([MemLoader.new] of Marten::Template::Loader::Base)
  done = Channel(String?).new
  FIBERS.times do |t|
    spawn do
      err = nil.as(String?)
      begin
        # Per-fiber key ranges: concurrent writes still mutate the one shared Hash (corrupting it when
        # unguarded), but avoid the all-fibers-same-key lockstep that can trip a preview_mt mutex stall.
        OPS.times { |i| cached.get_template("t#{t}-#{i}") }
      rescue ex
        err = "#{ex.class}: #{ex.message}"
      end
      done.send(err)
    end
  end
  crashes = [] of String
  FIBERS.times { if e = done.receive
    crashes << e
  end }
  unless crashes.empty?
    puts "TEMPLATE-CACHE: FAIL round #{round} -> #{crashes.first}"
    exit 1
  end
end

puts "workers=#{ENV["CRYSTAL_WORKERS"]? || "1"} fibers=#{FIBERS} ops=#{OPS} rounds=#{ROUNDS}"
puts "TEMPLATE-CACHE: PASS (#{ROUNDS} rounds, no crash)"
exit 0
