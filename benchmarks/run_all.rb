#!/usr/bin/env ruby
# frozen_string_literal: true
#
# benchmarks/run_all.rb — Run all available adapters against all csv_files/
#
# The SmarterCSV version used is the highest in BenchmarkConfig::SMARTER_CSV_VERSIONS.
# Gemfile.lock is irrelevant — the version is taken from config/benchmark.rb.
#
# Saves raw timing results to results/YYYY-MM-DD_HHMM_rubyX.Y.Z.raw.json.
# To format results into Markdown tables, run:
#   ruby benchmarks/format_results.rb
#
# Usage:
#   ruby benchmarks/run_all.rb
#   bundle exec ruby benchmarks/run_all.rb

require "benchmark"
require "fileutils"
require "json"
require "tmpdir"
require "csv"

# ── Ctrl-C handling ──────────────────────────────────────────────────────────
#
# First Ctrl-C: set $shutdown_requested. The version and adapter loops both
# check this flag at iteration boundaries and break out, so the ensure blocks
# still run and partial results are saved.
# Second Ctrl-C: hard exit. Useful when the current subprocess is hung.
$shutdown_requested = false
Signal.trap("INT") do
  if $shutdown_requested
    $stderr.puts "\n\nSecond interrupt — force exiting."
    Process.exit!(130)
  end
  $shutdown_requested = true
  $stderr.puts "\n\nInterrupt received — finishing current step and saving partial results... (Ctrl-C again to force exit)"
end

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(root)

zsv_lib = File.join(Dir.home, "GitHub", "zsv-ruby", "lib")
$LOAD_PATH.unshift(zsv_lib) if Dir.exist?(zsv_lib) && !$LOAD_PATH.include?(zsv_lib)

require_relative "../config/benchmark"
require_relative "../tools/merge_helpers"
require_relative "progress"
require_relative "eta"

# ── Parameters ────────────────────────────────────────────────────────────────

SMARTER_CSV_VERSIONS = BenchmarkConfig::SMARTER_CSV_VERSIONS
HIGHEST_VERSION      = SMARTER_CSV_VERSIONS.max_by { |v| Gem::Version.new(v) }
WARMUP               = BenchmarkConfig::WARMUP
ITERATIONS           = BenchmarkConfig::ITERATIONS
FILE_OPTIONS         = BenchmarkConfig::FILE_OPTIONS

# ── Preflight: verify all configured SmarterCSV versions are installed ───────
#
# Shells out to `gem list --exact smarter_csv` via Bundler.with_unbundled_env
# so we see the system gem index, not whatever Gemfile.lock has pinned. Aborts
# with an install hint if anything is missing, and flags prerelease versions
# (which won't be published on rubygems.org until released).

def installed_smarter_csv_versions
  output = if defined?(Bundler)
    Bundler.with_unbundled_env { `gem list --exact smarter_csv` }
  else
    `gem list --exact smarter_csv`
  end

  if (m = output.match(/^smarter_csv \(([^)]+)\)/))
    m[1].split(",").map(&:strip)
  else
    []
  end
end

unless SMARTER_CSV_VERSIONS.empty?
  installed = installed_smarter_csv_versions
  missing   = SMARTER_CSV_VERSIONS - installed

  unless missing.empty?
    $stderr.puts "ERROR: SmarterCSV versions listed in config/benchmark.rb are not installed:"
    missing.each do |v|
      $stderr.puts "  - #{v}   →   gem install smarter_csv -v #{v}"
    end
    $stderr.puts
    $stderr.puts "Installed: #{installed.empty? ? '(none)' : installed.join(', ')}"
    exit 1
  end

  prereleases = SMARTER_CSV_VERSIONS.select { |v| Gem::Version.new(v).prerelease? }
  unless prereleases.empty?
    $stderr.puts "Note: prerelease versions (not yet published on rubygems.org): " \
                 "#{prereleases.join(', ')}"
  end
end

# ── CSV file list ─────────────────────────────────────────────────────────────

CSV_FILES = (
  Dir[File.join(root, "csv_files", "actual",    "*.{csv,tsv}")] +
  Dir[File.join(root, "csv_files", "synthetic", "*.{csv,tsv}")]
).sort

if CSV_FILES.empty?
  warn "No CSV files found in csv_files/actual/ or csv_files/synthetic/."
  exit 1
end

def count_rows(filepath)
  n = 0
  File.foreach(filepath) { n += 1 }
  [n - 1, 0].max
end

ROW_COUNTS = CSV_FILES.each_with_object({}) do |fp, h|
  h[File.basename(fp)] = count_rows(fp)
end.freeze

# ── Load adapters ─────────────────────────────────────────────────────────────
#
# Loaded up front so the ETA estimator (below) can determine which adapters
# actually run in-process per file. The version-benchmark and adapter-benchmark
# loops further down both depend on ADAPTERS being defined here.

require "adapters/ruby_csv/csv_read"
require "adapters/ruby_csv/csv_hashes"
require "adapters/ruby_csv/csv_table"
require "adapters/smarter_csv/default"
require "adapters/smarter_csv/ruby_path"
require "adapters/zsv/zsv_raw"
require "adapters/zsv/zsv_wrapped"

ADAPTER_REGISTRY = {
  "ruby_csv/csv_read"     => Adapters::RubyCSV::CsvRead.new,
  "ruby_csv/csv_hashes"   => Adapters::RubyCSV::CsvHashes.new,
  "ruby_csv/csv_table"    => Adapters::RubyCSV::CsvTable.new,
  "smarter_csv/default"   => Adapters::SmarterCSVAdapter::Default.new,
  "smarter_csv/ruby_path" => Adapters::SmarterCSVAdapter::RubyPath.new,
  "zsv/zsv_raw"           => Adapters::ZSV::ZsvRaw.new,
  "zsv/zsv_wrapped"       => Adapters::ZSV::ZsvWrapped.new,
}.freeze

ALL_ADAPTERS = BenchmarkConfig::ADAPTERS.filter_map { |key| ADAPTER_REGISTRY[key] }.freeze
ADAPTERS     = ALL_ADAPTERS.select(&:available?)

ALL_ADAPTERS.reject(&:available?).each { |a| warn "SKIP: #{a.name} (not available)" }

# ── Determine cached vs to-be-run versions ───────────────────────────────────
#
# A version is loaded from cache if results/smarter_csv_<version>.json exists
# and isn't being force-recomputed. Computed once here and reused by both the
# ETA estimator and the version-benchmark loop further down.
#
# Override at runtime:
#   RECOMPUTE_VERSIONS=1.14.4,1.15.2 rake bench
#   RECOMPUTE_VERSIONS=all rake bench

recompute_env = ENV.fetch("RECOMPUTE_VERSIONS", "").split(",").map(&:strip)
recompute_all = recompute_env.include?("all")

versions_to_run = SMARTER_CSV_VERSIONS.reject do |version|
  canonical_path = File.join(root, "results", "smarter_csv_#{version}.json")
  !recompute_all && !recompute_env.include?(version) && File.exist?(canonical_path)
end

# ── Runtime estimate from prior run ──────────────────────────────────────────

in_process_per_file = CSV_FILES.each_with_object({}) do |fp, h|
  filename  = File.basename(fp)
  file_opts = FILE_OPTIONS.fetch(filename, {})
  h[filename] = ADAPTERS.reject { |a|
    a.is_a?(Adapters::SmarterCSVAdapter::Default) ||
      a.is_a?(Adapters::SmarterCSVAdapter::RubyPath) ||
      !a.accepts?(**file_opts)
  }.map(&:name)
end

eta = EtaEstimator.new(
  results_dir: File.join(root, "results"),
  warmup:      WARMUP,
  iterations:  ITERATIONS
).estimate(
  in_process_per_file: in_process_per_file,
  versions_to_run:     versions_to_run
)

total_start = Time.now
estimated_end = nil

if eta
  total_str = EtaEstimator.format(eta[:total_seconds])
  ver_str   = EtaEstimator.format(eta[:version_seconds])
  ada_str   = EtaEstimator.format(eta[:adapter_seconds])
  estimated_end = total_start + eta[:total_seconds]
  $stderr.puts "Estimated runtime: ~#{total_str}   (version phase #{ver_str}, adapter phase #{ada_str})   est. end: #{estimated_end.strftime('%Y-%m-%d %H:%M:%S')}"
  $stderr.puts "  Per-version sources:"
  eta[:per_version_sources].each { |v, src| $stderr.puts "    #{v.ljust(15)} ← #{src}" }
  eta[:missing_versions].each do |v|
    fb = eta[:fallback_used][v]
    msg = fb ? "estimated from closest available: #{fb}" : "no fallback available"
    $stderr.puts "    #{v.ljust(15)} ← (no historical data; #{msg})"
  end
else
  $stderr.puts "Estimated runtime: (no prior raw runs in results/)"
end

$stderr.puts "Start time: #{total_start.strftime('%Y-%m-%d %H:%M:%S')}"

# ── Multi-version SmarterCSV benchmarking ─────────────────────────────────────
#
# Each version runs in a fresh Ruby subprocess (via system) so that multiple
# gem versions can be activated without conflict. Results written to a temp
# JSON file and read back by the parent.

version_timings  = {}
cached_versions  = []   # versions whose timings were loaded from canonical cache (not freshly measured)

unless SMARTER_CSV_VERSIONS.empty?
  # ── Version ordering — reduce ordering bias ────────────────────────────────
  # Across multiple `rake bench` runs, randomized order ensures each version
  # gets, on average, similar conditions (cache state, thermal level, OS
  # scheduler luck). Without shuffling, versions later in the fixed order
  # systematically run on a hotter/more-loaded machine.
  #
  # BENCH_ORDER=random   (default) — fresh random shuffle
  # BENCH_ORDER=fixed              — config order (also: BENCH_SHUFFLE=0)
  # BENCH_ORDER=reverse            — reversed config order
  # BENCH_SEED=NNN                 — reproducible random shuffle (use with BENCH_ORDER=random)
  order_mode = ENV["BENCH_ORDER"] || (ENV["BENCH_SHUFFLE"] == "0" ? "fixed" : "random")
  iteration_order = SMARTER_CSV_VERSIONS.dup
  bench_seed = nil

  case order_mode
  when "random"
    if iteration_order.size > 1
      bench_seed = (ENV["BENCH_SEED"] || Random.new_seed).to_i
      iteration_order.shuffle!(random: Random.new(bench_seed))
      $stderr.puts "Version order: random (seed: #{bench_seed}; BENCH_SEED=N to reproduce)"
    else
      $stderr.puts "Version order: single version, no shuffling needed"
    end
  when "fixed"
    $stderr.puts "Version order: fixed (config order)"
  when "reverse"
    iteration_order.reverse!
    $stderr.puts "Version order: reversed config order"
  else
    warn "WARNING: unknown BENCH_ORDER=#{order_mode.inspect}; falling back to config order"
  end
  $stderr.puts "  #{iteration_order.join(' → ')}"
  version_run_order = iteration_order.dup

  zsv_lib_line = Dir.exist?(zsv_lib) ? "$LOAD_PATH.unshift(#{zsv_lib.inspect})" : ""

  iteration_order.each do |version|
    break if $shutdown_requested
    canonical_path = File.join(root, "results", "smarter_csv_#{version}.json")

    if !recompute_all && !recompute_env.include?(version) && File.exist?(canonical_path)
      cached = JSON.parse(File.read(canonical_path))
      version_timings[version] = cached.dig("version_timings", version) || {}
      cached_versions << version
      $stderr.puts "  SmarterCSV #{version}... loaded from #{File.basename(canonical_path)}"
      next
    end

    tmp_path = File.join(Dir.tmpdir, "csv_bench_ver_#{version}_#{Process.pid}.json")
    progress_path = File.expand_path("progress.rb", __dir__)

    script = <<~RUBY
      require "benchmark"
      require "json"
      require #{progress_path.inspect}
      #{zsv_lib_line}

      begin
        gem "smarter_csv", #{version.inspect}
      rescue Gem::MissingSpecVersionError, Gem::LoadError => e
        File.write(#{tmp_path.inspect}, JSON.generate({ version: #{version.inspect}, error: e.message, timings: {} }))
        exit 1
      end

      require "smarter_csv"

      csv_files    = JSON.parse(#{JSON.generate(CSV_FILES).inspect})
      file_options = JSON.parse(#{JSON.generate(FILE_OPTIONS.transform_keys(&:to_s).transform_values { |v| v.transform_keys(&:to_s) }).inspect})
      row_counts   = JSON.parse(#{JSON.generate(ROW_COUNTS).inspect})
      warmup       = #{WARMUP}
      iterations   = #{ITERATIONS}
      total_iter   = 2 * (warmup + iterations)
      timings      = {}

      csv_files.each_with_index do |filepath, i|
        filename  = File.basename(filepath)
        file_opts = (file_options[filename] || {}).transform_keys(&:to_sym)
        rows      = row_counts[filename] || 0

        progress = BenchmarkProgress.new(
          file_index: i + 1,
          total_files: csv_files.size,
          filename: filename,
          rows: rows,
          total_iterations: total_iter,
          label: "  SmarterCSV #{version}"
        )
        progress.start

        begin
          warmup.times { SmarterCSV.process(filepath, file_opts); progress.tick }
          c_samples = iterations.times.map do
            GC.start; GC.compact rescue nil
            t = Benchmark.realtime { SmarterCSV.process(filepath, file_opts) }
            progress.tick
            t
          end

          rb_opts = file_opts.merge(acceleration: false)
          warmup.times { SmarterCSV.process(filepath, rb_opts); progress.tick }
          rb_samples = iterations.times.map do
            GC.start; GC.compact rescue nil
            t = Benchmark.realtime { SmarterCSV.process(filepath, rb_opts) }
            progress.tick
            t
          end

          timings[filename] = { c_samples: c_samples, rb_samples: rb_samples }
          progress.done
        rescue StandardError => e
          $stderr.puts "\\n    ERROR on \#{filename}: \#{e.message}"
          timings[filename] = { c_samples: [], rb_samples: [] }
        end
      end

      File.write(#{tmp_path.inspect}, JSON.generate({ version: #{version.inspect}, timings: timings }))
    RUBY

    script_path = File.join(Dir.tmpdir, "csv_bench_ver_#{version}_#{Process.pid}.rb")
    File.write(script_path, script)
    exit_ok = if defined?(Bundler)
      Bundler.with_unbundled_env { system(RbConfig.ruby, script_path) }
    else
      system(RbConfig.ruby, script_path)
    end
    exit_status = $?.exitstatus

    begin
      data = JSON.parse(File.read(tmp_path))
      if data["error"] || !exit_ok
        reason = data["error"] || "subprocess exited with status #{exit_status}"
        warn "  SmarterCSV #{version}... FAILED: #{reason}"
        version_timings[version] = {}
      else
        version_timings[version] = data["timings"] || {}
        if version_timings[version].empty?
          $stderr.puts "  SmarterCSV #{version}... WARNING: empty timings"
        end
      end
    rescue StandardError => e
      warn "  SmarterCSV #{version}... FAILED to read results: #{e.message}"
      version_timings[version] = {}
    ensure
      FileUtils.rm_f(tmp_path)
      FileUtils.rm_f(script_path)
    end
  end
end

# ── Validate timings for SmarterCSV adapters ──────────────────────────────────
#
# The smarter_csv/* adapters do NOT execute against the in-process SmarterCSV
# loaded via Bundler — that would measure whatever Gemfile.lock resolved, not
# the version specified in config/benchmark.rb. Instead, their timings are
# sourced from version_timings[HIGHEST_VERSION], which was measured above in
# an isolated subprocess with the configured version activated via inline
# gem(). HIGHEST_VERSION must be present in SMARTER_CSV_VERSIONS.

smarter_in_adapters = BenchmarkConfig::ADAPTERS.any? { |k| k.start_with?("smarter_csv/") }

if smarter_in_adapters && HIGHEST_VERSION
  hv_timings = version_timings[HIGHEST_VERSION]
  if hv_timings.nil? || hv_timings.empty?
    abort "ERROR: smarter_csv adapter benchmarks require version_timings[#{HIGHEST_VERSION.inspect}] " \
          "to be populated. Ensure #{HIGHEST_VERSION} is in SMARTER_CSV_VERSIONS in config/benchmark.rb."
  end
end

# ── Helpers ───────────────────────────────────────────────────────────────────

def timed_run(adapter, filepath, opts = {}, &progress)
  WARMUP.times do
    adapter.call(filepath, **opts)
    progress&.call
  end
  ITERATIONS.times.map do
    GC.start
    GC.compact rescue nil
    t = Benchmark.realtime { adapter.call(filepath, **opts) }
    progress&.call
    t
  end
end

def format_duration(seconds)
  total = seconds.round
  h, rem = total.divmod(3600)
  m, s = rem.divmod(60)
  if h > 0
    "#{h}h #{m}m #{s}s"
  elsif m > 0
    "#{m}m #{s}s"
  else
    "#{seconds.round(1)}s"
  end
end

# ── Run adapter benchmarks ────────────────────────────────────────────────────
#
# The adapter loop and JSON write are wrapped in begin/ensure so that even on
# crash or Ctrl-C, partial results (and the already-computed version_timings)
# are flushed to disk. Losing a multi-hour run because of a late-stage error
# is unacceptable.

results = {}

begin
  $stderr.puts "(no adapters configured — skipping in-process adapter loop)" if ADAPTERS.empty?

  CSV_FILES.each_with_index do |filepath, i|
    break if $shutdown_requested
    filename  = File.basename(filepath)
    rows      = ROW_COUNTS[filename]
    results[filename] = { _rows: rows }

    # No adapters configured: still record _rows so format_results has row
    # counts for version-comparison tables, but skip per-file adapter work.
    next if ADAPTERS.empty?

    file_opts = FILE_OPTIONS.fetch(filename, {})

    in_process = ADAPTERS.reject do |a|
      a.is_a?(Adapters::SmarterCSVAdapter::Default) ||
        a.is_a?(Adapters::SmarterCSVAdapter::RubyPath) ||
        !a.accepts?(**file_opts)
    end

    progress = BenchmarkProgress.new(
      file_index:       i + 1,
      total_files:      CSV_FILES.size,
      filename:         filename,
      rows:             rows,
      total_iterations: in_process.size * (WARMUP + ITERATIONS)
    )
    progress.start
    tick = progress.method(:tick)

    ADAPTERS.each do |adapter|
      unless adapter.accepts?(**file_opts)
        results[filename][adapter.name] = { time_samples: [], rows_per_sec: nil }
        next
      end

      # SmarterCSV adapters: source samples from version_timings[HIGHEST_VERSION]
      # (measured in a subprocess with the configured gem version activated via
      # inline gem()). Do NOT call the in-process adapter — it would measure the
      # version Bundler resolved from Gemfile.lock, which may differ from config.
      #
      # The version cell may carry either single-run shape (c_samples) when the
      # version was measured fresh this session, or multi-run shape (c_runs)
      # when it was loaded from a canonical cache. Propagate whichever is there.
      case adapter
      when Adapters::SmarterCSVAdapter::Default, Adapters::SmarterCSVAdapter::RubyPath
        path = adapter.is_a?(Adapters::SmarterCSVAdapter::Default) ? "c" : "rb"
        cell = version_timings.dig(HIGHEST_VERSION, filename) || {}
        adapter_cell = { rows_per_sec: nil }
        if cell["#{path}_runs"].is_a?(Array) && !cell["#{path}_runs"].empty?
          adapter_cell[:time_runs] = cell["#{path}_runs"]
        elsif cell["#{path}_samples"].is_a?(Array) && !cell["#{path}_samples"].empty?
          adapter_cell[:time_samples] = cell["#{path}_samples"]
        end
        t = MergeHelpers.cell_value(cell, path)
        adapter_cell[:rows_per_sec] = t ? rows / t : nil
        results[filename][adapter.name] = adapter_cell
        next
      end

      begin
        samples = timed_run(adapter, filepath, file_opts, &tick)
        t = MergeHelpers.within_run_stat(samples)
        results[filename][adapter.name] = { time_samples: samples, rows_per_sec: t ? rows / t : nil }
      rescue StandardError => e
        warn "\n  ERROR running #{adapter.name} on #{filename}: #{e.message}"
        results[filename][adapter.name] = { time_samples: [], rows_per_sec: nil }
      end
    end

    progress.done
  end
ensure
  # ── Save JSON (skip when interrupted by Ctrl-C) ─────────────────────────────
  if $shutdown_requested
    $stderr.puts "Interrupted: skipping JSON write and symlink update."
  else
    begin
      smarter_version = HIGHEST_VERSION || (defined?(SmarterCSV) ? (SmarterCSV::VERSION rescue "?") : "?")
      csv_version     = (defined?(CSV) ? (CSV::VERSION rescue "?") : "?")
      zsv_version     = (defined?(ZSV) ? (ZSV::VERSION rescue "n/a") : "n/a")

      FileUtils.mkdir_p(File.join(root, "results"))
      timestamp = Time.now.strftime("%Y-%m-%d_%H%M")
      ruby_tag  = "ruby#{RUBY_VERSION}"

      json_path = File.join(root, "results", "#{timestamp}_#{ruby_tag}.raw.json")
      File.write(json_path, JSON.pretty_generate(
        ruby:                   RUBY_VERSION,
        platform:               RUBY_PLATFORM,
        smarter_csv:            smarter_version,
        csv:                    csv_version,
        zsv:                    zsv_version,
        warmup:                 WARMUP,
        iterations:             ITERATIONS,
        timestamp:              Time.now.strftime("%Y-%m-%d %H:%M:%S"),
        total_elapsed_seconds:  (Time.now - total_start).round(1),
        adapter_labels:         (ADAPTERS rescue []).each_with_object({}) { |a, h| h[a.name] = a.label },
        smarter_csv_versions:   SMARTER_CSV_VERSIONS,
        bench_seed:             (bench_seed rescue nil),
        version_run_order:      (version_run_order rescue []),
        cached_versions:        (cached_versions rescue []),
        version_timings:        (version_timings rescue {}),
        results:                (results rescue {})
      ))
      $stderr.puts "JSON saved to: #{json_path}"

      symlink_path = File.join(root, "results", "latest.json")
      File.delete(symlink_path) if File.symlink?(symlink_path)
      File.symlink(File.basename(json_path), symlink_path)
      $stderr.puts "Symlink updated: results/latest.json -> #{File.basename(json_path)}"
    rescue StandardError => write_err
      warn "ERROR writing results JSON: #{write_err.class}: #{write_err.message}"
      warn write_err.backtrace.first(10).join("\n") if write_err.backtrace
    end
  end

  actual_end = Time.now
  $stderr.puts ""
  $stderr.puts "Start time:     #{total_start.strftime('%Y-%m-%d %H:%M:%S')}"
  $stderr.puts "Est. end time:  #{estimated_end ? estimated_end.strftime('%Y-%m-%d %H:%M:%S') : '(no estimate)'}"
  $stderr.puts "Actual end:     #{actual_end.strftime('%Y-%m-%d %H:%M:%S')}"
  $stderr.puts "Total elapsed:  #{format_duration(actual_end - total_start)}"
end
